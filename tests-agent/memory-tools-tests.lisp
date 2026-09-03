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
