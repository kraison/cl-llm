;;;; tests-agent/memory-tools-tests.lisp -- spec SS5, SS6: the read
;;;; tools across a scope.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(test make-agent-tools-needs-a-producer-and-a-write-store-in-scope
  (with-stores (w p)
    (signals agent:scope-error (agent:make-agent-tools (list w p)))
    (signals agent:scope-error
      (agent:make-agent-tools (list w) :write-store p :producer +p+))
    (is (= 8 (length (agent:make-agent-tools (list w p) :producer +p+))))))

(test recall-spans-the-scope-and-names-the-store
  "SS6: reads run over every store in scope; each record says where it
came from; the private store is invisible when out of scope."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief p "owner" '(:person . "kevin"))
    (let* ((both (agent:make-agent-tools (list w p) :producer +p+))
           (only (agent:make-agent-tools (list w) :producer +p+))
           (r (%call both "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm"))
           (records (json:jget r "records")))
      (is (= 2 (length records)))
      (is (equal '("cl-llm-memory" "memory-private")
                 (sort (map 'list (lambda (x) (json:jget x "store")) records)
                       #'string<)))
      (let ((green (find "ci-status" records
                         :key (lambda (x) (json:jget x "relation"))
                         :test #'string=)))
        (is (string= "green" (json:jget green "object" "key")))
        (is (string= "verdict" (json:jget green "object" "namespace")))
        (is (string= "observed" (json:jget green "standing")))
        (is (string= "2026-09-01T08:00:00.000000Z"
                     (json:jget green "valid-from")))
        (is (null (json:jget green "valid-to")))
        (is (eq t (json:jget green "current")))
        (is (mem:cite-p (json:jget green "cite"))))
      (is (eq nil (json:jget r "truncated")))
      (let ((r2 (%call only "recall" "subject-namespace" "repo"
                       "subject-key" "cl-llm")))
        (is (= 1 (length (json:jget r2 "records")))
            "the private store is not in scope")))))

(test recall-clamps-to-max-rows-and-says-so
  (with-stores (w p)
    (dotimes (i 3)
      (%belief w (format nil "rel-~a" i) '(:v . "1")))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+
                                          :max-rows 2))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm")))
      (is (= 2 (length (json:jget r "records"))))
      (is (eq t (json:jget r "truncated"))))))

(test recall-filters-and-orders
  "Order is unit 1's: validity start descending."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "ci-status" '(:verdict . "red") :start "2026-09-02T08:00:00Z")
    (%belief w "last-push" '(:sha . "abc"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm" "relation" "ci-status")))
      (is (equal '("red" "green")
                 (map 'list (lambda (x) (json:jget x "object" "key"))
                      (json:jget r "records"))))
      (let ((old (second (coerce (json:jget r "records") 'list))))
        (is (eq nil (json:jget old "current")))
        (is (mem:cite-p (json:jget old "superseded-by")))))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm" "relation" "ci-status"
                     "at" "2026-09-01T12:00:00Z")))
      (is (= 1 (length (json:jget r "records")))))))

(test recall-interleaves-cross-store-newest-first
  "Cross-store merge follows unit 1's newest-validity-first order --
one store's newer record sorts ahead of another's older one regardless
of scope order (spec SS6)."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "old") :start "2026-09-01T08:00:00Z")
    (%belief p "ci-status" '(:verdict . "new") :start "2026-09-02T08:00:00Z")
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm" "relation" "ci-status")))
      (is (equal '("new" "old")
                 (map 'list (lambda (x) (json:jget x "object" "key"))
                      (json:jget r "records")))))))

(test recall-breaks-a-genuine-cross-store-tie-by-scope-order
  "Equal validity start AND equal recorded-at: STABLE-SORT then keeps
each row's pre-sort position, which is scope order (spec SS6)."
  (with-stores (w p)
    (let ((at (local-time:now)))
      (%belief-at w "1" at)
      (%belief-at p "1" at))
    (let* ((wp (agent:make-agent-tools (list w p) :producer +p+))
           (pw (agent:make-agent-tools (list p w) :producer +p+))
           (r-wp (%call wp "recall" "subject-namespace" "repo"
                        "subject-key" "cl-llm"))
           (r-pw (%call pw "recall" "subject-namespace" "repo"
                        "subject-key" "cl-llm")))
      (is (equal '("cl-llm-memory" "memory-private")
                 (map 'list (lambda (x) (json:jget x "store"))
                      (json:jget r-wp "records"))))
      (is (equal '("memory-private" "cl-llm-memory")
                 (map 'list (lambda (x) (json:jget x "store"))
                      (json:jget r-pw "records")))))))

(test recall-of-nothing-is-an-empty-array-not-an-absence
  (with-stores (w p)
    (gdb:with-transaction (:graph w)
      (mem:record-absence w +subj+ "release-date" :producer +p+
                          :standing :searched-empty))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm"))
           (rec (first (coerce (json:jget r "records") 'list))))
      (is (null (json:jget rec "object")))
      (is (string= "searched-empty" (json:jget rec "standing")))
      (let ((none (%call tools "recall" "subject-namespace" "repo"
                         "subject-key" "nothing-here")))
        (is (= 0 (length (json:jget none "records"))))))))

(test recall-of-an-unknown-namespace-is-an-empty-array
  "A namespace no belief was ever recorded under is never interned by
%FIND-KEYWORD, so it reads as nothing recorded, not an error (SS6)."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace"
                     "totally-unknown-namespace-zzz"
                     "subject-key" "cl-llm")))
      (is (= 0 (length (json:jget r "records")))))))

