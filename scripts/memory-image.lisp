;;;; One long-lived image holding one cl-llm memory store, served over
;;;; SWANK on loopback so cl-mcp-server's remote-* tools can run Lisp
;;;; and Prolog against it.  Run through scripts/run-memory.sh; the
;;;; how-to, including the cl-mcp-server side, is docs/agent-memory.md
;;;; "Running a memory image".  graph-db stores are single-process:
;;;; nothing else may hold the store while this runs.
;;;;
;;;; Configuration is the environment (defaults in run-memory.sh):
;;;;   CL_LLM_MEMORY_STORE        store directory
;;;;   CL_LLM_MEMORY_SYSTEM       graph-db system directory
;;;;   CL_LLM_MEMORY_GRAPH        graph name, read as a keyword
;;;;   CL_LLM_MEMORY_SWANK_PORT   SWANK port, loopback only
;;;;   CL_LLM_MEMORY_PRODUCER     producer for decisions written here
;;;;   CL_LLM_MEMORY_BUFFER_POOL  graph-db buffer-pool pages
;;;;   CL_LLM_MEMORY_CLOCK        system-clock directory
;;;;   CL_LLM_MEMORY_MCP_PORT     MCP listener port; empty turns it off
;;;;   CL_LLM_MEMORY_MCP_BIND     MCP listener address
;;;;   CL_LLM_MEMORY_PRINCIPALS   principals file for the hello
;;;;   CL_LLM_MEMORY_IDENTITY     identity provider: secret or tailscale
;;;;   CL_LLM_MEMORY_QUERY_TOOL   1 adds the guarded Prolog tool
;;;;   CL_LLM_MEMORY_K            retrieval cap for MCP connections
;;;;   CL_LLM_MEMORY_MAX_ROWS     row cap for MCP connections
;;;;   CL_LLM_MEMORY_EMBED_URL    semantic index: OpenAI-compatible
;;;;                              embeddings base URL; empty is off
;;;;   CL_LLM_MEMORY_EMBED_MODEL  its model, required with a URL
;;;;   CL_LLM_MEMORY_EMBED_KEY    its API key, when it needs one
;;;;   CL_LLM_MEMORY_EMBED_FLOOR  cosine floor, required with a URL
;;;;   CL_LLM_ASDF_REGISTRY       colon-separated trees ahead of
;;;;                              Quicklisp's search; the banner names
;;;;                              the graph-db it resolved (#72)

(require :asdf)
;; Before the quickload, so the engine is the one asked for (#72).
(load (merge-pathnames "registry.lisp" *load-truename*))
(ql:quickload '(:cl-llm/agent/mcp :swank) :silent t)
;; Loaded only when asked for: the query tool pulls in graph-db/query
;; (#44), which nothing else in the image needs.
(when (equal (sb-ext:posix-getenv "CL_LLM_MEMORY_QUERY_TOOL") "1")
  (ql:quickload :cl-llm/agent/prolog :silent t))

(defpackage #:cl-llm.memory-image
  (:use #:cl)
  (:local-nicknames (#:mem #:cl-llm.memory)
                    (#:gdb #:graph-db)
                    (#:st #:graph-db.spacetime)
                    (#:agent #:cl-llm.agent)
                    (#:mcp #:cl-llm.agent.mcp))
  (:export #:*graph* #:*producer* #:start #:stop))

(in-package #:cl-llm.memory-image)

(defvar *graph* nil "The open store; also bound as GDB:*GRAPH*.")
(defvar *producer* nil "Producer string for decisions written here.")
(defvar *clock* nil
  "The image's system clock.  A property of the image, not of the store
on disk: a store reopened without it silently resumes its own counter
(S6b recon C1), so every open here passes it.")
(defvar *listener* nil
  "The MCP listener, or NIL when CL_LLM_MEMORY_MCP_PORT is empty.")
(defvar *embedder* nil
  "The semantic index's embedder, or NIL when the index is off for this
run -- unconfigured, misconfigured, or the probe failed (#78 SS5).")
(defvar *indexer* nil
  "The endpoint indexer worker; NIL whenever *EMBEDDER* is.")

(defun %env (name &optional default)
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun %home (relative)
  (namestring (merge-pathnames relative (user-homedir-pathname))))

(defun %dir (s)
  (if (char= (char s (1- (length s))) #\/) s (concatenate 'string s "/")))

(defun start ()
  "Open the store (make it when absent), bind it as the current graph,
reset the semantic index's vector segment, start SWANK, then the MCP
listener unless CL_LLM_MEMORY_MCP_PORT is empty, then the endpoint
indexer; return the graph.  A listener that will not start is reported
and skipped, and so is an embedder that will not answer (the banner
reads \"mcp off\" / \"index off\"); the store's own refusals are not:
it lets GDB:STORE-NOT-CLOSED-CLEANLY-ERROR through rather than open a
store another image left dirty."
  (let* ((store (%dir (%env "CL_LLM_MEMORY_STORE"
                            (%home ".cl-llm-memory/working/"))))
         (system (%dir (%env "CL_LLM_MEMORY_SYSTEM"
                             (%home ".cl-llm-memory/system/"))))
         (clock-dir (%dir (%env "CL_LLM_MEMORY_CLOCK"
                                (%home ".cl-llm-memory/clock/"))))
         (name (intern (string-upcase
                        (%env "CL_LLM_MEMORY_GRAPH" "cl-llm-memory"))
                       :keyword))
         (port (parse-integer (%env "CL_LLM_MEMORY_SWANK_PORT" "4008")))
         (pool (parse-integer (%env "CL_LLM_MEMORY_BUFFER_POOL" "2000"))))
    (setf *producer*
          (%env "CL_LLM_MEMORY_PRODUCER"
                (format nil "claude-code/~(~A~)" (machine-instance))))
    (setf gdb:*system-directory* system)
    (setf *clock* (gdb:open-system-clock clock-dir))
    (setf *graph*
          (if (probe-file (concatenate 'string store "schema.dat"))
              (gdb:open-graph name store :buffer-pool-size pool
                              :system-clock *clock*)
              (gdb:make-graph name store :buffer-pool-size pool
                              :system-clock *clock*)))
    (setf gdb:*graph* *graph*)
    ;; Before the listener and the worker: the dimension is known only
    ;; from an embedding, and the engine's segment rebuild is unsafe
    ;; against a concurrent search (#78 SS4.3 step 4).  Guarded like the
    ;; listener below -- a down or misconfigured embedder costs this run
    ;; its index, never the image's store or its REPL.
    (handler-case
        (let ((ee (mcp:embedder-from-env)))
          (when ee
            (mem:reset-endpoint-segment
             *graph*
             (length (funcall (agent:endpoint-embedder-embed ee) "probe")))
            (setf *embedder* ee)))
      (error (c)
        (ignore-errors
         (format *error-output*
                 "~&memory image: semantic index off: ~a~%" c)
         (finish-output *error-output*))
        (setf *embedder* nil)))
    ;; Raw, not %ENV: empty means off, only unset defaults (#75).
    (let ((mcp-port (or (sb-ext:posix-getenv "CL_LLM_MEMORY_MCP_PORT")
                        "4009"))
          (mcp-bind (%env "CL_LLM_MEMORY_MCP_BIND" "127.0.0.1")))
      (swank:create-server :port port :dont-close t :interface "127.0.0.1")
      ;; SWANK first, and the listener guarded: a taken port, a bad
      ;; bind, an unparsable port or cap, or a malformed principals file
      ;; must cost the image its listener, not its REPL (the banner then
      ;; reads "mcp off").
      (when (plusp (length mcp-port))
        (handler-case
            (setf *listener*
                  (mcp:start-listener
                   :bind mcp-bind
                   :port (parse-integer mcp-port)
                   :stores (list *graph*) :write-store *graph*
                   :provider (intern
                              (string-upcase
                               (%env "CL_LLM_MEMORY_IDENTITY" "secret"))
                              :keyword)
                   :principals-path
                   (%env "CL_LLM_MEMORY_PRINCIPALS"
                         (%home ".cl-llm-memory/principals.sexp"))
                   :default-producer *producer*
                   :query-tool (equal (%env "CL_LLM_MEMORY_QUERY_TOOL")
                                      "1")
                   ;; The connection's caps are the image's (#58).
                   :k (parse-integer (%env "CL_LLM_MEMORY_K" "5"))
                   :max-rows (parse-integer
                              (%env "CL_LLM_MEMORY_MAX_ROWS" "50"))
                   :embedder *embedder*))
          (error (c)
            (ignore-errors
             (format *error-output*
                     "~&memory image: mcp listener disabled: ~a~%"
                     (type-of c)))
            (setf *listener* nil))))
      ;; One worker per image, logging to this call's *ERROR-OUTPUT*
      ;; (stderr here) -- a new thread sees only the global stream.
      (when *embedder*
        (setf *indexer*
              (mem:start-endpoint-indexer
               (list *graph*)
               :embed (agent:endpoint-embedder-embed *embedder*)
               :model (agent:endpoint-embedder-model *embedder*))))
      ;; graph-db's source directory: a mismatched engine shows here,
      ;; not at the first missing symbol (#72).
      (format t "~&memory image: ~(~S~) at ~A as ~A; clock ~A; ~
swank 127.0.0.1:~D; ~A; ~A; graph-db ~A~%"
              name store *producer* clock-dir port
              (if *listener*
                  (format nil "mcp ~A:~A" mcp-bind
                          (mcp:listener-port *listener*))
                  "mcp off")
              (if *embedder*
                  (format nil "index ~A"
                          (agent:endpoint-embedder-model *embedder*))
                  "index off")
              (asdf:system-source-directory
               (asdf:find-system :graph-db))))
    (finish-output)
    *graph*))

(defun stop ()
  "Stop the indexer, then the listener, then close the store without a
snapshot (unbounded work before the .dirty marker clears; a backup is a
separate operation), then the clock; never signals.  The worker writes
to the store, so it is joined first.  The exit hook: SBCL runs
*EXIT-HOOKS* on SIGTERM (measured in docs/superpowers/notes/
2026-09-06-memory-mcp-engine-api-facts.md E5), so a stop from the shell
or systemd leaves no .dirty marker."
  (when *indexer*
    (mem:stop-endpoint-indexer *indexer*)
    (setf *indexer* nil))
  (when *listener*
    (mcp:stop-listener *listener*)
    (setf *listener* nil))
  (when *graph*
    (ignore-errors (let ((gdb:*graph* *graph*))
                     (gdb:close-graph *graph* :snapshot-p nil)))
    (setf *graph* nil gdb:*graph* nil))
  (when *clock*
    (ignore-errors (gdb:close-system-clock *clock*))
    (setf *clock* nil)))

;; Before START, not after: an unhandled failure inside START escapes
;; with the store already open, and the unhandled-condition quit under
;; --disable-debugger runs *EXIT-HOOKS*, so the hook clears the .dirty
;; marker.  The two handled refusals below open nothing and keep
;; :abort t, which skips the hooks.  The listener's own failures never
;; reach here: START reports and skips it.
(push #'stop sb-ext:*exit-hooks*)

(handler-case (start)
  (gdb:store-not-closed-cleanly-error (c)
    (format *error-output* "~&memory image: ~A~%Another image may hold ~
the store.  If none does, delete its .dirty marker and start again.~%" c)
    (finish-output *error-output*)
    (sb-ext:exit :code 1 :abort t))
  (gdb:system-clock-in-use (c)
    (format *error-output* "~&memory image: ~A~%Another image holds the ~
clock at that location.  Stop it, or point CL_LLM_MEMORY_CLOCK ~
elsewhere.~%" c)
    (finish-output *error-output*)
    (sb-ext:exit :code 1 :abort t)))
(loop (sleep 86400))
