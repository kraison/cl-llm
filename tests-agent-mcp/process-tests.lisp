;;;; tests-agent-mcp/process-tests.lisp -- the solo server as a child
;;;; process: round trip, the double-hold refusal, SIGTERM.  Spec SS4,
;;;; SS6; recon C7, C8, E5.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defun %script (name)
  (namestring (asdf:system-relative-pathname :cl-llm
                                             (concatenate 'string
                                                          "scripts/" name))))

(defun %registry-env ()
  "CL_LLM_ASDF_REGISTRY naming the trees this image loaded, so the
child builds against the same engine and libraries (ruling 1)."
  (format nil "CL_LLM_ASDF_REGISTRY=~{~a~^:~}"
          (mapcar (lambda (s) (namestring (asdf:system-source-directory s)))
                  '(:cl-llm :graph-db :cl-mcp :opsis :cl-temporal-extent))))

(defun %solo-env (root &key clock)
  "The solo server's variables under ROOT; CLOCK overrides the clock
directory, so a child can reach the store's own refusal instead of
stopping at the clock's flock."
  (list (format nil "CL_LLM_MEMORY_STORE=~a" (%sub root "store/"))
        (format nil "CL_LLM_MEMORY_SYSTEM=~a" (%sub root "sys/"))
        (format nil "CL_LLM_MEMORY_CLOCK=~a" (or clock (%sub root "clock/")))
        "CL_LLM_MEMORY_PRODUCER=claude-code/test"
        "LC_ALL=C.UTF-8"
        (%registry-env)))

(defun %env-name (entry)
  (subseq entry 0 (position #\= entry)))

(defun %child-environment (assignments)
  "ASSIGNMENTS ahead of this image's environ, with every name they set
removed from it.  A duplicate name is not merely redundant: the shell
wrapper builds its variables by walking environ, so the LAST entry wins
there while POSIX GETENV takes the first -- and WITH-SOLO-ENV leaves
these same names behind in this image, empty, which would send the
child at the developer's real store."
  (let ((names (mapcar #'%env-name assignments)))
    (append assignments
            (remove-if (lambda (e)
                         (member (%env-name e) names :test #'string=))
                       (sb-ext:posix-environ)))))

(defun %launch-solo (root &key clock)
  "The solo server as a child, stdin/stdout/stderr as streams."
  (sb-ext:run-program (%script "run-memory-mcp.sh") '()
                      :environment (%child-environment
                                    (%solo-env root :clock clock))
                      :input :stream :output :stream :error :stream
                      :wait nil))

(defun %child-rpc (process method &optional params)
  (let ((in (sb-ext:process-input process))
        (out (sb-ext:process-output process)))
    (write-string (client:encode-request
                   (cl-mcp.json-rpc:make-request :id (incf *rpc-id*)
                                                 :method method
                                                 :params params))
                  in)
    (write-char #\Newline in)
    (force-output in)
    (client:parse-client-message (read-line out))))

(defun %wait (process &key (grace 15))
  "Wait up to GRACE seconds for PROCESS to exit; => exit code or NIL."
  (loop repeat (* 10 grace)
        while (sb-ext:process-alive-p process)
        do (sleep 0.1))
  (unless (sb-ext:process-alive-p process)
    (sb-ext:process-wait process)
    (sb-ext:process-exit-code process)))

(defun %stderr (process)
  (let ((s (sb-ext:process-error process)))
    (with-output-to-string (o)
      (loop for line = (read-line s nil nil) while line
            do (write-line line o)))))

(defmacro with-solo-env ((root) &body body)
  "The solo variables set in THIS image for cl-mcp/client's child, which
inherits the environment (recon C13), restored afterwards."
  `(let ((saved (mapcar (lambda (e) (cons (subseq e 0 (position #\= e))
                                          (uiop:getenv
                                           (subseq e 0 (position #\= e)))))
                        (%solo-env ,root))))
     (unwind-protect
          (progn
            (dolist (e (%solo-env ,root))
              (let ((at (position #\= e)))
                (setf (uiop:getenv (subseq e 0 at)) (subseq e (1+ at)))))
            ,@body)
       (dolist (pair saved)
         (setf (uiop:getenv (car pair)) (or (cdr pair) ""))))))

(test the-solo-server-round-trips-and-leaves-the-store-clean
  "SS4, SS6: cl-mcp/client spawns the solo server; tools list, a
conclude, a recall; then EOF, then the child exits and the store has no
.dirty marker and reopens clean.  DISCONNECT does not wait (recon C8),
so the process handle is captured first; the reopen binds
GDB:*SYSTEM-DIRECTORY* to the child's, which is where OPEN-GRAPH reads
the store's type ids from (GH #186)."
  (with-scratch-root (root)
    (with-solo-env (root)
      (let ((c (client:make-client
                :command (list (%script "run-memory-mcp.sh")))))
        (client:connect c)
        (let ((process (cl-mcp.client::client-process c)))
          (is (= 8 (length (client:list-tools c))))
          (let* ((out (client:call-tool
                       c "conclude"
                       '(("subject-namespace" . "repo")
                         ("subject-key" . "cl-llm") ("relation" . "a")
                         ("object-namespace" . "v") ("object-key" . "1")
                         ("rule" . "r"))))
                 (text (cdr (assoc "text" (first (getf out :content))
                                   :test #'string=))))
            (is (string= "concluded"
                         (json:jget (json:parse text) "outcome"))))
          (let* ((out (client:call-tool
                       c "recall" '(("subject-namespace" . "repo")
                                    ("subject-key" . "cl-llm"))))
                 (text (cdr (assoc "text" (first (getf out :content))
                                   :test #'string=))))
            (is (= 1 (length (json:jget (json:parse text) "records")))))
          (client:disconnect c)
          (uiop:wait-process process)
          (is (not (uiop:process-alive-p process)) "no child left running")
          (is (not (%dirty-p (%sub root "store/"))) "clean after EOF")
          (let* ((gdb:*system-directory* (%sub root "sys/"))
                 (g (gdb:open-graph :cl-llm-memory (%sub root "store/")
                                    :buffer-pool-size 1000)))
            (is (= 1 (length (mem:recall g '(:repo . "cl-llm"))))
                "reopens clean and holds the decision's belief")
            (let ((gdb:*graph* g)) (gdb:close-graph g :snapshot-p nil))))))))

(test a-second-solo-server-on-a-held-store-refuses
  "SS4: while one solo server holds the store, a second exits 1 with the
image's message and never answers a request.  Two refusals, because
OPEN-SCOPE opens the clock first: a child sharing the clock directory
stops at its flock, one with its own clock directory reaches the
store's .dirty marker.  The control is the first server answering
initialize, and its own clean exit afterwards."
  (with-scratch-root (root)
    (let ((first (%launch-solo root)))
      (unwind-protect
           (progn
             (is (%child-rpc first "initialize"
                             '(("protocolVersion" . "2025-06-18")
                               ("clientInfo" . (("name" . "t")
                                                ("version" . "0")))))
                 "control: the first server answers")
             (let ((second (%launch-solo root)))
               (is (eql 1 (%wait second)))
               (is (search "Another image holds the clock"
                           (%stderr second))))
             (let ((third (%launch-solo root :clock (%sub root "clock2/"))))
               (is (eql 1 (%wait third)))
               (is (search "Another image may hold the store"
                           (%stderr third)))))
        (close (sb-ext:process-input first))
        (is (eql 0 (%wait first)))
        (is (not (%dirty-p (%sub root "store/"))))))))

(test sigterm-leaves-the-store-clean
  "SS6 (recon E5): SIGTERM to the solo server mid-session runs the exit
hook; the store has no .dirty marker and reopens.  The control is the
marker's presence while the server runs."
  (with-scratch-root (root)
    (let ((process (%launch-solo root)))
      (%child-rpc process "initialize"
                  '(("protocolVersion" . "2025-06-18")
                    ("clientInfo" . (("name" . "t") ("version" . "0")))))
      (is (%dirty-p (%sub root "store/")) "control: dirty while held")
      (sb-ext:process-kill process sb-unix:sigterm)
      (is (eql 0 (%wait process)))
      (is (not (%dirty-p (%sub root "store/"))))
      (let* ((gdb:*system-directory* (%sub root "sys/"))
             (g (gdb:open-graph :cl-llm-memory (%sub root "store/")
                                :buffer-pool-size 1000)))
        (is (gdb::graph-open-p g))
        (let ((gdb:*graph* g)) (gdb:close-graph g :snapshot-p nil))))))
