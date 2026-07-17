;;;; anthropic.lisp -- the Anthropic Messages API.

(in-package #:cl-llm)

(defvar *max-tokens* nil
  "Max-tokens override. NIL means let the provider decide, mirroring how
*MODEL* defaults to NIL so PROVIDER-DEFAULT-MODEL decides. Anthropic still
requires max_tokens on every request, but that requirement is Anthropic's
alone -- ENCODE-REQUEST below falls back to a literal 4096 when neither an
explicit :max-tokens parameter nor this special is set, so the required
default lives with the provider that needs it instead of leaking into every
other provider (notably the OpenAI-compatible one, where max_tokens is
optional and must be omitted when unset).")

;;; Encoding

(defgeneric encode-part (provider part)
  (:documentation "Encode one content part as a JSON object."))

(defmethod encode-part ((provider anthropic-provider) (part text-part))
  (json:jobject :type "text" :text (part-text part)))

(defmethod encode-part ((provider anthropic-provider) (part tool-use-part))
  (json:jobject :type "tool_use"
                :id (part-id part)
                :name (part-name part)
                :input (or (part-arguments part) (json:jobject))))

(defmethod encode-part ((provider anthropic-provider) (part tool-result-part))
  (json:jobject :type "tool_result"
                :tool_use_id (part-tool-use-id part)
                :content (part-content part)
                :is_error (if (part-error-p part) :true nil)))

(defun encode-message (provider message)
  (json:jobject :role (string-downcase (symbol-name (message-role message)))
                :content (map 'vector
                              (lambda (part) (encode-part provider part))
                              (message-content message))))

(defmethod encode-request ((provider anthropic-provider) conversation
                           &key stream tools)
  (let ((parameters (conversation-parameters conversation)))
    (json:to-json
     (json:jobject
      :model (model-for provider conversation)
      :max_tokens (or (getf parameters :max-tokens) *max-tokens* 4096)
      :messages (map 'vector
                     (lambda (message) (encode-message provider message))
                     (conversation-messages conversation))
      :system (conversation-system conversation)
      :temperature (getf parameters :temperature)
      :top_p (getf parameters :top-p)
      :stop_sequences (when (getf parameters :stop)
                        (coerce (getf parameters :stop) 'vector))
      :tools (when tools
               (map 'vector (lambda (tool) (encode-tool provider tool)) tools))
      ;; Omitted entirely when false: jzon would emit "stream":false for NIL.
      :stream (when stream :true)))))

;;; Decoding

(defun anthropic-stop-reason (string)
  (cond ((null string) nil)
        ((string= string "end_turn") :end-turn)
        ((string= string "tool_use") :tool-use)
        ((string= string "max_tokens") :max-tokens)
        ((string= string "stop_sequence") :stop)
        (t nil)))

(defun decode-part (payload)
  (let ((type (json:jget payload "type")))
    (cond
      ((equal type "text")
       (make-text-part (or (json:jget payload "text") "")))
      ((equal type "tool_use")
       (make-tool-use-part (json:jget payload "id")
                           (json:jget payload "name")
                           (json:jget payload "input")))
      (t nil))))

(defun decode-usage (payload)
  (let ((usage (json:jget payload "usage")))
    (when usage
      (make-instance 'usage
                     :input-tokens (json:jget usage "input_tokens")
                     :output-tokens (json:jget usage "output_tokens")))))

(defmethod decode-response ((provider anthropic-provider) payload)
  (make-instance 'response
                 :content (remove nil (map 'list #'decode-part
                                           (or (json:jget payload "content") #())))
                 :stop-reason (anthropic-stop-reason (json:jget payload "stop_reason"))
                 :model (json:jget payload "model")
                 :usage (decode-usage payload)
                 :raw payload))

;;; Requesting

(defun parse-body-or-signal (body url)
  "Parse BODY as JSON, signalling LLM-PARSE-ERROR rather than letting a jzon
condition escape as something the caller cannot handle generically."
  (handler-case (json:parse body)
    (c:llm-error (e) (error e))
    (error ()
      (error 'c:llm-parse-error
             :payload (if (> (length body) 200) (subseq body 0 200) body)
             :message (format nil "Could not parse the response from ~a as JSON" url)))))

(defmethod encode-tool ((provider anthropic-provider) tool)
  (json:jobject :name (tool-name tool)
                :description (tool-description tool)
                :input_schema (tool-schema tool)))

(defmethod chat-request ((provider anthropic-provider) conversation &key tools)
  (let ((url (provider-endpoint provider)))
    (multiple-value-bind (body status)
        (request-with-retry url
                            :method :post
                            :headers (provider-headers provider)
                            :content (encode-request provider conversation
                                                     :tools tools))
      (declare (ignore status))
      (decode-response provider (parse-body-or-signal body url)))))

;;; Streaming

(defmethod parse-stream-event ((provider anthropic-provider) event)
  (let* ((data (sse:sse-event-data event))
         (payload (handler-case (json:parse data)
                    (error ()
                      (error 'c:llm-parse-error :payload data
                             :message "Malformed SSE data from Anthropic"))))
         (type (json:jget payload "type")))
    (cond
      ((equal type "content_block_delta")
       (let ((delta-type (json:jget payload "delta" "type")))
         (cond
           ((equal delta-type "text_delta")
            (values :text (json:jget payload "delta" "text")))
           ((equal delta-type "input_json_delta")
            (values :tool-arguments (json:jget payload "delta" "partial_json")))
           (t (values :ignore nil)))))
      ((equal type "content_block_start")
       (let ((block (json:jget payload "content_block")))
         (if (equal (json:jget block "type") "tool_use")
             (values :tool-use-start
                     (make-tool-use-part (json:jget block "id")
                                         (json:jget block "name")
                                         nil))
             (values :ignore nil))))
      ((equal type "message_start")
       (values :usage (decode-usage (json:jget payload "message"))))
      ((equal type "message_delta")
       ;; Anthropic reports output-token usage as a sibling of stop_reason in
       ;; this same event, not on its own event -- hand it back as a third
       ;; value so ACCUMULATE-EVENT can merge it without a separate :USAGE
       ;; event kind.
       (values :stop-reason
               (anthropic-stop-reason (json:jget payload "delta" "stop_reason"))
               (decode-usage payload)))
      ((equal type "message_stop") (values :done nil))
      ((equal type "error")
       (error 'c:llm-api-error
              :message (json:jget payload "error" "message")
              :error-type (json:jget payload "error" "type")))
      (t (values :ignore nil)))))

(defmethod stream-request ((provider anthropic-provider) conversation &key tools)
  (request-with-retry (provider-endpoint provider)
                      :method :post
                      :headers (provider-headers provider)
                      :content (encode-request provider conversation
                                               :stream t :tools tools)
                      :stream t))
