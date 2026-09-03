;;;; memory/write.lisp -- record, record an absence, retract.
;;;; Spec SS4-5: supersession closes validity; correction closes
;;;; transaction time; RECORD-BELIEF never retracts.

(in-package #:cl-llm.memory)

(define-condition belief-argument-error (error)
  ((argument :initarg :argument :reader belief-argument-error-argument)
   (value :initarg :value :reader belief-argument-error-value)
   (reason :initarg :reason :reader belief-argument-error-reason))
  (:report (lambda (c s)
             (format s "~a ~s: ~a"
                     (belief-argument-error-argument c)
                     (belief-argument-error-value c)
                     (belief-argument-error-reason c)))))

(define-condition belief-successor-before-predecessor (error)
  ((predecessor :initarg :predecessor :reader bsbp-predecessor)
   (start :initarg :start :reader bsbp-start))
  (:report (lambda (c s)
             (format s "a successor must start after its predecessor ~
                        (~a); to say the predecessor was wrong, ~
                        RETRACT-BELIEF it" (bsbp-start c)))))

(defun %arg-error (argument value reason)
  (error 'belief-argument-error
         :argument argument :value value :reason reason))

(defun %check-endpoint (argument pair)
  "(namespace-keyword . key-string), the namespace canonical -- the rule
SPLIT-CITE applies on the way back, so no belief is written whose own
cite cannot resolve (#32)."
  (unless (and (consp pair) (keywordp (car pair)) (stringp (cdr pair)))
    (%arg-error argument pair
                "must be (namespace-keyword . key-string)"))
  (unless (st:canonical-relation-p (string-downcase
                                    (symbol-name (car pair))))
    (%arg-error argument pair "namespace must be canonical [a-z0-9-]")))

(defun %check-producer (producer)
  (unless (st:canonical-producer-p producer)
    (%arg-error :producer producer
                "required; a canonical string [a-z0-9-/]")))

(defun %check-relation (relation)
  (unless (st:canonical-relation-p relation)
    (%arg-error :relation relation "a canonical string [a-z0-9-]")))

(defun %default-extent ()
  (te:make-interval (te:exact-bound (local-time:now))
                    (te:unknown-bound)
                    :semantics :validity :standing :asserted))

(defun %start-instant (claim)
  (te:bound-earliest (te:extent-start (st:claim-extent claim))))

(defun %open-p (claim)
  "Validity end unknown or unbounded -- the belief is still held.  A
claim with no validity extent at all is not \"still held\" in the
supersession sense: NIL (final review #14 unit 1 finding 2)."
  (let ((extent (st:claim-extent claim)))
    (and extent
         (let ((end (te:extent-end extent)))
           (or (te:bound-unknown-p end)
               (eq :unbounded (te:bound-latest end)))))))

(defun %series (graph producer subject relation)
  "Every claim -- both arities, retracted included -- one PRODUCER holds
on (SUBJECT, RELATION).  The engine indexes subject and producer, not
relation, so the relation filter is ours."
  (remove-if-not
   (lambda (c) (and (string= relation (st:claim-relation c))
                    (string= producer (st:claim-producer c))))
   (st:claims-touching graph 'belief (car subject) (cdr subject)
                       :role :subject)))

(defun %current-predecessor (graph producer subject relation)
  "The one open, current binary belief on the series, or NIL."
  (find-if (lambda (c) (and (typep c 'belief-binary)
                            (st:claim-current-p c)
                            (%open-p c)))
           (%series graph producer subject relation)))

(defun %close-validity (claim before)
  "Close CLAIM's validity 1 ns before BEFORE.  Intervals are closed and
:MEETS is not disjoint (manual ch. 18), so the end must precede the
successor's start strictly."
  (let* ((c (gdb:copy claim))
         (e (st:claim-extent c))
         (end (local-time:timestamp- before 1 :nsec)))
    (setf (st:claim-extent c)
          (te:make-interval (te:extent-start e) (te:exact-bound end)
                            :precision (te:extent-precision e)
                            :semantics :validity
                            :standing (te:extent-standing e)))
    (gdb:save c)
    c))

(defun %same-object-p (object pred)
  (and (string= (cdr object) (st:claim-object-key pred))
       (eq (car object) (st:claim-object-namespace pred))))

(defun record-belief (graph subject relation object
                      &key producer standing (extent (%default-extent))
                           confidence method rule-version)
  "Record that PRODUCER holds SUBJECT RELATION OBJECT, valid over
EXTENT (default [now, unknown)).  Returns the new BELIEF-BINARY -- or
the existing one when the same OBJECT is already held (idempotent).  A
different OBJECT currently held is SUPERSEDED: its validity closes just
before EXTENT's start, and both claims remain.  Never retracts.
Must run inside the caller's WITH-TRANSACTION."
  (%check-endpoint :subject subject)
  (%check-endpoint :object object)
  (%check-relation relation)
  (%check-producer producer)
  (unless (te:standing-present-p standing)
    (%arg-error :standing standing
                "a presence standing; absences go through RECORD-ABSENCE"))
  (let ((start (te:bound-earliest (te:extent-start extent)))
        (pred (%current-predecessor graph producer subject relation)))
    (when pred
      (cond ((%same-object-p object pred)
             (return-from record-belief pred))
            ((not (local-time:timestamp< (%start-instant pred) start))
             (error 'belief-successor-before-predecessor
                    :predecessor pred :start start))
            (t (%close-validity pred start))))
    (make-belief-binary
     :graph graph
     :subject-namespace (car subject) :subject-key (cdr subject)
     :relation relation
     :object-namespace (car object) :object-key (cdr object)
     :producer producer :standing standing :extent extent
     :confidence confidence :method method :rule-version rule-version)))

(defun %assert-from-file (graph subject relation object
                          &key producer method (extent (%default-extent)))
  "RECORD-BELIEF, but a file capture is truth (banners spec SS4): a
change RECORD-BELIEF can express as a supersession -- a different
OBJECT with a later validity start -- gets one, as always.  Anything
else that actually changed (the same OBJECT with a moved start or a
different METHOD; or a different OBJECT with a non-later start, which
RECORD-BELIEF would otherwise refuse) is a CORRECTION: the current
belief is wrong about when or what, so RETRACT-BELIEF it, then record
the file's current state fresh through RECORD-BELIEF, whose
predecessor lookup sees the retraction within this same transaction
(kraison/vivace-graph#324).  Must run inside the caller's
WITH-TRANSACTION."
  (let* ((start (te:bound-earliest (te:extent-start extent)))
         (pred (%current-predecessor graph producer subject relation)))
    (if (and pred
             (if (%same-object-p object pred)
                 (or (not (local-time:timestamp=
                           (%start-instant pred) start))
                     (string/= (or method "")
                              (or (st:claim-method pred) "")))
                 (not (local-time:timestamp< (%start-instant pred)
                                             start))))
        (progn
          (retract-belief pred)
          (record-belief graph subject relation object
                         :producer producer :standing :asserted
                         :method method :extent extent))
        (record-belief graph subject relation object
                       :producer producer :standing :asserted
                       :method method :extent extent))))

(defun record-absence (graph subject relation
                       &key producer standing
                            (extent (te:make-instant
                                     (te:exact-bound (local-time:now))
                                     :semantics :validity
                                     :standing :asserted)))
  "Record that PRODUCER looked for SUBJECT RELATION and STANDING says
what happened: :SEARCHED-EMPTY, :INDETERMINATE or :UNCOVERED.  EXTENT is
the search itself, an instant by default.  Returns the BELIEF-UNARY."
  (%check-endpoint :subject subject)
  (%check-relation relation)
  (%check-producer producer)
  (unless (member standing '(:searched-empty :indeterminate :uncovered))
    (%arg-error :standing standing
                "one of :searched-empty :indeterminate :uncovered"))
  (make-belief-unary
   :graph graph
   :subject-namespace (car subject) :subject-key (cdr subject)
   :relation relation
   :producer producer :standing standing :extent extent))

(defun retract-belief (claim &key (at (local-time:now)))
  "CLAIM was wrong: close its transaction period at AT and leave its
validity as recorded.  Only a BELIEF: a TRACE claim is a decision's own
record, not an opinion to withdraw (#14 unit 2 final review).  Signals
BELIEF-ARGUMENT-ERROR on a claim already retracted, because
RETRACT-CLAIM would silently do nothing."
  (unless (typep claim 'belief)
    (%arg-error :claim claim "only a belief can be retracted"))
  (unless (st:claim-current-p claim)
    (%arg-error :claim claim "already retracted"))
  (st:retract-claim claim :at at))
