;;;; conditions.lisp -- the cl-llm condition hierarchy.
;;;;
;;;; Reports must never include request headers: that is where API keys live.

(in-package #:cl-llm.conditions)

(define-condition llm-error (error)
  ()
  (:documentation "Base class for every error signalled by cl-llm."))

(define-condition llm-http-error (llm-error)
  ((status :initarg :status :initform nil :reader llm-error-status)
   (body :initarg :body :initform nil :reader llm-error-body)
   (url :initarg :url :initform nil :reader llm-error-url))
  (:report (lambda (condition stream)
             (format stream "LLM HTTP error~@[ ~a~]~@[ from ~a~]~@[: ~a~]"
                     (llm-error-status condition)
                     (llm-error-url condition)
                     (llm-error-body condition))))
  (:documentation "A transport or status failure. BODY is the raw response."))

(define-condition llm-api-error (llm-http-error)
  ((code :initarg :code :initform nil :reader llm-error-code)
   (error-type :initarg :error-type :initform nil :reader llm-error-type)
   (message :initarg :message :initform nil :reader llm-error-message))
  (:report (lambda (condition stream)
             (format stream "LLM API error~@[ ~a~]~@[ (~a)~]~@[ from ~a~]~@[: ~a~]"
                     (llm-error-status condition)
                     (llm-error-type condition)
                     (llm-error-url condition)
                     (llm-error-message condition))))
  (:documentation "A structured provider-level error, decoded from the body."))

(define-condition llm-rate-limit-error (llm-api-error)
  ((retry-after :initarg :retry-after :initform nil :reader llm-error-retry-after))
  (:documentation "HTTP 429. RETRY-AFTER is seconds, from the header, or NIL."))

(define-condition llm-auth-error (llm-api-error)
  ()
  (:documentation "HTTP 401/403 -- missing or invalid credentials."))

(define-condition llm-timeout-error (llm-error)
  ((url :initarg :url :initform nil :reader llm-error-url))
  (:report (lambda (condition stream)
             (format stream "LLM request timed out~@[ for ~a~]"
                     (llm-error-url condition))))
  (:documentation "The request exceeded the timeout."))

(define-condition llm-parse-error (llm-error)
  ((payload :initarg :payload :initform nil :reader llm-error-payload)
   (message :initarg :message :initform nil :reader llm-error-message))
  (:report (lambda (condition stream)
             (format stream "LLM parse error~@[: ~a~]~@[ in ~s~]"
                     (llm-error-message condition)
                     (llm-error-payload condition))))
  (:documentation "A malformed response body or SSE payload."))

(define-condition llm-tool-error (llm-error)
  ((tool-name :initarg :tool-name :initform nil :reader llm-error-tool-name)
   (underlying :initarg :underlying :initform nil :reader llm-error-underlying))
  (:report (lambda (condition stream)
             (format stream "~:[A tool~;Tool ~:*~a~] signalled an error~@[: ~a~]"
                     (llm-error-tool-name condition)
                     (llm-error-underlying condition))))
  (:documentation "A tool function signalled during the tool loop."))
