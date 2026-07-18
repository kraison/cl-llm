;;;; tests-vivace/packages.lisp

(defpackage #:cl-llm.rag.vivace/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:v #:cl-llm.rag.vivace)
                    (#:rag #:cl-llm.rag)
                    (#:llm #:cl-llm)
                    (#:gdb #:graph-db)))
