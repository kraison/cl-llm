;;;; tests-vivace/suite.lisp

(in-package #:cl-llm.rag.vivace/tests)

(def-suite :cl-llm-rag-vivace :description "cl-llm/rag/vivace offline suite.")
(in-suite :cl-llm-rag-vivace)

(test as-embedding-is-public
  "The RAG core export the adapter relies on is present."
  (is (fboundp 'rag:as-embedding))
  (is (equalp (rag:as-embedding '(1 2 3))
              (rag:as-embedding #(1.0d0 2.0d0 3.0d0)))))

;;; graph-db refuses MAKE-GRAPH, OPEN-GRAPH and MAKE-MEMORY-GRAPH while
;;; GDB:*SYSTEM-DIRECTORY* (its type-id registry) is NIL, vivace-graph
;;; #186.  Each test binds a fresh one, as tests-memory and tests-claims do.

(defparameter *test-buffer-pool-size* 1000
  "Size the suite starts graph-db's buffer pool at (#11).  The pool is one
process-wide resource, sized by whichever graph opens FIRST and held for
the life of the image: at MAKE-GRAPH's default of 100000 it pre-fills
~300 MB of buffers, and a :BUFFER-POOL-SIZE on any later graph is ignored.")

(defun %ensure-test-buffer-pool ()
  "Start graph-db's buffer pool at *TEST-BUFFER-POOL-SIZE* unless a pool is
already running, whose size then stays.  Returns the size in force."
  (gdb::ensure-buffer-pool *test-buffer-pool-size*)
  gdb:*buffer-pool-size*)

(defun %temp-system-directory ()
  "A fresh, not-yet-existing directory namestring under /tmp for
GDB:*SYSTEM-DIRECTORY*.  The caller deletes it: %DELETE-SYSTEM-DIRECTORY.
Every test binds one before its first graph, so this is also where the
buffer pool is pinned (%ENSURE-TEST-BUFFER-POOL): a test run alone in a
fresh image would otherwise size the pool at graph-db's default."
  (%ensure-test-buffer-pool)
  (format nil "/tmp/cl-llm-vg-sys-~a-~a/"
          (get-internal-real-time) (random 1000000)))

(defun %delete-system-directory ()
  "Delete the directory GDB:*SYSTEM-DIRECTORY* names, if it exists."
  (ignore-errors
   (uiop:delete-directory-tree (pathname gdb:*system-directory*)
                               :validate t :if-does-not-exist :ignore)))

(defmacro with-system-directory (() &body body)
  "Run BODY with GDB:*SYSTEM-DIRECTORY* bound to a fresh temp directory
(%TEMP-SYSTEM-DIRECTORY, which also pins the buffer pool), deleted
afterwards however BODY exits.  Graphs made inside share the directory, so
a close-and-reopen within BODY keeps its type ids."
  `(let ((gdb:*system-directory* (%temp-system-directory)))
     (unwind-protect (progn ,@body)
       (%delete-system-directory))))
