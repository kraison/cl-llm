;;;; live.lisp -- tests that hit real endpoints.
;;;;
;;;; Never run by (asdf:test-system :cl-llm). These cost money and need keys, so
;;;; they are gated: contributors without keys are never blocked.

(in-package #:cl-llm.live)

(def-suite cl-llm-live-suite
  :description "Tests against real Anthropic and local endpoints.")

(in-suite cl-llm-live-suite)

(defun live-enabled-p ()
  (let ((value (uiop:getenv "CL_LLM_LIVE")))
    (and value (string/= value "") (string/= value "0"))))

(defun local-base-url ()
  (or (uiop:getenv "CL_LLM_LOCAL_BASE_URL") "http://localhost:11434/v1"))

(defun local-model ()
  (or (uiop:getenv "CL_LLM_LOCAL_MODEL") "llama3.1"))

(test live-anthropic-ask
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (let ((llm:*provider* (make-instance 'llm:anthropic-provider))
            (llm:*max-tokens* 64))
        (let ((text (llm:ask "Reply with exactly the word: pong")))
          (is (stringp text))
          (is (search "pong" (string-downcase text)))))))

(test live-anthropic-streaming
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (let ((llm:*provider* (make-instance 'llm:anthropic-provider))
            (llm:*max-tokens* 64)
            (collected '()))
        (llm:with-streamed-response (r "Count: one two three")
          (llm:do-deltas (delta r) (push delta collected)))
        (is (plusp (length collected)) "At least one delta must arrive"))))

(test live-anthropic-tool-use
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (progn
        (llm:deftool live-add ((a :type integer) (b :type integer))
          "Add two integers together."
          (+ a b))
        (let ((llm:*provider* (make-instance 'llm:anthropic-provider))
              (llm:*max-tokens* 256))
          (let ((text (llm:ask "Use the live-add tool to add 17 and 25. Reply with just the number."
                               :tools '(live-add))))
            (is (search "42" text)))))))

(test live-local-ask
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (let ((llm:*provider* (make-instance 'llm:openai-compatible-provider
                                           :base-url (local-base-url)
                                           :model (local-model))))
        (handler-case
            (is (stringp (llm:ask "Reply with exactly the word: pong")))
          (c:llm-error (e)
            (skip "No local server at ~a: ~a" (local-base-url) e))))))
