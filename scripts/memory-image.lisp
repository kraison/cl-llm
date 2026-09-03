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

(require :asdf)
(ql:quickload '(:cl-llm/agent :swank) :silent t)

(defpackage #:cl-llm.memory-image
  (:use #:cl)
  (:local-nicknames (#:mem #:cl-llm.memory)
                    (#:gdb #:graph-db)
                    (#:st #:graph-db.spacetime)
                    (#:agent #:cl-llm.agent))
  (:export #:*graph* #:*producer* #:start #:stop))

(in-package #:cl-llm.memory-image)

(defvar *graph* nil "The open store; also bound as GDB:*GRAPH*.")
(defvar *producer* nil "Producer string for decisions written here.")

(defun %env (name default)
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun %home (relative)
  (namestring (merge-pathnames relative (user-homedir-pathname))))

(defun %dir (s)
  (if (char= (char s (1- (length s))) #\/) s (concatenate 'string s "/")))

(defun start ()
  "Open the store (make it when absent), bind it as the current graph,
start SWANK, return the graph.  Lets GDB:STORE-NOT-CLOSED-CLEANLY-ERROR
through rather than open a store another image left dirty."
  (let* ((store (%dir (%env "CL_LLM_MEMORY_STORE"
                            (%home ".cl-llm-memory/working/"))))
         (system (%dir (%env "CL_LLM_MEMORY_SYSTEM"
                             (%home ".cl-llm-memory/system/"))))
         (name (intern (string-upcase
                        (%env "CL_LLM_MEMORY_GRAPH" "cl-llm-memory"))
                       :keyword))
         (port (parse-integer (%env "CL_LLM_MEMORY_SWANK_PORT" "4008")))
         (pool (parse-integer (%env "CL_LLM_MEMORY_BUFFER_POOL" "2000"))))
    (setf *producer*
          (%env "CL_LLM_MEMORY_PRODUCER"
                (format nil "claude-code/~(~A~)" (machine-instance))))
    (setf gdb:*system-directory* system)
    (setf *graph*
          (if (probe-file (concatenate 'string store "schema.dat"))
              (gdb:open-graph name store :buffer-pool-size pool)
              (gdb:make-graph name store :buffer-pool-size pool)))
    (setf gdb:*graph* *graph*)
    (swank:create-server :port port :dont-close t :interface "127.0.0.1")
    (format t "~&memory image: ~(~S~) at ~A as ~A; swank 127.0.0.1:~D~%"
            name store *producer* port)
    (finish-output)
    *graph*))

(defun stop ()
  "Close the store; never signals.  Installed as an exit hook because
SBCL runs *EXIT-HOOKS* on SIGTERM (measured in sitrep #25), so a stop
from the shell or systemd leaves no .dirty marker."
  (when *graph*
    (ignore-errors (gdb:close-graph *graph*))
    (setf *graph* nil gdb:*graph* nil)))

(handler-case (start)
  (gdb:store-not-closed-cleanly-error (c)
    (format *error-output* "~&memory image: ~A~%Another image may hold ~
the store.  If none does, delete its .dirty marker and start again.~%" c)
    (finish-output *error-output*)
    (sb-ext:exit :code 1 :abort t)))
(push #'stop sb-ext:*exit-hooks*)
(loop (sleep 86400))
