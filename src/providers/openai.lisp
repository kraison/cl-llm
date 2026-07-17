;;;; openai.lisp -- OpenAI-compatible chat completions.
;;;;
;;;; Targets llama.cpp, Ollama, vLLM, and LM Studio. The shape differs from
;;;; Anthropic in ways worth naming: the system prompt is a message rather than
;;;; a field, content is a plain string rather than a parts array, tool
;;;; arguments arrive as a JSON *string* needing a second parse, and the stream
;;;; terminates with a literal [DONE] sentinel rather than a typed event.
;;;;
;;;; LIMITATION: streamed tool calls are not assembled. PARSE-STREAM-EVENT
;;;; below decodes far enough to terminate the stream cleanly and to pass
;;;; text deltas through, but a tool_calls delta in a streaming response is
;;;; silently ignored rather than accumulated into a TOOL-USE-PART. The
;;;; supported path for tool use on OpenAI-compatible endpoints is
;;;; non-streaming CHAT-REQUEST.

(in-package #:cl-llm)

;;; Encoding

(defun openai-encode-message (message)
  "Encode one message. Tool results become role \"tool\" messages, which is why
this cannot simply map over parts."
  (let ((parts (message-content message)))
    (let ((tool-result (find-if (lambda (p) (typep p 'tool-result-part)) parts)))
      (if tool-result
          (json:jobject :role "tool"
                        :tool_call_id (part-tool-use-id tool-result)
                        :content (princ-to-string (part-content tool-result)))
          (let ((tool-uses (remove-if-not (lambda (p) (typep p 'tool-use-part)) parts))
                (text (with-output-to-string (out)
                        (dolist (part parts)
                          (when (typep part 'text-part)
                            (write-string (part-text part) out))))))
            (json:jobject
             :role (string-downcase (symbol-name (message-role message)))
             :content (if (string= text "") nil text)
             :tool_calls (when tool-uses
                           (map 'vector
                                (lambda (part)
                                  (json:jobject
                                   :id (part-id part)
                                   :type "function"
                                   :function (json:jobject
                                              :name (part-name part)
                                              :arguments (json:to-json
                                                          (or (part-arguments part)
                                                              (json:jobject))))))
                                tool-uses))))))))

(defmethod encode-request ((provider openai-compatible-provider) conversation
                           &key stream tools)
  (let* ((parameters (conversation-parameters conversation))
         (system (conversation-system conversation))
         (messages (map 'list #'openai-encode-message
                        (conversation-messages conversation))))
    (json:to-json
     (json:jobject
      :model (model-for provider conversation)
      :messages (coerce (if system
                            (cons (json:jobject :role "system" :content system)
                                  messages)
                            messages)
                        'vector)
      ;; Optional here, unlike Anthropic: omit when unset.
      :max_tokens (getf parameters :max-tokens)
      :temperature (getf parameters :temperature)
      :top_p (getf parameters :top-p)
      :stop (when (getf parameters :stop)
              (coerce (getf parameters :stop) 'vector))
      :tools (when tools
               (map 'vector (lambda (tool) (encode-tool provider tool)) tools))
      :stream (when stream :true)))))

(defmethod encode-tool ((provider openai-compatible-provider) tool)
  (json:jobject :type "function"
                :function (json:jobject :name (tool-name tool)
                                        :description (tool-description tool)
                                        :parameters (tool-schema tool))))

;;; Decoding

(defun openai-stop-reason (string)
  (cond ((null string) nil)
        ((string= string "stop") :end-turn)
        ((string= string "length") :max-tokens)
        ((string= string "tool_calls") :tool-use)
        (t nil)))

(defun openai-decode-tool-call (payload)
  "Decode one tool_call. ARGUMENTS is a JSON string requiring a second parse."
  (let ((arguments (json:jget payload "function" "arguments")))
    (make-tool-use-part
     (json:jget payload "id")
     (json:jget payload "function" "name")
     (if (and arguments (stringp arguments) (string/= arguments ""))
         (handler-case (json:parse arguments)
           (error ()
             (error 'c:llm-parse-error :payload arguments
                    :message "Could not parse tool_call arguments as JSON")))
         (json:jobject)))))

(defmethod decode-response ((provider openai-compatible-provider) payload)
  (let* ((choice (json:jget payload "choices" 0))
         (message (json:jget choice "message"))
         (content (json:jget message "content"))
         (tool-calls (json:jget message "tool_calls"))
         (usage (json:jget payload "usage")))
    (make-instance
     'response
     :content (append
               (when (and content (string/= content ""))
                 (list (make-text-part content)))
               (when tool-calls
                 (map 'list #'openai-decode-tool-call tool-calls)))
     :stop-reason (openai-stop-reason (json:jget choice "finish_reason"))
     :model (json:jget payload "model")
     :usage (when usage
              (make-instance 'usage
                             :input-tokens (json:jget usage "prompt_tokens")
                             :output-tokens (json:jget usage "completion_tokens")))
     :raw payload)))

;;; Requesting

(defmethod chat-request ((provider openai-compatible-provider) conversation &key tools)
  (let ((url (provider-endpoint provider)))
    (multiple-value-bind (body status)
        (request-with-retry url
                            :method :post
                            :headers (provider-headers provider)
                            :content (encode-request provider conversation :tools tools))
      (declare (ignore status))
      (decode-response provider (parse-body-or-signal body url)))))

(defmethod stream-request ((provider openai-compatible-provider) conversation &key tools)
  (request-with-retry (provider-endpoint provider)
                      :method :post
                      :headers (provider-headers provider)
                      :content (encode-request provider conversation
                                               :stream t :tools tools)
                      :stream t))

(defmethod parse-stream-event ((provider openai-compatible-provider) event)
  (let ((data (sse:sse-event-data event)))
    ;; The terminator is a literal sentinel, not a typed event.
    (if (string= data "[DONE]")
        (values :done nil)
        (let* ((payload (handler-case (json:parse data)
                          (error ()
                            (error 'c:llm-parse-error :payload data
                                   :message "Malformed SSE data from the OpenAI-compatible endpoint"))))
               (choice (json:jget payload "choices" 0))
               (delta (json:jget choice "delta"))
               (content (json:jget delta "content"))
               (finish (json:jget choice "finish_reason")))
          (cond
            ((and content (string/= content "")) (values :text content))
            (finish (values :stop-reason (openai-stop-reason finish)))
            (t (values :ignore nil)))))))
