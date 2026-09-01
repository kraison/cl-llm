;;;; tests-memory/harness.lisp -- a real on-disk graph per test, as
;;;; tests-claims does.

(in-package #:cl-llm.memory/tests)

(def-suite :cl-llm-memory
  :description "cl-llm/memory offline suite (on-disk graph).")
(in-suite :cl-llm-memory)

(defun %call-with-graph (fn)
  (let* ((dir (format nil "/tmp/cl-llm-memory-test-~a-~a/"
                      (get-internal-real-time) (random 1000000)))
         (gdb:*system-directory*
           (format nil "/tmp/cl-llm-memory-sys-~a-~a/"
                   (get-internal-real-time) (random 1000000)))
         (graph (gdb:make-graph :cl-llm-memory dir
                                :buffer-pool-size 1000)))
    (unwind-protect (funcall fn graph)
      (ignore-errors (gdb:close-graph graph))
      (ignore-errors (uiop:delete-directory-tree
                      (pathname dir) :validate t))
      (ignore-errors (uiop:delete-directory-tree
                      (pathname gdb:*system-directory*)
                      :validate t :if-does-not-exist :ignore)))))

(defmacro with-memory-graph ((g) &body body)
  `(%call-with-graph (lambda (,g) ,@body)))

(defun %ts (string)
  (local-time:parse-timestring string))

(defun %interval (y1 y2)
  "A :VALIDITY interval from Jan 1 Y1 to Jan 1 Y2."
  (te:make-interval
   (te:exact-bound (%ts (format nil "~d-01-01T00:00:00Z" y1)))
   (te:exact-bound (%ts (format nil "~d-01-01T00:00:00Z" y2)))
   :semantics :validity :standing :asserted))

(defun %open-from (ts)
  "[TS, unknown) -- a belief still held."
  (te:make-interval (te:exact-bound ts) (te:unknown-bound)
                    :semantics :validity :standing :asserted))

(defparameter +p+ "claude-code/test"
  "The producer every test writes under, canonical (vg#160).")
