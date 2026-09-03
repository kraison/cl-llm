;;;; tests-memory/packages.lisp

(defpackage #:cl-llm.memory/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:mem #:cl-llm.memory)
                    (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent))
  ;; Shared with cl-llm/agent/tests (#14 unit 3 residual): a banner
  ;; correction needs the same in-place file rewrite there.
  (:export #:%replace-all-in-file))
