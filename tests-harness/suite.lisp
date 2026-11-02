;;;; tests-harness/suite.lisp -- the suite, and a scratch directory.

(in-package #:cl-llm.harness/tests)

(def-suite :cl-llm-harness
  :description "cl-llm/harness offline suite (mock providers only).")
(in-suite :cl-llm-harness)

(defun %call-with-scratch-dir (fn)
  "Call FN with a fresh directory pathname, deleted afterwards."
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "/tmp/cl-llm-harness-~a-~a/"
                      (get-internal-real-time) (random 1000000)))))
    (ensure-directories-exist dir)
    (unwind-protect (funcall fn dir)
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defmacro with-scratch-dir ((var) &body body)
  `(%call-with-scratch-dir (lambda (,var) ,@body)))

(defun write-text (pathname text)
  "Write TEXT to PATHNAME, replacing it; returns PATHNAME."
  (with-open-file (s pathname :direction :output :if-exists :supersede)
    (write-string text s))
  pathname)
