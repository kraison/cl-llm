;;;; tests/conditions.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test conditions-hierarchy
  "Every condition must be reachable as an LLM-ERROR."
  (dolist (type '(c:llm-http-error c:llm-api-error c:llm-rate-limit-error
                  c:llm-auth-error c:llm-timeout-error c:llm-parse-error
                  c:llm-tool-error))
    (is (subtypep type 'c:llm-error)
        "~a should be a subtype of llm-error" type))
  (is (subtypep 'c:llm-rate-limit-error 'c:llm-api-error))
  (is (subtypep 'c:llm-auth-error 'c:llm-api-error))
  (is (subtypep 'c:llm-api-error 'c:llm-http-error)))

(test conditions-readers
  (let ((e (make-condition 'c:llm-rate-limit-error
                           :status 429 :url "https://x/y" :body "{}"
                           :message "slow down" :error-type "rate_limit_error"
                           :retry-after 30)))
    (is (= 429 (c:llm-error-status e)))
    (is (string= "https://x/y" (c:llm-error-url e)))
    (is (string= "slow down" (c:llm-error-message e)))
    (is (= 30 (c:llm-error-retry-after e)))))

(test conditions-report-is-readable-and-leaks-no-secrets
  "The report must be human-readable and must never include headers."
  (let ((text (princ-to-string
               (make-condition 'c:llm-api-error
                               :status 400 :url "https://api.anthropic.com/v1/messages"
                               :message "bad request" :error-type "invalid_request_error"))))
    (is (search "400" text))
    (is (search "bad request" text))
    (is (not (search "sk-ant" text)))))

(test conditions-tool-error
  (let ((e (make-condition 'c:llm-tool-error :tool-name "get-weather"
                                             :underlying "boom")))
    (is (string= "get-weather" (c:llm-error-tool-name e)))
    (is (search "get-weather" (princ-to-string e)))))
