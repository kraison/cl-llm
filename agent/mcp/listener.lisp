;;;; agent/mcp/listener.lisp -- one cl-mcp server per accepted
;;;; connection, in the memory image.  Spec SS5, SS6; recon C3, C10.

(in-package #:cl-llm.agent.mcp)

(defstruct listener
  socket thread (stopping nil) port stores write-store
  (provider :secret) principals-path default-producer query-tool)

(defun start-listener (&key (bind "127.0.0.1") (port 0) stores write-store
                            (provider :secret) principals-path
                            default-producer query-tool)
  "Listen on BIND:PORT (0 for an ephemeral port; LISTENER-PORT reads it
back) and serve each connection its own server over STORES.  Refuses a
non-loopback BIND without principals (SS5)."
  (check-bind bind (and principals-path (read-principals principals-path)))
  (let* ((socket (usocket:socket-listen bind port :reuse-address t
                                                  :element-type 'character))
         (listener (make-listener :socket socket
                                  :port (usocket:get-local-port socket)
                                  :stores stores :write-store write-store
                                  :provider provider
                                  :principals-path principals-path
                                  :default-producer default-producer
                                  :query-tool query-tool)))
    (setf (listener-thread listener)
          (bt:make-thread (lambda () (%accept-loop listener))
                          :name "cl-llm memory mcp listener"))
    listener))

(defun stop-listener (listener)
  "Set STOPPING, join the accept thread, then close the socket: a parked
accept does not wake on close (recon C3), so the loop polls.  Live
connections are not drained (SS9).  Idempotent; never signals."
  (setf (listener-stopping listener) t)
  (let ((thread (listener-thread listener)))
    (when (and thread (bt:thread-alive-p thread))
      (ignore-errors (bt:join-thread thread))))
  (setf (listener-thread listener) nil)
  (when (listener-socket listener)
    (ignore-errors (usocket:socket-close (listener-socket listener)))
    (setf (listener-socket listener) nil))
  listener)

(defun %accept-loop (listener)
  (loop until (listener-stopping listener)
        do (when (usocket:wait-for-input (listener-socket listener)
                                         :timeout 0.5 :ready-only t)
             (let ((socket (ignore-errors
                            (usocket:socket-accept
                             (listener-socket listener)
                             :element-type 'character))))
               (when socket
                 (bt:make-thread
                  (lambda () (%serve-guarded listener socket))
                  :name "cl-llm memory mcp connection"))))))

(defun %serve-guarded (listener socket)
  "Run %SERVE-CONNECTION; the image runs with the debugger disabled, so
an escaping condition -- a dead client, a broken pipe out of
RUN-SERVER's own error path onto this SOCKET's stream -- would end the
whole image, not just this connection.  Logs the peer and the
condition TYPE only, never its message, which could carry a secret."
  (handler-case (%serve-connection listener socket)
    (error (c)
      (ignore-errors            ; a broken stderr must not escape the guard
       (format *error-output* "~&memory mcp: connection from ~a ended: ~a~%"
               (%address-string (ignore-errors
                                 (usocket:get-peer-address socket)))
               (type-of c))
       (finish-output *error-output*)))))

(defun %serve-connection (listener socket)
  "Read the first line; a hello is consumed, any other line is replayed
ahead of the socket (with its newline: READ-LINE runs across a
concatenated stream's boundary, recon E3).  A refused identity closes
the socket before any handshake.  The UNWIND-PROTECT is established
before any read of SOCKET, so a reset during that read still closes
it."
  (unwind-protect
       (let* ((stream (usocket:socket-stream socket))
              (peer (usocket:get-peer-address socket))
              (line (read-line stream nil nil)))
         (when line
           (let* ((hello-p (hello-line-p line))
                  (principals (and (listener-principals-path listener)
                                   (read-principals
                                    (listener-principals-path listener))))
                  (producer (resolve-identity (listener-provider listener)
                                              (and hello-p line) peer
                                              (listener-default-producer
                                               listener)
                                              principals)))
             (if (eq producer :refused)
                 (ignore-errors ; a broken stderr must not lose the refusal
                  (format *error-output* "~&memory mcp: refused ~a~%"
                          (%address-string peer)))
                 (let ((server (make-memory-server
                                (listener-stores listener)
                                :write-store (listener-write-store listener)
                                :producer producer
                                :query-tool (listener-query-tool listener)))
                       (input (if hello-p
                                  stream
                                  (make-concatenated-stream
                                   (make-string-input-stream
                                    (concatenate 'string line
                                                 (string #\Newline)))
                                   stream))))
                   (mcp:run-server server :input input :output stream))))))
    (ignore-errors (usocket:socket-close socket))))
