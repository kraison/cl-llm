;;;; agent/memory-tools.lisp -- recall, trace, decisions-citing,
;;;; conclude, conclude-absence, retract.  Spec SS6.

(in-package #:cl-llm.agent)

(defun %recall-tool (scope)
  (llm:make-tool
   "recall"
   "Recall what is believed about a subject: every belief on
(subject-namespace, subject-key) across the memory in scope, newest
validity first, each with its cite, standing, validity window, whether
it is current, and what superseded it.  Optional relation narrows to
one predicate; optional at (RFC 3339) keeps only beliefs valid then."
   '((subject-namespace :type string) (subject-key :type string)
     (relation :type string :optional t) (at :type string :optional t))
   (lambda (subject-namespace subject-key relation at)
     ;; The namespace is resolved, not looked up in this image: what
     ;; was recorded under it is the store's answer (#61).  An
     ;; uncanonical name is an error, as in retrieve, never an empty
     ;; array a caller could mistake for nothing recorded (#63).
     (let* ((subject (cons (%keyword subject-namespace) subject-key))
            (instant (and at (%parse-iso at)))
            ;; One RECALL over the scope: the memory layer merges and
            ;; computes supersession under the trust rule (S6b SS4).
            (rows (mem:recall (scope-write-store scope) subject
                              :relation relation :at instant
                              :scope (scope-stores scope))))
       ;; Seed the cache in SCOPE order, not row order: first-wins must
       ;; mean first-in-scope, whatever recall's tie-break put first
       ;; (S6b SS6, #48).
       (dolist (g (scope-stores scope))
         (dolist (r rows)
           (when (eq g (mem:belief-record-store r))
             (note-cite scope
                        (mem:claim-cite (mem:belief-record-claim r))
                        g))))
       (let* ((cap (scope-max-rows scope))
              (shown (subseq rows 0 (min cap (length rows)))))
         (json:to-json
          (json:jobject
           "records" (map 'vector #'%record-json shown)
           "truncated" (%bool (> (length rows) cap)))))))))

(defun %trace-tool (scope)
  (llm:make-tool
   "trace"
   "Reconstruct a decision as of when it was made: its rule, outcome,
the conclusion, every evidence cite resolved to the version believed
then with what has changed since, and any refusals."
   '((decision-id :type string))
   (lambda (decision-id)
     ;; No NOTE-CITE here: each record already carries the store
     ;; MEM:TRACE resolved it against, and seeding the cache from a
     ;; trace would make a later CONCLUDE charge the evidence to
     ;; whichever store the cache saw (#14 unit 2 final review).
     (let ((rec (mem:trace (scope-write-store scope) decision-id
                           :scope (scope-stores scope))))
       (unless rec (error "no decision ~a in scope" decision-id))
       (json:to-json
        (json:jobject
         "id" decision-id
         "store" (mem:decision-record-store rec)
         "epoch" (mem:decision-record-epoch rec)
         ;; Which axis the cites were resolved on (#53).
         "axis" (%standing (mem:decision-record-axis rec))
         "producer" (mem:decision-record-producer rec)
         "at" (%iso (mem:decision-record-at rec))
         "rule" (mem:decision-record-rule rec)
         "rule-version" (mem:decision-record-rule-version rec)
         "confidence" (mem:decision-record-confidence rec)
         "outcome" (%standing (mem:decision-record-outcome rec))
         "conclusion" (let ((c (mem:decision-record-conclusion rec)))
                        (and c (%cite-record-json c)))
         "evidence" (map 'vector #'%cite-record-json
                         (mem:decision-record-evidence rec))
         "refusals" (map 'vector
                         (lambda (f) (json:jobject "family" (car f)
                                                   "text" (cdr f)))
                         (mem:decision-record-refusals rec))))))))

(defun %decisions-citing-tool (scope)
  (llm:make-tool
   "decisions-citing"
   "The decisions whose evidence cites a claim, newest first: which
conclusions rest on this belief."
   '((cite :type string))
   (lambda (cite)
     ;; MEM:DECISIONS-CITING unions SCOPE, orders newest first with an
     ;; id tiebreak (SS5), and names each decision's store (S6b SS7).
     (let ((pairs (mem:decisions-citing (scope-write-store scope) cite
                                        :scope (scope-stores scope))))
       (json:to-json
        (json:jobject
         "decisions"
         (map 'vector
              (lambda (pair)
                (json:jobject "id" (car pair) "store" (cdr pair)))
              pairs)))))))

;;; Write tools: conclude, conclude-absence, retract.  Spec SS6.

(defparameter +presence-standings+ '("inferred" "observed" "asserted"))
(defparameter +absence-standings+
  '("searched-empty" "indeterminate" "uncovered"))

(defun %check-standing (string allowed)
  (unless (member string allowed :test #'string=)
    (error "standing must be one of ~{~a~^, ~}" allowed))
  (%keyword string))

(defun %evidence-pairs (scope evidence)
  "(cite . store-name) per cite the model passed.  A cite CITE-STORE
cannot resolve in scope is an error -- ruling: never silently charged
to the write store (SS6)."
  (loop for cite across (or evidence #())
        for g = (or (cite-store scope cite)
                    (error "cite ~a is not in scope" cite))
        collect (cons cite (mem:store-name g))))

(defun %decision-json (scope d)
  (json:to-json
   (json:jobject
    "id" (mem:decision-id d)
    "store" (mem:store-name (scope-write-store scope))
    "epoch" (mem:decision-epoch d)
    "outcome" (%standing (mem:decision-outcome d))
    "claim-cite" (let ((c (mem:decision-claim d)))
                   (and c (progn (note-cite scope (mem:claim-cite c)
                                            (scope-write-store scope))
                                 (mem:claim-cite c))))
    ;; MEM:TRACE never returns NIL here: both CONCLUDE paths -- commit
    ;; and %WRITE-REFUSAL (memory/trace.lisp) -- write an outcome claim
    ;; before returning, so D's id always resolves to one.
    "refusals" (map 'vector
                    (lambda (f) (json:jobject "family" (car f)
                                              "text" (cdr f)))
                    (mem:decision-record-refusals
                     (mem:trace (scope-write-store scope)
                                (mem:decision-id d)))))))

(defun %conclude-tool (scope)
  (llm:make-tool
   "conclude"
   "Record a belief as a decision: subject relation object, under a
named rule, citing the evidence (cites from earlier results).  The
write is validated before it commits; a refusal comes back as outcome
\"refused\" with the constraint families, and writes nothing.
standing: inferred (default), observed or asserted.  valid-from: when
the belief starts to hold (RFC 3339; default now)."
   '((subject-namespace :type string) (subject-key :type string)
     (relation :type string)
     (object-namespace :type string) (object-key :type string)
     (rule :type string)
     (evidence :type (list string) :optional t)
     (standing :type string :default "inferred")
     (confidence :type number :optional t)
     (rule-version :type string :optional t)
     (valid-from :type string :optional t))
   (lambda (subject-namespace subject-key relation object-namespace
            object-key rule evidence standing confidence rule-version
            valid-from)
     (let* ((st (%check-standing standing +presence-standings+))
            (extent (and valid-from
                         (te:make-interval
                          (te:exact-bound (%parse-iso valid-from))
                          (te:unknown-bound)
                          :semantics :validity :standing :asserted)))
            (d (mem:conclude
                (scope-write-store scope)
                (append (list :belief
                              (cons (%keyword subject-namespace)
                                    subject-key)
                              relation
                              (cons (%keyword object-namespace)
                                    object-key)
                              :standing st)
                        (and extent (list :extent extent)))
                :producer (scope-producer scope)
                :evidence (%evidence-pairs scope evidence)
                :rule rule :rule-version rule-version
                :confidence confidence
                :scope (scope-stores scope))))
       (%decision-json scope d)))))

(defun %conclude-absence-tool (scope)
  (llm:make-tool
   "conclude-absence"
   "Record that you looked and found nothing, as a decision: standing
searched-empty (looked in a nameable place, nothing there),
indeterminate (could not find out) or uncovered (nothing has looked).
Validated and traced like conclude."
   '((subject-namespace :type string) (subject-key :type string)
     (relation :type string) (rule :type string)
     (standing :type string)
     (evidence :type (list string) :optional t)
     (rule-version :type string :optional t))
   (lambda (subject-namespace subject-key relation rule standing
            evidence rule-version)
     (let ((d (mem:conclude
               (scope-write-store scope)
               (list :absence
                     (cons (%keyword subject-namespace) subject-key)
                     relation
                     :standing (%check-standing
                                standing +absence-standings+))
               :producer (scope-producer scope)
               :evidence (%evidence-pairs scope evidence)
               :rule rule :rule-version rule-version
               :scope (scope-stores scope))))
       (%decision-json scope d)))))

(defun %retract-tool (scope)
  (llm:make-tool
   "retract"
   "Say a belief was wrong: close its transaction period, leaving its
validity as recorded.  Only beliefs in the writable store; a cite from
a read-only store is an error."
   '((cite :type string))
   (lambda (cite)
     (let ((g (cite-store scope cite)))
       (unless g (error "no claim for cite ~a in scope" cite))
       (unless (eq g (scope-write-store scope))
         (error "store ~a is not writable in this scope"
                (mem:store-name g)))
       (multiple-value-bind (family ns key) (mem:split-cite cite)
         ;; CITE-STORE resolves any registered family, and a decision's
         ;; trace vertices are visible through the query tool -- refuse
         ;; here as well as in RETRACT-BELIEF (#14 unit 2 final review).
         (unless (eq family 'mem:belief)
           (error "only beliefs are retractable; ~a names a ~(~a~)"
                  cite family))
         ;; CLAIMS-TOUCHING returns retracted claims too, and a
         ;; claim's identity key -- hence its cite -- survives
         ;; retraction (claim-identity-key).  Prefer the still-current
         ;; claim over whichever CLAIMS-TOUCHING hands back first, in
         ;; case two ever share a cite; the unrestricted search is
         ;; only a fallback so RETRACT-BELIEF can still report
         ;; "already retracted" when every match is dead.
         (let ((claim (or (find cite
                                (st:claims-touching g family ns key
                                                    :role :subject
                                                    :current t)
                                :key #'mem:claim-cite :test #'string=)
                          (find cite
                                (st:claims-touching g family ns key
                                                    :role :subject)
                                :key #'mem:claim-cite :test #'string=))))
           (unless claim (error "no claim for cite ~a" cite))
           (let ((retracted
                   (gdb:with-transaction (:graph g)
                     (mem:retract-belief claim))))
             (json:to-json
              (json:jobject
               "cite" cite
               "store" (mem:store-name g)
               "retracted-at"
               (%iso (te:bound-latest
                      (te:extent-end
                       (st:claim-transaction-extent
                        retracted)))))))))))))
