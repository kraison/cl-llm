;;;; quickstart.lisp -- the shortest path to a response, and the two providers.
;;;;
;;;; Load this file, then: (examples/quickstart:run)
;;;; (or evaluate the forms in RUN one at a time at the REPL).

(ql:quickload :cl-llm)

(defpackage #:examples/quickstart
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run))

(in-package #:examples/quickstart)

;;; cl-llm is REPL-first: a one-liner works, and the same call scales to full
;;; control. Every special variable (*provider*, *model*, *temperature*, ...)
;;; mirrors a keyword argument of the same name, so you never switch APIs.

;;; Two providers you can bind to llm:*provider*:

(defun anthropic ()
  "The Anthropic Messages API. Reads ANTHROPIC_API_KEY from the environment."
  (make-instance 'llm:anthropic-provider))

(defun local-ollama ()
  "A local (or any OpenAI-compatible) endpoint: Ollama, llama.cpp, vLLM, LM Studio."
  (make-instance 'llm:openai-compatible-provider
                 :base-url "http://localhost:11434/v1"
                 :model    "qwen2.5:7b"))

(defun run ()
  ;; Pick whichever you have available.
  (setf llm:*provider* (local-ollama))

  ;; 1. The one-liner. ASK returns (values text response).
  (format t "~&--- ask ---~%~a~%" (llm:ask "In one sentence, what is Common Lisp?"))
  ;; => "Common Lisp is a modern, general-purpose programming language ..."

  ;; 2. The second value is the full response object: stop reason, token usage,
  ;;    content parts, the raw decoded payload.
  (multiple-value-bind (text response) (llm:ask "Name three Lisp dialects.")
    (declare (ignore text))
    (format t "~&--- response object ---~%stop=~s  tokens in/out=~a/~a~%"
            (llm:response-stop-reason response)
            (llm:usage-input-tokens  (llm:response-usage response))
            (llm:usage-output-tokens (llm:response-usage response))))
  ;; => stop=:END-TURN  tokens in/out=39/19

  ;; 3. Specials vs. keywords are the SAME API. These three are equivalent ways
  ;;    to set the temperature; the keyword wins over the special when both are
  ;;    present.
  (llm:ask "Say hi." :temperature 0.2)                 ; keyword
  (let ((llm:*temperature* 0.2)) (llm:ask "Say hi."))  ; special
  (let ((llm:*temperature* 0.9))
    (llm:ask "Say hi." :temperature 0.2))              ; keyword wins -> 0.2

  ;; 4. Full control in one call, without touching the specials:
  (format t "~&--- fully specified ---~%~a~%"
          (llm:ask "Give me a haiku about parentheses."
                   :provider (local-ollama)
                   :model "qwen2.5:7b"
                   :temperature 0.8
                   :max-tokens 60
                   :system "You are a poet who loves Lisp."))

  (values))

;; (examples/quickstart:run)
