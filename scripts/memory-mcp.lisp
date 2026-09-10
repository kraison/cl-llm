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
  ;; CL_LLM_ASDF_REGISTRY (#72): scripts/registry.lisp.
  (load (merge-pathnames "registry.lisp" *load-truename*))
  (funcall (intern "QUICKLOAD" "QL") :cl-llm/agent/mcp :silent t)
  (when (equal (uiop:getenv "CL_LLM_MEMORY_QUERY_TOOL") "1")
    (funcall (intern "QUICKLOAD" "QL") :cl-llm/agent/prolog :silent t)))

(defpackage #:cl-llm.memory-mcp
  (:use #:cl)
  (:local-nicknames (#:mcp #:cl-llm.agent.mcp) (#:gdb #:graph-db)
                    (#:mem #:cl-llm.memory) (#:agent #:cl-llm.agent)))

(in-package #:cl-llm.memory-mcp)

(defvar *stores* nil)
(defvar *clock* nil)
(defvar *embedder* nil
  "The semantic index's embedder, or NIL when the index is off for this
run -- unconfigured, misconfigured, or the probe failed (#78 SS5).")
(defvar *indexer* nil
  "The endpoint indexer worker; NIL whenever *EMBEDDER* is.")

(defun %home (relative)
  (namestring (merge-pathnames relative (user-homedir-pathname))))

(defun %dir (s) (namestring (uiop:ensure-directory-pathname s)))

(defun %note (control &rest args)
  "One line to stderr, guarded: a broken stream must not cost the
session its server."
  (ignore-errors
   (format *error-output* "~&memory mcp: ~?~%" control args)
   (finish-output *error-output*)))

(defun stop ()
  "Stop the indexer -- it writes to the stores, so it is joined first --
then close every store and the clock; never signals; idempotent.  The
exit hook, so SIGTERM leaves no .dirty marker (SS6)."
  (when *indexer*
    (mem:stop-endpoint-indexer *indexer*)
    (setf *indexer* nil))
  (when (or *stores* *clock*)
    (mcp:close-scope *stores* *clock*)
    (setf *stores* nil *clock* nil)))

(defun start ()
  "Point log4cl's console at stderr, open the scope, reset the semantic
index's vector segments, and build the server; => the cl-mcp server.
The worker is not started here: the caller starts it once START has
returned, so it logs to the process's stderr and never to the JSON-RPC
stdout (#78 SS5)."
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
    ;; Before OPEN-SCOPE, and GLOBAL rather than a LET: log4cl resolves
    ;; *DEBUG-IO* per write, and a thread created later inherits the
    ;; global value (BT:*DEFAULT-SPECIAL-BINDINGS* is NIL), whose output
    ;; side under --script is stdout -- so graph-db's buffer-pool
    ;; monitor thread logs into the JSON-RPC stream (kraison/cl-llm#79).
    (let ((io (make-two-way-stream *standard-input* *error-output*)))
      (setf (sb-ext:symbol-global-value 'cl:*debug-io*) io
            *debug-io* io))
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
      ;; Before the server can serve a search: the dimension is known
      ;; only from an embedding, and the engine's segment rebuild is
      ;; unsafe against a concurrent search (#78 SS4.3 step 4).  A down
      ;; or misconfigured embedder costs this run its index, never the
      ;; session -- the tools stay lexical and the client sees a server.
      (handler-case
          (let ((ee (mcp:embedder-from-env)))
            (when ee
              (let ((d (mcp:probe-embedding-dimension ee)))
                (dolist (g stores)
                  (when (mem:reset-endpoint-segment g d)
                    (%note "semantic index: segment reset to ~
dimension ~d (~a)"
                           d (mem:store-name g)))))
              (setf *embedder* ee)
              ;; The image says this in its banner; the solo server has
              ;; none, and "index on" is not otherwise observable (#78).
              (%note "index ~a floor ~a (key: ~a)"
                     (agent:endpoint-embedder-model ee)
                     (agent:endpoint-embedder-floor ee)
                     (mcp:embed-key-source))))
        (error (c)
          (%note "semantic index off: ~a" (mcp:index-off-reason c))
          (setf *embedder* nil)))
      (mcp:make-memory-server
       stores :write-store write-store :producer producer
       :embedder *embedder*
       :query-tool (equal (mcp:env "CL_LLM_MEMORY_QUERY_TOOL") "1")))))

(defun %die (control &rest args)
  "Report on stderr and exit 1.  STOP first: the exit is :abort t, which
skips the hooks, and the hook is not pushed yet -- a failure after
OPEN-SCOPE returned would otherwise leave the .dirty marker behind.  A
no-op on the two refusal paths, where nothing opened."
  (stop)
  (apply #'format *error-output* control args)
  (finish-output *error-output*)
  (sb-ext:exit :code 1 :abort t))

(let ((server
        ;; stdout carries JSON-RPC only, so the open's logging goes to
        ;; stderr by binding, not by trusting the engine's stream.
        (handler-case (let ((*standard-output* *error-output*))
                        (start))
          (gdb:store-not-closed-cleanly-error (c)
            (%die "~&memory mcp: ~A~%Another image may hold the store.  ~
                   If none does, delete its .dirty marker and start ~
                   again.~%" c))
          (gdb:system-clock-in-use (c)
            (%die "~&memory mcp: ~A~%Another image holds the clock at ~
                   that location.~%" c))
          (error (c)
            (%die "~&memory mcp: ~A~%" c)))))
  ;; Only once the scope is open: every failure above leaves through
  ;; %DIE, which stops the scope itself before exiting with no hook.
  (push #'stop sb-ext:*exit-hooks*)
  ;; One worker per process, started outside START's *STANDARD-OUTPUT*
  ;; binding: it logs to the *ERROR-OUTPUT* of this call, which here is
  ;; the process's stderr -- stdout carries JSON-RPC only (#78 SS4.3).
  (when *embedder*
    (setf *indexer*
          (mem:start-endpoint-indexer
           *stores*
           :embed (agent:endpoint-embedder-embed *embedder*)
           :model (agent:endpoint-embedder-model *embedder*))))
  (cl-mcp:run-server server :input *standard-input*
                            :output *standard-output*)
  (stop)
  (sb-ext:exit :code 0))
