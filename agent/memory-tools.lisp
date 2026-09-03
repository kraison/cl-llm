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
     ;; An unknown namespace is never interned by %FIND-KEYWORD, so it
     ;; reads as "nothing recorded" -- an empty array -- not an error.
     (let* ((ns (%find-keyword subject-namespace))
            (subject (and ns (cons ns subject-key)))
            (instant (and at (%parse-iso at)))
            (rows '()))
       (when subject
         (dolist (g (scope-stores scope))
           (dolist (r (mem:recall g subject :relation relation :at instant))
             (note-cite scope (mem:claim-cite (mem:belief-record-claim r))
                        g)
             (push (cons g r) rows))))
       (setf rows (stable-sort (nreverse rows)
                               (lambda (a b)
                                 (mem:claim-before-p
                                  (mem:belief-record-claim (cdr a))
                                  (mem:belief-record-claim (cdr b))))))
       (let* ((cap (scope-max-rows scope))
              (shown (subseq rows 0 (min cap (length rows)))))
         (json:to-json
          (json:jobject
           "records" (map 'vector
                          (lambda (x) (%record-json (car x) (cdr x)))
                          shown)
           "truncated" (%bool (> (length rows) cap)))))))))

(defun %find-decision (scope id)
  "The store holding decision ID, or NIL."
  (find-if (lambda (g) (st:claims-touching g 'mem:trace :decision id
                                           :role :subject :limit 1))
           (scope-stores scope)))

(defun %trace-tool (scope)
  (llm:make-tool
   "trace"
   "Reconstruct a decision as of the instant it was made: its rule,
outcome, the conclusion, every evidence cite resolved to the version
believed then with what has changed since, and any refusals."
   '((decision-id :type string))
   (lambda (decision-id)
     (let ((g (%find-decision scope decision-id)))
       (unless g (error "no decision ~a in scope" decision-id))
       (let ((rec (mem:trace g decision-id :scope (scope-stores scope))))
         ;; Only note a cite whose store CITE-STORE actually resolved --
         ;; never fall back to G, the decision's own store, or an
         ;; out-of-scope cite gets falsely cached as resolvable here and
         ;; renders with a STORE alongside its true :ABSENT STATE.
         (dolist (r (mem:decision-record-evidence rec))
           (let ((s (cite-store scope (mem:cite-record-cite r))))
             (when s (note-cite scope (mem:cite-record-cite r) s))))
         (json:to-json
          (json:jobject
           "id" decision-id
           "store" (mem:store-name g)
           "producer" (mem:decision-record-producer rec)
           "at" (%iso (mem:decision-record-at rec))
           "rule" (mem:decision-record-rule rec)
           "rule-version" (mem:decision-record-rule-version rec)
           "confidence" (mem:decision-record-confidence rec)
           "outcome" (%standing (mem:decision-record-outcome rec))
           "conclusion" (let ((c (mem:decision-record-conclusion rec)))
                          (and c (%cite-record-json (mem:store-name g) c)))
           "evidence" (map 'vector
                           (lambda (r)
                             (%cite-record-json
                              (let ((s (cite-store
                                        scope (mem:cite-record-cite r))))
                                (and s (mem:store-name s)))
                              r))
                           (mem:decision-record-evidence rec))
           "refusals" (map 'vector
                           (lambda (f) (json:jobject "family" (car f)
                                                     "text" (cdr f)))
                           (mem:decision-record-refusals rec)))))))))

(defun %decisions-citing-tool (scope)
  (llm:make-tool
   "decisions-citing"
   "The decisions whose evidence cites a claim, newest first: which
conclusions rest on this belief."
   '((cite :type string))
   (lambda (cite)
     ;; MEM:DECISIONS-CITING already unions SCOPE and orders newest
     ;; first with an id tiebreak (SS5) -- one call, not one per store,
     ;; and no per-decision TRACE just to re-derive that order.
     (let ((ids (mem:decisions-citing (first (scope-stores scope)) cite
                                      :scope (scope-stores scope))))
       (json:to-json
        (json:jobject
         "decisions"
         (map 'vector
              (lambda (id)
                (json:jobject "id" id "store"
                              (mem:store-name (%find-decision scope id))))
              ids)))))))

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
    "outcome" (%standing (mem:decision-outcome d))
    "claim-cite" (let ((c (mem:decision-claim d)))
                   (and c (progn (note-cite scope (mem:claim-cite c)
                                            (scope-write-store scope))
                                 (mem:claim-cite c))))
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
                :confidence confidence)))
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
                     :standing (%check-standing standing
                                                 +absence-standings+))
               :producer (scope-producer scope)
               :evidence (%evidence-pairs scope evidence)
               :rule rule :rule-version rule-version)))
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
         (let ((claim (find cite
                            (st:claims-touching g family ns key
                                                :role :subject)
                            :key #'mem:claim-cite :test #'string=)))
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
