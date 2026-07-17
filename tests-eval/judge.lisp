;;;; tests-eval/judge.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(test parse-judge-score-fraction
  (multiple-value-bind (value rationale) (eval:parse-judge-score "0.8 fluent and clear")
    (is (= 0.8 value))
    (is (search "fluent" rationale))))

(test parse-judge-score-percentage
  (is (= 0.9 (eval:parse-judge-score "90 - strong answer"))))

(test parse-judge-score-hundred
  (is (= 1.0 (eval:parse-judge-score "100"))))

(test parse-judge-score-unparseable
  (is (null (eval:parse-judge-score "no number here"))))

(test defjudge-uses-the-mock-and-scores
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "0.75 the answer is mostly right"))))
    (eval:defjudge judge-quality (case response)
      (declare (ignore response))
      (format nil "Grade the answer to: ~a" (eval:case-input case)))
    (let ((s (eval:run-scorer (eval:find-scorer 'judge-quality)
                              (eval:make-case "2+2?")
                              (response-with-text "4"))))
      (is (= 0.75 (eval:score-value s)))
      (is (search "mostly right" (eval:score-explanation s))))))

(test defjudge-unparseable-reply-scores-0
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "I cannot grade this"))))
    (eval:defjudge judge-garbage (case response)
      (declare (ignore case response))
      "grade it")
    (let ((s (eval:run-scorer (eval:find-scorer 'judge-garbage)
                              (eval:make-case "q")
                              (response-with-text "a"))))
      (is (= 0.0 (eval:score-value s)))
      (is (search "unparseable" (eval:score-explanation s))))))

(test defjudge-swallows-llm-error
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (error 'llm:llm-api-error :status 500 :message "judge down")))))
    (eval:defjudge judge-failing (case response)
      (declare (ignore case response))
      "grade it")
    (let ((s (eval:run-scorer (eval:find-scorer 'judge-failing)
                              (eval:make-case "q")
                              (response-with-text "a"))))
      (is (= 0.0 (eval:score-value s)))
      (is (stringp (eval:score-explanation s))))))
