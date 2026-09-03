;;;; tests-agent/memory-tools-tests.lisp -- spec SS5, SS6: the read
;;;; tools across a scope.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(test make-agent-tools-needs-a-producer-and-a-write-store-in-scope
  (with-stores (w p)
    (signals error (agent:make-agent-tools (list w p)))
    (signals error (agent:make-agent-tools (list w) :write-store p
                                                    :producer +p+))
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

(test trace-of-an-unknown-id-signals
  (with-stores (w p)
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "trace")
                       (%args "decision-id" "nope"))))))
