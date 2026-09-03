;;;; agent/packages.lisp

(defpackage #:cl-llm.agent
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:json #:cl-llm.json)
                    (#:mem #:cl-llm.memory)
                    (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent)
                    (#:rag #:cl-llm.rag)
                    (#:claims #:cl-llm.rag.claims))
  (:export
   ;; scope
   #:scope #:make-scope #:scope-stores #:scope-write-store
   #:scope-producer #:scope-sources #:scope-k #:scope-max-rows
   #:find-store #:note-cite #:cite-store #:scope-error
   ;; tools
   #:make-agent-tools #:make-memory-tools #:make-planner-tools))
