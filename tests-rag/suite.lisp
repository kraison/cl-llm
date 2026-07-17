;;;; tests-rag/suite.lisp

(in-package #:cl-llm.rag.test)

(def-suite cl-llm-rag-suite
  :description "All offline tests for cl-llm/rag.")

(in-suite cl-llm-rag-suite)

(test rag-harness-is-wired
  (is (find-package '#:cl-llm.rag))
  (is (subtypep 'rag:llm-rag-error 'c:llm-error)))
