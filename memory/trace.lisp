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
  "CITE-P only checks shape; SPLIT-CITE actually parses, so call it to
catch a malformed cite here -- before CONCLUDE's transaction opens --
rather than later, when TRACE would signal on the whole decision
(final review #14 unit 1 finding 1)."
  (cond ((cite-p x) (split-cite x) x)
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

(defun %claim-store (claim)
  "The name of the store holding CLAIM, or NIL.  RESOLVE-NODE-GRAPH is
the engine's only route from a node to its store and is internal
(noted on kraison/vivace-graph#322)."
  (let ((g (graph-db::resolve-node-graph (gdb:id claim))))
    (and g (store-name g))))

(defun %evidence-of (x write-store)
  "(cite . store-name) for one EVIDENCE item (SS4.2): a cite string
means WRITE-STORE; a (cite . store) pair passes through; a claim
resolves its own store, falling back to WRITE-STORE."
  (cond ((cite-p x) (cons (progn (split-cite x) x) write-store))
        ((and (consp x) (cite-p (car x)) (stringp (cdr x)))
         (split-cite (car x))
         x)
        ((ignore-errors (%family-parent-of x))
         (cons (claim-cite x) (or (%claim-store x) write-store)))
        (t (%arg-error :evidence x
                       "a claim, a cite string, or (cite . store)"))))

(defun %write-evidence (graph id pairs producer)
  ;; :FROM-END T: the first store recorded for a repeated cite wins,
  ;; matching %VIOLATION-FAMILIES' first-per-family rule.
  (dolist (pair (remove-duplicates pairs :key #'car :test #'string=
                                   :from-end t))
    (%trace-claim graph id "evidence" :claim (car pair) producer :observed
                  :method (cdr pair))))

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

(defun %write-refusal (graph id report pairs producer)
  "A fresh transaction recording the refusal (SS4 step 2/3)."
  (let ((outcome nil))
    (gdb:with-transaction (:graph graph)
      (dolist (row (%violation-families report))
        (setf outcome
              (%trace-claim graph id "refused" :violation (car row)
                            producer :observed :method (cdr row))))
      (%write-evidence graph id pairs producer))
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
        (pairs (mapcar (lambda (e) (%evidence-of e (store-name graph)))
                       evidence))
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
            (%write-evidence graph id pairs producer))
          (make-decision :id id :outcome :concluded :claim claim
                         :at (st:claim-recorded-at outcome)))
      (%refused (c)
        (%write-refusal graph id (%refused-report c) pairs producer))
      (gdb:constraint-violation (c)
        ;; The report is advisory (SS2); the commit is the enforcement.
        (%write-refusal graph id c pairs producer)))))

(defstruct decision-record
  "TRACE's answer (SS5).  CONCLUSION is a CITE-RECORD or NIL; EVIDENCE a
list of CITE-RECORDs in cite order; REFUSALS (family . text) in family
order."
  id producer at rule rule-version confidence outcome
  conclusion evidence refusals)

(defun %decision-claims (graph id)
  (st:claims-touching graph 'trace :decision id :role :subject))

(defun %recorded-instant (claim)
  "RECORDED-AT as a TIMESTAMP; a trace claim always has one."
  (let ((at (st:claim-recorded-at claim)))
    (unless (typep at 'local-time:timestamp)
      (%arg-error :claim claim "a trace claim with no recorded-at"))
    at))

(defun %store-in-scope (name scope)
  (find name scope :key #'store-name :test #'string=))

(defun %resolve-in (cite store-name graph scope at)
  "CITE resolved in the store its evidence claim named, when that store
is in SCOPE; unit-1 evidence (no store) resolves in GRAPH; a store out
of scope is :ABSENT (SS4.3).  The record's STORE is the store actually
resolved against, so a cite held by two stores reports the one this
decision named -- not whichever a cache saw first (#14 unit 2 final
review)."
  (let ((g (if store-name (%store-in-scope store-name scope) graph)))
    (if g
        (let ((r (resolve-cite g cite at)))
          (setf (cite-record-store r) (store-name g))
          r)
        (make-cite-record :cite cite :state :absent))))

(defun trace (graph decision-id &key (scope (list graph)))
  "The decision DECISION-ID reconstructed as of its own instant (SS5),
or NIL when no such decision was recorded.  Each evidence cite
resolves in the store it names, when that store is in SCOPE (SS4.3)."
  (let* ((claims (%decision-claims graph decision-id))
         (outcome (find-if (lambda (c)
                             (member (st:claim-relation c)
                                     '("concluded" "refused")
                                     :test #'string=))
                           claims)))
    (when outcome
      (let* ((at (%recorded-instant outcome))
             (concluded (and (string= "concluded" (st:claim-relation outcome))
                             outcome))
             (evidence (sort (mapcar (lambda (c)
                                       (cons (st:claim-object-key c)
                                             (st:claim-method c)))
                                     (remove "evidence" claims
                                             :key #'st:claim-relation
                                             :test-not #'string=))
                             #'string< :key #'car))
             (refusals (sort (loop for c in claims
                                   when (string= "refused"
                                                 (st:claim-relation c))
                                     collect (cons (st:claim-object-key c)
                                                   (st:claim-method c)))
                             #'string< :key #'car)))
        (make-decision-record
         :id decision-id
         :producer (st:claim-producer outcome)
         :at at
         ;; NIL on the refused path: the rule is not recorded there.
         :rule (and concluded (st:claim-method concluded))
         :rule-version (and concluded (st:claim-rule-version concluded))
         :confidence (and concluded (st:claim-confidence concluded))
         :outcome (if concluded :concluded :refused)
         ;; The conclusion is always the deciding store's own claim, so
         ;; it resolves in GRAPH -- %RESOLVE-IN with no named store.
         :conclusion (and concluded
                          (%resolve-in (st:claim-object-key concluded)
                                       nil graph scope at))
         :evidence (mapcar (lambda (pair)
                             (%resolve-in (car pair) (cdr pair)
                                          graph scope at))
                           evidence)
         :refusals refusals)))))

(defun trace-listing (graph decision-ids)
  "The deterministic shape capture-and-diff compares (SS7): one row per
id, in the given order, with no id or timestamp in it."
  (loop for id in decision-ids
        for rec = (trace graph id)
        collect (list (decision-record-outcome rec)
                      (decision-record-rule rec)
                      (let ((c (decision-record-conclusion rec)))
                        (and c (cite-record-cite c)))
                      (mapcar (lambda (r) (list (cite-record-cite r)
                                                (cite-record-state r)
                                                (cite-record-changed-since r)))
                              (decision-record-evidence rec))
                      (mapcar #'car (decision-record-refusals rec)))))

(defun decisions-citing (graph claim-or-cite &key (scope (list graph)))
  "Ids of the decisions whose EVIDENCE cites CLAIM-OR-CITE, RECORDED-AT
descending then id (SS5), unioned over every store in SCOPE (SS4.3).
NIL means no decisions cite it."
  (let* ((cite (%cite-of claim-or-cite))
         (claims (loop for g in scope
                       append (st:claims-touching g 'trace :claim cite
                                                  :role :object
                                                  :relation "evidence"))))
    (mapcar #'cdr
            (sort (mapcar (lambda (c) (cons (%recorded-instant c)
                                            (st:claim-subject-key c)))
                          claims)
                  (lambda (a b)
                    (or (local-time:timestamp> (car a) (car b))
                        (and (local-time:timestamp= (car a) (car b))
                             (string< (cdr a) (cdr b)))))))))
