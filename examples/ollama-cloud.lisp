;;;; ollama-cloud.lisp -- run big models remotely through the local Ollama proxy.
;;;;
;;;; The model runs on Ollama's servers; your local `ollama` just forwards
;;;; requests for `:cloud` model names. Nothing loads into local RAM, and
;;;; cl-llm needs no API key on this path -- the local proxy handles auth.
;;;;
;;;; Prerequisites: `ollama` running locally, signed in to Ollama Cloud
;;;; (`ollama signin`). Free-tier cloud models include gpt-oss:120b-cloud and
;;;; gpt-oss:20b-cloud; others (glm-*, deepseek-*) require a subscription.
;;;;
;;;; Load this file, then: (examples/ollama-cloud:run)

(ql:quickload :cl-llm)

(defpackage #:examples/ollama-cloud
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run #:cloud-provider))

(in-package #:examples/ollama-cloud)

;;; Same openai-compatible-provider as a local model -- only the model name
;;; carries the `:cloud` suffix that tells Ollama to run it remotely.

(defun cloud-provider (&optional (model "gpt-oss:120b-cloud"))
  (make-instance 'llm:openai-compatible-provider
                 :base-url "http://localhost:11434/v1"
                 :model    model))

(defun run ()
  (setf llm:*provider* (cloud-provider "gpt-oss:120b-cloud"))
  ;; A big remote model is slower than a local one; give it room. The 60s
  ;; default is tight for a 120B model over the network.
  (setf llm:*timeout* 300)

  ;; 1. A one-shot ask against the 120B model -- running entirely remotely.
  (format t "~&--- ask (120B, remote) ---~%~a~%"
          (llm:ask "In one sentence, what is a Lisp macro?"))
  ;; => "A Lisp macro is a compile-time code-transformer that receives
  ;;     unevaluated Lisp forms and expands them into new Lisp code ..."

  ;; 2. Streaming works the same as local -- deltas arrive over the wire.
  (format t "~&--- streaming ---~%")
  (llm:with-streamed-response (r "Count from 1 to 5, comma-separated.")
    (llm:do-deltas (d r) (write-string d) (force-output)))
  (terpri)

  ;; 3. Tools work too: the remote model requests the call, your Lisp function
  ;;    runs locally, and the result is fed back.
  (llm:deftool multiply ((a :type integer) (b :type integer))
    "Multiply two integers."
    (* a b))
  (format t "~&--- tool loop ---~%~a~%"
          (llm:ask "Use the multiply tool to compute 34 times 21." :tools '(multiply)))
  ;; => "34 × 21 = 714."

  (values))

;;; A subscription-only model surfaces as a clean llm-auth-error (HTTP 403):
;;;
;;;   (handler-case
;;;       (let ((llm:*provider* (cloud-provider "glm-5.2:cloud")))
;;;         (llm:ask "hi"))
;;;     (llm:llm-auth-error (e)
;;;       (format t "needs a subscription: ~a~%" e)))
;;;
;;; Talking DIRECTLY to https://ollama.com/v1 (bypassing the local proxy) instead
;;; needs a bearer token; pass it explicitly:
;;;
;;;   (make-instance 'llm:openai-compatible-provider
;;;                  :base-url "https://ollama.com/v1"
;;;                  :model "gpt-oss:120b"
;;;                  :api-key (uiop:getenv "OLLAMA_API_KEY"))

;; (examples/ollama-cloud:run)
