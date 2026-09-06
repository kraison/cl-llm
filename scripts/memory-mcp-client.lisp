;;;; scripts/memory-mcp-client.lisp -- a stdio relay to the memory
;;;; image's MCP listener: `claude mcp add memory -- sbcl --script
;;;; <this> --port 4009 [--host H] [--principal claude-code/laptop]`.
;;;; The principal's secret comes from ~/.cl-llm-memory/client.sexp,
;;;; (("<producer>" . "<secret>") ...), so the command line carries
;;;; none.  Exits when either side closes.  docs/agent-memory.md.

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

(defun %secret (principal)
  (let ((path (merge-pathnames ".cl-llm-memory/client.sexp"
                               (user-homedir-pathname))))
    (unless (probe-file path)
      (error "no ~a to look up ~a in" path principal))
    (let ((entries (with-open-file (s path)
                     (let ((*read-eval* nil)) (read s nil nil)))))
      (or (cdr (assoc principal entries :test #'string=))
          (error "no secret for ~a in ~a" principal path)))))

(defun %pump (from to done)
  (bt:make-thread
   (lambda ()
     (unwind-protect
          (loop for line = (read-line from nil nil)
                while line
                do (write-line line to) (force-output to))
       (funcall done)))))

(let* ((host (%option "--host" "127.0.0.1"))
       (port (parse-integer (%option "--port" "4009")))
       (principal (%option "--principal" nil))
       (socket (usocket:socket-connect host port :element-type 'character))
       (stream (usocket:socket-stream socket))
       (lock (bt:make-lock))
       (finished nil))
  (when principal
    (format stream "{\"cl-llm-memory\": {\"principal\": ~s, ~
                    \"secret\": ~s}}~%"
            principal (%secret principal))
    (force-output stream))
  (flet ((done () (bt:with-lock-held (lock) (setf finished t))))
    (%pump *standard-input* stream #'done)
    (%pump stream *standard-output* #'done)
    (loop until (bt:with-lock-held (lock) finished) do (sleep 0.1))
    (ignore-errors (usocket:socket-close socket))
    (sb-ext:exit :code 0 :abort t)))
