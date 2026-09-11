;;;; tests-agent/planner-tools-tests.lisp -- spec SS7.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %seed-two-stores (w p)
  (%belief w "ci-status" '(:verdict . "green"))
  (%belief w "ci-status" '(:verdict . "red") :start "2026-09-02T08:00:00Z")
  (%belief p "owner" '(:person . "kevin")))

(test retrieve-fuses-the-scopes-claim-sources-and-cites-each-claim
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "anything"
                     "endpoints" (vector "repo:cl-llm")))
           (ev (coerce (json:jget r "evidence") 'list)))
      (is (equal '("claim") (coerce (json:jget r "modes") 'list)))
      (is (= 3 (length ev)))
      (is (every (lambda (e) (mem:cite-p (json:jget e "cite"))) ev))
      (is (equal '("cl-llm-memory" "memory-private")
                 (sort (remove-duplicates
                        (mapcar (lambda (e) (json:jget e "store")) ev)
                        :test #'string=)
                       #'string<)))
      (is (every (lambda (e) (stringp (json:jget e "text"))) ev))
      (is (stringp (json:jget r "bounds" "window" "from")))
      (is (string= "inferred" (json:jget r "bounds" "window" "standing"))))))

(test retrieve-applies-a-supplied-window-and-reports-it-asserted
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm")
                     "from" "2026-09-02T08:00:00Z"
                     "to" "2026-09-03T00:00:00Z"))
           (keys (mapcar (lambda (e) (json:jget e "cite"))
                         (coerce (json:jget r "evidence") 'list))))
      (is (string= "asserted" (json:jget r "bounds" "window" "standing")))
      ;; Supersession closes green 1ns before red's 09-02T08:00 start
      ;; (memory/write.lisp %CLOSE-VALIDITY); the window starts exactly
      ;; there, so ALLEN-RELATION reads green as definitely :BEFORE it
      ;; and BOUNDED-EVIDENCE drops it (rag/bundle.lisp).  Red and the
      ;; open owner belief survive.
      (is (= 2 (length keys)))))
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm")
                     "from" "2026-09-02T00:00:00Z"
                     "to" "2026-09-03T00:00:00Z"))
           (keys (mapcar (lambda (e) (json:jget e "cite"))
                         (coerce (json:jget r "evidence") 'list))))
      ;; A window starting at midnight overlaps green's last eight
      ;; hours: ALLEN-RELATION answers neither :BEFORE nor :AFTER, so
      ;; uncertainty is never exclusion -- all three survive.
      (is (= 3 (length keys))))))

(test retrieve-clamps-k-and-a-recognised-endpoint-with-nothing-is-searched-empty
  (with-stores (w p)
    (%seed-two-stores w p)
    ;; TRUNCATED is RECALL's rule (spec SS5): fuse at k+1, cut to k, so
    ;; it says more existed -- not merely that the page filled.
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+ :k 1))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm") "k" 50)))
      (is (= 1 (length (json:jget r "evidence"))))
      (is (eq t (json:jget r "truncated"))
          "a second and third claim existed past k"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+ :k 3))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm"))))
      (is (= 3 (length (json:jget r "evidence"))))
      (is (eq nil (json:jget r "truncated"))
          "control: an exactly-full page is not truncated"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:nothing-here")))
           (ev (coerce (json:jget r "evidence") 'list)))
      ;; Two stores in scope, two distinct absence items -- a store's
      ;; own name in each one's document id keeps FUSE from collapsing
      ;; them to one (claims/source.lisp %ABSENCE-EVIDENCE).
      (is (= 2 (length ev)))
      (is (every (lambda (e)
                   (string= "searched-empty" (json:jget e "standing")))
                 ev))
      (is (every (lambda (e) (null (json:jget e "cite"))) ev))
      (is (equal '("cl-llm-memory" "memory-private")
                 (sort (mapcar (lambda (e) (json:jget e "store")) ev)
                       #'string<))
          "each absence names the store that looked"))))

(test plan-bounds-derives-a-window-from-the-seed
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "plan-bounds" "query" "q"
                     "endpoints" (vector "repo:cl-llm"))))
      (is (string= "2026-09-01T08:00:00.000000Z"
                   (json:jget r "window" "from")))
      (is (string= "inferred" (json:jget r "window" "standing")))
      (is (null (json:jget r "box")))
      (is (string= "searched-empty" (json:jget r "box-standing"))))))

