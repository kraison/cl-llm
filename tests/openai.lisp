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
  "Regression: a plain-string user message still encodes to exactly one user
message with string content."
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (= 1 (length (json:jget body "messages"))))
    (is (string= "user" (json:jget body "messages" 0 "role")))
    (is (string= "hi" (json:jget body "messages" 0 "content"))
        "OpenAI content is a string, not a parts array")))

(test openai-encode-omits-max-tokens-when-unset
  "Unlike Anthropic, max_tokens is optional here and must be omitted."
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (null (nth-value 1 (gethash "max_tokens" body))))))

(test openai-encode-omits-optional-parameters-when-unset
  "temperature, top_p, stop, tools, and stream must be genuinely absent keys
(not present-with-value-null) when the caller never set them -- mirrors the
existing max_tokens absence coverage, extended to the rest of the optional
fields."
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (null (nth-value 1 (gethash "temperature" body))))
    (is (null (nth-value 1 (gethash "top_p" body))))
    (is (null (nth-value 1 (gethash "stop" body))))
    (is (null (nth-value 1 (gethash "tools" body))))
    (is (null (nth-value 1 (gethash "stream" body))))))

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
  "Regression: a single tool-result part still encodes to exactly one tool
message."
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation
             :messages (list (llm:make-message
                              :user (list (llm:make-tool-result-part "tc_1" "22C"))))))
         (body (json:parse (llm:encode-request p c))))
    (is (= 1 (length (json:jget body "messages"))))
    (is (string= "tool" (json:jget body "messages" 0 "role")))
    (is (string= "tc_1" (json:jget body "messages" 0 "tool_call_id")))
    (is (string= "22C" (json:jget body "messages" 0 "content")))))

(test openai-encode-multiple-tool-results-become-separate-tool-messages
  "Anthropic bundles every tool result for a turn into ONE message with
multiple content parts; OpenAI requires ONE role:\"tool\" message PER
tool_call_id. A single Lisp message carrying two tool-result parts -- exactly
what RUN-TOOL-LOOP produces after a parallel tool-call turn -- must therefore
encode to TWO JSON messages, in order, each with its own tool_call_id and
content."
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation
             :messages (list (llm:make-message
                              :user (list (llm:make-tool-result-part "tc_1" "result-one")
                                          (llm:make-tool-result-part "tc_2" "result-two"))))))
         (body (json:parse (llm:encode-request p c))))
    (is (= 2 (length (json:jget body "messages")))
        "both tool results must survive encoding, not just the first")
    (is (string= "tool" (json:jget body "messages" 0 "role")))
    (is (string= "tc_1" (json:jget body "messages" 0 "tool_call_id")))
    (is (string= "result-one" (json:jget body "messages" 0 "content")))
    (is (string= "tool" (json:jget body "messages" 1 "role")))
    (is (string= "tc_2" (json:jget body "messages" 1 "tool_call_id")))
    (is (string= "result-two" (json:jget body "messages" 1 "content")))))

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

(test ask-openai-omits-max-tokens-by-default
  "CT-1: ASK's :max-tokens keyword defaults to *max-tokens*, which is now NIL,
so COLLECT-PARAMETERS omits :max-tokens entirely and the OpenAI-compatible
encoder must send NO max_tokens key at all -- not max_tokens: 4096, which
silently caps local-model output and sends a field the provider means to
omit."
  (with-fake-driver (d (:status 200 :body (openai-response-fixture)))
    (let ((llm:*provider* (test-openai-provider)))
      (llm:ask "hi")
      (is (null (nth-value 1 (gethash "max_tokens" (last-request-body d))))
          "max_tokens must be genuinely absent, not present as 4096"))))

(test ask-openai-max-tokens-explicit-keyword-wins
  (with-fake-driver (d (:status 200 :body (openai-response-fixture)))
    (let ((llm:*provider* (test-openai-provider)))
      (llm:ask "hi" :max-tokens 500)
      (is (= 500 (json:jget (last-request-body d) "max_tokens"))))))

(test ask-openai-max-tokens-special-variable-wins
  (with-fake-driver (d (:status 200 :body (openai-response-fixture)))
    (let ((llm:*provider* (test-openai-provider))
          (llm:*max-tokens* 1000))
      (llm:ask "hi")
      (is (= 1000 (json:jget (last-request-body d) "max_tokens"))))))

