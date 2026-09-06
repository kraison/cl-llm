;;;; tests-agent-mcp/listener-tests.lisp -- one server per connection
;;;; over an ephemeral loopback port.  Spec SS5, SS6; recon C3, C6, C10.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defmacro with-listener ((var w p &rest args) &body body)
  `(let ((,var (mcp:start-listener :bind "127.0.0.1" :port 0
                                   :stores (list ,w ,p) :write-store ,w
                                   :default-producer +p+ ,@args)))
     (unwind-protect (progn ,@body)
       (mcp:stop-listener ,var))))

(defun %connect (port &optional hello)
  "=> (values socket stream), HELLO sent first when given."
  (let* ((socket (usocket:socket-connect "127.0.0.1" port
                                         :element-type 'character))
         (stream (usocket:socket-stream socket)))
    (when hello
      (write-string hello stream) (write-char #\Newline stream)
      (force-output stream))
    (values socket stream)))

(defvar *rpc-id* 0)

(defun %rpc (stream method &optional params)
  "Send one request, read one response line; => the parsed response
(a JSON-RPC-RESPONSE struct; RESPONSE-RESULT is a string-keyed alist)."
  (write-string (client:encode-request
                 (cl-mcp.json-rpc:make-request :id (incf *rpc-id*)
                                               :method method
                                               :params params))
                stream)
  (write-char #\Newline stream)
  (force-output stream)
  (client:parse-client-message (read-line stream)))

(defun %initialize (stream)
  (%rpc stream "initialize"
        '(("protocolVersion" . "2025-06-18")
          ("clientInfo" . (("name" . "test") ("version" . "0")))
          ("capabilities" . nil))))

(defun %call (stream name args)
  "The tool's text result, or (values text t) on isError."
  (let* ((response (%rpc stream "tools/call"
                         `(("name" . ,name) ("arguments" . ,args))))
         (result (cl-mcp.json-rpc:response-result response))
         (content (cdr (assoc "content" result :test #'string=)))
         (text (cdr (assoc "text" (first content) :test #'string=))))
    (values text (cdr (assoc "isError" result :test #'string=)))))

(defun %conclude-args (relation)
  `(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
    ("relation" . ,relation) ("object-namespace" . "v")
    ("object-key" . "1") ("rule" . "r")))

(test a-known-secret-writes-under-its-principal
  "SS5: a hello with a known secret sets the connection's producer; the
decision it writes carries it.  The control is a connection with no
hello, which writes under the image's default."
  (with-stores (w p)
    (with-scratch-root (root)
      (let ((path (%write-principals
                   root '(("claude-code/tester" . "s1")))))
        (with-listener (l w p :principals-path path)
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l)
                        (%hello "claude-code/tester" "s1"))
            (%initialize stream)
            (let ((id (json:jget (json:parse
                                  (%call stream "conclude"
                                         (%conclude-args "a")))
                                 "id")))
              (is (string= "claude-code/tester"
                           (mem:decision-record-producer (mem:trace w id)))))
            (usocket:socket-close socket))
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l))
            (%initialize stream)
            (let ((id (json:jget (json:parse
                                  (%call stream "conclude"
                                         (%conclude-args "b")))
                                 "id")))
              (is (string= +p+ (mem:decision-record-producer (mem:trace w id)))
                  "control: no hello on loopback, the default"))
            (usocket:socket-close socket)))))))

(test a-refused-hello-closes-before-initialize
  "SS5: a wrong secret closes the connection with no handshake -- the
next read is EOF, not a response.  The control is the right secret on
the same listener."
  (with-stores (w p)
    (with-scratch-root (root)
      (let ((path (%write-principals
                   root '(("claude-code/tester" . "s1")))))
        (with-listener (l w p :principals-path path)
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l)
                        (%hello "claude-code/tester" "wrong"))
            (is (eq :eof (read-line stream nil :eof)))
            (usocket:socket-close socket))
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l)
                        (%hello "claude-code/tester" "s1"))
            (is (cl-mcp.json-rpc:response-result (%initialize stream))
                "control")
            (usocket:socket-close socket)))))))

(test two-connections-see-each-others-commits
  "SS5: concurrent connections are concurrent transactions on one
image; B recalls what A concluded."
  (with-stores (w p)
    (with-listener (l w p)
      (multiple-value-bind (sa sta) (%connect (mcp:listener-port l))
        (multiple-value-bind (sb stb) (%connect (mcp:listener-port l))
          (%initialize sta) (%initialize stb)
          (%call sta "conclude" (%conclude-args "shared"))
          (let ((rows (json:jget (json:parse
                                  (%call stb "recall"
                                         '(("subject-namespace" . "repo")
                                           ("subject-key" . "cl-llm"))))
                                 "records")))
            (is (= 1 (length rows))))
          (usocket:socket-close sb))
        (usocket:socket-close sa)))))

(test stop-ends-the-accept-loop
  "recon C3: closing a listening socket does not wake a parked accept,
so STOP sets a flag the polling loop reads; afterwards the thread is
gone and a connect is refused.  The control is a connect before STOP."
  (with-stores (w p)
    (let ((l (mcp:start-listener :bind "127.0.0.1" :port 0
                                 :stores (list w p) :write-store w
                                 :default-producer +p+)))
      (multiple-value-bind (socket stream) (%connect (mcp:listener-port l))
        (is (cl-mcp.json-rpc:response-result (%initialize stream))
            "control: accepting before stop")
        (usocket:socket-close socket))
      (let ((thread (mcp:listener-thread l)))
        (mcp:stop-listener l)
        (is (not (bt:thread-alive-p thread)))
        (signals error (usocket:socket-connect "127.0.0.1"
                                               (mcp:listener-port l)))
        (finishes (mcp:stop-listener l) "idempotent")))))
