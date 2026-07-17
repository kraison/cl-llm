;;;; tests/tool-loop.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun tool-use-fixture (&key (id "tu_1") (name "tool-echo") (input "{\"text\":\"hi\"}"))
  (format nil "{\"model\":\"m\",\"stop_reason\":\"tool_use\",\"content\":[
                 {\"type\":\"tool_use\",\"id\":\"~a\",\"name\":\"~a\",\"input\":~a}]}"
          id name input))

(test tool-loop-executes-tool-and-returns-final-answer
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo the text." (format nil "echo:~a" text)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (let ((text (llm:ask "say hi" :tools '(tool-echo))))
          (is (string= "Hello" text) "The final non-tool-use response is returned")
          (is (= 2 (length (fake-requests d)))))))))

(test tool-loop-sends-the-tool-result-back
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo the text." (format nil "echo:~a" text)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (llm:ask "say hi" :tools '(tool-echo))
        (let ((body (last-request-body d)))
          ;; messages: user, assistant(tool_use), user(tool_result)
          (is (= 3 (length (json:jget body "messages"))))
          (is (string= "tool_result" (json:jget body "messages" 2 "content" 0 "type")))
          (is (string= "tu_1" (json:jget body "messages" 2 "content" 0 "tool_use_id")))
          (is (string= "echo:hi" (json:jget body "messages" 2 "content" 0 "content"))))))))

(test tool-loop-passes-typed-arguments
  (with-clean-registry
    (eval '(llm:deftool tool-add ((a :type integer) (b :type integer))
            "Add two integers." (+ a b)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture
                                             :name "tool-add" :input "{\"a\":2,\"b\":3}"))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (llm:ask "add" :tools '(tool-add))
        (is (string= "5" (json:jget (last-request-body d)
                                    "messages" 2 "content" 0 "content")))))))

(test tool-loop-reports-tool-errors-back-to-the-model
  "A signalling tool must produce an is_error result, not crash the loop."
  (with-clean-registry
    (eval '(llm:deftool tool-boom (text) "Always fails." (error "kaboom ~a" text)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture :name "tool-boom"))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (is (string= "Hello" (llm:ask "go" :tools '(tool-boom))))
        (let ((body (last-request-body d)))
          (is (eq t (json:jget body "messages" 2 "content" 0 "is_error")))
          (is (search "kaboom" (json:jget body "messages" 2 "content" 0 "content"))))))))

(test tool-loop-respects-max-tool-turns
  "A model that never stops requesting tools must hit a hard bound."
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." text))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (tool-use-fixture)))
      (with-test-provider
        (signals c:llm-tool-error
          (llm:ask "loop" :tools '(tool-echo) :max-tool-turns 2))
        (is (= 2 (length (fake-requests d)))
            "Exactly max-tool-turns requests, then stop")))))

(test tool-loop-default-max-turns-is-8
  (is (= 8 llm:*max-tool-turns*)))

(test tool-loop-succeeds-when-final-answer-lands-exactly-on-max-turns
  "A legitimate exchange that resolves on the very last permitted turn must NOT
be falsely treated as exceeding the bound -- the off-by-one boundary in both
directions matters."
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." text))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (is (string= "Hello"
                     (llm:ask "go" :tools '(tool-echo) :max-tool-turns 2)))
        (is (= 2 (length (fake-requests d)))
            "Exactly max-tool-turns requests were made, and no error signalled")))))

(test tool-loop-handles-multiple-tool-calls-in-one-response
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." text))
    (with-fake-driver
        (d (:status 200
            :body "{\"model\":\"m\",\"stop_reason\":\"tool_use\",\"content\":[
                     {\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"tool-echo\",\"input\":{\"text\":\"a\"}},
                     {\"type\":\"tool_use\",\"id\":\"tu_2\",\"name\":\"tool-echo\",\"input\":{\"text\":\"b\"}}]}")
           (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (llm:ask "go" :tools '(tool-echo))
        (let ((body (last-request-body d)))
          (is (= 2 (length (json:jget body "messages" 2 "content")))
              "Both results go in ONE user message")
          (is (string= "a" (json:jget body "messages" 2 "content" 0 "content")))
          (is (string= "b" (json:jget body "messages" 2 "content" 1 "content"))))))))

(test tool-loop-unknown-tool-signals
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." text))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture :name "not-registered")))
      (with-test-provider
        (signals c:llm-tool-error (llm:ask "go" :tools '(tool-echo)))))))

(test tool-loop-without-tools-does-not-loop
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (is (string= "Hello" (llm:ask "hi")))
      (is (= 1 (length (fake-requests d)))))))