(test ask-streamed-openai-omits-max-tokens-by-default
  "Streamed ASK (WITH-STREAMED-RESPONSE / OPEN-STREAMED-RESPONSE) must show
the same absence as non-streaming ASK: *max-tokens* defaults to NIL, so the
OpenAI-compatible encoder omits max_tokens on the streamed request body too."
  (with-fake-driver
      (d (:status 200
          :body (format nil "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}~%~%~
                             data: [DONE]~%~%")))
    (let ((llm:*provider* (test-openai-provider)))
      (llm:with-streamed-response (r "hi")
        (llm:do-deltas (delta r) (declare (ignore delta))))
      (is (null (nth-value 1 (gethash "max_tokens" (last-request-body d))))
          "streamed request body must omit max_tokens, not send 4096"))))

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

(test openai-tool-loop-sends-all-parallel-tool-results-as-separate-messages
  "End-to-end mirror of TOOL-LOOP-HANDLES-MULTIPLE-TOOL-CALLS-IN-ONE-RESPONSE
(tests/tool-loop.lisp) for the openai-compatible path: when the model
requests two tool calls in one turn, RUN-TOOL-LOOP batches both results into
ONE Lisp message, and the follow-up request must carry BOTH as separate
role:\"tool\" JSON messages -- not just the first."
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." (format nil "echo:~a" text)))
    (with-fake-driver
        (d (:status 200
            :body "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"tool_calls\":[
                     {\"id\":\"tc_1\",\"type\":\"function\",\"function\":{\"name\":\"tool-echo\",
                      \"arguments\":\"{\\\"text\\\":\\\"a\\\"}\"}},
                     {\"id\":\"tc_2\",\"type\":\"function\",\"function\":{\"name\":\"tool-echo\",
                      \"arguments\":\"{\\\"text\\\":\\\"b\\\"}\"}}]}}]}")
           (:status 200 :body (openai-response-fixture)))
      (let ((llm:*provider* (test-openai-provider)))
        (is (string= "Hello" (llm:ask "go" :tools '(tool-echo))))
        (let ((body (last-request-body d)))
          (is (= 4 (length (json:jget body "messages")))
              "user, assistant(tool_calls), tool(tc_1), tool(tc_2)")
          (is (string= "tool" (json:jget body "messages" 2 "role")))
          (is (string= "tc_1" (json:jget body "messages" 2 "tool_call_id")))
          (is (string= "echo:a" (json:jget body "messages" 2 "content")))
          (is (string= "tool" (json:jget body "messages" 3 "role")))
          (is (string= "tc_2" (json:jget body "messages" 3 "tool_call_id")))
          (is (string= "echo:b" (json:jget body "messages" 3 "content"))))))))

(test openai-parse-stream-event-bundled-content-and-finish-reason-keeps-stop-reason
  "A single SSE chunk carrying both non-empty content AND a finish_reason must
not silently lose the stop reason. Real OpenAI-compatible servers (llama.cpp,
Ollama, vLLM, LM Studio) send finish_reason on its own chunk with an empty
delta, matching OpenAI's own chunking, so this is a robustness case rather
than an observed one -- but the wire format does not guarantee it, so
PARSE-STREAM-EVENT must not silently drop the stop reason if it happens."
  (let* ((p (test-openai-provider))
         (event (sse:make-sse-event
                 nil "{\"choices\":[{\"delta\":{\"content\":\"final\"},
                          \"finish_reason\":\"stop\"}]}")))
    (multiple-value-bind (kind value) (llm:parse-stream-event p event)
      (is (eq :stop-reason kind))
      (is (eq :end-turn value)))))

(test openai-streaming-bundled-chunk-end-to-end-preserves-stop-reason
  "End-to-end: a stream whose only content chunk also carries finish_reason
must still leave RESPONSE-STOP-REASON set to :END-TURN after FINISH-RESPONSE,
not NIL."
  (with-fake-driver
      (d (:status 200
          :body (format nil "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},~
                                     \"finish_reason\":\"stop\"}]}~%~%~
                             data: [DONE]~%~%")))
    (let ((llm:*provider* (test-openai-provider)))
      (llm:with-streamed-response (r "hi")
        (is (eq :end-turn (llm:response-stop-reason (llm:finish-response r))))))))
