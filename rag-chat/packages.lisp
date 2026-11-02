;;;; rag-chat/packages.lisp -- a RAG turn that understands follow-ups
;;;; (#90).  docs/conversations.md, "The conversational turn".

(defpackage #:cl-llm.rag.chat
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:json #:cl-llm.json)
                    (#:rag #:cl-llm.rag)
                    (#:harness #:cl-llm.harness))
  (:export #:*rewrite-instructions* #:*summary-instructions*
           #:rag-chat #:make-rag-chat #:rag-chat-turn
           #:rag-turn #:rag-turn-answer #:rag-turn-hits
           #:rag-turn-standalone #:rag-turn-stop-reason #:rag-turn-error
           #:rag-turn-runs))
