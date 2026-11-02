;;;; rag-chat.lisp -- a RAG conversation that understands follow-ups.
;;;;
;;;; Load this file, then:
;;;;   (examples/rag-chat:offline)        ; no network: mock models
;;;;   (examples/rag-chat:run :model ...) ; a local llama-server model
;;;; Guide: docs/conversations.md

(ql:quickload :cl-llm/rag/chat)

(defpackage #:examples/rag-chat
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag)
                    (#:chat #:cl-llm.rag.chat)
                    (#:harness #:cl-llm.harness))
  (:export #:offline #:run))

(in-package #:examples/rag-chat)

(defparameter *documents*
  '(("zephyr" "Zephyr-9"
     "The Zephyr-9 is a compact water pump. It is powered by a two-stroke
diesel engine and moves 900 litres a minute.")
    ("aquila" "Aquila-4"
     "The Aquila-4 is an electric water pump, powered from a 24 V battery."))
  "(id title text): the corpus both parts search.")

(defun corpus-index ()
  "A RAG index over *DOCUMENTS*, with a mock embedder: no network."
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder))))
    (rag:add-documents index
                       (loop for (id title text) in *documents*
                             collect (rag:make-document
                                      text :id id
                                           :metadata (list :title title))))
    index))

(defun show (turn)
  (format t "~&Searched for: ~a~%~a~%  (~s, ~d sources)~%"
          (chat:rag-turn-standalone turn) (chat:rag-turn-answer turn)
          (chat:rag-turn-stop-reason turn)
          (length (chat:rag-turn-hits turn)))
  turn)

(defun offline ()
  "Two turns on mock models: the second is rewritten before searching."
  (harness:reset-persona-state)
  (let* ((index (corpus-index))
         (answer (llm:make-mock-provider
                  :responder (constantly "It runs on a diesel engine [1].")))
         (rewrite (llm:make-mock-provider
                   :responder (constantly "How is the Zephyr-9 powered?")))
         (chat (chat:make-rag-chat
                :answer-persona (harness:make-persona :name "kb"
                                                      :provider answer)
                :rewrite-persona (harness:make-persona :name "kb-rewrite"
                                                       :provider rewrite)
                :retrieve (lambda (q k) (rag:retrieve index q :k k))))
         (sc (llm:make-stored-conversation :owner "example")))
    (show (chat:rag-chat-turn chat sc "Tell me about the Zephyr-9."))
    ;; Searched for: Tell me about the Zephyr-9.   (the first, as asked)
    (show (chat:rag-chat-turn chat sc "How is it powered?"))
    ;; Searched for: How is the Zephyr-9 powered?
    sc))

(defun run (&key (base-url "http://127.0.0.1:8080/v1") (model "local")
                 key-file (directory "/tmp/cl-llm-rag-chat-example/")
                 (question "How is it powered?"))
  "Ask QUESTION in the current conversation kept under DIRECTORY, on a
local llama-server model; a first run starts with a question about the
Zephyr-9 so the follow-up has something to follow.  Rerun to resume."
  (harness:reset-persona-state)
  (let* ((index (corpus-index))
         (store (llm:make-file-conversation-store directory))
         (sc (or (llm:current-conversation store "example")
                 (llm:new-conversation store "example")))
         (persona (harness:make-persona
                   :name "local-kb" :system "Be brief."
                   :provider (list :kind :openai-compatible
                                   :base-url base-url :model model
                                   :api-key-file key-file)
                   :parameters '(:max-tokens 12000)
                   :max-seconds 600))
         (chat (chat:make-rag-chat
                :answer-persona persona
                :retrieve (lambda (q k) (rag:retrieve index q :k k)))))
    (when (null (llm:stored-conversation-turns sc))
      (show (chat:rag-chat-turn chat sc "Tell me about the Zephyr-9 pump."
                                :store store)))
    (show (chat:rag-chat-turn chat sc question :store store))))
