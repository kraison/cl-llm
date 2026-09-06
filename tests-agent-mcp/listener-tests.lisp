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

(defun %read-bounded (socket stream &optional (timeout 5))
  "The next line of STREAM, :EOF when the peer closed, :TIMEOUT when
nothing arrives within TIMEOUT seconds -- a socket the server leaked
must fail a test, not hang the suite (#58)."
  (if (usocket:wait-for-input socket :timeout timeout :ready-only t)
      (read-line stream nil :eof)
      :timeout))

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
      (unwind-protect
           (progn
             (multiple-value-bind (socket stream)
                 (%connect (mcp:listener-port l))
               (is (cl-mcp.json-rpc:response-result (%initialize stream))
                   "control: accepting before stop")
               (usocket:socket-close socket))
             (let ((thread (mcp:listener-thread l)))
               (mcp:stop-listener l)
               (is (not (bt:thread-alive-p thread)))
               (signals usocket:connection-refused-error
                 (usocket:socket-connect "127.0.0.1"
                                         (mcp:listener-port l)))
               (finishes (mcp:stop-listener l) "idempotent")))
        (mcp:stop-listener l)))))

(test a-json-array-first-line-is-replayed-not-fatal
  "A top-level JSON array is not a hello: %HELLO-OBJECT's widened
IGNORE-ERRORS covers the ASSOC a non-object line would otherwise make
signal, so HELLO-LINE-P is NIL and the array replays as an ordinary
JSON-RPC line; cl-mcp's own RUN-SERVER loop answers it with an error
response rather than the connection ending the image (recon: the
connection thread's HANDLER-CASE is the other half of this fix).  The
control is a second, ordinary connection on the same listener
completing INITIALIZE -- proof the image survived."
  (with-stores (w p)
    (with-listener (l w p)
      (multiple-value-bind (socket stream) (%connect (mcp:listener-port l))
        (write-string "[1,2,3]" stream) (write-char #\Newline stream)
        (force-output stream)
        (is (cl-mcp.json-rpc:response-error
             (client:parse-client-message (read-line stream))))
        (usocket:socket-close socket))
      (multiple-value-bind (socket stream) (%connect (mcp:listener-port l))
        (is (cl-mcp.json-rpc:response-result (%initialize stream))
            "control: the image survived")
        (usocket:socket-close socket)))))

(test a-dropped-connection-is-closed-when-its-thread-cannot-start
  "#58: when the connection thread cannot start, the accept guard
logged and continued, leaving the accepted socket open -- a client
waiting on a connection nobody would serve.  The handler now closes it,
so the first read is EOF.  *MAKE-CONNECTION-THREAD* is SETF, not bound:
the accept loop runs in its own thread, which sees the global value.
The control is a second connection completing INITIALIZE while the hook
is still installed -- the loop kept accepting and the hook delegated."
  (with-stores (w p)
    (with-listener (l w p)
      (let ((default mcp::*make-connection-thread*)
            (failed nil))
        (unwind-protect
             (progn
               (setf mcp::*make-connection-thread*
                     (lambda (fn name)
                       (if failed
                           (funcall default fn name)
                           (progn (setf failed t)
                                  (error "no thread")))))
               (multiple-value-bind (socket stream)
                   (%connect (mcp:listener-port l))
                 (is (eq :eof (%read-bounded socket stream)))
                 (usocket:socket-close socket))
               (multiple-value-bind (socket stream)
                   (%connect (mcp:listener-port l))
                 (is (cl-mcp.json-rpc:response-result (%initialize stream))
                     "control: the loop kept accepting")
                 (usocket:socket-close socket)))
          (setf mcp::*make-connection-thread* default))
        (is-true failed "the hook fired: MAKE-THREAD did signal once")))))

(test listener-caps-reach-the-tools
  "#58: the caps a listener is started with are the caps of every
connection's tools -- MAKE-MEMORY-SERVER's K and MAX-ROWS were fixed at
their defaults before.  With :MAX-ROWS 1 over two beliefs on one
subject, recall returns one record and truncated true; the control is a
listener with the defaults, which returns both and truncated false."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "owner" '(:person . "kevin"))
    (let ((args '(("subject-namespace" . "repo")
                  ("subject-key" . "cl-llm"))))
      (with-listener (l w p :max-rows 1)
        (multiple-value-bind (socket stream) (%connect (mcp:listener-port l))
          (%initialize stream)
          (let ((out (json:parse (%call stream "recall" args))))
            (is (= 1 (length (json:jget out "records"))))
            (is (eq t (json:jget out "truncated"))))
          (usocket:socket-close socket)))
      (with-listener (l w p)
        (multiple-value-bind (socket stream) (%connect (mcp:listener-port l))
          (%initialize stream)
          (let ((out (json:parse (%call stream "recall" args))))
            (is (= 2 (length (json:jget out "records")))
                "control: the default cap returns both")
            (is (null (json:jget out "truncated"))))
          (usocket:socket-close socket))))))

(test two-principals-write-concurrently-under-their-own-names
  "SS5 (#58): identity is per connection, not per image.  Two
connections are open at once, each having sent its own hello; each
concludes and each decision carries its own producer.  The two
assertions are each other's control: one producer for the image would
fail one of them."
  (with-stores (w p)
    (with-scratch-root (root)
      (let ((path (%write-principals root '(("claude-code/alpha" . "sa")
                                            ("claude-code/beta" . "sb")))))
        (with-listener (l w p :principals-path path)
          (multiple-value-bind (sa sta)
              (%connect (mcp:listener-port l)
                        (%hello "claude-code/alpha" "sa"))
            (multiple-value-bind (sb stb)
                (%connect (mcp:listener-port l)
                          (%hello "claude-code/beta" "sb"))
              (%initialize sta)
              (%initialize stb)
              (let ((ida (json:jget (json:parse
                                     (%call sta "conclude"
                                            (%conclude-args "alpha")))
                                    "id"))
                    (idb (json:jget (json:parse
                                     (%call stb "conclude"
                                            (%conclude-args "beta")))
                                    "id")))
                (is (string= "claude-code/alpha"
                             (mem:decision-record-producer
                              (mem:trace w ida))))
                (is (string= "claude-code/beta"
                             (mem:decision-record-producer
                              (mem:trace w idb)))))
              (usocket:socket-close sb))
            (usocket:socket-close sa)))))))
