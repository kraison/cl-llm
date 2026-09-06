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
