;;;; tests/openai.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun test-openai-provider ()
  (make-instance 'llm:openai-compatible-provider
                 :base-url "http://localhost:11434/v1" :model "llama3.1"))

(defun openai-response-fixture ()
  "{\"model\":\"llama3.1\",\"choices\":[{\"finish_reason\":\"stop\",
     \"message\":{\"role\":\"assistant\",\"content\":\"Hello\"}}],
     \"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}")

(test openai-encode-system-is-a-message
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :system "be terse"
                                   :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "system" (json:jget body "messages" 0 "role")))
    (is (string= "be terse" (json:jget body "messages" 0 "content")))
    (is (string= "user" (json:jget body "messages" 1 "role")))
    (is (null (nth-value 1 (gethash "system" body)))
        "system must NOT be a top-level field for OpenAI")))

(test openai-encode-content-is-a-plain-string
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "hi" (json:jget body "messages" 0 "content"))
        "OpenAI content is a string, not a parts array")))

(test openai-encode-omits-max-tokens-when-unset
  "Unlike Anthropic, max_tokens is optional here and must be omitted."
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (null (nth-value 1 (gethash "max_tokens" body))))))

(test openai-encode-tool
  (with-clean-registry
    (eval '(llm:deftool tool-weather (city) "Look up weather." city))
    (let* ((p (test-openai-provider))
           (encoded (json:parse (json:to-json
                                 (llm:encode-tool p (llm:find-tool 'tool-weather))))))
      (is (string= "function" (json:jget encoded "type")))
      (is (string= "tool-weather" (json:jget encoded "function" "name")))
      (is (string= "string"
                   (json:jget encoded "function" "parameters" "properties" "city" "type"))))))

(test openai-encode-tool-result-message
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation
             :messages (list (llm:make-message
                              :user (list (llm:make-tool-result-part "tc_1" "22C"))))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "tool" (json:jget body "messages" 0 "role")))
    (is (string= "tc_1" (json:jget body "messages" 0 "tool_call_id")))
    (is (string= "22C" (json:jget body "messages" 0 "content")))))

(test openai-decode-text-response
  (let* ((p (test-openai-provider))
         (r (llm:decode-response p (json:parse (openai-response-fixture)))))
    (is (string= "Hello" (llm:response-text r)))
    (is (eq :end-turn (llm:response-stop-reason r)))
    (is (= 10 (llm:usage-input-tokens (llm:response-usage r))))
    (is (= 3 (llm:usage-output-tokens (llm:response-usage r))))))

(test openai-decode-tool-calls-parses-argument-string
  "OpenAI sends arguments as a JSON STRING that must be parsed."
  (let* ((p (test-openai-provider))
         (payload (json:parse
                   "{\"model\":\"m\",\"choices\":[{\"finish_reason\":\"tool_calls\",
                      \"message\":{\"tool_calls\":[{\"id\":\"tc_1\",\"type\":\"function\",
                        \"function\":{\"name\":\"get-weather\",
                                     \"arguments\":\"{\\\"city\\\":\\\"Oakland\\\"}\"}}]}}]}"))
         (r (llm:decode-response p payload))
         (call (first (llm:response-tool-calls r))))
    (is (eq :tool-use (llm:response-stop-reason r)))
    (is (string= "tc_1" (llm:part-id call)))
    (is (string= "get-weather" (llm:part-name call)))
    (is (string= "Oakland" (gethash "city" (llm:part-arguments call))))))

(test openai-decode-finish-reason-length
  (let* ((p (test-openai-provider))
         (r (llm:decode-response
             p (json:parse "{\"choices\":[{\"finish_reason\":\"length\",
                              \"message\":{\"content\":\"x\"}}]}"))))
    (is (eq :max-tokens (llm:response-stop-reason r)))))

(test openai-chat-request-end-to-end
  (with-fake-driver (d (:status 200 :body (openai-response-fixture)))
    (let ((p (test-openai-provider))
          (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
      (is (string= "Hello" (llm:response-text (llm:chat-request p c))))
      (is (string= "http://localhost:11434/v1/chat/completions"
                   (getf (last-request d) :url))))))

(test openai-streaming
  (with-fake-driver
      (d (:status 200
          :body (format nil "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}~%~%~
                             data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}~%~%~
                             data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}~%~%~
                             data: [DONE]~%~%")))
    (let ((llm:*provider* (test-openai-provider)))
      (llm:with-streamed-response (r "hi")
        (is (string= "Hel" (llm:next-delta r)))
        (is (string= "lo" (llm:next-delta r)))
        (is (null (llm:next-delta r)))))))

(test openai-stream-done-sentinel-terminates
  (let* ((p (test-openai-provider))
         (event (sse:make-sse-event nil "[DONE]")))
    (is (eq :done (llm:parse-stream-event p event)))))

(test openai-tool-loop-end-to-end
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." (format nil "echo:~a" text)))
    (with-fake-driver
        (d (:status 200
            :body "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"tool_calls\":[
                     {\"id\":\"tc_1\",\"type\":\"function\",\"function\":{\"name\":\"tool-echo\",
                      \"arguments\":\"{\\\"text\\\":\\\"hi\\\"}\"}}]}}]}")
           (:status 200 :body (openai-response-fixture)))
      (let ((llm:*provider* (test-openai-provider)))
        (is (string= "Hello" (llm:ask "go" :tools '(tool-echo))))
        (let ((body (last-request-body d)))
          (is (string= "tool" (json:jget body "messages" 2 "role")))
          (is (string= "echo:hi" (json:jget body "messages" 2 "content"))))))))
