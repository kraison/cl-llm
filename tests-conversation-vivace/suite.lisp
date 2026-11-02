;;;; tests-conversation-vivace/suite.lisp -- an on-disk graph per test.

(in-package #:cl-llm.conversation.vivace/tests)

(def-suite :cl-llm-conversation-vivace
  :description "cl-llm/conversation/vivace offline suite (on-disk graph).")
(in-suite :cl-llm-conversation-vivace)

(defparameter +graph-name+ :cl-llm-conversations-test)

(cv:define-conversation-store :cl-llm-conversations-test)

(defun %scratch (prefix)
  (format nil "/tmp/cl-llm-~a-~a-~a/"
          prefix (get-internal-real-time) (random 1000000)))

(defun %call-with-graph (fn)
  "FN of (graph dir) on a fresh graph; the system directory and the
graph's directory are deleted afterwards."
  (let* ((dir (%scratch "conv-graph"))
         (gdb:*system-directory* (%scratch "conv-sys"))
         (graph (gdb:make-graph +graph-name+ dir :buffer-pool-size 1000)))
    (unwind-protect (funcall fn graph dir)
      (ignore-errors (gdb:close-graph graph))
      (ignore-errors (uiop:delete-directory-tree (pathname dir)
                                                 :validate t))
      (ignore-errors (uiop:delete-directory-tree
                      (pathname gdb:*system-directory*)
                      :validate t :if-does-not-exist :ignore)))))

(defmacro with-graph ((graph &optional (dir (gensym "DIR"))) &body body)
  `(%call-with-graph (lambda (,graph ,dir)
                       (declare (ignorable ,dir))
                       ,@body)))

(defun %ann (&rest kv)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun %age (store sc seconds)
  (decf (llm:stored-conversation-updated sc) seconds)
  (llm:save-conversation store sc))
