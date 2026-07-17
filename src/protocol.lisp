;;;; protocol.lisp -- provider classes and the generic functions each backend
;;;; must implement.

(in-package #:cl-llm)

(defvar *getenv-function* (lambda (name) (uiop:getenv name))
  "Indirection over the environment so tests need not mutate the real one.")

(defclass provider ()
  ((model :initarg :model :initform nil :reader provider-model
          :documentation "Model to use, or NIL to defer to PROVIDER-DEFAULT-MODEL.")
   (api-key :initarg :api-key :initform nil :reader provider-api-key-slot)
   (base-url :initarg :base-url :reader provider-base-url))
  (:documentation "Abstract base for an LLM backend."))

(defgeneric provider-default-model (provider)
  (:documentation "The model to use when none was specified."))

(defgeneric provider-endpoint (provider &key stream)
  (:documentation "The full URL to POST to."))

(defgeneric provider-headers (provider)
  (:documentation "Request headers as an alist. Never log the result: it
contains credentials."))

(defgeneric provider-api-key (provider)
  (:documentation "Resolve the API key from the initarg, then the environment.
Signals LLM-AUTH-ERROR if one is required and absent."))

(defgeneric encode-request (provider conversation &key stream tools)
  (:documentation "Encode CONVERSATION as a JSON request body string."))

(defgeneric decode-response (provider payload)
  (:documentation "Decode a parsed JSON PAYLOAD into a RESPONSE."))

(defgeneric parse-stream-event (provider event)
  (:documentation "Interpret one SSE-EVENT. Returns (values KIND VALUE) where
KIND is one of :TEXT (VALUE is a string delta), :TOOL-USE-START (VALUE is a
TOOL-USE-PART), :TOOL-ARGUMENTS (VALUE is a partial JSON string), :STOP-REASON
(VALUE is a keyword), :USAGE (VALUE is a USAGE), :DONE, or :IGNORE."))

(defgeneric chat-request (provider conversation &key tools)
  (:documentation "Perform a non-streaming request and return a RESPONSE."))

(defgeneric stream-request (provider conversation &key tools)
  (:documentation "Perform a streaming request and return an open character
stream of SSE data. The caller owns the stream and must close it."))

(defgeneric encode-tool (provider tool)
  (:documentation "Encode TOOL as provider-specific JSON."))

(defgeneric model-for (provider conversation)
  (:documentation "The model to use for CONVERSATION on PROVIDER."))

(defmethod model-for ((provider provider) conversation)
  (or (and conversation (conversation-model conversation))
      (provider-model provider)
      (provider-default-model provider)))

;;; Anthropic

(defclass anthropic-provider (provider)
  ((base-url :initarg :base-url :initform "https://api.anthropic.com"
             :reader provider-base-url)
   (api-version :initarg :api-version :initform "2023-06-01"
                :reader provider-api-version))
  (:documentation "The Anthropic Messages API."))

(defmethod provider-default-model ((provider anthropic-provider))
  "claude-opus-4-8")

(defmethod provider-endpoint ((provider anthropic-provider) &key stream)
  (declare (ignore stream))
  (concatenate 'string (provider-base-url provider) "/v1/messages"))

(defmethod provider-api-key ((provider anthropic-provider))
  (or (provider-api-key-slot provider)
      (funcall *getenv-function* "ANTHROPIC_API_KEY")
      (error 'c:llm-auth-error
             :status nil
             :message "No Anthropic API key. Pass :api-key or set ANTHROPIC_API_KEY.")))

(defmethod provider-headers ((provider anthropic-provider))
  (list (cons "content-type" "application/json")
        (cons "x-api-key" (provider-api-key provider))
        (cons "anthropic-version" (provider-api-version provider))))

;;; OpenAI-compatible (llama.cpp, Ollama, vLLM, LM Studio)

(defclass openai-compatible-provider (provider)
  ((base-url :initarg :base-url :reader provider-base-url
             :initform (error "openai-compatible-provider requires :base-url, ~
                               e.g. \"http://localhost:11434/v1\".")))
  (:documentation "Any endpoint speaking the OpenAI chat-completions API."))

(defmethod provider-default-model ((provider openai-compatible-provider))
  (or (provider-model provider)
      (error 'c:llm-api-error
             :message "openai-compatible-provider has no model; pass :model.")))

(defmethod provider-endpoint ((provider openai-compatible-provider) &key stream)
  (declare (ignore stream))
  (concatenate 'string (provider-base-url provider) "/chat/completions"))

(defmethod provider-api-key ((provider openai-compatible-provider))
  "Optional: local servers accept any key or none."
  (or (provider-api-key-slot provider)
      (funcall *getenv-function* "OPENAI_API_KEY")))

(defmethod provider-headers ((provider openai-compatible-provider))
  (let ((key (provider-api-key provider)))
    (append (list (cons "content-type" "application/json"))
            (when key
              (list (cons "authorization" (concatenate 'string "Bearer " key)))))))
