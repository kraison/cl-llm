;;;; rag-local.lisp -- RAG against a real, local embeddings model (Ollama).
;;;;
;;;; The same pipeline as rag-quickstart.lisp, but with a REAL embedder and a REAL
;;;; answering model instead of the mocks. Embeddings run locally through Ollama,
;;;; so the corpus never leaves your machine -- the data-sovereignty / offline
;;;; posture the EOD use case needs.
;;;;
;;;; Prerequisites: `ollama` running locally, with an embedding model and a chat
;;;; model pulled:
;;;;   ollama pull nomic-embed-text     ; the embedder (768-dim, multilingual-ish)
;;;;   ollama pull qwen2.5:7b           ; any local chat model works
;;;; (For a bigger answering model with no local RAM, point *provider* at a
;;;;  :cloud model instead -- see ollama-cloud.lisp.)
;;;;
;;;; Load this file, then: (examples/rag-local:run)

(ql:quickload :cl-llm/rag)

(defpackage #:examples/rag-local
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag))
  (:export #:run #:local-index))

(in-package #:examples/rag-local)

(defparameter *ollama* "http://localhost:11434/v1")

;;; Descriptive ordnance-identification facts (public reference material, not
;;; procedures). A real deployment would index thousands of such passages.
(defparameter *corpus*
  (list
   (rag:make-document
    "The TM-62M is a Soviet-designed anti-tank blast mine with a metal body and a
     pressure-activated fuze. It holds a high-explosive main charge."
    :id "tm62m" :metadata '(:title "TM-62M" :language "en"))
   (rag:make-document
    "The PFM-1 is a small scatterable anti-personnel blast mine, nicknamed the
     butterfly mine for its winged shape. It is pressure-sensitive."
    :id "pfm1" :metadata '(:title "PFM-1" :language "en"))
   (rag:make-document
    "The OZM-72 is a bounding anti-personnel fragmentation mine that launches to
     roughly waist height before detonating."
    :id "ozm72" :metadata '(:title "OZM-72" :language "en"))))

(defun local-index ()
  "Build an index whose embedder is a local Ollama embeddings model, and load the
corpus into it. The chat model is chosen separately, via *provider* in RUN."
  (let ((index (rag:make-index
                :embedder (rag:make-openai-compatible-embedder
                           :base-url *ollama* :model "nomic-embed-text"))))
    (rag:add-documents index *corpus*)
    index))

(defun run ()
  ;; The answering model: any local chat model. Embeddings and answering are
  ;; independent -- different models, one for vectors, one for text.
  (setf llm:*provider* (make-instance 'llm:openai-compatible-provider
                                      :base-url *ollama* :model "qwen2.5:7b"))

  (let ((index (local-index)))
    (format t "~&--- indexed ~a chunk(s) with real embeddings ---~%"
            (rag:store-count (rag:index-store index)))

    ;; 1. Retrieve: embed the query with the SAME model and rank by cosine.
    (format t "~&--- retrieve ---~%")
    (loop for hit in (rag:retrieve index "anti-tank mine with a pressure fuze" :k 2)
          do (format t "  ~,3f  [~a]~%"
                     (rag:hit-score hit)
                     (getf (rag:chunk-metadata (rag:hit-chunk hit)) :title)))
    ;; => 0.775  [TM-62M]       ; a real embedder ranks the anti-tank mine first
    ;;    0.746  [PFM-1]         ; (nomic-embed-text; exact scores vary by model version)

    ;; 2. Grounded answer from the real model, constrained to the retrieved
    ;;    sources. A caller :system persona is composed WITH the grounding rules,
    ;;    never replacing them.
    (multiple-value-bind (answer hits)
        (rag:rag-ask index "What kind of fuze does the TM-62M use?"
                     :k 3
                     :system "You are an EOD reference assistant. Be terse and factual.")
      (format t "~&--- rag-ask ---~%~a~%  sources: ~{~a~^, ~}~%"
              answer
              (mapcar (lambda (h) (getf (rag:chunk-metadata (rag:hit-chunk h)) :title))
                      hits)))
    ;; => The TM-62M uses a pressure-activated fuze [1].
    ;;      sources: TM-62M, OZM-72, PFM-1

    ;; 3. Abstention: an out-of-corpus question. A well-behaved model declines
    ;;    rather than inventing an answer -- the behavior the grounding prompt asks
    ;;    for, and the property the eval harness exists to MEASURE before trust.
    (format t "~&--- rag-ask (out of corpus) ---~%~a~%"
            (rag:rag-ask index "What was the population of Kyiv in 1900?" :k 3))
    ;; => not in the provided sources (a strong model abstains; a weak one may not
    ;;    -- which is exactly what you'd score with cl-llm/eval)

    ;; 4. Persistence: embedding a large corpus is the expensive step, so index
    ;;    once and reload. SAVE-INDEX writes the vectors + provenance; LOAD-INDEX
    ;;    reattaches an embedder (the SAME model -- dimensions must match).
    (let ((path (merge-pathnames "cl-llm-rag-local.store" (uiop:temporary-directory))))
      (rag:save-index index path)
      (let ((reloaded (rag:load-index
                       path
                       (rag:make-openai-compatible-embedder
                        :base-url *ollama* :model "nomic-embed-text"))))
        (format t "~&--- reloaded ~a chunk(s) from ~a ---~%"
                (rag:store-count (rag:index-store reloaded)) path))))
  (values))

;; (examples/rag-local:run)
