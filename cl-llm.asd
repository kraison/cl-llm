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
                              :components ((:file "anthropic")))
                             (:file "tool-loop")
                             (:file "facade"))))
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
                             (:file "tool-loop"))))
  :perform (test-op (op c)
             (unless (symbol-call :cl-llm.test :run-offline-suite)
               (error "cl-llm test suite failed."))))
