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
   #:scope-embedder
   #:find-store #:note-cite #:cite-store #:scope-error #:clamp
   ;; render
   #:json-bool
   ;; tools
   #:make-agent-tools #:make-memory-tools #:make-planner-tools
   #:make-key-extractor
   ;; the semantic endpoint index (#78)
   #:endpoint-embedder #:make-endpoint-embedder #:endpoint-embedder-p
   #:endpoint-embedder-embedder #:endpoint-embedder-model
   #:endpoint-embedder-floor #:endpoint-embedder-embed
   #:make-hybrid-key-extractor
   ;; annotate
   #:annotation-tools #:annotate-banners #:*annotation-instructions*))
