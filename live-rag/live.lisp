;;;; live-rag/live.lisp -- tests against a real embeddings endpoint. Gated.

(in-package #:cl-llm.rag.live)

(def-suite cl-llm-rag-live-suite :description "Live embeddings tests.")
(in-suite cl-llm-rag-live-suite)

(defun live-enabled-p ()
  (let ((v (uiop:getenv "CL_LLM_LIVE"))) (and v (string/= v "") (string/= v "0"))))

(defun live-embedder ()
  (rag:make-openai-compatible-embedder
   :base-url (or (uiop:getenv "CL_LLM_RAG_BASE_URL") "http://localhost:11434/v1")
   :model (or (uiop:getenv "CL_LLM_RAG_EMBED_MODEL") "nomic-embed-text")))

(test live-embed-and-retrieve
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (handler-case
          (let ((index (rag:make-index :embedder (live-embedder))))
            (rag:add-documents index
                               (list (rag:make-document "The TM-62 is a Soviet anti-tank mine." :id "tm62")
                                     (rag:make-document "Field first aid for blast injuries." :id "aid")))
            (let ((hit (first (rag:retrieve index "anti-tank landmine" :k 1))))
              (is (string= "tm62" (rag:chunk-document-id (rag:hit-chunk hit))))))
        (cl-llm:llm-error (e)
          (skip "No embeddings endpoint (pull nomic-embed-text and run ollama with --embeddings): ~a" e)))))
