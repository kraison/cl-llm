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