(test retrieve-seeds-the-cite-cache-in-scope-order
  "S6b SS6 (#48): one cite held by both stores.  W also matches a
confound claim FUSE ranks ahead of its own ci-status copy, so P's
copy -- P's only match -- always out-ranks W's: with no confound the
two copies would tie in FUSE's own ranking and hash order could
launder the bug either way.  With a genuine rank gap, whatever order
SCOPE lists the two stores in, the cache must still name the FIRST
store in scope, not fusion's ranking.  The reversed scope is the
control."
  (with-stores (w p)
    (%belief w "marker" '(:flag . "set") :subject (cons :repo "confound"))
    (let* ((cw (%belief w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite cw))
           (eps (vector "repo:confound" "repo:cl-llm")))
      (%belief p "ci-status" '(:verdict . "green"))
      (let ((scope (agent:make-scope (list w p) :write-store w
                                     :producer +p+)))
        (%call (agent:make-planner-tools scope) "retrieve"
               "query" "ci-status of repo cl-llm" "endpoints" eps)
        (is (eq w (gethash cite (agent::scope-cites scope)))
            "the cache itself holds it")
        (is (eq w (agent:cite-store scope cite))))
      (let ((scope (agent:make-scope (list p w) :write-store w
                                     :producer +p+)))
        (%call (agent:make-planner-tools scope) "retrieve"
               "query" "ci-status of repo cl-llm" "endpoints" eps)
        (is (eq p (gethash cite (agent::scope-cites scope)))
            "the cache itself holds it")
        (is (eq p (agent:cite-store scope cite)) "control: reversed")))))

(test retrieve-signals-on-a-noncanonical-endpoint-namespace
  "Controller ruling 2: %ENDPOINTS uses the validating %KEYWORD for the
namespace half of each \"namespace:key\" string, so a non-canonical
namespace is a tool error, not a silent intern."
  (with-stores (w p)
    (%seed-two-stores w p)
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "retrieve")
                       (%args "query" "q"
                              "endpoints" (vector "Bad NS:cl-llm")))))))

;;; #64 SS4.2: the query string finds endpoints.

