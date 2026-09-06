;;;; tests-agent-mcp/harness.lisp -- scratch directories per test.

(in-package #:cl-llm.agent.mcp/tests)

(def-suite :cl-llm-agent-mcp
  :description "cl-llm/agent/mcp offline suite (on-disk stores).")
(in-suite :cl-llm-agent-mcp)

(defun %fresh-root ()
  (format nil "/tmp/cl-llm-mcp-~a-~a/" (get-internal-real-time)
          (random 1000000)))

(defmacro with-scratch-root ((root) &body body)
  "ROOT bound to a fresh directory namestring (trailing slash); deleted
after BODY.  Stores, the clock and the system directory live under it."
  `(let ((,root (%fresh-root)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       (pathname ,root) :validate t
                       :if-does-not-exist :ignore)))))

(defun %sub (root name)
  "ROOT/NAME/ as a namestring with a trailing slash."
  (concatenate 'string root name))

(defun %dirty-p (dir)
  (probe-file (concatenate 'string dir ".dirty")))

(defun %open (root spec &optional write)
  "OPEN-SCOPE under ROOT with the test's clock and system dirs."
  (mcp:open-scope :spec spec :write write
                  :clock-dir (%sub root "clock/")
                  :system-dir (%sub root "sys/")
                  :buffer-pool 1000))
