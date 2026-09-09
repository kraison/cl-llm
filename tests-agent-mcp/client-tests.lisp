;;;; tests-agent-mcp/client-tests.lisp -- the stdio relay
;;;; (scripts/memory-mcp-client.lisp) as a child against a listener: a
;;;; refused hello exits 2 with a message and --secret-file names the
;;;; secret (#73); stdin EOF drains the replies before exit (#74).

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defmacro with-client-root ((root) &body body)
  "ROOT bound to a fresh /tmp/cl-llm-mcp-client-<random>/ namestring,
deleted after BODY.  The principals and client secret files live here;
~/.cl-llm-memory is never touched."
  `(let ((,root (format nil "/tmp/cl-llm-mcp-client-~a-~a/"
                        (get-internal-real-time) (random 1000000))))
     (ensure-directories-exist ,root)
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       (pathname ,root) :validate t
                       :if-does-not-exist :ignore)))))

(defun %write-secret (root name entries)
  "ROOT/NAME holding ENTRIES in client.sexp's shape; => its namestring."
  (let ((path (concatenate 'string root name)))
    (ensure-directories-exist path)
    (with-open-file (s path :direction :output :if-exists :supersede)
      (prin1 entries s))
    path))

(defun %launch-client (port principal secret)
  "The relay as a child of this image, dialling PORT as PRINCIPAL with
the secret file SECRET; stdin/stdout/stderr as streams."
  (sb-ext:run-program "sbcl"
                      (list "--script" (%script "memory-mcp-client.lisp")
                            "--host" "127.0.0.1"
                            "--port" (princ-to-string port)
                            "--principal" principal
                            "--secret-file" secret)
                      :search t :input :stream :output :stream
                      :error :stream :wait nil))

(defun %request-line (id method &optional params)
  (client:encode-request
   (cl-mcp.json-rpc:make-request :id id :method method :params params)))

(defun %batch (n)
  "initialize as id 1, then tools/list as ids 2..N."
  (cons (%request-line 1 "initialize"
                       '(("protocolVersion" . "2025-06-18")
                         ("clientInfo" . (("name" . "t")
                                          ("version" . "0")))))
        (loop for id from 2 to n collect (%request-line id "tools/list"))))

(defun %drain (stream)
  "A thread reading STREAM's lines to EOF; JOIN-THREAD => the lines."
  (bt:make-thread (lambda ()
                    (loop for line = (read-line stream nil nil)
                          while line collect line))
                  :name "client-tests drain"))

(defun %run-client (port principal secret lines)
  "Spawn the relay, write LINES to its stdin and close it at once (the
#74 shape), wait up to 60 s (the child quickloads usocket);
=> (values exit-code stdout-lines stderr-string).  A child alive after
the grace is reaped, so the drains end and the code is NIL."
  (let ((process (%launch-client port principal secret)))
    (unwind-protect
         (let ((out (%drain (sb-ext:process-output process)))
               (err (%drain (sb-ext:process-error process)))
               (in (sb-ext:process-input process)))
           (dolist (line lines) (write-line line in))
           (force-output in)
           (close in)
           (let ((code (%wait process :grace 60)))
             (%reap process)
             (values code (bt:join-thread out)
                     (format nil "~{~a~%~}" (bt:join-thread err)))))
      (%reap process))))

(defun %ids (lines)
  (mapcar (lambda (line) (json:jget (json:parse line) "id")) lines))

(test client-refused-hello-exits-2-with-a-message
  "#73: a hello with the wrong secret is refused and the listener closes
the connection; the relay exits 2 with one stderr line naming the
principal and the secret's path, and writes nothing to stdout.  The old
relay exited 0 with both streams empty."
  (with-stores (w p)
    (with-client-root (root)
      (let ((principals (%write-principals
                         root '(("claude-code/laptop" . "right"))))
            (secret (%write-secret
                     root "client.sexp"
                     '(("claude-code/laptop" . "wrong")))))
        (with-listener (l w p :provider :secret :principals-path principals)
          (multiple-value-bind (code out err)
              (%run-client (mcp:listener-port l) "claude-code/laptop"
                           secret (%batch 2))
            (is (eql 2 code) "exit 2, got ~s; stderr: ~a" code err)
            (is (null out) "nothing on stdout: ~s" out)
            (is (search "refused" err) "stderr: ~a" err)
            (is (search "claude-code/laptop" err) "stderr: ~a" err)
            (is (search secret err) "the secret's path; stderr: ~a" err)))))))

(test client-drains-replies-after-stdin-eof
  "#74: initialize plus 29 tools/list written and stdin closed at once;
every reply reaches stdout, in order, before the relay exits 0.  The
old relay exited when stdin hit EOF, dropping replies in flight."
  (with-stores (w p)
    (with-client-root (root)
      (let ((principals (%write-principals
                         root '(("claude-code/laptop" . "s"))))
            (secret (%write-secret
                     root "client.sexp" '(("claude-code/laptop" . "s")))))
        (with-listener (l w p :provider :secret :principals-path principals)
          (multiple-value-bind (code out err)
              (%run-client (mcp:listener-port l) "claude-code/laptop"
                           secret (%batch 30))
            (is (eql 0 code) "exit 0, got ~s; stderr: ~a" code err)
            (is (= 30 (length out)) "30 replies, got ~a" (length out))
            (is (equal (loop for i from 1 to 30 collect i) (%ids out)))))))))

(test client-reads-the-secret-from-secret-file
  "#73: the secret comes from --secret-file, not ~/.cl-llm-memory/
client.sexp: a file elsewhere holding the right secret gets initialize
through, and the result names the server."
  (with-stores (w p)
    (with-client-root (root)
      (let ((principals (%write-principals
                         root '(("claude-code/laptop" . "s"))))
            (secret (%write-secret
                     root "elsewhere/secret.sexp"
                     '(("claude-code/laptop" . "s")))))
        (with-listener (l w p :provider :secret :principals-path principals)
          (multiple-value-bind (code out err)
              (%run-client (mcp:listener-port l) "claude-code/laptop"
                           secret (%batch 1))
            (is (eql 0 code) "exit 0, got ~s; stderr: ~a" code err)
            (is (= 1 (length out)) "one reply, got ~a" (length out))
            (is (equal "cl-llm-memory"
                       (json:jget (json:parse (or (first out) "{}"))
                                  "result" "serverInfo" "name")))))))))
