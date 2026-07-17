;;;; tests-eval/score.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(test score-basic
  (let ((s (eval:score 0.8 :explanation "good enough")))
    (is (= 0.8 (eval:score-value s)))
    (is (string= "good enough" (eval:score-explanation s)))))

(test score-explanation-defaults-to-nil
  (is (null (eval:score-explanation (eval:score 1.0)))))

(test score-clamps-above-one
  (is (= 1.0 (eval:score-value (eval:score 1.7)))))

(test score-clamps-below-zero
  (is (= 0.0 (eval:score-value (eval:score -0.5)))))

(test score-keeps-in-range-values
  (is (= 0.0 (eval:score-value (eval:score 0.0))))
  (is (= 0.5 (eval:score-value (eval:score 1/2))))
  (is (= 1.0 (eval:score-value (eval:score 1)))))

(test score-non-real-signals-eval-error
  (signals eval:llm-eval-error (eval:score "not a number"))
  (signals eval:llm-eval-error (eval:score nil)))

(test llm-eval-error-is-an-llm-error
  (is (subtypep 'eval:llm-eval-error 'c:llm-error)))
