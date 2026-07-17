;;;; tests/streaming.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun anthropic-stream-fixture ()
  (format nil
          "event: message_start~%data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":10}}}~%~%~
           event: content_block_start~%data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}~%~%~
           event: content_block_delta~%data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}~%~%~
           event: content_block_delta~%data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}~%~%~
           event: content_block_stop~%data: {\"type\":\"content_block_stop\",\"index\":0}~%~%~
           event: message_delta~%data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}~%~%~
           event: message_stop~%data: {\"type\":\"message_stop\"}~%~%"))

(test streaming-next-delta-yields-text-in-order
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (llm:with-streamed-response (r "hi")
        (is (string= "Hel" (llm:next-delta r)))
        (is (string= "lo" (llm:next-delta r)))
        (is (null (llm:next-delta r)) "NIL signals the end of the stream")))))

(test streaming-do-deltas-collects-everything
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (let ((collected '()))
        (llm:with-streamed-response (r "hi")
          (llm:do-deltas (delta r) (push delta collected)))
        (is (string= "Hello" (apply #'concatenate 'string (nreverse collected))))))))

(test streaming-request-sets-the-stream-flag
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (llm:with-streamed-response (r "hi")
        (llm:do-deltas (delta r) (declare (ignore delta))))
      (is (eq t (json:jget (last-request-body d) "stream"))))))

(test streaming-finish-response-assembles-a-full-response
  "Nothing is lost by streaming: the assembled response must match a normal one."
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (llm:with-streamed-response (r "hi")
        (llm:do-deltas (delta r) (declare (ignore delta)))
        (let ((response (llm:finish-response r)))
          (is (string= "Hello" (llm:response-text response)))
          (is (eq :end-turn (llm:response-stop-reason response)))
          (is (= 3 (llm:usage-output-tokens (llm:response-usage response)))))))))

(test streaming-closes-the-stream-on-normal-exit
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (let ((saved nil))
        (llm:with-streamed-response (r "hi")
          (setf saved r)
          (llm:next-delta r))
        (is (not (llm:streamed-response-open-p saved))
            "with-streamed-response must close the stream")))))

(test streaming-closes-the-stream-on-nonlocal-exit
  "The unwind-protect must fire even when the body throws."
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (let ((saved nil))
        (ignore-errors
         (llm:with-streamed-response (r "hi")
           (setf saved r)
           (error "boom")))
        (is (not (llm:streamed-response-open-p saved)))))))

(test streaming-signals-api-error-before-reading
  (with-fake-driver (d (:status 429 :body "{\"error\":{\"message\":\"slow\"}}"))
    (with-test-provider
      (without-sleeping (ds)
        (let ((llm:*retries* 0))
          (signals c:llm-rate-limit-error
            (llm:with-streamed-response (r "hi")
              (llm:next-delta r))))))))

(test anthropic-parse-stream-event-text-delta
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event
                "content_block_delta"
                "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")))
    (multiple-value-bind (kind value) (llm:parse-stream-event p event)
      (is (eq :text kind))
      (is (string= "x" value)))))

(test anthropic-parse-stream-event-ping-is-ignored
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event "ping" "{\"type\":\"ping\"}")))
    (is (eq :ignore (llm:parse-stream-event p event)))))

(test anthropic-parse-stream-event-message-stop-is-done
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event "message_stop" "{\"type\":\"message_stop\"}")))
    (is (eq :done (llm:parse-stream-event p event)))))

(test anthropic-parse-stream-event-error-signals
  "An error event mid-stream must surface as a condition, not silence."
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event
                "error"
                "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}")))
    (signals c:llm-api-error (llm:parse-stream-event p event))))
