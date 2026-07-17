;;;; tests-eval/packages.lisp

(defpackage #:cl-llm.eval.test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:eval #:cl-llm.eval)
                    (#:c #:cl-llm.conditions))
  (:export #:cl-llm-eval-suite))
