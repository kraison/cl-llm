;;;; tests-agent-prolog/packages.lisp

(defpackage #:cl-llm.agent.prolog/tests
  (:use #:cl #:fiveam #:cl-llm.agent/tests)
  (:local-nicknames (#:prolog #:cl-llm.agent.prolog) (#:agent #:cl-llm.agent)
                    (#:llm #:cl-llm) (#:json #:cl-llm.json)
                    (#:mem #:cl-llm.memory)))
