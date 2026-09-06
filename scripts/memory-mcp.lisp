;;;; scripts/memory-mcp.lisp -- the memory as a stdio MCP server, the
;;;; solo mode: one process per client session, launched by the client.
;;;; Run through scripts/run-memory-mcp.sh; docs/agent-memory.md, "The
;;;; memory as an MCP server".  stdout carries JSON-RPC only: everything
;;;; else goes to stderr.

;; --script skips the userinit, so Quicklisp is loaded by hand (the
;; same dance as cl-mcp-server/run-server.lisp).  Two forms, not one:
;; --script reads a whole top-level form before evaluating it, so the
;; UIOP symbols below cannot be read until (require :asdf) has run.
(let ((*standard-output* *error-output*)
      (*trace-output* *error-output*))
  (require :asdf)
  (flet ((try (path) (when (probe-file path) (load path) t)))
    (let ((home (user-homedir-pathname)))
      (or (try (merge-pathnames "quicklisp/setup.lisp" home))
          (try (merge-pathnames ".quicklisp/setup.lisp" home))
          (try #p"/usr/local/share/quicklisp/setup.lisp")))))

(let ((*standard-output* *error-output*)
      (*trace-output* *error-output*))
  ;; CL_LLM_ASDF_REGISTRY: colon-separated trees, first on the registry,
  ;; so the child builds what its launcher built (plan ruling 1).
  (let ((registry (uiop:getenv "CL_LLM_ASDF_REGISTRY")))
    (when (and registry (plusp (length registry)))
      (dolist (dir (reverse (uiop:split-string registry :separator ":")))
        (when (plusp (length dir))
          (push (uiop:ensure-directory-pathname dir)
                asdf:*central-registry*)))))
  (funcall (intern "QUICKLOAD" "QL") :cl-llm/agent/mcp :silent t)
  (when (equal (uiop:getenv "CL_LLM_MEMORY_QUERY_TOOL") "1")
    (funcall (intern "QUICKLOAD" "QL") :cl-llm/agent/prolog :silent t)))

(defpackage #:cl-llm.memory-mcp
  (:use #:cl)
  (:local-nicknames (#:mcp #:cl-llm.agent.mcp) (#:gdb #:graph-db)))

(in-package #:cl-llm.memory-mcp)

(defvar *stores* nil)
(defvar *clock* nil)

(defun %home (relative)
  (namestring (merge-pathnames relative (user-homedir-pathname))))

(defun %dir (s) (namestring (uiop:ensure-directory-pathname s)))

(defun stop ()
  "Close every store, then the clock; never signals; idempotent.  The
exit hook, so SIGTERM leaves no .dirty marker (SS6)."
  (when (or *stores* *clock*)
    (mcp:close-scope *stores* *clock*)
    (setf *stores* nil *clock* nil)))

(defun start ()
  "Open the scope and build the server; => the cl-mcp server."
  (let* ((scope (mcp:env "CL_LLM_MEMORY_SCOPE"))
         (spec (if scope
                   (mcp:parse-scope scope)
                   (list (cons (intern (string-upcase
                                        (mcp:env "CL_LLM_MEMORY_GRAPH"
                                                 "cl-llm-memory"))
                                       :keyword)
                               (%dir (mcp:env
                                      "CL_LLM_MEMORY_STORE"
                                      (%home
                                       ".cl-llm-memory/working/")))))))
         (producer (mcp:env "CL_LLM_MEMORY_PRODUCER"
                            (format nil "claude-code/~(~a~)"
                                    (machine-instance)))))
    (multiple-value-bind (stores write-store clock)
        (mcp:open-scope
         :spec spec :write (mcp:env "CL_LLM_MEMORY_WRITE")
         :clock-dir (%dir (mcp:env "CL_LLM_MEMORY_CLOCK"
                                   (%home ".cl-llm-memory/clock/")))
         :system-dir (%dir (mcp:env "CL_LLM_MEMORY_SYSTEM"
                                    (%home ".cl-llm-memory/system/")))
         :buffer-pool (parse-integer
                       (mcp:env "CL_LLM_MEMORY_BUFFER_POOL" "2000")))
      (setf *stores* stores *clock* clock)
      (mcp:make-memory-server
       stores :write-store write-store :producer producer
       :query-tool (equal (mcp:env "CL_LLM_MEMORY_QUERY_TOOL") "1")))))

(defun %die (control &rest args)
  (apply #'format *error-output* control args)
  (finish-output *error-output*)
  (sb-ext:exit :code 1 :abort t))

(let ((server
        (handler-case (start)
          (gdb:store-not-closed-cleanly-error (c)
            (%die "~&memory mcp: ~A~%Another image may hold the store.  ~
                   If none does, delete its .dirty marker and start ~
                   again.~%" c))
          (gdb:system-clock-in-use (c)
            (%die "~&memory mcp: ~A~%Another image holds the clock at ~
                   that location.~%" c))
          (error (c)
            (%die "~&memory mcp: ~A~%" c)))))
  ;; Only once the scope is open: a refusal above exits with no hook.
  (push #'stop sb-ext:*exit-hooks*)
  (cl-mcp:run-server server :input *standard-input*
                            :output *standard-output*)
  (stop)
  (sb-ext:exit :code 0))
