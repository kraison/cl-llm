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

;;; A local llama-server model (#88).  Opt in with CL_LLM_LIVE plus
;;; CL_LLM_LLAMA_BASE_URL, CL_LLM_LLAMA_MODEL and CL_LLM_LLAMA_KEY_FILE.
;;; A cold first reply loads the model: the timeout allows for it, and
;;; max-tokens leaves room for a reasoning model's thinking.

(defun llama-enabled-p ()
  (and (live-enabled-p)
       (let ((url (uiop:getenv "CL_LLM_LLAMA_BASE_URL")))
         (and url (string/= url "")))))

(defun llama-provider ()
  "An openai-compatible-provider for the CL_LLM_LLAMA_* server."
  (let ((key-file (uiop:getenv "CL_LLM_LLAMA_KEY_FILE")))
    (make-instance 'llm:openai-compatible-provider
                   :base-url (uiop:getenv "CL_LLM_LLAMA_BASE_URL")
                   :model (or (uiop:getenv "CL_LLM_LLAMA_MODEL")
                              "local")
                   :api-key (and key-file (string/= key-file "")
                                 (string-trim
                                  '(#\Space #\Newline #\Return #\Tab)
                                  (uiop:read-file-line key-file))))))

(defmacro with-llama (() &body body)
  `(if (not (llama-enabled-p))
       (skip "CL_LLM_LIVE or CL_LLM_LLAMA_BASE_URL is not set.")
       (let ((llm:*provider* (llama-provider))
             (llm:*timeout* 300)
             (llm:*max-tokens* 12000))
         ,@body)))

(test live-llama-ask
  (with-llama ()
    (let ((text (llm:ask "Reply with exactly the word: pong")))
      (is (search "pong" (string-downcase text)))
      ;; Reasoning arrives as untagged prose, so a leak shows as length.
      (is (< (length text) 20)
          "reasoning leaked into the answer: ~s" text))))

(test live-llama-conversation
  (with-llama ()
    (let ((c (llm:make-conversation :provider llm:*provider*)))
      (llm:send c "My name is Ada. Reply OK.")
      (let ((text (llm:response-text
                   (llm:send c "What is my name? One word."))))
        (is (search "ada" (string-downcase text)) "got ~s" text)))))

(test live-llama-tool
  (with-llama ()
    (llm:deftool live-add ((a :type integer) (b :type integer))
      "Add two integers together."
      (+ a b))
    (let ((text (llm:ask (concatenate 'string
                                      "Use the live-add tool to add 17 "
                                      "and 25. Reply with just the number.")
                         :tools '(live-add))))
      (is (search "42" text) "got ~s" text))))

(test live-llama-streaming
  (with-llama ()
    (let ((collected '()))
      (llm:with-streamed-response (r "Count: one two three")
        (llm:do-deltas (delta r) (push delta collected)))
      (is (plusp (length collected)) "at least one delta must arrive")
      (is (search "three"
                  (string-downcase
                   (apply #'concatenate 'string (reverse collected))))))))

(test live-llama-persona-run
  "A persona run on the local model under the harness's guards (#85)."
  (with-llama ()
    (let* ((add (llm:make-tool 'live-add "Add two integers together."
                               '((a :type integer) (b :type integer))
                               (lambda (a b) (+ a b))))
           (persona (harness:make-persona
                     :name "live-adder" :tools (list add)
                     :provider llm:*provider*
                     :parameters '(:max-tokens 12000)
                     :max-seconds 600 :max-run-tokens 60000 :max-turns 4))
           (r (progn (harness:reset-persona-state "live-adder")
                     (harness:run-persona
                      persona
                      (concatenate 'string
                                   "Use the live-add tool to add 17 and 25."
                                   " Reply with just the number.")))))
      (is (eq :end-turn (harness:run-stop-reason r))
          "stopped ~s: ~a" (harness:run-stop-reason r) (harness:run-error r))
      (is (search "42" (or (harness:run-text r) "")) "got ~s"
          (harness:run-text r))
      (is (= 1 (length (harness:run-tool-calls r))))
      (is (string= "live-add"
                   (getf (first (harness:run-tool-calls r)) :name)))
      (is (plusp (harness:run-input-tokens r))))))
