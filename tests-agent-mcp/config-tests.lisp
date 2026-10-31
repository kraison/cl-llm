;;;; tests-agent-mcp/config-tests.lisp -- the environment to a scope,
;;;; and the bounded close.  Spec SS4, SS6.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(test parse-scope-reads-names-and-dirs-in-order
  "SS4: \"name=dir,name=dir\" in trust order; a malformed entry signals."
  (let ((scope (mcp:parse-scope "private=/tmp/p, working=/tmp/w")))
    (is (equal '(:private :working) (mapcar #'car scope)))
    (is (string= "/tmp/p/" (cdr (first scope))) "trailing slash added")
    (is (string= "/tmp/w/" (cdr (second scope)))))
  (signals error (mcp:parse-scope "nodir"))
  (signals error (mcp:parse-scope "=/tmp/x"))
  (is (null (mcp:parse-scope "")) "control: empty is empty"))

(test a-runtime-declared-store-name-opens
  "recon C11: DEFINE-MEMORY-STORE evaluated at run time for a name the
image never declared lets that store open and hold a belief.  The
control is the library's own :cl-llm-memory in the same scope, and
CHECK-SCOPE accepting the pair proves they share the clock."
  (with-scratch-root (root)
    (let ((spec (list (cons :memory-third (%sub root "third/"))
                      (cons :cl-llm-memory (%sub root "main/")))))
      (multiple-value-bind (stores write clock) (%open root spec)
        (unwind-protect
             (progn
               (is (= 2 (length stores)))
               (is (eq write (second stores)) "default write: the last")
               (is (eq :memory-third (gdb:graph-name (first stores))))
               (gdb:with-transaction (:graph (first stores))
                 (mem:record-belief (first stores) '(:repo . "x") "owner"
                                    '(:person . "k")
                                    :producer +p+ :standing :observed))
               (is (= 1 (length (mem:recall (first stores)
                                            '(:repo . "x")))))
               (is (eq stores (mem:check-scope stores :write-store write))
                   "one clock across the scope"))
          (mcp:close-scope stores clock))))))

(test open-scope-names-the-write-store
  (with-scratch-root (root)
    (let ((spec (list (cons :memory-third (%sub root "a/"))
                      (cons :cl-llm-memory (%sub root "b/")))))
      (multiple-value-bind (stores write clock)
          (%open root spec "memory-third")
        (is (eq (first stores) write))
        (mcp:close-scope stores clock))
      (signals error (%open root spec "no-such-store")))))

(test the-shutdown-closes-every-store-with-graph-bound
  "recon C2: CLOSE-SCOPE over two stores binds *GRAPH* per store and
skips the snapshot; both .dirty markers are gone afterwards and both
stores reopen without recovery.  The control is the markers' presence
while the stores are open.  Idempotent: a second CLOSE-SCOPE is a no-op."
  (with-scratch-root (root)
    (let ((spec (list (cons :memory-third (%sub root "a/"))
                      (cons :cl-llm-memory (%sub root "b/")))))
      (multiple-value-bind (stores write clock) (%open root spec)
        (declare (ignore write))
        (is (every (lambda (e) (%dirty-p (cdr e))) spec)
            "control: dirty while open")
        (mcp:close-scope stores clock)
        (is (notany (lambda (e) (%dirty-p (cdr e))) spec))
        (finishes (mcp:close-scope stores clock)))
      (multiple-value-bind (stores write clock) (%open root spec)
        (declare (ignore write))
        (is (= 2 (length stores)) "reopens clean")
        (mcp:close-scope stores clock)))))

(test the-embedder-comes-from-the-environment-or-is-absent
  "SS5: the semantic index's embedder is the four CL_LLM_MEMORY_EMBED_*
variables.  An empty (or unset) URL is inert; with a URL the model and
the floor are required, and the floor must read as a real in [0, 1]."
  (let ((saved (mapcar (lambda (n) (cons n (uiop:getenv n)))
                       '("CL_LLM_MEMORY_EMBED_URL"
                         "CL_LLM_MEMORY_EMBED_MODEL"
                         "CL_LLM_MEMORY_EMBED_KEY"
                         "CL_LLM_MEMORY_EMBED_FLOOR"))))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_URL") "")
           (is (null (mcp:embedder-from-env)) "empty URL: inert")
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_URL")
                 "http://127.0.0.1:1/v1"
                 (uiop:getenv "CL_LLM_MEMORY_EMBED_MODEL") "m"
                 (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "0.42")
           (let ((ee (mcp:embedder-from-env)))
             (is (agent:endpoint-embedder-p ee))
             (is (string= "m" (agent:endpoint-embedder-model ee)))
             (is (= 0.42 (agent:endpoint-embedder-floor ee))))
           ;; No round trip is made here: the URL is a closed port.
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "not-a-number")
           (signals (error "a floor that is not a number")
             (mcp:embedder-from-env))
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "0.42 junk")
           (signals (error "a floor the read does not consume whole")
             (mcp:embedder-from-env))
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "  0.42  ")
           (is (= 0.42 (agent:endpoint-embedder-floor
                        (mcp:embedder-from-env)))
               "control: surrounding space is trimmed, not junk")
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "1.5")
           (signals (error "a floor outside [0, 1]")
             (mcp:embedder-from-env))
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "")
           (signals (error "a URL needs a floor") (mcp:embedder-from-env))
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "0.5"
                 (uiop:getenv "CL_LLM_MEMORY_EMBED_MODEL") "")
           (signals (error "and a model") (mcp:embedder-from-env)))
      (dolist (p saved) (setf (uiop:getenv (car p)) (or (cdr p) ""))))))

