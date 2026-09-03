;;;; agent/prolog/packages.lisp

(defpackage #:cl-llm.agent.prolog
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm) (#:json #:cl-llm.json)
                    (#:agent #:cl-llm.agent) (#:mem #:cl-llm.memory)
                    (#:gdb #:graph-db))
  (:export #:make-query-tool))
