;;;; cl-llm.asd

(defsystem "cl-llm"
  :description "Common Lisp library for interacting with and tuning LLMs"
  :author "Kevin Raison"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("dexador" "com.inuoe.jzon" "uiop")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "conditions")
                             (:file "json")
                             (:file "sse")
                             (:file "http")
                             (:file "retry")
                             (:file "core")
                             (:file "tools")
                             (:file "protocol")
                             (:module "providers"
                              :serial t
                              :components ((:file "anthropic")
                                           (:file "openai")))
                             (:file "tool-loop")
                             (:file "facade")
                             (:file "streaming")
                             (:file "mock"))))
  :in-order-to ((test-op (test-op "cl-llm/tests"))))

(defsystem "cl-llm/tests"
  :description "Offline test suite for cl-llm"
  :license "MIT"
  :depends-on ("cl-llm" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "packages")
                             (:file "suite")
                             (:file "json")
                             (:file "conditions")
                             (:file "sse")
                             (:file "fake-driver")
                             (:file "http")
                             (:file "retry")
                             (:file "core")
                             (:file "protocol")
                             (:file "anthropic")
                             (:file "tools")
                             (:file "facade")
                             (:file "tool-loop")
                             (:file "streaming")
                             (:file "openai")
                             (:file "mock"))))
  :perform (test-op (op c)
             (unless (symbol-call :cl-llm.test :run-offline-suite)
               (error "cl-llm test suite failed."))))

(defsystem "cl-llm/live"
  :description "Live-endpoint tests for cl-llm. Requires CL_LLM_LIVE=1."
  :license "MIT"
  :depends-on ("cl-llm" "fiveam")
  :serial t
  :components ((:module "live"
                :serial t
                :components ((:file "packages")
                             (:file "live"))))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! (find-symbol* :cl-llm-live-suite :cl-llm.live))
               (error "cl-llm live suite failed."))))

(defsystem "cl-llm/eval"
  :description "Evaluation harness for cl-llm: dataset x variants x scorers."
  :license "MIT"
  :depends-on ("cl-llm")
  :serial t
  :components ((:module "eval"
                :serial t
                :components ((:file "packages")
                             (:file "score")
                             (:file "case")
                             (:file "scorer")
                             (:file "judge")
                             (:file "suite")
                             (:file "run")
                             (:file "report"))))
  :in-order-to ((test-op (test-op "cl-llm/eval/tests"))))

(defsystem "cl-llm/eval/tests"
  :description "Offline test suite for cl-llm/eval."
  :license "MIT"
  :depends-on ("cl-llm/eval" "fiveam")
  :serial t
  :components ((:module "tests-eval"
                :serial t
                :components ((:file "packages")
                             (:file "suite")
                             (:file "score")
                             (:file "scorer")
                             (:file "judge")
                             (:file "run")
                             (:file "report"))))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run!
                                  (find-symbol* :cl-llm-eval-suite :cl-llm.eval.test))
               (error "cl-llm/eval test suite failed."))))

(defsystem "cl-llm/rag"
  :description "Retrieval-augmented generation for cl-llm."
  :license "MIT"
  :depends-on ("cl-llm" "cl-temporal-extent")
  :serial t
  :components ((:module "rag"
                :serial t
                :components ((:file "packages")
                             (:file "embed")
                             (:file "document")
                             (:file "chunk")
                             (:file "store")
                             (:file "retrieve")
                             (:file "index")
                             (:file "sparse")
                             (:file "hybrid")
                             (:file "bundle")
                             (:file "answer"))))
  :in-order-to ((test-op (test-op "cl-llm/rag/tests"))))

(defsystem "cl-llm/rag/tests"
  :description "Offline test suite for cl-llm/rag."
  :license "MIT"
  :depends-on ("cl-llm/rag" "fiveam")
  :serial t
  :components ((:module "tests-rag"
                :serial t
                :components ((:file "packages")
                             (:file "suite")
                             (:file "embed")
                             (:file "document")
                             (:file "store")
                             (:file "retrieve")
                             (:file "index")
                             (:file "sparse")
                             (:file "hybrid")
                             (:file "bundle")
                             (:file "answer"))))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run!
                                  (find-symbol* :cl-llm-rag-suite :cl-llm.rag.test))
               (error "cl-llm/rag test suite failed."))))

(defsystem "cl-llm/rag/live"
  :description "Live embeddings tests for cl-llm/rag. Requires CL_LLM_LIVE=1."
  :license "MIT"
  :depends-on ("cl-llm/rag" "fiveam")
  :serial t
  :components ((:module "live-rag"
                :serial t
                :components ((:file "packages")
                             (:file "live"))))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run!
                                  (find-symbol* :cl-llm-rag-live-suite :cl-llm.rag.live))
               (error "cl-llm/rag live suite failed."))))

