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
(defvar *exiting* nil
  "T once a stop has begun, by STOP or by the SIGTERM handler, which
then does nothing more (#84).")

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
  "Stop the indexer -- it writes to the stores, so it is joined first,
under a bound -- then close every store and the clock; never signals,
but a close that fails says so on stderr (MCP:CLOSE-SCOPE);
idempotent.  The exit hook, reached on the main thread on SIGTERM
(%EXIT-FROM-THE-MAIN-THREAD, #84), so a stop leaves no .dirty marker
(SS6); one stderr line says it began, when there was anything to stop,
and from then on a SIGTERM is ignored (*EXITING*)."
  (setf *exiting* t)
  (when (or *indexer* *stores* *clock*)
    (%note "stopping"))
  (when *indexer*
    ;; The embedder's own bound (MCP:%BOUNDED-EMBED, 30 s) plus a
    ;; margin: past that the worker is abandoned rather than allowed to
    ;; hold SIGTERM until the supervisor's SIGKILL (#78 I2).
    (mem:stop-endpoint-indexer *indexer* :timeout 35)
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
      ;; Before the server can serve when the probe answers: the
      ;; dimension is known only from an embedding (#78 SS4.3 step 4).
      ;; A misconfigured embedder costs this run its index, never the
      ;; session -- the tools stay lexical and the client sees a server.
      (handler-case
          (let ((ee (mcp:embedder-from-env)))
            (when ee
              (handler-case
                  (mcp:prepare-endpoint-index ee stores #'%note)
                ;; An embedder that does not answer is a cold start as
                ;; often as an outage: the index is off, lexical,
                ;; until the worker's retry of the probe succeeds
                ;; (#80 item 3) -- for what can recover (transport, a
                ;; timeout, a 5xx).  An auth error or another 4xx is
                ;; a misconfiguration and an engine error is not the
                ;; embedder's: those fall through to OFF, now.
                (error (c)
                  (unless (mcp:probe-retry-p c) (error c))
                  (setf (agent:endpoint-embedder-ready ee) nil)
                  (%note "semantic index: probe failed: ~a; lexical ~
until the worker's retry succeeds" c)))
              (setf *embedder* ee)
              ;; The image says this in its banner; the solo server has
              ;; none, and "index on" is not otherwise observable (#78).
              (%note "index ~a floor ~a (key: ~a)~:[, probe pending~;~]"
                     (agent:endpoint-embedder-model ee)
                     (agent:endpoint-embedder-floor ee)
                     (mcp:embed-key-source)
                     (agent:endpoint-embedder-ready ee))))
        (error (c)
          (%note "semantic index off: ~a" (mcp:index-off-reason c))
          (setf *embedder* nil)))
      (mcp:make-memory-server
       stores :write-store write-store :producer producer
       :embedder *embedder*
       :query-tool (equal (mcp:env "CL_LLM_MEMORY_QUERY_TOOL") "1")))))

(defun %die (control &rest args)
  "Report on stderr and exit 1.  STOP first: the exit is :abort t, which
skips the hooks, so a failure after OPEN-SCOPE returned would otherwise
leave the .dirty marker behind.  A no-op on the two refusal paths,
where nothing opened."
  (stop)
  (apply #'format *error-output* control args)
  (finish-output *error-output*)
  (sb-ext:exit :code 1 :abort t))

(defun %exit-from-the-main-thread (signal info context)
  "The SIGTERM handler: EXIT on the main thread, whichever thread the
kernel delivered the signal to, so the hook runs STOP there and never
on the worker STOP joins; nothing once a stop has begun, so a second
SIGTERM cannot abort the close (#84; the long form is
memory-image.lisp's)."
  (declare (ignore signal info context))
  (unless (sb-ext:compare-and-swap (symbol-value '*exiting*) nil t)
    (let ((main (sb-thread:main-thread)))
      (if (eq main sb-thread:*current-thread*)
          (sb-ext:exit)
          (handler-case (sb-thread:interrupt-thread main #'sb-ext:exit)
            (sb-thread:interrupt-thread-error () (sb-ext:exit)))))))

;; Before START, as in memory-image.lisp (#84): a SIGTERM while START
;; holds the scope open -- in the embedder's probe, say -- exits through
;; the hook, on the main thread, rather than through SBCL's own handler
;; with no hook to run.  The refusals below leave through %DIE, whose
;; :abort t skips the hook after stopping the scope itself.
(push #'stop sb-ext:*exit-hooks*)
(sb-sys:enable-interrupt sb-unix:sigterm #'%exit-from-the-main-thread)

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
  ;; One worker per process, started outside START's *STANDARD-OUTPUT*
  ;; binding: it logs to the *ERROR-OUTPUT* of this call, which here is
  ;; the process's stderr -- stdout carries JSON-RPC only (#78 SS4.3).
  (when *embedder*
    (setf *indexer*
          (mem:start-endpoint-indexer
           *stores*
           :embed (agent:endpoint-embedder-embed *embedder*)
           :model (agent:endpoint-embedder-model *embedder*)
           ;; Only after a failed probe: the worker retries it before
           ;; its sweep, bounded (#80 item 3).
           :prepare (let ((ee *embedder*) (stores *stores*))
                      (unless (agent:endpoint-embedder-ready ee)
                        (lambda ()
                          (mcp:retry-endpoint-index
                           ee stores #'%note)))))))
  (cl-mcp:run-server server :input *standard-input*
                            :output *standard-output*)
  (stop)
  (sb-ext:exit :code 0))
