;;;; tests/suite.lisp

(in-package #:cl-llm.test)

(def-suite cl-llm-suite
  :description "All offline tests for cl-llm.")

(in-suite cl-llm-suite)

(test harness-is-wired
  "The suite runs and packages are loadable."
  (is (find-package '#:cl-llm))
  (is (find-package '#:cl-llm.json)))
