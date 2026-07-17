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
  "The report must be human-readable and must never include headers or body,
even when a secret-shaped value is present in the body."
  (let ((text (princ-to-string
               (make-condition 'c:llm-api-error
                               :status 400 :url "https://api.anthropic.com/v1/messages"
                               :message "bad request" :error-type "invalid_request_error"
                               :body "{\"error\": {\"message\": \"bad key sk-ant-api03-SECRETVALUE\"}}"))))
    (is (search "400" text))
    (is (search "bad request" text))
    (is (not (search "sk-ant-api03-SECRETVALUE" text)))))

(test conditions-tool-error
  (let ((e (make-condition 'c:llm-tool-error :tool-name "get-weather"
                                             :underlying "boom")))
    (is (string= "get-weather" (c:llm-error-tool-name e)))
    (is (search "get-weather" (princ-to-string e)))))

(test public-condition-api-catches-and-reads
  "The public CL-LLM package must genuinely re-export the condition symbols
from CL-LLM.CONDITIONS -- not merely intern same-named symbols -- so that a
consumer using only the LLM: nickname can catch and inspect errors this
library signals. This is the exact pattern the README documents."
  (is (eq 'llm:llm-error 'c:llm-error)
      "LLM:LLM-ERROR must be EQ to C:LLM-ERROR (a true re-export), not a distinct symbol")
  (is (eq 'llm:llm-error-status 'c:llm-error-status))
  (let ((caught nil))
    (handler-case
        (error 'llm:llm-auth-error :status 401 :message "nope")
      (llm:llm-error (e)
        (setf caught e)))
    (is (not (null caught))
        "handler-case on LLM:LLM-ERROR must catch a signalled LLM-AUTH-ERROR")
    (is (= 401 (llm:llm-error-status caught))
        "LLM:LLM-ERROR-STATUS must be callable on the condition via the public package")))

(test conditions-tool-error-report-without-tool-name
  "When TOOL-NAME is NIL (e.g. the bounded tool loop giving up after
max-tool-turns), the report must still read as a sensible sentence and
must never print the literal NIL."
  (let* ((e (make-condition 'c:llm-tool-error
                            :tool-name nil
                            :underlying "The model still requested tools after 8 turns (max-tool-turns). Giving up."))
         (text (princ-to-string e)))
    (is (search "max-tool-turns" text))
    (is (not (search "NIL" text)))))
