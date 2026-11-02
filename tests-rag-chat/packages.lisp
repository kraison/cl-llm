;;;; tests-rag-chat/packages.lisp

(defpackage #:cl-llm.rag.chat/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:chat #:cl-llm.rag.chat)
                    (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag)
                    (#:harness #:cl-llm.harness)))
