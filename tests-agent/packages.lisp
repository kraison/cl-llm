;;;; tests-agent/packages.lisp

(defpackage #:cl-llm.agent/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:agent #:cl-llm.agent)
                    (#:llm #:cl-llm)
                    (#:json #:cl-llm.json)
                    (#:mem #:cl-llm.memory)
                    (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent)
                    (#:rag #:cl-llm.rag)
                    ;; %REPLACE-ALL-IN-FILE, shared rather than
                    ;; duplicated (#14 unit 3 residual).
                    (#:memt #:cl-llm.memory/tests))
  ;; Shared with cl-llm/agent/prolog/tests (#14 unit 2); controller
  ;; ruling: kept under their existing %-names, no rename.
  (:export #:with-stores #:%belief #:%tool #:%args #:%call #:+p+ #:+subj+
           #:%banner-dir))