(test retrieve-finds-endpoints-in-the-query-string
  (with-stores (w p)
    (%belief w "outage-root-cause" '(:cause . "quill")
             :subject '(:incident . "ledger-freeze-2026-05-22"))
    (%belief p "owner" '(:person . "kevin"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve"
                     "query" "why did the ledger freeze in May"))
           (ev (coerce (json:jget r "evidence") 'list)))
      (is (equal '("incident:ledger-freeze-2026-05-22")
                 (coerce (json:jget r "endpoints") 'list)))
      (is (= 1 (length ev)))
      (is (search "ledger-freeze-2026-05-22" (json:jget (first ev) "text")))
      (is (mem:cite-p (json:jget (first ev) "cite")))
      (is (string= "cl-llm-memory" (json:jget (first ev) "store"))))))

(test explicit-endpoints-come-first-and-are-never-displaced
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "outage-root-cause" '(:cause . "quill")
             :subject '(:incident . "ledger-freeze-2026-05-22"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+ :k 1))
           (r (%call tools "retrieve" "query" "ledger freeze"
                     "endpoints" (vector "repo:cl-llm"))))
      ;; the union is capped at 2k = 2: the explicit one, then the best
      ;; extracted one; the explicit one is consulted in both stores
      ;; and listed once
      (is (equal '("repo:cl-llm" "incident:ledger-freeze-2026-05-22")
                 (coerce (json:jget r "endpoints") 'list)))
      (is (= 1 (length (json:jget r "evidence"))))
      (is (json:jget r "truncated")))))

(test retrieve-refuses-when-nothing-would-be-consulted
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (handler-case
          (progn (%call tools "retrieve"
                        "query" "completely unrelated banana helicopter")
                 (fail "an unconsulted retrieve must be refused"))
        (llm:llm-tool-error (e)
          (let ((text (princ-to-string (llm:llm-error-underlying e))))
            (is (search "no endpoint recognised" text))
            (is (search "banana helicopter" text))
            (is (search "list-taxonomy" text)))))
      (signals llm:llm-tool-error
        (%call tools "plan-bounds" "query" "banana helicopter")))))

(defclass %stub-source () ())

(defmethod rag:collect-evidence ((s %stub-source) query &key k bounds)
  (declare (ignore query k bounds))
  (list (rag:make-evidence
         :chunk (rag:make-chunk "stub text" :document-id "stub:1")
         :score 1d0 :method :dense :source s :standing :observed)))

(test retrieve-runs-over-an-operator-source-with-no-endpoints
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools
                   (list w p) :producer +p+
                   :sources (list (make-instance '%stub-source))))
           (r (%call tools "retrieve" "query" "banana helicopter"))
           (ev (json:jget r "evidence")))
      (is (= 0 (length (json:jget r "endpoints"))))
      (is (= 1 (length ev)))
      (is (string= "stub text" (json:jget (elt ev 0) "text")))
      (is (= 0 (length (json:jget (%call tools "plan-bounds"
                                         "query" "banana helicopter")
                                  "endpoints")))))))

;;; #78 SS7: retrieve routes through the semantic endpoint index.

(test retrieve-routes-a-paraphrase-through-the-semantic-index
  "#78 SS7 test 1: the lexical route finds nothing; the dense fill
does, and retrieve cites the belief.  Control: no embedder refuses."
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "replica-checksum-mismatch")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (let* ((ee (%embedder))
           (tools (agent:make-agent-tools (list w p) :producer +p+
                                          :embedder ee))
           (plain (agent:make-agent-tools (list w p) :producer +p+))
           (q "why was the deployment reverted in august"))
      (%drain (list w) ee)
      (signals llm:llm-tool-error (%call plain "retrieve" "query" q))
      (let ((r (%call tools "retrieve" "query" q)))
        ;; The incident's profile is at cosine .37, the cause's at .25:
        ;; only the one above the floor is consulted.
        (is (equal '("incident:ledger-rollback-2026-08-30")
                   (coerce (json:jget r "endpoints") 'list)))
        (is (= 1 (length (json:jget r "evidence"))))
        (is (search "replica-checksum-mismatch"
                    (json:jget (elt (json:jget r "evidence") 0) "text")))))))

(test retrieve-still-refuses-an-unindexed-topic-with-an-embedder
  "#78 R3: the floor is a refusal, not a ranking -- a query no profile
embeds near still names nothing, and the message is unchanged."
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "replica-checksum-mismatch")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (let* ((ee (%embedder))
           (tools (agent:make-agent-tools (list w p) :producer +p+
                                          :embedder ee)))
      (%drain (list w) ee)
      (handler-case
          (progn (%call tools "retrieve" "query" "pelican migration")
                 (fail "must refuse"))
        (llm:llm-tool-error (e)
          (is (search "no endpoint recognised"
                      (princ-to-string (llm:llm-error-underlying e)))))))))

