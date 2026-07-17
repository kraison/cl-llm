;;;; tests-rag/packages.lisp

(defpackage #:cl-llm.rag.test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag)
                    (#:json #:cl-llm.json)
                    (#:c #:cl-llm.conditions))
  (:export #:cl-llm-rag-suite))
