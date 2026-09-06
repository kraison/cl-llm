;;;; memory/cite.lisp -- a claim as a string that survives regeneration,
;;;; and its resolution as of an instant or a commit epoch.  Spec
;;;; 2026-09-02 SS3, SS5; the epoch axis is S6b SS7 (#53).

(in-package #:cl-llm.memory)

(defun %family-parent-of (claim)
  "The registered parent class of CLAIM's family.  CLAIM-FAMILY is keyed
by the parent symbol only, so walk the precedence list until one
answers (an engine-side CLAIM-FAMILY-OF is asked for on
kraison/vivace-graph#321)."
  (dolist (class (sb-mop:class-precedence-list (class-of claim))
                 (%arg-error :claim claim "not a member of a claim family"))
    (let ((name (class-name class)))
      (when (and name (ignore-errors (st:claim-family name)))
        (return name)))))

(defun %render-family (symbol)
  (format nil "~(~a::~a~)"
          (package-name (symbol-package symbol)) (symbol-name symbol)))

(defun claim-cite (claim)
  "CLAIM as a cite: \"<pkg>::<parent>|<identity-key>\" (SS3)."
  (format nil "~a|~a" (%render-family (%family-parent-of claim))
          (st:claim-identity-key claim)))

(defun cite-p (x)
  (and (stringp x) (search "::" x) (position #\| x) t))

(defun %parse-family (string)
  (let ((sep (search "::" string)))
    (unless sep (%arg-error :cite string "no package-qualified family"))
    (let* ((pkg (find-package (string-upcase (subseq string 0 sep))))
           (sym (and pkg (find-symbol (string-upcase
                                       (subseq string (+ sep 2)))
                                      pkg))))
      (unless (and sym (ignore-errors (st:claim-family sym)))
        (%arg-error :cite string "names no registered claim family"))
      sym)))

(defun split-cite (cite)
  "Four values: the family's parent symbol, the subject namespace
keyword, the subject key, and the identity key.  A cite the engine did
not render is a BELIEF-ARGUMENT-ERROR.  The identity key's split, its
escape rule and the namespace rule -- canonical, THEN interned, so no
caller string can mint an unrecoverable keyword (#14 unit 2 final
review) -- are the engine's SPLIT-CLAIM-IDENTITY-KEY
(kraison/vivace-graph#321)."
  (unless (cite-p cite) (%arg-error :cite cite "not a cite"))
  (let* ((bar (position #\| cite))
         (family (%parse-family (subseq cite 0 bar)))
         (ikey (subseq cite (1+ bar))))
    (multiple-value-bind (producer namespace key)
        (handler-case (st:split-claim-identity-key ikey)
          (st:malformed-claim-identity-key ()
            (%arg-error :cite cite
                        "identity key is not one the engine rendered")))
      (declare (ignore producer))
      (values family namespace key ikey))))

(defstruct cite-record
  "One cite resolved AS OF an instant or a commit epoch (SS5, #53).
STATE is :RESOLVED, :REAPED or :ABSENT; CLAIM is the version believed
then when :RESOLVED.  CHANGED-SINCE is :RETRACTED, :SUPERSEDED,
:UPDATED or NIL.  STORE names the store the cite was actually resolved
against -- NIL when none was (SS4.3); RESOLVE-CITE fills it in, from
the first store in scope holding the identity (S6b SS6).
SUPERSEDED-BY is (cite . store-name) of the claim that superseded this
one from elsewhere in the scope, NIL otherwise (#53)."
  cite family (state :absent) claim standing extent changed-since store
  superseded-by)

(defun %stamp= (a b)
  "Version stamps by value: LOCAL-TIME:TIMESTAMP is a CLOS instance, so
EQUAL is EQ on it and the node cache can hand back one EQ instance for
two lookups of the same claim, passing vacuously.  A claim predating
the axis has a NIL stamp; two NILs match, one NIL is a change."
  (cond ((and (null a) (null b)) t)
        ((or (null a) (null b)) nil)
        (t (local-time:timestamp= a b))))

(defun %changed-since (as-of-version current)
  (cond ((and (st:claim-current-p as-of-version)
              (not (st:claim-current-p current)))
         :retracted)
        ((and (%open-p as-of-version) (not (%open-p current)))
         :superseded)
        ((not (%stamp= (st:claim-version-stamp as-of-version)
                       (st:claim-version-stamp current)))
         :updated)
        (t nil)))

(defun %current-among (ikey claims)
  "The claim in CLAIMS whose identity key is IKEY, preferring one still
current.  The key survives retraction and re-assertion
(kraison/vivace-graph#303), so retract-and-re-record of the identical
fact leaves two nodes on one key; anchoring on whichever the index
hands back first reported a held belief as :RETRACTED (#30)."
  (let ((matches (remove ikey claims :key #'st:claim-identity-key
                                     :test-not #'string=)))
    (or (find-if #'st:claim-current-p matches) (first matches))))

(defun %versions-on-axis (graph family ns key at epoch)
  "The subject's claims in GRAPH as of one axis: :AS-OF-EPOCH when EPOCH
is an integer, :AS-OF otherwise (#53).  The engine signals
ST:EPOCH-AXIS-UNAVAILABLE for an epoch read of a clockless store; only
a caller that passed an epoch reaches it, so it is not caught here."
  (if epoch
      (st:claims-touching graph family ns key :role :subject
                                              :as-of-epoch epoch)
      (st:claims-touching graph family ns key :role :subject :as-of at)))

(defun %recall-row (rows graph ikey)
  "The RECALL row for the current version of IKEY in GRAPH, under
%CURRENT-AMONG's preference -- the key survives retract-and-re-assert,
so one store can hold two nodes carrying it."
  (let ((matches (remove-if-not
                  (lambda (r)
                    (and (eq graph (belief-record-store r))
                         (string= ikey (st:claim-identity-key
                                        (belief-record-claim r)))))
                  rows)))
    (or (find-if (lambda (r)
                   (st:claim-current-p (belief-record-claim r)))
                 matches)
        (first matches))))

(defun %note-supersession (record graph scope)
  "RECORD amended when a store in SCOPE holds a claim superseding the
one it resolved to, under RECALL's trust rule (#53): CHANGED-SINCE
becomes :SUPERSEDED and SUPERSEDED-BY (cite . store-name).  Beliefs
only, and only where %CHANGED-SINCE found nothing and the claim is
still open: inside one store a supersession closes the predecessor's
validity, so only another store can hide one.  GRAPH is the store
RECORD resolved in.  Returns RECORD."
  (let ((claim (cite-record-claim record)))
    (when (and (rest scope)
               (eq :resolved (cite-record-state record))
               (eq 'belief (cite-record-family record))
               (null (cite-record-changed-since record))
               (%open-p claim))
      (let* ((rows (recall (first scope)
                           (cons (st:claim-subject-namespace claim)
                                 (st:claim-subject-key claim))
                           :relation (st:claim-relation claim)
                           :producer (st:claim-producer claim)
                           :include-retracted t :scope scope))
             (row (%recall-row rows graph (st:claim-identity-key claim)))
             (succ (and row (belief-record-superseded-by row))))
        (when succ
          (setf (cite-record-changed-since record) :superseded
                (cite-record-superseded-by record)
                (cons (claim-cite succ)
                      (store-name
                       (belief-record-superseded-by-store row)))))))
    record))

(defun resolve-cite (graph cite at &key epoch (scope (list graph)))
  "CITE as of AT, or of the commit :EPOCH (SS5, #53), in the first store
of SCOPE holding its identity (S6b SS6): find the claim by identity
among the subject's claims, then ask that store for the version
believed then.  Exactly one axis -- both or neither is a
BELIEF-ARGUMENT-ERROR, and an :EPOCH read of a clockless store is the
engine's ST:EPOCH-AXIS-UNAVAILABLE, a caller error.  Never substitutes
the current version -- it is consulted only for CHANGED-SINCE, which is
computed inside the resolving store, then amended for a supersession
elsewhere in SCOPE (%NOTE-SUPERSESSION).  STORE is filled on a resolved
or reaped record, NIL on an absent one.  A claim from a family with no
validity extent can only report CHANGED-SINCE :RETRACTED, :UPDATED or
NIL -- :SUPERSEDED needs %OPEN-P, which such a claim never satisfies.
Runs under the scope's snapshots and is refused inside an open write
transaction, like every reader (SS3)."
  (when (eq (null at) (null epoch))
    (%arg-error :epoch epoch "exactly one of AT and :EPOCH"))
  ;; GRAPH must be in SCOPE (SS3); :WRITE-STORE is the membership check.
  (check-scope scope :write-store graph)
  (with-scope-snapshots (scope)
    (multiple-value-bind (family ns key ikey) (split-cite cite)
      (let* ((current nil)
             ;; The GRAPH fallback is never dereferenced: CURRENT is NIL
             ;; then.
             (g (or (find-if (lambda (s)
                               (setf current
                                     (%current-among
                                      ikey (st:claims-touching s family ns
                                                               key
                                                               :role
                                                               :subject))))
                             scope)
                    graph))
             (id (and current (gdb:id current)))
             (then (and id
                        (find-if (lambda (c)
                                   (equalp id (if (st:reaped-claim-p c)
                                                  (st:reaped-claim-id c)
                                                  (gdb:id c))))
                                 (%versions-on-axis g family ns key
                                                    at epoch)))))
        (cond ((null then)
               (make-cite-record :cite cite :family family :state :absent))
              ((st:reaped-claim-p then)
               (make-cite-record :cite cite :family family :state :reaped
                                 :store (store-name g)))
              (t
               (%note-supersession
                (make-cite-record :cite cite :family family
                                  :state :resolved
                                  :claim then
                                  :standing (st:claim-standing then)
                                  :extent (st:claim-extent then)
                                  :changed-since
                                  (%changed-since then current)
                                  :store (store-name g))
                g scope)))))))
