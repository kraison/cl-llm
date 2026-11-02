;;;; tests-conversation-vivace/packages.lisp

(defpackage #:cl-llm.conversation.vivace/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:cv #:cl-llm.conversation.vivace)
                    (#:llm #:cl-llm)
                    (#:gdb #:graph-db)))