(test the-index-off-line-tells-an-outage-from-an-engine-error
  "SS5: the one stderr line an entry point prints must not blame the
embedder for a store whose segment the reset could not touch -- the two
want different fixes."
  (let ((outage (make-condition 'cl-llm.conditions:llm-timeout-error
                                :url "http://127.0.0.1:1/v1/embeddings"))
        (other (make-condition 'simple-error
                               :format-control "segment ~a is busy"
                               :format-arguments '("endpoint-vector"))))
    (is (search "timed out" (mcp:index-off-reason outage)))
    (is (not (search "engine error" (mcp:index-off-reason outage)))
        "an embedder failure prints itself")
    (is (search "engine error while resetting"
                (mcp:index-off-reason other)))
    (is (search "segment endpoint-vector is busy"
                (mcp:index-off-reason other))
        "and still names the condition")))

(defun %constant-embed (dimension)
  "EMBED answering the same DIMENSION vector for every text."
  (lambda (text)
    (declare (ignore text))
    (make-array dimension :element-type 'single-float
                          :initial-element 1f0)))

(test prepare-endpoint-index-marks-the-embedder-ready
  "#80 item 3: the entry points' start step, also the worker's PREPARE.
A probe that signals leaves the embedder as it was and the error
propagates; one that answers resets a segment of another dimension,
clears another model's vectors, notes each, and marks the embedder
ready."
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "x")
             :subject '(:incident . "ledger-rollback"))
    (%belief p "root-cause" '(:cause . "y")
             :subject '(:incident . "ledger-freeze"))
    ;; W: the synonym embedder's dimension, another model's vectors.
    ;; P: another dimension altogether.
    (mem:drain-endpoint-vectors (list w) :embed (%constant-embed 32)
                                         :model "old")
    (mem:drain-endpoint-vectors (list p) :embed (%constant-embed 4)
                                         :model "old")
    (let* ((notes '())
           (note (lambda (control &rest args)
                   (push (apply #'format nil control args) notes)))
           (down (agent:make-endpoint-embedder
                  (cl-llm.rag:make-openai-compatible-embedder
                   :base-url "http://127.0.0.1:1/v1" :model "m")
                  :floor 0.3))
           (ee (cl-llm.agent/tests::%embedder)))
      (setf (agent:endpoint-embedder-ready down) nil
            (agent:endpoint-embedder-ready ee) nil)
      (signals cl-llm.conditions:llm-error
        (mcp:prepare-endpoint-index down (list w p) note))
      (is-false (agent:endpoint-embedder-ready down)
                "a probe that signals leaves it not ready")
      (is (null notes) "and touched no store")
      (is (eq t (mcp:prepare-endpoint-index ee (list w p) note)))
      (is-true (agent:endpoint-embedder-ready ee))
      (is (= 2 (length notes)) "one line per store changed: ~s" notes)
      (is (find-if (lambda (n)
                     (search "cleared 2 vectors of another model" n))
                   notes)
          "W's two vectors of the old model went: ~s" notes)
      (is (find-if (lambda (n) (search "segment reset to dimension 32"
                                       n))
                   notes)
          "P's segment was reset to the embedder's dimension: ~s" notes)
      (is (null (mem:nearest-endpoints w (funcall (%constant-embed 32)
                                                  "q")
                                       :k 5))
          "nothing of the old model is searchable")
      (is (= 2 (length (mem:dirty-endpoints w "synonym-test")))
          "and W's endpoints are dirty for the sweep"))))

(test the-probe-retries-only-what-can-recover
  "#80 review: transport, a timeout, a dropped stream, a rate limit
and a 5xx are retried from the worker; an auth error, any other 4xx
and an engine error turn the index off at once."
  (flet ((http (type &rest args)
           (apply #'make-condition type :url "http://e/v1/embeddings"
                  args)))
    (is-true (mcp:probe-retry-p (http 'cl-llm.conditions:llm-http-error
                                      :status nil :body "refused"))
             "transport: no status")
    (is-true (mcp:probe-retry-p (http 'cl-llm.conditions:llm-timeout-error)))
    (is-true (mcp:probe-retry-p (http 'cl-llm.conditions:llm-api-error
                                      :status 503 :body "")))
    (is-true (mcp:probe-retry-p (http 'cl-llm.conditions:llm-api-error
                                      :status 408 :body "")))
    (is-true (mcp:probe-retry-p
              (http 'cl-llm.conditions:llm-rate-limit-error
                    :status 429 :body "")))
    (is-true (mcp:probe-retry-p (make-condition 'end-of-file
                                                :stream *standard-input*))
             "a dropped connection the HTTP layer did not translate")
    (is-false (mcp:probe-retry-p (http 'cl-llm.conditions:llm-auth-error
                                       :status 401 :body ""))
              "a wrong key")
    (is-false (mcp:probe-retry-p (http 'cl-llm.conditions:llm-api-error
                                       :status 404 :body ""))
              "a model the endpoint lacks")
    (is-false (mcp:probe-retry-p (http 'cl-llm.conditions:llm-api-error
                                       :status 400 :body "")))
    (is-false (mcp:probe-retry-p (make-condition 'simple-error
                                                 :format-control "engine"))
              "an engine error is not the embedder's")))

(defclass %failing-embedder (cl-llm.rag:embedder)
  ((condition :initarg :condition :reader %failing-condition))
  (:default-initargs :model "m")
  (:documentation "An embedder whose every EMBED signals CONDITION."))

(defmethod cl-llm.rag:embed ((e %failing-embedder) input)
  (declare (ignore input))
  (error (%failing-condition e)))

(test the-workers-prepare-retries-or-gives-up-by-the-probes-failure
  "#80 review: RETRY-ENDPOINT-INDEX lets a 503 propagate, so the worker
retries it, and turns a 401 into ENDPOINT-INDEX-OFF naming it, so the
worker stops at once; the embedder stays not ready either way."
  (with-stores (w p)
    (flet ((embedder (type status)
             (let ((ee (agent:make-endpoint-embedder
                        (make-instance
                         '%failing-embedder
                         :condition (make-condition
                                     type :status status :body ""
                                     :url "http://e/v1/embeddings"))
                        :floor 0.3)))
               (setf (agent:endpoint-embedder-ready ee) nil)
               ee))
           (note (control &rest args)
             (declare (ignore control args))
             (fail "no store was touched")))
      (let ((down (embedder 'cl-llm.conditions:llm-api-error 503)))
        (signals cl-llm.conditions:llm-api-error
          (mcp:retry-endpoint-index down (list w p) #'note))
        (is-false (agent:endpoint-embedder-ready down)))
      (let ((wrong (embedder 'cl-llm.conditions:llm-auth-error 401)))
        (handler-case
            (progn (mcp:retry-endpoint-index wrong (list w p) #'note)
                   (fail "a 401 must end the retries"))
          (mem:endpoint-index-off (c)
            (is (search "401" (mem:endpoint-index-off-reason c))
                "and name the status: ~a" c)
            (is (not (search "engine error"
                             (mem:endpoint-index-off-reason c)))
                "as the embedder's failure, not the engine's")))
        (is-false (agent:endpoint-embedder-ready wrong))))))

(test the-start-line-names-which-key-the-embedder-will-send
  "#78: an empty CL_LLM_MEMORY_EMBED_KEY is not \"no credential\" --
RAG falls back to OPENAI_API_KEY (rag/embed.lisp:91) -- so the image's
banner and the solo server's start line must say which one goes out."
  (let ((saved (mapcar (lambda (n) (cons n (uiop:getenv n)))
                       '("CL_LLM_MEMORY_EMBED_KEY" "OPENAI_API_KEY"))))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_KEY") ""
                 (uiop:getenv "OPENAI_API_KEY") "")
           (is (string= "none" (mcp:embed-key-source)))
           (setf (uiop:getenv "OPENAI_API_KEY") "sk-would-have-leaked")
           (is (string= "OPENAI_API_KEY fallback" (mcp:embed-key-source))
               "an empty variable still sends a token")
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_KEY") "explicit")
           (is (string= "env CL_LLM_MEMORY_EMBED_KEY"
                        (mcp:embed-key-source))
               "the explicit key wins"))
      (dolist (p saved) (setf (uiop:getenv (car p)) (or (cdr p) ""))))))
