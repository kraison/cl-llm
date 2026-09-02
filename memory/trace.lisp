;;;; memory/trace.lisp -- decisions as claims: CONCLUDE, TRACE,
;;;; DECISIONS-CITING.  Spec 2026-09-02 SS3-SS5.

(in-package #:cl-llm.memory)

(defstruct decision
  "What CONCLUDE returns (SS4).  OUTCOME is :CONCLUDED or :REFUSED; CLAIM
the belief or absence written (NIL when refused); REPORT the
VALIDATION-REPORT or the commit condition (NIL when concluded); AT the
outcome claim's RECORDED-AT."
  id outcome claim report at)

(defun %mint-id ()
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))

(defun %instant-now ()
  (te:make-instant (te:exact-bound (local-time:now))
                   :semantics :validity :standing :asserted))

;; No shared CLAIM class exists across families -- each parent from
;; DEF-CLAIM-CLASSES stands alone (kraison/vivace-graph#321).
;; %FAMILY-PARENT-OF (cite.lisp) answers for any registered family and
;; signals on a non-claim, so it doubles as the membership test here.
(defun %cite-of (x)
  (cond ((cite-p x) x)
        ((ignore-errors (%family-parent-of x)) (claim-cite x))
        (t (%arg-error :evidence x "a claim or a cite string"))))

(defun %check-proposal (proposal)
  "Argument errors surface before any transaction opens (SS4 step 1)."
  (unless (and (consp proposal) (member (first proposal) '(:belief :absence)))
    (%arg-error :proposal proposal "(:belief ...) or (:absence ...)"))
  (destructuring-bind (kind subject relation &rest more) proposal
    (%check-endpoint :subject subject)
    (%check-relation relation)
    (when (eq kind :belief)
      (%check-endpoint :object (first more)))))

(defun %stage (graph proposal producer rule rule-version confidence)
  "Run the tenant writer for PROPOSAL inside the open transaction."
  (destructuring-bind (kind subject relation &rest more) proposal
    (ecase kind
      (:belief
       (destructuring-bind (object &key (standing :inferred) extent) more
         (apply #'record-belief graph subject relation object
                :producer producer :standing standing
                :method rule :rule-version rule-version
                :confidence confidence
                (and extent (list :extent extent)))))
      (:absence
       (destructuring-bind (&key (standing :searched-empty) extent) more
         (apply #'record-absence graph subject relation
                :producer producer :standing standing
                (and extent (list :extent extent))))))))

(defun %trace-claim (graph id relation ns key producer standing
                     &key method rule-version confidence)
  (make-trace-binary
   :graph graph
   :subject-namespace :decision :subject-key id
   :relation relation
   :object-namespace ns :object-key key
   :producer producer :standing standing :extent (%instant-now)
   :method method :rule-version rule-version :confidence confidence))

(defun %write-evidence (graph id cites producer)
  (dolist (cite (remove-duplicates cites :test #'string=))
    (%trace-claim graph id "evidence" :claim cite producer :observed)))

(define-condition %refused (error)
  ((report :initarg :report :reader %refused-report))
  (:documentation "Unwinds CONCLUDE's transaction without committing
(SS4 step 2); never escapes CONCLUDE."))

(defun %staged-writes ()
  "The open transaction's delta, for VALIDATE-WRITES.  Internal reader;
export asked on kraison/vivace-graph#320."
  (graph-db::writes gdb:*transaction*))

(defun %violation-families (report-or-condition)
  "(family . text) per violation, first per family, in family order."
  (let ((rows (if (typep report-or-condition 'gdb:validation-report)
                  (loop for (family nil detail)
                          in (gdb:validation-report-violations
                              report-or-condition)
                        collect (cons (string-downcase (symbol-name family))
                                      (princ-to-string detail)))
                  (list (cons "commit"
                              (princ-to-string report-or-condition))))))
    (sort (remove-duplicates rows :key #'car :test #'string= :from-end t)
          #'string< :key #'car)))

(defun %write-refusal (graph id report cites producer)
  "A fresh transaction recording the refusal (SS4 step 2/3)."
  (let ((outcome nil))
    (gdb:with-transaction (:graph graph)
      (dolist (row (%violation-families report))
        (setf outcome
              (%trace-claim graph id "refused" :violation (car row)
                            producer :observed :method (cdr row))))
      (%write-evidence graph id cites producer))
    (make-decision :id id :outcome :refused :report report
                   :at (st:claim-recorded-at outcome))))

(defun conclude (graph proposal
                 &key producer evidence rule rule-version confidence)
  "Decide PROPOSAL from EVIDENCE under RULE (SS4).  Owns its
transaction; signals BELIEF-ARGUMENT-ERROR when one is already open.
Returns a DECISION -- a refusal is RETURNED as one with :OUTCOME
:REFUSED and REPORT set, never signalled."
  (when gdb:*transaction*
    (%arg-error :transaction gdb:*transaction*
                "CONCLUDE owns its transaction; call it outside one"))
  (%check-producer producer)
  (unless (stringp rule) (%arg-error :rule rule "a string naming the rule"))
  (%check-proposal proposal)
  (let ((id (%mint-id))
        (cites (mapcar #'%cite-of evidence))
        (claim nil) (outcome nil))
    (handler-case
        (progn
          (gdb:with-transaction (:graph graph)
            (setf claim (%stage graph proposal producer rule rule-version
                                confidence))
            (let ((report (gdb:validate-writes graph (%staged-writes))))
              (when (gdb:validation-report-violations report)
                (error '%refused :report report)))
            (setf outcome
                  (%trace-claim graph id "concluded" :claim
                                (claim-cite claim) producer :inferred
                                :method rule :rule-version rule-version
                                :confidence confidence))
            (%write-evidence graph id cites producer))
          (make-decision :id id :outcome :concluded :claim claim
                         :at (st:claim-recorded-at outcome)))
      (%refused (c)
        (%write-refusal graph id (%refused-report c) cites producer))
      (gdb:constraint-violation (c)
        ;; The report is advisory (SS2); the commit is the enforcement.
        (%write-refusal graph id c cites producer)))))
