;;;; testing-with-mock.lisp -- test your own cl-llm code with no network.
;;;;
;;;; MOCK-PROVIDER is a real provider that returns scripted responses instead of
;;;; making HTTP requests. Bind CL-LLM:*PROVIDER* to one and your ASK/SEND/tool
;;;; code runs deterministically, offline, with no API key -- ideal for unit
;;;; tests of application logic that sits on top of cl-llm.
;;;;
;;;; This example needs NO network and NO key. Load it, then:
;;;;   (examples/testing-with-mock:run)

(ql:quickload :cl-llm)

(defpackage #:examples/testing-with-mock
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run))

(in-package #:examples/testing-with-mock)

(defun run ()
  ;; 1. A fixed reply: the responder is a function of the outgoing conversation.
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "a scripted answer"))))
    (format t "~&--- fixed reply ---~%~a~%" (llm:ask "anything")))
  ;; => a scripted answer

  ;; 2. A reply that depends on the input. The responder sees the whole
  ;;    conversation, so you can script realistic behavior.
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (let ((prompt (llm:part-text
                                       (first (llm:message-content
                                               (car (last (llm:conversation-messages
                                                           conversation))))))))
                          (if (search "capital" prompt) "Paris" "I don't know"))))))
    (format t "~&--- input-dependent ---~%~a / ~a~%"
            (llm:ask "What is the capital of France?")
            (llm:ask "What is the meaning of life?")))
  ;; => Paris / I don't know

  ;; 3. Script a full RESPONSE (not just text) to exercise stop reasons, usage,
  ;;    or tool calls in your tests.
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (make-instance 'llm:response
                                       :content (list (llm:make-text-part "capped"))
                                       :stop-reason :max-tokens)))))
    (multiple-value-bind (text response) (llm:ask "x")
      (format t "~&--- scripted response object ---~%text=~s stop=~s~%"
              text (llm:response-stop-reason response))))
  ;; => text="capped" stop=:MAX-TOKENS

  ;; 4. Simulate a failure: a responder may signal, so you can test your error
  ;;    handling without waiting for a real 500.
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (error 'llm:llm-api-error :status 500 :message "simulated outage")))))
    (format t "~&--- simulated failure ---~%~a~%"
            (handler-case (llm:ask "x")
              (llm:llm-error (e) (format nil "caught ~a: ~a" (type-of e) e)))))
  ;; => caught LLM-API-ERROR: ...

  (values))

;; (examples/testing-with-mock:run)
