;;;; tests/mock.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test mock-provider-chat-request-wraps-a-string
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "scripted reply"))))
    (multiple-value-bind (text response) (llm:ask "anything")
      (is (string= "scripted reply" text))
      (is (typep response 'llm:response))
      (is (eq :end-turn (llm:response-stop-reason response))))))

(test mock-provider-responder-sees-the-conversation
  (let* ((seen nil)
         (llm:*provider*
           (llm:make-mock-provider
            :responder (lambda (conversation)
                         (setf seen conversation)
                         "ok"))))
    (llm:ask "the prompt text")
    (is (typep seen 'llm:conversation))
    (is (string= "the prompt text"
                 (llm:part-text
                  (first (llm:message-content
                          (first (llm:conversation-messages seen)))))))))

(test mock-provider-responder-can-return-a-full-response
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (make-instance 'llm:response
                                       :content (list (llm:make-text-part "built"))
                                       :stop-reason :max-tokens)))))
    (multiple-value-bind (text response) (llm:ask "x")
      (is (string= "built" text))
      (is (eq :max-tokens (llm:response-stop-reason response))))))

(test mock-provider-responder-can-signal
  "A responder may signal to simulate an API failure; the signal propagates."
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (error 'llm:llm-api-error :status 500 :message "boom")))))
    (signals llm:llm-api-error (llm:ask "x"))))

(test mock-provider-streaming-yields-the-text
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "streamed hello"))))
    (llm:with-streamed-response (r "hi")
      (let ((collected '()))
        (llm:do-deltas (d r) (push d collected))
        (is (string= "streamed hello"
                     (apply #'concatenate 'string (nreverse collected))))))))
