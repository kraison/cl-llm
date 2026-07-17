;;;; tests/anthropic.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun test-anthropic-provider ()
  (make-instance 'llm:anthropic-provider :api-key "sk-test"))

(defun anthropic-response-fixture ()
  "{\"id\":\"msg_1\",\"model\":\"claude-opus-4-8\",\"stop_reason\":\"end_turn\",
    \"content\":[{\"type\":\"text\",\"text\":\"Hello\"}],
    \"usage\":{\"input_tokens\":10,\"output_tokens\":3}}")

(test anthropic-encode-basic-request
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "claude-opus-4-8" (json:jget body "model")))
    (is (= 4096 (json:jget body "max_tokens")) "max_tokens is required by Anthropic")
    (is (string= "user" (json:jget body "messages" 0 "role")))
    (is (string= "text" (json:jget body "messages" 0 "content" 0 "type")))
    (is (string= "hi" (json:jget body "messages" 0 "content" 0 "text")))))

(test anthropic-encode-omits-unset-optional-parameters
  "An unset temperature must be ABSENT, not false -- this is the jzon nil trap."
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (null (nth-value 1 (gethash "temperature" body)))
        "temperature must not appear at all")
    (is (null (nth-value 1 (gethash "system" body))))
    (is (null (nth-value 1 (gethash "tools" body))))))

(test anthropic-encode-system-is-top-level
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :system "be terse"
                                   :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "be terse" (json:jget body "system")))))

(test anthropic-encode-parameters
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))
                                   :parameters '(:temperature 0.2 :max-tokens 100)))
         (body (json:parse (llm:encode-request p c))))
    (is (= 0.2d0 (json:jget body "temperature")))
    (is (= 100 (json:jget body "max_tokens")))))

(test anthropic-encode-stream-flag
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
    (is (eq t (json:jget (json:parse (llm:encode-request p c :stream t)) "stream")))
    (is (null (nth-value 1 (gethash "stream" (json:parse (llm:encode-request p c)))))
        "stream must be omitted, not false, for non-streaming requests")))

(test anthropic-encode-tool-result-message
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation
             :messages (list (llm:make-message
                              :user (list (llm:make-tool-result-part "tu_1" "22C"))))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "tool_result" (json:jget body "messages" 0 "content" 0 "type")))
    (is (string= "tu_1" (json:jget body "messages" 0 "content" 0 "tool_use_id")))
    (is (string= "22C" (json:jget body "messages" 0 "content" 0 "content")))))

(test anthropic-decode-text-response
  (let* ((p (test-anthropic-provider))
         (r (llm:decode-response p (json:parse (anthropic-response-fixture)))))
    (is (string= "Hello" (llm:response-text r)))
    (is (eq :end-turn (llm:response-stop-reason r)))
    (is (string= "claude-opus-4-8" (llm:response-model r)))
    (is (= 10 (llm:usage-input-tokens (llm:response-usage r))))
    (is (= 3 (llm:usage-output-tokens (llm:response-usage r))))))

(test anthropic-decode-tool-use-response
  (let* ((p (test-anthropic-provider))
         (payload (json:parse
                   "{\"model\":\"m\",\"stop_reason\":\"tool_use\",\"content\":[
                      {\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"get-weather\",
                       \"input\":{\"city\":\"Oakland\"}}]}"))
         (r (llm:decode-response p payload))
         (call (first (llm:response-tool-calls r))))
    (is (eq :tool-use (llm:response-stop-reason r)))
    (is (string= "tu_1" (llm:part-id call)))
    (is (string= "get-weather" (llm:part-name call)))
    (is (string= "Oakland" (gethash "city" (llm:part-arguments call))))))

(test anthropic-decode-unknown-stop-reason-is-nil
  (let* ((p (test-anthropic-provider))
         (r (llm:decode-response p (json:parse "{\"content\":[],\"stop_reason\":\"weird\"}"))))
    (is (null (llm:response-stop-reason r)))))

(test anthropic-chat-request-end-to-end
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (let* ((p (test-anthropic-provider))
           (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
           (r (llm:chat-request p c)))
      (is (string= "Hello" (llm:response-text r)))
      (is (string= "https://api.anthropic.com/v1/messages"
                   (getf (last-request d) :url)))
      (is (string= "sk-test"
                   (cdr (assoc "x-api-key" (getf (last-request d) :headers)
                               :test #'string-equal)))))))

(test anthropic-chat-request-signals-on-api-error
  (with-fake-driver (d (:status 400 :body "{\"error\":{\"message\":\"bad\",\"type\":\"invalid_request_error\"}}"))
    (let ((p (test-anthropic-provider))
          (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
      (signals c:llm-api-error (llm:chat-request p c)))))

(test anthropic-chat-request-signals-parse-error-on-garbage
  (with-fake-driver (d (:status 200 :body "not json at all"))
    (let ((p (test-anthropic-provider))
          (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
      (signals c:llm-parse-error (llm:chat-request p c)))))
