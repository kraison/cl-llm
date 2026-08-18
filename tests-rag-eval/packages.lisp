;;;; tests-rag-eval/packages.lisp

(defpackage #:cl-llm.rag.eval.test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rag #:cl-llm.rag)
                    (#:eval #:cl-llm.eval)
                    (#:re #:cl-llm.rag.eval))
  (:export #:cl-llm-rag-eval-suite))
