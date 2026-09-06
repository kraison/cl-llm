;;;; tests-agent-mcp/packages.lisp

(defpackage #:cl-llm.agent.mcp/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:mcp #:cl-llm.agent.mcp)
                    (#:agent #:cl-llm.agent)
                    (#:mem #:cl-llm.memory)
                    (#:gdb #:graph-db)
                    (#:st #:graph-db.spacetime)
                    (#:json #:cl-llm.json)
                    (#:mcp.tools #:cl-mcp.tools)
                    (#:client #:cl-mcp.client))
  ;; The clocked two-store fixture and its helpers (tests-agent/harness).
  (:import-from #:cl-llm.agent/tests
                #:with-stores #:%belief #:+p+ #:+subj+))
