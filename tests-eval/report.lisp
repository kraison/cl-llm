;;;; tests-eval/report.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(defun run-tiny-suite ()
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite report-suite
      :dataset (list (eval:make-case "hi" :expected "hi")
                     (eval:make-case "yo" :expected "NOPE"))
      :variants ((:model "m" :temperature 0.0 :label "cold"))
      :scorers (eval:exact-match))
    (eval:run-suite 'report-suite)))

(test print-object-renders-a-table
  (let ((text (princ-to-string (run-tiny-suite))))
    (is (search "cold" text) "variant label appears")
    (is (search "exact-match" text) "scorer column appears")))

(test report-returns-the-result
  (let ((result (run-tiny-suite)))
    (is (eq result (eval:report result :stream (make-broadcast-stream))))))

(test report-detail-shows-explanations
  (let* ((result (run-tiny-suite))
         (text (with-output-to-string (s)
                 (eval:report result :detail t :stream s))))
    ;; the mismatching case's explanation mentions the expected value
    (is (search "NOPE" text) "detail shows the expected value from the explanation")))

(test report-summary-shows-mean
  (let* ((result (run-tiny-suite))
         (text (with-output-to-string (s)
                 (eval:report result :stream s))))
    ;; one match out of two -> mean 0.5 appears in some rendering
    (is (or (search "0.5" text) (search "0.50" text)))))

(test print-object-shows-dash-for-nil-mean
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (c) (declare (ignore c))
                        (error 'llm:llm-api-error :status 500 :message "x")))))
    (eval:defsuite dash-suite
      :dataset (list (eval:make-case "x" :expected "x"))
      :variants ((:model "m" :label "v"))
      :scorers (eval:exact-match))
    (let ((text (princ-to-string (eval:run-suite 'dash-suite))))
      (is (search "—" text) "a nil mean renders as an em dash"))))