(test retrieve-embeds-the-query-once-per-call-across-stores
  "#78 R7: one embedding per call, not one per store and not one per
extractor invocation -- retrieve runs each store's extractor three
times (consulted, seed, bounded fusion)."
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "x")
             :subject '(:incident . "ledger-rollback"))
    (%belief p "root-cause" '(:cause . "y")
             :subject '(:incident . "ledger-freeze"))
    (let* ((calls 0)
           (ee (%embedder))
           (tools (agent:make-agent-tools (list w p) :producer +p+
                                          :embedder ee)))
      (%drain (list w p) ee)
      ;; Count query embeddings only: wrap the generic after the drain.
      (let ((old (fdefinition 'rag:embed)))
        (unwind-protect
             (progn
               (setf (fdefinition 'rag:embed)
                     (lambda (e input) (incf calls) (funcall old e input)))
               ;; The endpoint is named outright so the refusal cannot
               ;; end the call before the second and third extractions.
               (%call tools "retrieve"
                      "query" "why was the deployment reverted"
                      "endpoints" (vector "incident:ledger-rollback"))
               (is (= 1 calls) "one embedding for two stores, got ~a"
                   calls))
          (setf (fdefinition 'rag:embed) old))))))

(test conclude-and-retract-notify-the-indexer-and-never-embed
  "#78 SS7 test 8: the write path embeds nothing; it wakes the worker
after its transaction commits."
  (with-stores (w p)
    (let* ((calls 0) (notified 0)
           (ee (%embedder))
           (tools (agent:make-agent-tools (list w p) :producer +p+
                                          :embedder ee))
           (old (fdefinition 'mem:notify-endpoint-indexer))
           (old-embed (fdefinition 'rag:embed)))
      (unwind-protect
           (progn
             (setf (fdefinition 'mem:notify-endpoint-indexer)
                   (lambda (&optional i) (declare (ignore i))
                     (incf notified) nil)
                   (fdefinition 'rag:embed)
                   (lambda (e input) (incf calls) (funcall old-embed e input)))
             (let ((r (%call tools "conclude"
                             "subject-namespace" "incident"
                             "subject-key" "ledger-rollback"
                             "relation" "root-cause"
                             "object-namespace" "cause"
                             "object-key" "bad-deploy"
                             "rule" "test")))
               (is (string= "concluded" (json:jget r "outcome"))
                   "control: the write committed")
               (is (= 0 calls) "conclude embedded ~a times" calls)
               (is (= 1 notified) "conclude woke the indexer ~a times"
                   notified)
               (%call tools "retract" "cite" (json:jget r "claim-cite"))
               (is (= 0 calls) "retract embedded ~a times" calls)
               (is (= 2 notified) "retract woke the indexer ~a times"
                   (- notified 1))))
        (setf (fdefinition 'mem:notify-endpoint-indexer) old
              (fdefinition 'rag:embed) old-embed)))))

(test conclude-absence-does-not-notify-the-indexer
  "#78 SS4.2: an absence touches no endpoint, so it wakes nothing."
  (with-stores (w p)
    (let* ((notified 0)
           (tools (agent:make-agent-tools (list w p) :producer +p+
                                          :embedder (%embedder)))
           (old (fdefinition 'mem:notify-endpoint-indexer)))
      (unwind-protect
           (progn
             (setf (fdefinition 'mem:notify-endpoint-indexer)
                   (lambda (&optional i) (declare (ignore i))
                     (incf notified) nil))
             (let ((r (%call tools "conclude-absence"
                             "subject-namespace" "incident"
                             "subject-key" "ledger-rollback"
                             "relation" "root-cause" "rule" "test"
                             "standing" "searched-empty")))
               (is (string= "concluded" (json:jget r "outcome"))
                   "control: the absence was recorded")
               (is (= 0 notified) "an absence woke the indexer ~a times"
                   notified)))
        (setf (fdefinition 'mem:notify-endpoint-indexer) old)))))

(test the-embedder-must-be-an-endpoint-embedder
  (with-stores (w p)
    (signals agent:scope-error
      (agent:make-scope (list w p) :producer +p+
                        :embedder (rag:make-mock-embedder)))
    (is (null (agent:scope-embedder
               (agent:make-scope (list w p) :producer +p+))))
    (let ((ee (%embedder)))
      (is (eq ee (agent:scope-embedder
                  (agent:make-scope (list w p) :producer +p+
                                    :embedder ee)))))))

(defun %ends-with (suffix text)
  "True when TEXT ends with SUFFIX.  A function, not an AND inside IS:
FIVEAM evaluates both arms of the form it reports on."
  (let ((n (length suffix)) (m (length text)))
    (and (<= n m) (string= suffix text :start2 (- m n)))))

(test retrieve-marks-evidence-another-producers-belief-outdates
  "#82: the evidence line itself says the belief is outdated, so a
model reading the bundle sees what RECALL would have told it."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green") :producer +px+)
    (%belief w "ci-status" '(:verdict . "red") :producer +py+
                           :start "2026-09-02T08:00:00Z")
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm")))
           (ev (coerce (json:jget r "evidence") 'list))
           (green (find-if (lambda (e) (search "verdict:green"
                                               (json:jget e "text")))
                           ev))
           (red (find-if (lambda (e) (search "verdict:red"
                                             (json:jget e "text")))
                         ev)))
      ;; Two claims from W, plus P's searched-empty item: P holds
      ;; nothing on this endpoint (claims/source.lisp %ABSENCE-EVIDENCE).
      (is (= 3 (length ev)))
      (is (not (null green)))
      (is (not (null red)))
      (is (%ends-with (format nil " (outdated by ~a)"
                              (json:jget red "cite"))
                      (json:jget green "text"))
          "the outdated line ends with the leader's cite: ~a"
          (json:jget green "text"))
      (is (null (search "outdated by" (json:jget red "text")))
          "control: the leader's own line is unchanged"))))
