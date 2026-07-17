;;;; tests-eval/suite.lisp

(in-package #:cl-llm.eval.test)

(def-suite cl-llm-eval-suite
  :description "All offline tests for cl-llm/eval.")

(in-suite cl-llm-eval-suite)

(test eval-harness-is-wired
  (is (find-package '#:cl-llm.eval))
  (is (find-package '#:cl-llm)))

(test parse-variant-splits-args-from-eval-keys
  (let ((v (eval:parse-variant '(:model "m" :temperature 0.2 :label "cold"))))
    (is (string= "cold" (eval:variant-label v)))
    (is (equal '(:model "m" :temperature 0.2) (eval:variant-args v)))))

(test parse-variant-prompt-fn-defaults-to-case-input
  (let ((v (eval:parse-variant '(:model "m"))))
    (is (string= "hi" (funcall (eval:variant-prompt-fn v) (eval:make-case "hi"))))))

(test parse-variant-custom-prompt-fn
  (let ((v (eval:parse-variant
            (list :model "m"
                  :prompt-fn (lambda (c) (format nil "Q: ~a" (eval:case-input c)))))))
    (is (string= "Q: hi" (funcall (eval:variant-prompt-fn v) (eval:make-case "hi"))))
    (is (null (getf (eval:variant-args v) :prompt-fn))
        ":prompt-fn must be stripped from the args forwarded to ask")))

(test parse-variant-label-defaults-to-nonempty-string
  (is (stringp (eval:variant-label (eval:parse-variant '(:model "m" :temperature 0.0))))))

(test defsuite-registers-and-resolves
  (defparameter *suite-cases* (list (eval:make-case "q" :expected "a")))
  (eval:defsuite my-suite
    :dataset *suite-cases*
    :variants ((:model "m" :temperature 0.0))
    :scorers (eval:exact-match))
  (let ((s (eval:find-suite 'my-suite)))
    (is (string= "my-suite" (eval:suite-name s)))
    (is (equal *suite-cases* (funcall (eval:suite-dataset-fn s))))
    (is (= 1 (length (eval:suite-variants s))))
    (is (= 1 (length (eval:suite-scorers s))))
    (is (string= "exact-match" (eval:scorer-name (first (eval:suite-scorers s)))))))

(test defsuite-dataset-is-evaluated-at-run-time
  "The dataset form is re-evaluated each call, so a mutated special is seen."
  (defparameter *dyn-cases* (list (eval:make-case "one")))
  (eval:defsuite dyn-suite
    :dataset *dyn-cases*
    :variants ((:model "m"))
    :scorers (eval:exact-match))
  (let ((s (eval:find-suite 'dyn-suite)))
    (is (= 1 (length (funcall (eval:suite-dataset-fn s)))))
    (setf *dyn-cases* (list (eval:make-case "one") (eval:make-case "two")))
    (is (= 2 (length (funcall (eval:suite-dataset-fn s)))))))

(test find-suite-unknown-signals
  (signals eval:llm-eval-error (eval:find-suite 'no-such-suite)))
