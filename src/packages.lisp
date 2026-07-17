;;;; packages.lisp -- package definitions for cl-llm

(defpackage #:cl-llm.conditions
  (:use #:cl)
  (:export #:llm-error
           #:llm-http-error
           #:llm-api-error
           #:llm-rate-limit-error
           #:llm-auth-error
           #:llm-timeout-error
           #:llm-parse-error
           #:llm-tool-error
           #:llm-error-status
           #:llm-error-body
           #:llm-error-url
           #:llm-error-code
           #:llm-error-type
           #:llm-error-message
           #:llm-error-retry-after
           #:llm-error-payload
           #:llm-error-tool-name
           #:llm-error-underlying))

(defpackage #:cl-llm.json
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:parse
           #:to-json
           #:jget
           #:jobject
           #:jarray
           #:jvalue))

(defpackage #:cl-llm.sse
  (:use #:cl)
  (:export #:sse-event
           #:sse-event-p
           #:make-sse-event
           #:sse-event-type
           #:sse-event-data
           #:read-event))

(defpackage #:cl-llm.http
  (:use #:cl)
  (:local-nicknames (#:c #:cl-llm.conditions))
  (:export #:driver
           #:dexador-driver
           #:*driver*
           #:perform-request
           #:perform-stream-request))

(defpackage #:cl-llm
  (:use #:cl)
  (:local-nicknames (#:json #:cl-llm.json)
                    (#:http #:cl-llm.http)
                    (#:sse #:cl-llm.sse)
                    (#:c #:cl-llm.conditions))
  (:import-from #:cl-llm.conditions
                #:llm-error #:llm-http-error #:llm-api-error #:llm-rate-limit-error
                #:llm-auth-error #:llm-timeout-error #:llm-parse-error #:llm-tool-error
                #:llm-error-status #:llm-error-body #:llm-error-url #:llm-error-code
                #:llm-error-type #:llm-error-message #:llm-error-retry-after
                #:llm-error-payload #:llm-error-tool-name #:llm-error-underlying)
  (:export
   ;; conditions (genuinely re-exported from cl-llm.conditions via :import-from
   ;; above -- these ARE the cl-llm.conditions symbols, not distinct ones)
   #:llm-error #:llm-http-error #:llm-api-error #:llm-rate-limit-error
   #:llm-auth-error #:llm-timeout-error #:llm-parse-error #:llm-tool-error
   #:llm-error-status #:llm-error-body #:llm-error-url #:llm-error-code
   #:llm-error-type #:llm-error-message #:llm-error-retry-after
   #:llm-error-payload #:llm-error-tool-name #:llm-error-underlying
   #:*retries*
   #:*timeout*
   #:*max-tokens*
   ;; content parts
   #:content-part #:text-part #:tool-use-part #:tool-result-part
   #:part-text #:part-id #:part-name #:part-arguments
   #:part-tool-use-id #:part-content #:part-error-p
   #:make-text-part #:make-tool-use-part #:make-tool-result-part
   ;; messages and conversations
   #:message #:make-message #:message-role #:message-content
   #:conversation #:make-conversation #:add-message
   #:conversation-messages #:conversation-system #:conversation-provider
   #:conversation-model #:conversation-parameters
   ;; responses
   #:response #:response-content #:response-stop-reason #:response-model
   #:response-usage #:response-raw #:response-text #:response-tool-calls
   #:response-message
   #:usage #:usage-input-tokens #:usage-output-tokens
   ;; providers and protocol
   #:provider #:anthropic-provider #:openai-compatible-provider
   #:provider-model #:provider-default-model #:provider-endpoint
   #:provider-headers #:provider-api-key #:provider-base-url
   #:encode-request #:decode-response #:parse-stream-event
   #:chat-request #:stream-request
   ;; tools
   #:tool #:deftool #:find-tool #:register-tool #:unregister-tool
   #:tool-name #:tool-description #:tool-schema #:tool-function
   #:encode-tool #:call-tool
   ;; facade
   #:ask #:send
   #:*provider* #:*model* #:*temperature* #:*top-p* #:*stop*
   #:*system* #:*tools* #:*max-tool-turns*
   ;; streaming
   #:streamed-response #:streamed-response-open-p
   #:open-streamed-response #:close-streamed-response
   #:next-event #:next-delta #:finish-response
   #:with-streamed-response #:do-deltas))
