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
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "1.5")
           (signals (error "a floor outside [0, 1]")
             (mcp:embedder-from-env))
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "")
           (signals (error "a URL needs a floor") (mcp:embedder-from-env))
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "0.5"
                 (uiop:getenv "CL_LLM_MEMORY_EMBED_MODEL") "")
           (signals (error "and a model") (mcp:embedder-from-env)))
      (dolist (p saved) (setf (uiop:getenv (car p)) (or (cdr p) ""))))))
