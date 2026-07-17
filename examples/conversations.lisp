;;;; conversations.lisp -- multi-turn chat with preserved history.
;;;;
;;;; ASK is single-shot (a throwaway conversation). To keep history across
;;;; turns, make a CONVERSATION and SEND to it: each turn's user message and the
;;;; assistant reply are appended, and the whole history is re-sent every turn.
;;;;
;;;; Load this file, then: (examples/conversations:run)

(ql:quickload :cl-llm)

(defpackage #:examples/conversations
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run))

(in-package #:examples/conversations)

(defun provider ()
  (make-instance 'llm:openai-compatible-provider
                 :base-url "http://localhost:11434/v1"
                 :model    "qwen2.5:7b"))

(defun run ()
  (setf llm:*provider* (provider))

  ;; A conversation carries a system prompt and accumulates turns.
  (let ((chat (llm:make-conversation :system "You are terse. Answer in under 10 words.")))

    ;; SEND returns the assistant RESPONSE; RESPONSE-TEXT pulls the text.
    (format t "~&U: My name is Kevin.~%A: ~a~%"
            (llm:response-text (llm:send chat "My name is Kevin.")))

    ;; The model remembers, because the prior turns are re-sent.
    (format t "~&U: What is my name?~%A: ~a~%"
            (llm:response-text (llm:send chat "What is my name?")))
    ;; => A: Your name is Kevin.

    (format t "~&U: And spell it backwards.~%A: ~a~%"
            (llm:response-text (llm:send chat "And spell it backwards.")))

    ;; Inspect the accumulated history: user/assistant/user/assistant/...
    (format t "~&--- history (~a messages) ---~%" (length (llm:conversation-messages chat)))
    (dolist (m (llm:conversation-messages chat))
      (format t "  ~(~a~): ~a~%"
              (llm:message-role m)
              (llm:part-text (first (llm:message-content m))))))

  ;; Note: a conversation can pin its own provider, independent of *provider*:
  ;;   (llm:make-conversation :provider (provider) :system "...")
  ;; Also: if a SEND fails mid-conversation (e.g. a 401), cl-llm rolls the
  ;; conversation back to before that turn, so a retry doesn't send two user
  ;; messages in a row.

  (values))

;; (examples/conversations:run)
