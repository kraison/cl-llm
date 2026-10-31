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

(defun %temp-system-directory ()
  "A fresh, not-yet-existing directory namestring under /tmp for
GDB:*SYSTEM-DIRECTORY*.  The caller deletes it: %DELETE-SYSTEM-DIRECTORY."
  (format nil "/tmp/cl-llm-vg-sys-~a-~a/"
          (get-internal-real-time) (random 1000000)))

(defun %delete-system-directory ()
  "Delete the directory GDB:*SYSTEM-DIRECTORY* names, if it exists."
  (ignore-errors
   (uiop:delete-directory-tree (pathname gdb:*system-directory*)
                               :validate t :if-does-not-exist :ignore)))

(defmacro with-system-directory (() &body body)
  "Run BODY with GDB:*SYSTEM-DIRECTORY* bound to a fresh temp directory,
deleted afterwards however BODY exits.  Graphs made inside share it, so a
close-and-reopen within BODY keeps its type ids."
  `(let ((gdb:*system-directory* (%temp-system-directory)))
     (unwind-protect (progn ,@body)
       (%delete-system-directory))))
