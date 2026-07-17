;;;; tests-eval/scorer.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(defun response-with-text (text)
  (make-instance 'llm:response :content (list (llm:make-text-part text))))

(test make-case-fields
  (let ((c (eval:make-case "in" :expected "out" :metadata '(:tag 1))))
    (is (string= "in" (eval:case-input c)))
    (is (string= "out" (eval:case-expected c)))
    (is (equal '(:tag 1) (eval:case-metadata c)))))

(test make-case-optional-fields-default-nil
  (let ((c (eval:make-case "in")))
    (is (null (eval:case-expected c)))
    (is (null (eval:case-metadata c)))))

(test exact-match-scores-1-on-match
  (let ((s (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                            (eval:make-case "q" :expected "hello")
                            (response-with-text "hello"))))
    (is (= 1.0 (eval:score-value s)))))

(test exact-match-scores-0-on-mismatch
  (let ((s (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                            (eval:make-case "q" :expected "hello")
                            (response-with-text "goodbye"))))
    (is (= 0.0 (eval:score-value s)))
    (is (stringp (eval:score-explanation s)))))

(test exact-match-requires-expected
  (signals eval:llm-eval-error
    (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                     (eval:make-case "q")
                     (response-with-text "x"))))

(test exact-match-nil-response-scores-0
  (let ((s (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                            (eval:make-case "q" :expected "hello")
                            nil)))
    (is (= 0.0 (eval:score-value s)))))

(test defscorer-defines-and-registers
  (eval:defscorer contains-hi (case response)
    "Score 1.0 if the response text contains 'hi'."
    (declare (ignore case))
    (if (and response (search "hi" (llm:response-text response)))
        (eval:score 1.0)
        (eval:score 0.0 :explanation "no 'hi'")))
  (let ((scorer (eval:find-scorer 'contains-hi)))
    (is (string= "contains-hi" (eval:scorer-name scorer)))
    (is (= 1.0 (eval:score-value
                (eval:run-scorer scorer (eval:make-case "q")
                                 (response-with-text "oh hi there")))))))

(test find-scorer-accepts-symbol-string-object
  (let ((scorer (eval:find-scorer 'eval:exact-match)))
    (is (eq scorer (eval:find-scorer "exact-match")))
    (is (eq scorer (eval:find-scorer scorer)))))

(test find-scorer-unknown-signals
  (signals eval:llm-eval-error (eval:find-scorer 'no-such-scorer)))
