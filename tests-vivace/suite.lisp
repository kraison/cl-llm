;;;; tests-vivace/suite.lisp

(in-package #:cl-llm.rag.vivace/tests)

(def-suite :cl-llm-rag-vivace :description "cl-llm/rag/vivace offline suite.")
(in-suite :cl-llm-rag-vivace)

(test as-embedding-is-public
  "The RAG core export the adapter relies on is present."
  (is (fboundp 'rag:as-embedding))
  (is (equalp (rag:as-embedding '(1 2 3))
              (rag:as-embedding #(1.0d0 2.0d0 3.0d0)))))
