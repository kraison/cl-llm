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
           #:jarray))

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
           #:perform-stream-request
           #:normalize-response-headers))

(defpackage #:cl-llm
  (:use #:cl)
  (:local-nicknames (#:json #:cl-llm.json)
                    (#:http #:cl-llm.http)
                    (#:sse #:cl-llm.sse)
                    (#:c #:cl-llm.conditions))
  (:export
   ;; conditions (re-exported from cl-llm.conditions)
   #:llm-error #:llm-http-error #:llm-api-error #:llm-rate-limit-error
   #:llm-auth-error #:llm-timeout-error #:llm-parse-error #:llm-tool-error
   #:llm-error-status #:llm-error-body #:llm-error-url #:llm-error-code
   #:llm-error-type #:llm-error-message #:llm-error-retry-after
   #:llm-error-payload #:llm-error-tool-name #:llm-error-underlying))
