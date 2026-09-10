;;;; agent/mcp/packages.lisp -- the memory as its own MCP server (#57).

(defpackage #:cl-llm.agent.mcp
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions)
                    (#:agent #:cl-llm.agent)
                    (#:mem #:cl-llm.memory)
                    (#:rag #:cl-llm.rag)
                    (#:gdb #:graph-db)
                    (#:st #:graph-db.spacetime)
                    (#:mcp #:cl-mcp)
                    (#:mcp.tools #:cl-mcp.tools))
  (:export
   ;; config
   #:env #:parse-scope #:declare-store-schemas #:open-scope #:close-scope
   ;; the semantic endpoint index's embedder (#78 SS5)
   #:embedder-from-env #:probe-embedding-dimension #:embed-key-source
   #:index-off-reason
   ;; adapter
   #:make-memory-server #:register-llm-tool
   ;; identity
   #:read-principals #:loopback-p #:check-bind #:hello-line-p
   #:parse-hello #:resolve-identity
   ;; listener
   #:listener #:start-listener #:stop-listener #:listener-port
   #:listener-thread))
