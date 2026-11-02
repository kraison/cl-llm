;;;; tests-harness/packages.lisp

(defpackage #:cl-llm.harness/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:json #:cl-llm.json)
                    (#:harness #:cl-llm.harness)))
