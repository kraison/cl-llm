;;;; memory/recall.lisp -- read back by subject, bounded by validity,
;;;; with supersession and retraction visible.  Spec SS6.

(in-package #:cl-llm.memory)

(defstruct belief-record
  "One recalled claim plus what a caller would otherwise recompute
wrongly.  SUPERSEDED-BY is COMPUTED -- the next current claim in the
same (producer subject relation) series by validity start, in a store
no later in scope order (SS4, the trust rule) -- never stored, so it
cannot go stale.  OUTDATED-BY is the same question across producers
(#82): the latest-starting belief on this (subject relation) that is
current in its own series, when it starts strictly later than this one
and the trust rule allows it.  STORE is the graph the claim lives in;
SUPERSEDED-BY-STORE the successor's, OUTDATED-BY-STORE the leader's."
  claim
  (current-p nil)
  (superseded-by nil)
  (retracted-at nil)
  standing
  extent
  store
  (superseded-by-store nil)
  (outdated-by nil)
  (outdated-by-store nil))

(defun %retracted-at (claim)
  (let ((e (st:claim-transaction-extent claim)))
    (and e
         (not (st:claim-current-p claim))
         (let ((end (te:bound-latest (te:extent-end e))))
           (and (typep end 'local-time:timestamp) end)))))

(defun %recorded-at (claim)
  "A timestamp for ordering; a pre-axis claim sorts last."
  (let ((at (st:claim-recorded-at claim)))
    (if (typep at 'local-time:timestamp)
        at
        (local-time:unix-to-timestamp 0))))

(defun %series-key (claim)
  (list (st:claim-producer claim)
        (st:claim-subject-namespace claim)
        (st:claim-subject-key claim)
        (st:claim-relation claim)))

(defun %successor (claim series owner)
  "The earliest-starting current claim in SERIES that starts after
CLAIM and lives in a store no later in scope order than CLAIM's, or
NIL.  OWNER maps each claim to its store's position in the scope (SS4:
a lower-trust store never supersedes a higher one)."
  (let ((start (%start-instant claim))
        (pos (gethash claim owner))
        (best nil))
    (dolist (c series best)
      (when (and (not (eq c claim))
                 (st:claim-current-p c)
                 (<= (gethash c owner) pos)
                 (local-time:timestamp< start (%start-instant c))
                 (or (null best)
                     (local-time:timestamp< (%start-instant c)
                                            (%start-instant best))))
        (setf best c)))))

(defun %group-key (claim)
  "The currency group (#82): one (subject relation), every producer."
  (list (st:claim-subject-namespace claim)
        (st:claim-subject-key claim)
        (st:claim-relation claim)))

(defun %leads-p (a b owner)
  "A is the better leader of a group: a later validity start, else the
more trusted store, else the lower identity key -- a total order, so
the leader never depends on traversal order (#82)."
  (let ((sa (%start-instant a)) (sb (%start-instant b))
        (pa (gethash a owner)) (pb (gethash b owner)))
    (cond ((local-time:timestamp> sa sb) t)
          ((local-time:timestamp< sa sb) nil)
          ((/= pa pb) (< pa pb))
          (t (and (string< (st:claim-identity-key a)
                           (st:claim-identity-key b))
                  t)))))

(defun %group-leader (group series owner)
  "The leader of GROUP -- one (subject relation) across producers and
stores: the latest-starting belief among those current in their own
series, or NIL.  A retracted, closed or superseded belief never leads
(#82)."
  (let ((best nil))
    (dolist (c group best)
      (when (and (st:claim-current-p c)
                 (%open-p c)
                 (null (%successor c (gethash (%series-key c) series)
                                   owner))
                 (or (null best) (%leads-p c best owner)))
        (setf best c)))))

(defun %outdating (leader claim owner)
  "LEADER when it outdates CLAIM: a strictly later validity start, from
a store no later in scope order than CLAIM's (SS4's trust rule, as for
supersession).  Equal starts are a disagreement, not an outdating."
  (and leader
       (not (eq leader claim))
       (local-time:timestamp< (%start-instant claim)
                              (%start-instant leader))
       (<= (gethash leader owner) (gethash claim owner))
       leader))

(defun outdated-by (claim graph)
  "The belief in GRAPH that outdates CLAIM -- the leader of its
(subject relation) group across producers (#82) -- or NIL.  For a
caller holding one claim rather than a RECALL row: one store, so no
trust rule applies, at the cost of one CLAIMS-TOUCHING on the subject.
Trap: a retracted, closed or superseded CLAIM is never outdated, only
replaced in its own series."
  (let ((series (make-hash-table :test 'equal))
        (owner (make-hash-table :test 'eq))
        (group '()))
    (dolist (c (st:claims-touching graph 'belief
                                   (st:claim-subject-namespace claim)
                                   (st:claim-subject-key claim)
                                   :role :subject :current t))
      (setf (gethash c owner) 0)
      (push c (gethash (%series-key c) series))
      (when (string= (st:claim-relation claim) (st:claim-relation c))
        (push c group)))
    ;; The group's own object for CLAIM, not the caller's: EQ on two
    ;; reads of one node holds only while the engine's cache does.
    (let ((self (find (st:claim-identity-key claim) group
                      :key #'st:claim-identity-key :test #'string=)))
      (and self
           (%open-p self)
           (null (%successor self (gethash (%series-key self) series)
                             owner))
           (%outdating (%group-leader group series owner) self owner)))))

(defun %object-key-for-order (claim)
  (if (typep claim 'belief-binary) (st:claim-object-key claim) ""))

(defun %before-p (a b)
  "The order contract: validity start descending, RECORDED-AT descending,
object key ascending."
  (let ((sa (%start-instant a)) (sb (%start-instant b)))
    (cond ((local-time:timestamp> sa sb) t)
          ((local-time:timestamp< sa sb) nil)
          (t (let ((ra (%recorded-at a)) (rb (%recorded-at b)))
               (cond ((local-time:timestamp> ra rb) t)
                     ((local-time:timestamp< ra rb) nil)
                     (t (string< (%object-key-for-order a)
                                 (%object-key-for-order b)))))))))

(defun claim-before-p (a b)
  "T when claim A sorts before claim B under RECALL's order (SS6)."
  (%before-p a b))

(defun %producer-match-p (producer claim)
  "PRODUCER selects CLAIM: a name ending in \"/\" is a PREFIX, so
\"<agent>/<host>/\" answers for every instance on that host (#82);
any other name must match exactly."
  (let ((held (st:claim-producer claim))
        (n (length producer)))
    (if (and (plusp n) (char= #\/ (char producer (1- n))))
        (and (<= n (length held)) (string= producer held :end2 n))
        (string= producer held))))

(defun %recall-in (graph subject relation producer at include-retracted)
  "Today's single-store selection for GRAPH: (values WANTED ALL).  The
:AT membership test is EQL on claim objects, sound only within one
store (recon E4), so it stays here, before the union."
  (let* ((all (st:claims-touching graph 'belief (car subject)
                                  (cdr subject) :role :subject))
         ;; The engine's :AT is the validity filter (cl-temporal-extent#2
         ;; fixed the open-ended case it used to get wrong).
         (at-window (and at (st:claims-touching
                             graph 'belief (car subject) (cdr subject)
                             :role :subject :at at)))
         (wanted (remove-if-not
                  (lambda (c)
                    (and (or (null relation)
                             (string= relation (st:claim-relation c)))
                         (or (null producer)
                             (%producer-match-p producer c))
                         (or include-retracted (st:claim-current-p c))
                         (or (null at) (member c at-window))))
                  all)))
    (values wanted all)))

(defun recall (graph subject &key relation producer at include-retracted
                                  (scope (list graph)))
  "BELIEF-RECORDs about SUBJECT over SCOPE, ordered newest validity
first (SS6; SS4 for the scope).  RELATION and PRODUCER narrow the
series -- a PRODUCER ending in \"/\" is a prefix (#82); AT keeps only
beliefs valid at that instant; retracted claims are excluded unless
INCLUDE-RETRACTED.  Each record names its store; supersession and
OUTDATED-BY are computed over the whole scope under the trust rule,
the second across producers, and neither is narrowed by the filters.
Nothing recorded returns NIL -- which is not an absence standing."
  (%check-endpoint :subject subject)
  ;; GRAPH must be in SCOPE (SS3); :WRITE-STORE is the membership check.
  (check-scope scope :write-store graph)
  (with-scope-snapshots (scope)
    (let ((series (make-hash-table :test 'equal))
          (groups (make-hash-table :test 'equal))
          (leaders (make-hash-table :test 'equal))
          (owner (make-hash-table :test 'eq))
          (rows '()))
      ;; Store-major in scope order, then a stable sort: a genuine
      ;; cross-store tie breaks by scope order (agent SS6).
      (loop for g in scope
            for pos from 0
            do (multiple-value-bind (wanted all)
                   (%recall-in g subject relation producer at
                               include-retracted)
                 ;; Successors and leaders are found within the full
                 ;; series, so a claim outside the AT window -- or
                 ;; outside the PRODUCER filter, which is the point of
                 ;; the group (#82) -- can still be named.
                 (dolist (c all)
                   (setf (gethash c owner) pos)
                   (push c (gethash (%series-key c) series))
                   (push c (gethash (%group-key c) groups)))
                 (dolist (c (sort (copy-list wanted) #'%before-p))
                   (push (cons g c) rows))))
      (maphash (lambda (key group)
                 (setf (gethash key leaders)
                       (%group-leader group series owner)))
               groups)
      (loop for (g . c) in (stable-sort (nreverse rows) #'%before-p
                                        :key #'cdr)
            for succ = (%successor c (gethash (%series-key c) series)
                                   owner)
            for current = (and (st:claim-current-p c) (%open-p c)
                               (null succ))
            for leader = (and current
                              (%outdating (gethash (%group-key c) leaders)
                                          c owner))
            collect (make-belief-record
                     :claim c
                     :current-p current
                     :superseded-by succ
                     :superseded-by-store (and succ
                                               (nth (gethash succ owner)
                                                    scope))
                     :outdated-by leader
                     :outdated-by-store (and leader
                                             (nth (gethash leader owner)
                                                  scope))
                     :retracted-at (%retracted-at c)
                     :standing (st:claim-standing c)
                     :extent (st:claim-extent c)
                     :store g)))))
