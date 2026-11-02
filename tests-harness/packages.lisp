;;;; tests-harness/packages.lisp

(defpackage #:cl-llm.harness/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:harness #:cl-llm.harness)))
