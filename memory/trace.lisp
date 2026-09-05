;;;; memory/trace.lisp -- decisions as claims: CONCLUDE, TRACE,
;;;; DECISIONS-CITING.  Spec 2026-09-02 SS3-SS5.

(in-package #:cl-llm.memory)

(defstruct decision
  "What CONCLUDE returns (SS4).  OUTCOME is :CONCLUDED or :REFUSED; CLAIM
the belief or absence written (NIL when refused); REPORT the
VALIDATION-REPORT, the commit condition, or a (:SCOPE-CONFLICT cite
store) list (NIL when concluded); AT the outcome claim's RECORDED-AT;
EPOCH the committing transaction's id -- the shared clock's epoch when
the store is attached to one (S6b SS7)."
  id outcome claim report at epoch)

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
  ;; One row per cite: the family's identity excludes METHOD, so a
  ;; second row for the same cite from another store would collide on
  ;; the unique constraint (S6b SS7, #51 documented).  :FROM-END T: the
  ;; first store in PAIRS -- scope order, as the tools build it -- names
  ;; the row.
  (dolist (pair (remove-duplicates pairs :key #'car :test #'string=
                                   :from-end t))
    (%trace-claim graph id "evidence" :claim (car pair) producer :observed
                  :method (cdr pair))))

(define-condition %refused (error)
  ((report :initarg :report :reader %refused-report))
  (:documentation "Unwinds CONCLUDE's transaction without committing
(SS4 step 2); never escapes CONCLUDE."))

(defun %violation-families (report-or-condition)
  "(family . text) per violation, first per family, in family order.
A (:SCOPE-CONFLICT cite store) report is one SCOPE-CONFLICT row whose
text is prose, never a printed form (S6b SS5, recon C2)."
  (let ((rows (cond ((typep report-or-condition 'gdb:validation-report)
                     (loop for (family nil detail)
                             in (gdb:validation-report-violations
                                 report-or-condition)
                           collect (cons (string-downcase
                                          (symbol-name family))
                                         (princ-to-string detail))))
                    ((and (consp report-or-condition)
                          (eq :scope-conflict (first report-or-condition)))
                     (list (cons "scope-conflict"
                                 (format nil "~a in the higher-trust ~
                                              store ~a governs this ~
                                              series"
                                         (second report-or-condition)
                                         (third report-or-condition)))))
                    (t (list (cons "commit"
                                   (princ-to-string
                                    report-or-condition)))))))
    (sort (remove-duplicates rows :key #'car :test #'string= :from-end t)
          #'string< :key #'car)))

(defun %write-refusal (graph id report pairs producer rule rule-version)
  "A fresh transaction recording the refusal (SS4 step 2/3): one REFUSED
claim per violated family, and one ATTEMPTED claim naming the rule the
agent was applying, with CONCLUDED's slots, so a refused decision still
says under which rule (#35).  The transaction's id is the decision's
epoch (S6b SS7)."
  (let* ((outcome nil)
         (tx (gdb:with-transaction (:graph graph)
               (%trace-claim graph id "attempted" :rule rule producer
                             :observed :method rule
                             :rule-version rule-version)
               (dolist (row (%violation-families report))
                 (setf outcome
                       (%trace-claim graph id "refused" :violation (car row)
                                     producer :observed :method (cdr row))))
               (%write-evidence graph id pairs producer)
               gdb:*transaction*)))
    (make-decision :id id :outcome :refused :report report
                   :at (st:claim-recorded-at outcome)
                   ;; TRANSACTION-ID is internal to the engine (recon C10).
                   :epoch (graph-db::transaction-id tx))))

(defun %scope-conflict-report (cite store-name)
  (list :scope-conflict cite store-name))

(defun %proposal-start (more)
  "The validity start a (:BELIEF subject relation object . MORE) proposal
will be recorded with: its :EXTENT's, else now (RECORD-BELIEF's
default)."
  (let ((extent (getf (rest more) :extent)))
    (if extent
        (te:bound-earliest (te:extent-start extent))
        (local-time:now))))

(defun %governing-prior (proposal producer scope)
  "For a (:BELIEF ...) PROPOSAL, (values PRIOR STORE): the current open
binary claim of the same series, across SCOPE, whose validity start is
latest but not after the proposal's; the first store in scope order on
a tie.  NIL for an absence, which has no series (recon C3), and when no
prior governs.  Computed here, not by %CURRENT-PREDECESSOR, which is
unambiguous only inside one store.  Caller holds the snapshots."
  (destructuring-bind (kind subject relation &rest more) proposal
    (when (eq kind :belief)
      (let ((start (%proposal-start more))
            (best nil) (best-store nil))
        (dolist (g scope (values best best-store))
          (dolist (c (%series g producer subject relation))
            (when (and (typep c 'belief-binary)
                       (st:claim-current-p c)
                       (%open-p c)
                       (not (local-time:timestamp< start
                                                   (%start-instant c)))
                       (or (null best)
                           (local-time:timestamp< (%start-instant best)
                                                  (%start-instant c))))
              (setf best c best-store g))))))))

(defun conclude (graph proposal
                 &key producer evidence rule rule-version confidence
                      (scope (list graph)))
  "Decide PROPOSAL from EVIDENCE under RULE (SS4).  Owns its
transaction; signals BELIEF-ARGUMENT-ERROR when one is already open.
Returns a DECISION -- a refusal is RETURNED as one with :OUTCOME
:REFUSED and REPORT set, never signalled.  Under SCOPE (S6b SS5) a
belief governed by a prior in a higher-trust store is refused as
SCOPE-CONFLICT before the transaction opens; one in a lower-trust
store is overridden and recorded as evidence.  Advisory, like the
validation report: the commit is the enforcement."
  (when gdb:*transaction*
    (%arg-error :transaction gdb:*transaction*
                "CONCLUDE owns its transaction; call it outside one"))
  (check-scope scope :write-store graph)
  (%check-producer producer)
  (unless (stringp rule) (%arg-error :rule rule "a string naming the rule"))
  (%check-proposal proposal)
  (let ((id (%mint-id))
        (pairs (mapcar (lambda (e) (%evidence-of e (store-name graph)))
                       evidence))
        (claim nil) (outcome nil))
    (multiple-value-bind (prior store)
        (with-scope-snapshots (scope)
          (%governing-prior proposal producer scope))
      (when (and prior (not (eq store graph)))
        (if (< (position store scope) (position graph scope))
            (return-from conclude
              (%write-refusal graph id
                              (%scope-conflict-report (claim-cite prior)
                                                      (store-name store))
                              pairs producer rule rule-version))
            ;; Lower trust: overridden at read time (SS4); say so.
            (setf pairs (append pairs
                                (list (cons (claim-cite prior)
                                            (store-name store))))))))
    (handler-case
        (let ((tx (gdb:with-transaction (:graph graph)
                    (setf claim (%stage graph proposal producer rule
                                        rule-version confidence))
                    (let ((report (gdb:validate-transaction graph)))
                      (when (gdb:validation-report-violations report)
                        (error '%refused :report report)))
                    (setf outcome
                          (%trace-claim graph id "concluded" :claim
                                        (claim-cite claim) producer
                                        :inferred :method rule
                                        :rule-version rule-version
                                        :confidence confidence))
                    (%write-evidence graph id pairs producer)
                    gdb:*transaction*)))
          (make-decision :id id :outcome :concluded :claim claim
                         :at (st:claim-recorded-at outcome)
                         :epoch (graph-db::transaction-id tx)))
      (%refused (c)
        (%write-refusal graph id (%refused-report c) pairs producer
                        rule rule-version))
      (gdb:constraint-violation (c)
        ;; The report is advisory (SS2); the commit is the enforcement.
        (%write-refusal graph id c pairs producer rule rule-version)))))

(defstruct decision-record
  "TRACE's answer (SS5).  CONCLUSION is a CITE-RECORD or NIL; EVIDENCE a
list of CITE-RECORDs in cite order; REFUSALS (family . text)
in family order.  STORE names the store the decision was found in;
EPOCH is the outcome claim's commit epoch, NIL for a claim written
before the engine stamped one (S6b SS7)."
  id producer at rule rule-version confidence outcome
  conclusion evidence refusals store epoch)

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
found in the first store of SCOPE holding it, or NIL when no store
does.  Each evidence cite resolves in the store it names, when that
store is in SCOPE (SS4.3).  Runs under the scope's snapshots (S6b)."
  ;; GRAPH must be in SCOPE (SS3); :WRITE-STORE is the membership check.
  (check-scope scope :write-store graph)
  (with-scope-snapshots (scope)
    (let* ((g (find-if (lambda (s) (%decision-claims s decision-id))
                       scope))
           (claims (and g (%decision-claims g decision-id)))
           (outcome (find-if (lambda (c)
                               (member (st:claim-relation c)
                                       '("concluded" "refused")
                                       :test #'string=))
                             claims)))
      (when outcome
        (let* ((at (%recorded-instant outcome))
               (concluded (and (string= "concluded"
                                        (st:claim-relation outcome))
                               outcome))
               ;; The rule on the refused path (#35); NIL for a decision
               ;; recorded before ATTEMPTED claims existed.
               (attempted (or concluded
                              (find "attempted" claims
                                    :key #'st:claim-relation
                                    :test #'string=)))
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
           :rule (and attempted (st:claim-method attempted))
           :rule-version (and attempted (st:claim-rule-version attempted))
           :confidence (and concluded (st:claim-confidence concluded))
           :outcome (if concluded :concluded :refused)
           ;; The conclusion is always the deciding store's own claim,
           ;; so it resolves in G -- %RESOLVE-IN with no named store.
           :conclusion (and concluded
                            (%resolve-in (st:claim-object-key concluded)
                                         nil g scope at))
           :evidence (mapcar (lambda (pair)
                               (%resolve-in (car pair) (cdr pair)
                                            g scope at))
                             evidence)
           :refusals refusals
           :store (store-name g)
           :epoch (st:claim-commit-epoch outcome)))))))

(defun trace-listing (graph decision-ids &key (scope (list graph)))
  "The deterministic shape capture-and-diff compares (SS7): one row per
id, in the given order, with no id or timestamp in it.  SCOPE resolves
cross-store evidence as TRACE does (#34); an id no store in SCOPE holds
is a (:MISSING NIL NIL NIL NIL) row, never a signal (S6b, #47).  Runs
under the scope's snapshots, once, so the listing is one consistent
read (S6b)."
  ;; GRAPH must be in SCOPE (SS3); :WRITE-STORE is the membership check.
  (check-scope scope :write-store graph)
  (with-scope-snapshots (scope)
    (loop for id in decision-ids
          for rec = (trace graph id :scope scope)
          collect (if (null rec)
                      (list :missing nil nil nil nil)
                      (list (decision-record-outcome rec)
                            (decision-record-rule rec)
                            (let ((c (decision-record-conclusion rec)))
                              (and c (cite-record-cite c)))
                            (mapcar (lambda (r)
                                      (list (cite-record-cite r)
                                            (cite-record-state r)
                                            (cite-record-changed-since r)))
                                    (decision-record-evidence rec))
                            (mapcar #'car
                                    (decision-record-refusals rec)))))))

(defun decisions-citing (graph claim-or-cite &key (scope (list graph)))
  "(id . store-name) per decision whose EVIDENCE cites CLAIM-OR-CITE,
RECORDED-AT descending then id (SS5), unioned over every store in SCOPE
under its snapshots (S6b SS7).  NIL means no decisions cite it."
  ;; GRAPH must be in SCOPE (SS3); :WRITE-STORE is the membership check.
  (check-scope scope :write-store graph)
  (let ((cite (%cite-of claim-or-cite)))
    (with-scope-snapshots (scope)
      (let ((rows (loop for g in scope
                        append (mapcar
                                (lambda (c)
                                  (list (%recorded-instant c)
                                        (st:claim-subject-key c)
                                        (store-name g)))
                                (st:claims-touching
                                 g 'trace :claim cite :role :object
                                 :relation "evidence")))))
        (mapcar (lambda (r) (cons (second r) (third r)))
                (sort rows
                      (lambda (a b)
                        (or (local-time:timestamp> (first a) (first b))
                            (and (local-time:timestamp= (first a)
                                                        (first b))
                                 (string< (second a) (second b)))))))))))
