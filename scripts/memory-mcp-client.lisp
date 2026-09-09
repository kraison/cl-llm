;;;; scripts/memory-mcp-client.lisp -- a stdio relay to the memory
;;;; image's MCP listener: `claude mcp add memory -- sbcl --script
;;;; <this> --port 4009 [--host H] [--principal claude-code/laptop]
;;;; [--secret-file PATH]`.  The principal's secret comes from the
;;;; secret file, (("<producer>" . "<secret>") ...): --secret-file,
;;;; else CL_LLM_MEMORY_CLIENT, else ~/.cl-llm-memory/client.sexp; the
;;;; command line carries none (#73).  stdin EOF half-closes the
;;;; socket and the replies still coming drain to stdout; the process
;;;; exits when the listener closes (#74): 0, or 2 when a hello was
;;;; sent and nothing came back -- refused (#73; a session that asked
;;;; nothing reads the same).  Anything else is 1.  docs/agent-memory.md.

(let ((*standard-output* *error-output*))
  (require :asdf)
  (flet ((try (path) (when (probe-file path) (load path) t)))
    (let ((home (user-homedir-pathname)))
      (or (try (merge-pathnames "quicklisp/setup.lisp" home))
          (try (merge-pathnames ".quicklisp/setup.lisp" home)))))
  (funcall (intern "QUICKLOAD" "QL") '(:usocket :bordeaux-threads)
           :silent t))

(defpackage #:cl-llm.memory-mcp-client (:use #:cl))
(in-package #:cl-llm.memory-mcp-client)

(defun %option (name default)
  (let ((tail (member name sb-ext:*posix-argv* :test #'string=)))
    (if (and tail (cdr tail)) (second tail) default)))

(defun %secret-path ()
  "--secret-file, else CL_LLM_MEMORY_CLIENT, else the default (#73)."
  (or (%option "--secret-file" nil)
      (let ((env (sb-ext:posix-getenv "CL_LLM_MEMORY_CLIENT")))
        (and env (plusp (length env)) env))
      (merge-pathnames ".cl-llm-memory/client.sexp"
                       (user-homedir-pathname))))

(defun %secret (principal path)
  "PRINCIPAL's secret from the file at PATH; an error naming PATH when
the file or the entry is missing (exit 1 under --script)."
  (unless (probe-file path)
    (error "no ~a to look up ~a in" path principal))
  (let ((entries (with-open-file (s path)
                   (let ((*read-eval* nil)) (read s nil nil)))))
    (or (cdr (assoc principal entries :test #'string=))
        (error "no secret for ~a in ~a" principal path))))

(defun %pump (from to &optional done)
  "Relay lines FROM to TO in a thread, calling DONE at the end; the
thread's value (JOIN-THREAD) is the count relayed.  IGNORE-ERRORS: a
read or write racing the socket's close must end this thread quietly,
not exit 1."
  (bt:make-thread
   (lambda ()
     (let ((n 0))
       (unwind-protect
            (ignore-errors
             (loop for line = (read-line from nil nil)
                   while line
                   do (write-line line to) (force-output to) (incf n)))
         (when done (funcall done)))
       n))))

(let* ((host (%option "--host" "127.0.0.1"))
       (port (parse-integer (%option "--port" "4009")))
       (principal (%option "--principal" nil))
       (secret-path (%secret-path))
       (socket (usocket:socket-connect host port :element-type 'character))
       (stream (usocket:socket-stream socket)))
  (when principal
    (format stream "{\"cl-llm-memory\": {\"principal\": ~s, ~
                    \"secret\": ~s}}~%"
            principal (%secret principal secret-path))
    (force-output stream))
  ;; Asymmetric (#74): stdin EOF means no more requests, not no more
  ;; replies.  Half-close for writing; the listener closes at its input
  ;; EOF, which ends the socket pump, which ends the process.
  (%pump *standard-input* stream
         (lambda () (ignore-errors (usocket:socket-shutdown socket :output))))
  (let ((relayed (bt:join-thread (%pump stream *standard-output*))))
    (ignore-errors (usocket:socket-close socket))
    (finish-output *standard-output*)
    ;; A hello answered by a close and nothing else was refused (#73);
    ;; with no hello, an empty session is an empty session.
    (cond ((and principal (zerop relayed))
           (format *error-output*
                   "~&memory relay: hello for ~a refused (secret from ~a)~%"
                   principal secret-path)
           (finish-output *error-output*)
           (sb-ext:exit :code 2))
          (t (sb-ext:exit :code 0)))))
