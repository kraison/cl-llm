;;;; memory/recall.lisp -- read back by subject, bounded by validity,
;;;; with supersession and retraction visible.  Spec SS6.

(in-package #:cl-llm.memory)

(defstruct belief-record
  "One recalled claim plus what a caller would otherwise recompute
wrongly.  SUPERSEDED-BY is COMPUTED -- the next current claim in the
same (producer subject relation) series by validity start, in a store
no later in scope order (SS4, the trust rule) -- never stored, so it
cannot go stale.  STORE is the graph the claim lives in;
SUPERSEDED-BY-STORE the successor's."
  claim
  (current-p nil)
  (superseded-by nil)
  (retracted-at nil)
  standing
  extent
  store
  (superseded-by-store nil))

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
                             (string= producer (st:claim-producer c)))
                         (or include-retracted (st:claim-current-p c))
                         (or (null at) (member c at-window))))
                  all)))
    (values wanted all)))

(defun recall (graph subject &key relation producer at include-retracted
                                  (scope (list graph)))
  "BELIEF-RECORDs about SUBJECT over SCOPE, ordered newest validity
first (SS6; SS4 for the scope).  RELATION and PRODUCER narrow the
series; AT keeps only beliefs valid at that instant; retracted claims
are excluded unless INCLUDE-RETRACTED.  Each record names its store;
supersession is computed over the whole scope under the trust rule.
Nothing recorded returns NIL -- which is not an absence standing."
  (%check-endpoint :subject subject)
  (check-scope scope)
  (with-scope-snapshots (scope)
    (let ((series (make-hash-table :test 'equal))
          (owner (make-hash-table :test 'eq))
          (rows '()))
      ;; Store-major in scope order, then a stable sort: a genuine
      ;; cross-store tie breaks by scope order (agent SS6).
      (loop for g in scope
            for pos from 0
            do (multiple-value-bind (wanted all)
                   (%recall-in g subject relation producer at
                               include-retracted)
                 ;; Successors are found within the full series, so a
                 ;; claim outside the AT window can still be named as
                 ;; what superseded one inside.
                 (dolist (c all)
                   (setf (gethash c owner) pos)
                   (push c (gethash (%series-key c) series)))
                 (dolist (c (sort (copy-list wanted) #'%before-p))
                   (push (cons g c) rows))))
      (loop for (g . c) in (stable-sort (nreverse rows) #'%before-p
                                        :key #'cdr)
            for succ = (%successor c (gethash (%series-key c) series)
                                   owner)
            collect (make-belief-record
                     :claim c
                     :current-p (and (st:claim-current-p c) (%open-p c)
                                     (null succ))
                     :superseded-by succ
                     :superseded-by-store (and succ
                                               (nth (gethash succ owner)
                                                    scope))
                     :retracted-at (%retracted-at c)
                     :standing (st:claim-standing c)
                     :extent (st:claim-extent c)
                     :store g)))))
