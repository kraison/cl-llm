;;;; tests/facade.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defmacro with-test-provider (&body body)
  "Bind *provider* to an Anthropic provider with a fixed key."
  `(let ((llm:*provider* (make-instance 'llm:anthropic-provider :api-key "sk-test")))
     ,@body))

(test facade-defaults
  (is (typep llm:*provider* 'llm:anthropic-provider)
      "*provider* must default to an anthropic-provider")
  (is (null llm:*model*) "*model* defaults to NIL so the provider decides")
  (is (= 4096 llm:*max-tokens*))
  (is (= 8 llm:*max-tool-turns*)))

(test ask-returns-text-and-response
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (multiple-value-bind (text response) (llm:ask "hi")
        (is (string= "Hello" text))
        (is (typep response 'llm:response))
        (is (string= "Hello" (llm:response-text response)))))))

(test ask-sends-the-prompt-as-a-user-message
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (llm:ask "what is CLOS?")
      (let ((body (last-request-body d)))
        (is (string= "user" (json:jget body "messages" 0 "role")))
        (is (string= "what is CLOS?" (json:jget body "messages" 0 "content" 0 "text")))))))

(test ask-honors-keyword-arguments
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (llm:ask "hi" :temperature 0.2 :system "be terse" :max-tokens 50)
      (let ((body (last-request-body d)))
        (is (= 0.2d0 (json:jget body "temperature")))
        (is (string= "be terse" (json:jget body "system")))
        (is (= 50 (json:jget body "max_tokens")))))))

(test ask-honors-special-variables
  "The specials and the keywords must be the same API, not two parallel ones."
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((llm:*model* "claude-haiku-4-5-20251001")
            (llm:*temperature* 0.9))
        (llm:ask "hi"))
      (let ((body (last-request-body d)))
        (is (string= "claude-haiku-4-5-20251001" (json:jget body "model")))
        (is (= 0.9d0 (json:jget body "temperature")))))))

(test ask-keyword-overrides-special
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((llm:*temperature* 0.9))
        (llm:ask "hi" :temperature 0.1))
      (is (= 0.1d0 (json:jget (last-request-body d) "temperature"))))))

(test send-appends-both-messages-to-the-conversation
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((c (llm:make-conversation :system "be terse")))
        (llm:send c "hi")
        (is (= 2 (length (llm:conversation-messages c))))
        (is (eq :user (llm:message-role (first (llm:conversation-messages c)))))
        (is (eq :assistant (llm:message-role (second (llm:conversation-messages c)))))
        (is (string= "Hello"
                     (llm:part-text (first (llm:message-content
                                            (second (llm:conversation-messages c)))))))))))

(test send-accumulates-history-across-turns
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture))
                       (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((c (llm:make-conversation)))
        (llm:send c "one")
        (llm:send c "two")
        (is (= 4 (length (llm:conversation-messages c))))
        (let ((body (last-request-body d)))
          (is (= 3 (length (json:jget body "messages")))
              "The second request must carry the prior turns")
          (is (string= "one" (json:jget body "messages" 0 "content" 0 "text")))
          (is (string= "two" (json:jget body "messages" 2 "content" 0 "text"))))))))

(test send-uses-the-conversation-provider-when-set
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (let* ((p (make-instance 'llm:anthropic-provider
                             :api-key "sk-conv" :base-url "http://conv.example"))
           (c (llm:make-conversation :provider p)))
      (llm:send c "hi")
      (is (string= "http://conv.example/v1/messages" (getf (last-request d) :url))))))

(test ask-propagates-errors
  (with-fake-driver (d (:status 401 :body "{\"error\":{\"message\":\"nope\"}}"))
    (with-test-provider
      (signals c:llm-auth-error (llm:ask "hi")))))

(test send-rolls-back-user-message-on-failure-from-empty-conversation
  "A SEND that signals must leave an empty conversation empty, not with a
lone unanswered USER message that would break role alternation on retry."
  (with-fake-driver (d (:status 401 :body "{\"error\":{\"message\":\"nope\"}}"))
    (with-test-provider
      (let ((c (llm:make-conversation)))
        (handler-case (llm:send c "hi")
          (c:llm-auth-error () nil))
        (is (= 0 (length (llm:conversation-messages c)))
            "the failed turn's user message must be rolled back")))))

(test send-rolls-back-user-message-on-failure-preserving-prior-turns
  "The rollback must restore the conversation to its pre-call state exactly
-- prior turns must survive, not just result in an empty list."
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture))
                       (:status 401 :body "{\"error\":{\"message\":\"nope\"}}"))
    (with-test-provider
      (let ((c (llm:make-conversation)))
        (llm:send c "one")
        (is (= 2 (length (llm:conversation-messages c))))
        (let ((before (llm:conversation-messages c)))
          (handler-case (llm:send c "two")
            (c:llm-auth-error () nil))
          (is (= 2 (length (llm:conversation-messages c)))
              "the second, failed turn must be rolled back")
          (is (eq before (llm:conversation-messages c))
              "rollback must restore the exact prior list, not merely its length")
          (is (string= "one"
                       (llm:part-text (first (llm:message-content
                                              (first (llm:conversation-messages c))))))))))))

(test send-retry-after-failure-yields-alternating-roles
  "A failed SEND followed by a successful SEND on the same conversation must
produce strictly alternating USER/ASSISTANT roles -- not two USER messages
in a row, which the Anthropic API rejects."
  (with-fake-driver (d (:status 401 :body "{\"error\":{\"message\":\"nope\"}}")
                       (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((c (llm:make-conversation)))
        (handler-case (llm:send c "hi")
          (c:llm-auth-error () nil))
        (llm:send c "hi")
        (is (equal '(:user :assistant)
                   (mapcar #'llm:message-role (llm:conversation-messages c))))
        (let ((body (last-request-body d)))
          (is (equal '("user")
                     (loop for i below (length (json:jget body "messages"))
                           collect (json:jget body "messages" i "role")))))))))

(test send-preserves-the-retry-request-restart
  "SEND must not use HANDLER-CASE to roll back, because HANDLER-CASE unwinds
the stack before running its handler -- that would destroy the RETRY-REQUEST
restart established deep inside REQUEST-WITH-RETRY before an outer
HANDLER-BIND ever got a chance to invoke it. Prove the restart survives by
invoking it from a HANDLER-BIND wrapped around SEND and confirming SEND
still returns successfully."
  (with-fake-driver (d (:status 400 :body "{\"error\":{\"message\":\"bad\"}}")
                       (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((c (llm:make-conversation)))
        (handler-bind ((c:llm-api-error
                         (lambda (e)
                           (declare (ignore e))
                           (let ((restart (find-restart 'cl-llm::retry-request)))
                             (is-true restart
                                      "retry-request restart must still be reachable from SEND")
                             (invoke-restart restart)))))
          (let ((response (llm:send c "hi")))
            (is (typep response 'llm:response))
            (is (string= "Hello" (llm:response-text response)))))
        (is (= 2 (length (llm:conversation-messages c)))
            "the eventually-successful turn must still append both messages")))))

(test send-success-still-appends-both-messages
  "Guard against over-rollback: a SEND that succeeds must still append both
the user message and the assistant reply."
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((c (llm:make-conversation)))
        (llm:send c "hi")
        (is (equal '(:user :assistant)
                   (mapcar #'llm:message-role (llm:conversation-messages c))))))))