(defsystem "cl-llm/rag/vivace"
  :description "vivace-graph (graph-db) backed vector store for cl-llm/rag."
  :license "MIT"
  ;; graph-db/CORE, not the full graph-db: the chunk store is embedded
  ;; and needs no HTTP server or replication transport, and the full
  ;; system's :ningle/:clack web stack should not be the price of a
  ;; vector store -- a headless service host found it exactly that way.
  :depends-on ("cl-llm/rag" "graph-db/core")
  :serial t
  :pathname "vivace/"
  :components ((:file "packages")
               (:file "schema")
               (:file "store")))

(defsystem "cl-llm/rag/claims"
  :description "Claim traversal as an evidence-bundle source (#13 unit 3)."
  :license "MIT"
  :depends-on ("cl-llm/rag" "graph-db/spacetime")
  :serial t
  :pathname "claims/"
  :components ((:file "packages")
               (:file "source"))
  ;; Without this, (asdf:test-system :cl-llm/rag/claims) is a silent
  ;; no-op -- CI's claims step ran nothing from ad0d2eb until this
  ;; landed (kraison/cl-llm#26).
  :in-order-to ((test-op (test-op "cl-llm/rag/claims/tests"))))

(defsystem "cl-llm/rag/claims/tests"
  :description "On-disk-graph tests for cl-llm/rag/claims."
  :license "MIT"
  :depends-on ("cl-llm/rag/claims" "fiveam")
  :serial t
  :pathname "tests-claims/"
  :components ((:file "packages")
               (:file "source-tests"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-rag-claims)
               (error "cl-llm/rag/claims suite failed."))))

(defsystem "cl-llm/memory"
  :description "Tenant three: an agent's beliefs as claims (#16)."
  :license "MIT"
  ;; graph-db/spacetime only -- never cl-llm core or cl-llm/rag: this
  ;; tenant needs no LLM (spec 2026-09-01-agent-memory-tenant SS8).
  :depends-on ("graph-db/spacetime" "ironclad" "babel")
  :serial t
  :pathname "memory/"
  :components ((:file "packages")
               (:file "schema")
               (:file "write")
               (:file "recall")
               (:file "capture")
               (:file "cite")
               (:file "trace"))
  ;; The test-op link: without it TEST-SYSTEM is a silent no-op
  ;; (docs/ci.md, kraison/cl-llm#26).
  :in-order-to ((test-op (test-op "cl-llm/memory/tests"))))

(defsystem "cl-llm/memory/tests"
  :description "On-disk-graph tests for cl-llm/memory."
  :license "MIT"
  :depends-on ("cl-llm/memory" "fiveam")
  :serial t
  :pathname "tests-memory/"
  :components ((:file "packages")
               (:file "harness")
               (:file "schema-tests")
               (:file "write-tests")
               (:file "recall-tests")
               (:file "capture-tests")
               (:file "cite-tests")
               (:file "trace-tests"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-memory)
               (error "cl-llm/memory suite failed."))))

(defsystem "cl-llm/rag/vivace/tests"
  :description "Offline (in-memory-graph) tests for cl-llm/rag/vivace."
  :license "MIT"
  :depends-on ("cl-llm/rag/vivace" "cl-llm/rag" "fiveam")
  :serial t
  :pathname "tests-vivace/"
  :components ((:file "packages")
               (:file "suite")
               (:file "schema")
               (:file "store-scan")
               (:file "store-cache")
               (:file "store-segment")
               (:file "integration"))
  ;; NB: this suite needs a bigger heap than SBCL's 1GB default -- run with
  ;; `sbcl --dynamic-space-size 4096`, or ASDF:TEST-SYSTEM below exhausts it
  ;; on roughly two runs in three. See the Testing section of README.md and
  ;; tests-vivace/store-segment.lisp's header comment; tracked as cl-llm#11.
  :perform (test-op (o c)
             (unless (uiop:symbol-call :fiveam :run! :cl-llm-rag-vivace)
               (error "cl-llm/rag/vivace tests failed."))))

(defsystem "cl-llm/rag/eval"
  :description "Deterministic scoring of retrieval bundles."
  :license "MIT"
  :depends-on ("cl-llm/rag" "cl-llm/eval")
  :serial t
  :pathname "rag-eval/"
  :components ((:file "packages")
               (:file "scorers")
               (:file "golden"))
  :in-order-to ((test-op (test-op "cl-llm/rag/eval/tests"))))

(defsystem "cl-llm/rag/eval/tests"
  :description "Offline test suite for cl-llm/rag/eval."
  :license "MIT"
  :depends-on ("cl-llm/rag/eval" "fiveam")
  :serial t
  :pathname "tests-rag-eval/"
  :components ((:file "packages")
               (:file "suite")
               (:file "scorers")
               (:file "golden"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run!
                                  (find-symbol* :cl-llm-rag-eval-suite
                                                :cl-llm.rag.eval.test))
               (error "cl-llm/rag/eval test suite failed."))))

(defsystem "cl-llm/bench"
  :description "Benchmarks for cl-llm/rag. Not loaded by the test suites."
  :license "MIT"
  :depends-on ("cl-llm/rag/vivace")
  :serial t
  :components ((:module "bench"
                :serial t
                :components ((:file "packages")
                             (:file "corpus")
                             (:file "attribution")))))
