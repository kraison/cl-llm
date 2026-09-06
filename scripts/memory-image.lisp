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

(require :asdf)
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

(defun %env (name &optional default)
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun %home (relative)
  (namestring (merge-pathnames relative (user-homedir-pathname))))

(defun %dir (s)
  (if (char= (char s (1- (length s))) #\/) s (concatenate 'string s "/")))

(defun start ()
  "Open the store (make it when absent), bind it as the current graph,
start the MCP listener unless CL_LLM_MEMORY_MCP_PORT is empty, start
SWANK, return the graph.  Lets GDB:STORE-NOT-CLOSED-CLEANLY-ERROR
through rather than open a store another image left dirty."
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
    (let ((mcp-port (%env "CL_LLM_MEMORY_MCP_PORT" "4009"))
          (mcp-bind (%env "CL_LLM_MEMORY_MCP_BIND" "127.0.0.1")))
      (when (plusp (length mcp-port))
        (setf *listener*
              (mcp:start-listener
               :bind mcp-bind
               :port (parse-integer mcp-port)
               :stores (list *graph*) :write-store *graph*
               :provider (intern (string-upcase
                                  (%env "CL_LLM_MEMORY_IDENTITY" "secret"))
                                 :keyword)
               :principals-path
               (%env "CL_LLM_MEMORY_PRINCIPALS"
                     (%home ".cl-llm-memory/principals.sexp"))
               :default-producer *producer*
               :query-tool (equal (%env "CL_LLM_MEMORY_QUERY_TOOL") "1"))))
      (swank:create-server :port port :dont-close t :interface "127.0.0.1")
      (format t "~&memory image: ~(~S~) at ~A as ~A; clock ~A; ~
swank 127.0.0.1:~D; ~A~%"
              name store *producer* clock-dir port
              (if *listener*
                  (format nil "mcp ~A:~A" mcp-bind
                          (mcp:listener-port *listener*))
                  "mcp off")))
    (finish-output)
    *graph*))

(defun stop ()
  "Stop the listener, close the store without a snapshot (unbounded work
before the .dirty marker clears; a backup is a separate operation), then
the clock; never signals.  The exit hook: SBCL runs *EXIT-HOOKS* on
SIGTERM (measured in docs/superpowers/notes/2026-09-06-memory-mcp-
engine-api-facts.md E5), so a stop from the shell or systemd leaves no
.dirty marker."
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

;; Before START, not after: a failure inside START -- a listener port
;; already in use, a non-loopback bind with no principals -- escapes
;; with the store already open, and the unhandled-condition quit under
;; --disable-debugger runs *EXIT-HOOKS*, so the hook clears the .dirty
;; marker.  The two handled refusals below open nothing and keep
;; :abort t, which skips the hooks.
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
