;;;; tests-eval/run.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(defun echo-mock ()
  "A mock whose reply is the last user message's text."
  (llm:make-mock-provider
   :responder (lambda (conversation)
                (llm:part-text
                 (first (llm:message-content
                         (car (last (llm:conversation-messages conversation)))))))))

(test run-suite-produces-a-cell-per-case-times-variant
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite grid-suite
      :dataset (list (eval:make-case "a" :expected "a")
                     (eval:make-case "b" :expected "b"))
      :variants ((:model "m" :temperature 0.0)
                 (:model "m" :temperature 1.0))
      :scorers (eval:exact-match))
    (let ((result (eval:run-suite 'grid-suite)))
      (is (= 4 (length (eval:result-cells result)))))))

(test run-suite-scores-exact-match-with-echo
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite echo-suite
      :dataset (list (eval:make-case "hello" :expected "hello"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let ((result (eval:run-suite 'echo-suite)))
      ;; echo returns the prompt, which equals expected -> mean 1.0
      (is (= 1.0 (eval:result-mean result
                                   (eval:variant-label
                                    (first (eval:suite-variants
                                            (eval:find-suite 'echo-suite))))
                                   "exact-match"))))))

(test run-suite-uses-the-variant-prompt-fn
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite promptfn-suite
      :dataset (list (eval:make-case "world" :expected "hi world"))
      :variants ((:model "m"
                  :prompt-fn (lambda (c) (format nil "hi ~a" (eval:case-input c)))))
      :scorers (eval:exact-match))
    (let ((result (eval:run-suite 'promptfn-suite)))
      (is (= 1.0 (eval:result-mean result
                                   (eval:variant-label
                                    (first (eval:suite-variants
                                            (eval:find-suite 'promptfn-suite))))
                                   "exact-match"))))))

(test run-suite-records-error-cells-without-aborting
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (let ((prompt (llm:part-text
                                       (first (llm:message-content
                                               (car (last (llm:conversation-messages
                                                           conversation))))))))
                          (if (string= prompt "boom")
                              (error 'llm:llm-api-error :status 500 :message "down")
                              prompt))))))
    (eval:defsuite mixed-suite
      :dataset (list (eval:make-case "ok" :expected "ok")
                     (eval:make-case "boom" :expected "boom"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let* ((result (eval:run-suite 'mixed-suite))
           (label (eval:variant-label
                   (first (eval:suite-variants (eval:find-suite 'mixed-suite))))))
      (is (= 2 (length (eval:result-cells result))))
      (is (= 1 (eval:result-error-count result label)))
      ;; mean over the ONE non-error cell is 1.0, not NaN
      (is (= 1.0 (eval:result-mean result label "exact-match")))
      (is (find-if #'eval:cell-error (eval:result-cells result))))))

(test run-suite-mean-is-nil-when-all-cells-errored
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (error 'llm:llm-api-error :status 500 :message "always")))))
    (eval:defsuite all-fail-suite
      :dataset (list (eval:make-case "x" :expected "x"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let* ((result (eval:run-suite 'all-fail-suite))
           (label (eval:variant-label
                   (first (eval:suite-variants (eval:find-suite 'all-fail-suite))))))
      (is (null (eval:result-mean result label "exact-match"))))))

(test run-suite-eval-map-is-used
  "Rebinding *eval-map* changes how the grid is traversed."
  (let ((llm:*provider* (echo-mock))
        (calls 0))
    (eval:defsuite map-suite
      :dataset (list (eval:make-case "a" :expected "a"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let ((eval:*eval-map* (lambda (fn list) (incf calls) (mapcar fn list))))
      (eval:run-suite 'map-suite))
    (is (plusp calls) "*eval-map* must be the traversal seam")))
