;;;; rag/packages.lisp

(defpackage #:cl-llm.rag
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:json #:cl-llm.json)
                    (#:c #:cl-llm.conditions))
  (:export
   #:llm-rag-error #:rag-error-message
   #:embedder #:embedder-model #:embed
   #:openai-compatible-embedder #:make-openai-compatible-embedder
   #:mock-embedder #:make-mock-embedder #:embedder-dimension
   #:embedding
   #:document #:make-document #:document-id #:document-text #:document-metadata
   #:chunk #:make-chunk #:chunk-text #:chunk-document-id #:chunk-metadata #:chunk-embedding
   #:hit #:make-hit #:hit-chunk #:hit-score
   #:split-text
   ;; grows in later tasks
   ))

(in-package #:cl-llm.rag)

(define-condition llm-rag-error (c:llm-error)
  ((message :initarg :message :initform nil :reader rag-error-message))
  (:report (lambda (condition stream)
             (format stream "cl-llm/rag error~@[: ~a~]" (rag-error-message condition))))
  (:documentation "A RAG misuse: an empty corpus, an embedding-dimension
mismatch, an unknown store, or a malformed document."))