(test recall-of-a-malformed-timestamp-signals
  (with-stores (w p)
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "recall")
                       (%args "subject-namespace" "repo"
                              "subject-key" "cl-llm"
                              "at" "not-a-time"))))))

(test trace-and-decisions-citing-across-the-scope
  (with-stores (w p)
    (let* ((private (%belief p "owner" '(:person . "kevin")))
           (d (mem:conclude w (list :belief +subj+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list private)
                            :rule "r" :rule-version "1"))
           (tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "trace" "decision-id" (mem:decision-id d))))
      (is (string= "concluded" (json:jget r "outcome")))
      (is (string= "cl-llm-memory" (json:jget r "store")))
      (is (string= "r" (json:jget r "rule")))
      (let ((ev (first (coerce (json:jget r "evidence") 'list))))
        (is (string= "memory-private" (json:jget ev "store")))
        (is (string= "resolved" (json:jget ev "state")))
        (is (null (json:jget ev "changed-since"))))
      (let ((c (%call tools "decisions-citing"
                      "cite" (mem:claim-cite private))))
        (is (string= (mem:decision-id d)
                     (json:jget (first (coerce (json:jget c "decisions")
                                               'list))
                                "id")))))))

(test trace-omits-store-for-an-out-of-scope-evidence-cite
  "An evidence cite naming a store outside this tool set's scope
resolves :ABSENT; it must not be rendered with a STORE anyway -- that
would falsely suggest it was found (spec SS6)."
  (with-stores (w p)
    (let* ((private (%belief p "owner" '(:person . "kevin")))
           (d (mem:conclude w (list :belief +subj+ "releasable"
                                    '(:v . "yes") :standing :inferred)
                            :producer +p+ :evidence (list private)
                            :rule "r"))
           (tools (agent:make-agent-tools (list w) :producer +p+))
           (r (%call tools "trace" "decision-id" (mem:decision-id d)))
           (ev (first (coerce (json:jget r "evidence") 'list))))
      (is (string= "absent" (json:jget ev "state")))
      (is (not (nth-value 1 (gethash "store" ev)))))))

(test decisions-citing-orders-newest-first-across-stores
  "The newer decision -- written into the second store -- sorts first,
regardless of which store either lives in (spec SS5/SS6)."
  (with-stores (w p)
    (let* ((private (%belief p "owner" '(:person . "kevin")))
           (d1 (mem:conclude w (list :belief +subj+ "releasable"
                                     '(:v . "yes") :standing :inferred)
                             :producer +p+ :evidence (list private)
                             :rule "r1"))
           (d2 (mem:conclude p (list :belief +subj+ "deployable"
                                     '(:v . "yes") :standing :inferred)
                             :producer +p+ :evidence (list private)
                             :rule "r2"))
           (tools (agent:make-agent-tools (list w p) :producer +p+))
           (c (%call tools "decisions-citing"
                     "cite" (mem:claim-cite private)))
           (ids (map 'list (lambda (x) (json:jget x "id"))
                     (json:jget c "decisions"))))
      (is (equal (list (mem:decision-id d2) (mem:decision-id d1)) ids)))))

(test trace-of-an-unknown-id-signals
  (with-stores (w p)
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "trace")
                       (%args "decision-id" "nope"))))))

(test conclude-writes-a-decision-into-the-write-store-citing-what-it-read
  (with-stores (w p)
    (%belief p "owner" '(:person . "kevin"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm"))
           (cite (json:jget (first (coerce (json:jget r "records") 'list))
                            "cite"))
           (c (%call tools "conclude"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "releasable"
                     "object-namespace" "verdict" "object-key" "yes"
                     "rule" "owner-says" "rule-version" "1"
                     "evidence" (vector cite) "confidence" 0.8)))
      (is (string= "concluded" (json:jget c "outcome")))
      (is (string= "cl-llm-memory" (json:jget c "store")))
      (is (mem:cite-p (json:jget c "claim-cite")))
      (is (equalp #() (json:jget c "refusals")))
      (let ((t2 (%call tools "trace" "decision-id" (json:jget c "id"))))
        (is (string= "owner-says" (json:jget t2 "rule")))
        (is (string= cite (json:jget (first (coerce (json:jget t2 "evidence")
                                                   'list))
                                     "cite")))
        (is (string= "memory-private"
                     (json:jget (first (coerce (json:jget t2 "evidence")
                                               'list))
                                "store"))))
      (is (= 1 (length (mem:recall w +subj+ :relation "releasable"))))
      (is (null (mem:recall p +subj+ :relation "releasable"))
          "control: the private store gained nothing"))))

(test conclude-standing-defaults-to-inferred-and-is-checked
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (c (%call tools "conclude"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "x" "object-namespace" "v" "object-key" "1"
                     "rule" "r")))
      (is (string= "concluded" (json:jget c "outcome")))
      (is (eq :inferred (st:claim-standing
                         (mem:belief-record-claim
                          (first (mem:recall w +subj+ :relation "x"))))))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "conclude")
                       (%args "subject-namespace" "repo" "subject-key" "cl-llm"
                              "relation" "y" "object-namespace" "v"
                              "object-key" "1" "rule" "r"
                              "standing" "searched-empty"))))))

(test a-refused-conclude-is-a-result-the-model-can-read
  "SS6: refusal is data.  A lapsed belief re-asserted inside its own
window trips the validator; no belief is written."
  (with-stores (w p)
    (gdb:with-transaction (:graph w)
      (mem:record-belief w +subj+ "ci-status" '(:verdict . "green")
                         :producer +p+ :standing :observed
                         :extent (te:make-interval
                                  (te:exact-bound (%ts "2026-01-01T00:00:00Z"))
                                  (te:exact-bound (%ts "2026-03-01T00:00:00Z"))
                                  :semantics :validity :standing :asserted)))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (c (%call tools "conclude"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "ci-status" "object-namespace" "verdict"
                     "object-key" "green" "rule" "r" "standing" "observed"
                     "valid-from" "2026-02-01T00:00:00Z")))
      (is (string= "refused" (json:jget c "outcome")))
      (is (null (json:jget c "claim-cite")))
      (is (string= "subsystem"
                   (json:jget (first (coerce (json:jget c "refusals") 'list))
                              "family")))
      (is (= 1 (length (mem:recall w +subj+ :relation "ci-status"
                                   :include-retracted t)))
          "nothing new was written"))))

(test conclude-absence-writes-a-unary-decision
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (c (%call tools "conclude-absence"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "release-date" "rule" "looked"
                     "standing" "searched-empty")))
      (is (string= "concluded" (json:jget c "outcome")))
      (let ((r (first (mem:recall w +subj+ :relation "release-date"))))
        (is (typep (mem:belief-record-claim r) 'mem:belief-unary))
        (is (eq :searched-empty (mem:belief-record-standing r)))))))

(test retract-acts-on-the-write-store-only
  (with-stores (w p)
    (let* ((own (%belief w "ci-status" '(:verdict . "green")))
           (theirs (%belief p "owner" '(:person . "kevin")))
           (tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retract" "cite" (mem:claim-cite own))))
      (is (string= (mem:claim-cite own) (json:jget r "cite")))
      (is (stringp (json:jget r "retracted-at")))
      (is (null (mem:recall w +subj+ :relation "ci-status")))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "retract")
                       (%args "cite" (mem:claim-cite theirs))))
      (is (= 1 (length (mem:recall p +subj+ :relation "owner")))
          "control: the private belief stands")
      (signals (llm:llm-tool-error "already retracted")
        (llm:call-tool (%tool tools "retract")
                       (%args "cite" (mem:claim-cite own)))))))

(test retract-then-conclude-at-the-same-valid-from-is-refused
  "Review finding 1 asked whether RETRACT then CONCLUDE at the same
VALID-FROM leaves two live claims sharing one cite -- CLAIMS-TOUCHING
returns retracted claims too, and a claim's identity key (hence its
cite) survives retraction.  Verified empirically (see the fix report):
BELIEF's own :UNIQUE identity tuple is canonicalized by the same
EXTENT-SEXP-START-KEY function CLAIM-CITE uses (spacetime/claim.lisp,
DEF-CLAIM-CLASSES: \"the extent START joins both identity tuples\"), so
the engine refuses the second write outright -- a retracted claim still
holds its slot.  This locks in that safety property; RETRACT is still
made to prefer a CURRENT claim over CLAIMS-TOUCHING's first hit as
defense in depth, in case a future write path (bulk import, a schema
relaxation) ever produces a genuine collision this constraint no longer
catches."
  (with-stores (w p)
    (let* ((own (%belief w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite own))
           (tools (agent:make-agent-tools (list w p) :producer +p+)))
      (%call tools "retract" "cite" cite)
      (let ((c (%call tools "conclude"
                      "subject-namespace" "repo" "subject-key" "cl-llm"
                      "relation" "ci-status" "object-namespace" "verdict"
                      "object-key" "green" "rule" "r"
                      "valid-from" "2026-09-01T08:00:00Z")))
        (is (string= "refused" (json:jget c "outcome")))
        (is (null (json:jget c "claim-cite")))
        (is (string= "unique"
                     (json:jget (first (coerce (json:jget c "refusals")
                                               'list))
                                "family"))))
      (is (null (mem:recall w +subj+ :relation "ci-status"))
          "nothing live survives either write"))))

(test conclude-rejects-a-noncanonical-namespace-and-writes-nothing
  "Controller ruling 2: every namespace the model supplies to a write
tool goes through the validating %KEYWORD, so a namespace that is not
[a-z0-9-]+ is a tool error, never a silent intern -- on either side of
conclude's proposal, and on conclude-absence too -- and no partial
write survives it."
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (before-beliefs (st:claims-touching w 'mem:belief :repo
                                               "cl-llm" :role :subject))
           (before-traces (st:claims-by-producer w 'mem:trace +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "conclude")
                       (%args "subject-namespace" "Repo Name"
                              "subject-key" "cl-llm"
                              "relation" "x" "object-namespace" "v"
                              "object-key" "1" "rule" "r")))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "conclude")
                       (%args "subject-namespace" "repo"
                              "subject-key" "cl-llm"
                              "relation" "x" "object-namespace" "Bad NS"
                              "object-key" "1" "rule" "r")))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "conclude-absence")
                       (%args "subject-namespace" "Repo Name"
                              "subject-key" "cl-llm"
                              "relation" "x" "rule" "r"
                              "standing" "searched-empty")))
      (is (= (length before-beliefs)
             (length (st:claims-touching w 'mem:belief :repo "cl-llm"
                                         :role :subject)))
          "control: no belief claim was written")
      (is (= (length before-traces)
             (length (st:claims-by-producer w 'mem:trace +p+)))
          "control: no decision/trace claim was written"))))

(test conclude-signals-on-an-evidence-cite-out-of-scope
  "Controller ruling 3: a cite the model passed that CITE-STORE cannot
resolve in scope is an error, never silently charged to the write
store."
  (with-stores (w p)
    (let* ((theirs (%belief p "owner" '(:person . "kevin")))
           (tools (agent:make-agent-tools (list w) :producer +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "conclude")
                       (%args "subject-namespace" "repo"
                              "subject-key" "cl-llm"
                              "relation" "x" "object-namespace" "v"
                              "object-key" "1" "rule" "r"
                              "evidence" (vector (mem:claim-cite theirs)))))
      (is (null (mem:recall w +subj+ :relation "x"))
          "nothing was written"))))
