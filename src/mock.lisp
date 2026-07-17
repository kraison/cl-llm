;;;; mock.lisp -- a provider that returns scripted responses with no HTTP.
;;;;
;;;; Placed in the core (not eval) because it makes the whole library testable
;;;; by its users, not only by cl-llm's own suite. The evaluation harness
;;;; consumes it; so can anyone writing tests against cl-llm.

(in-package #:cl-llm)

(defclass mock-provider (provider)
  ((responder :initarg :responder :reader mock-provider-responder
              :documentation "A function of the outgoing CONVERSATION returning
either a string (becomes the assistant text) or a fully-formed RESPONSE."))
  (:documentation "A provider that scripts responses instead of making requests."))

(defun make-mock-provider (&key responder model)
  "Make a mock provider. RESPONDER is (conversation) -> string-or-response.
MODEL is accepted for symmetry with real providers and is otherwise unused."
  (make-instance 'mock-provider :responder responder :model model))

(defun mock-response (result)
  "Normalize a responder RESULT (a string or a RESPONSE) into a RESPONSE."
  (etypecase result
    (response result)
    (string (make-instance 'response
                           :content (list (make-text-part result))
                           :stop-reason :end-turn))))

(defmethod chat-request ((provider mock-provider) conversation &key tools)
  (declare (ignore tools))
  (mock-response (funcall (mock-provider-responder provider) conversation)))

(defmethod stream-request ((provider mock-provider) conversation &key tools)
  (declare (ignore tools))
  ;; Encode the scripted text as a tiny two-event SSE body the mock's own
  ;; PARSE-STREAM-EVENT understands. JSON-encoding the text keeps multi-line
  ;; text from breaking SSE line framing.
  (let* ((response (mock-response
                    (funcall (mock-provider-responder provider) conversation)))
         (text (response-text response)))
    (make-string-input-stream
     (format nil "data: ~a~%~%data: [DONE]~%~%"
             (json:to-json (json:jobject :text text))))))

(defmethod parse-stream-event ((provider mock-provider) event)
  (let ((data (sse:sse-event-data event)))
    (if (string= data "[DONE]")
        (values :done nil)
        (values :text (json:jget (json:parse data) "text")))))
