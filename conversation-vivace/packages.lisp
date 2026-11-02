;;;; conversation-vivace/packages.lisp -- stored conversations in a
;;;; graph-db graph (#89).  docs/conversations.md, "The graph store".

(defpackage #:cl-llm.conversation.vivace
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:gdb #:graph-db))
  (:export #:define-conversation-store
           #:graph-conversation-store #:make-graph-conversation-store
           #:graph-conversation-store-graph))
