;;;; tests-eval/suite.lisp

(in-package #:cl-llm.eval.test)

(def-suite cl-llm-eval-suite
  :description "All offline tests for cl-llm/eval.")

(in-suite cl-llm-eval-suite)

(test eval-harness-is-wired
  "The eval suite runs and its packages are loadable."
  (is (find-package '#:cl-llm.eval))
  (is (find-package '#:cl-llm)))
