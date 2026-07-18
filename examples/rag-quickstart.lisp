;;;; rag-quickstart.lisp -- retrieval-augmented generation, end to end, offline.
;;;;
;;;; cl-llm/rag adds: chunk a corpus, embed it into a vector store, retrieve the
;;;; passages relevant to a question, and answer GROUNDED IN and CITING those
;;;; passages -- saying "not in the provided sources" instead of guessing.
;;;;
;;;; This example runs entirely OFFLINE: a MOCK-EMBEDDER (deterministic
;;;; bag-of-words vectors, real cosine ranking) plus a MOCK-PROVIDER standing in
;;;; for the answering model. No network, no API key. Swap in a real embedder and
;;;; provider (see rag-local.lisp) and nothing else changes.
;;;;
;;;; Load this file, then: (examples/rag-quickstart:run)

(ql:quickload :cl-llm/rag)

(defpackage #:examples/rag-quickstart
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag))
  (:export #:run))

(in-package #:examples/rag-quickstart)

;;; A tiny corpus of descriptive ordnance-identification facts -- the kind of
;;; specialist reference material RAG exists to ground answers in. (Plain public
;;; descriptions, not procedures: this is a howto, not demining guidance.) Each
;;; document carries provenance in its metadata; retrieval preserves it so every
;;; answer can cite where it came from.
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

;;; A scripted stand-in for the answering model. A REAL model reads the numbered
;;; Sources block and the grounding system prompt and produces these itself; this
;;; mock mimics the contract so the example is deterministic and offline: it cites
;;; when the sources cover the question's subject, and abstains otherwise. RAG-ASK
;;; sends "Sources:\n...\nQuestion: <q>", so we pull the question back out.
(defun question-of (user-prompt)
  (let ((pos (search "Question: " user-prompt)))
    (if pos (subseq user-prompt (+ pos (length "Question: "))) user-prompt)))

(defun grounding-mock ()
  (llm:make-mock-provider
   :responder
   (lambda (conversation)
     (let* ((messages (llm:conversation-messages conversation))
            (user (llm:part-text (first (llm:message-content (car (last messages))))))
            (q (question-of user)))
       (cond
         ((search "TM-62" q) "The TM-62M uses a pressure-activated fuze [1].")
         ((search "butterfly" q) "The butterfly mine is the PFM-1, an anti-personnel blast mine [1].")
         ;; Off-corpus: the grounding discipline says abstain rather than guess.
         (t "not in the provided sources"))))))

(defun run ()
  ;; 1. Build an index (embedder + vector store + chunker) and load the corpus.
  ;;    ADD-DOCUMENTS chunks each document, embeds every chunk in ONE batch call,
  ;;    and stores them with their provenance.
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder))))
    (rag:add-documents index *corpus*)
    (format t "~&--- indexed ~a chunk(s) ---~%" (rag:store-count (rag:index-store index)))
    ;; => --- indexed 3 chunk(s) ---

    ;; 2. Retrieval is REAL here: the mock embedder produces genuine (bag-of-words)
    ;;    vectors, so shared words raise cosine and the nearest chunk ranks first.
    (format t "~&--- retrieve: \"anti-tank mine with a metal body and high-explosive charge\" ---~%")
    (loop for hit in (rag:retrieve index "anti-tank mine with a metal body and high-explosive charge" :k 2)
          for chunk = (rag:hit-chunk hit)
          do (format t "  ~,3f  [~a] ~a~%"
                     (rag:hit-score hit)
                     (getf (rag:chunk-metadata chunk) :title)
                     (rag:chunk-document-id chunk)))
    ;; => 0.725  [TM-62M] tm62m         ; genuinely ranked first by cosine overlap
    ;;    0.643  [OZM-72] ozm72          ; (toy 32-dim mock; a real embedder separates these further)

    ;; 3. RAG-ASK: retrieve, assemble a numbered/cited context, and ask the model
    ;;    to answer ONLY from it. Returns (values answer hits) -- you always get
    ;;    the sources the answer was grounded in.
    (multiple-value-bind (answer hits)
        (rag:rag-ask index "What fuze does the TM-62M use?"
                     :k 3 :provider (grounding-mock))
      (format t "~&--- rag-ask (grounded) ---~%~a~%  grounded on: ~{~a~^, ~}~%"
              answer
              (mapcar (lambda (h) (getf (rag:chunk-metadata (rag:hit-chunk h)) :title))
                      hits)))
    ;; => The TM-62M uses a pressure-activated fuze [1].
    ;;      grounded on: TM-62M, PFM-1, OZM-72

    ;; 4. Abstention is a first-class outcome. An off-corpus question retrieves
    ;;    low-relevance passages, and the grounding prompt makes the model decline
    ;;    rather than hallucinate.
    (format t "~&--- rag-ask (out of corpus) ---~%~a~%"
            (rag:rag-ask index "What is the capital of France?"
                         :provider (grounding-mock)))
    ;; => not in the provided sources

    ;; 5. The agentic path: MAKE-RETRIEVAL-TOOL wraps the index as a cl-llm:tool
    ;;    the model can call (via :tools in ASK) to fetch its own cited context.
    ;;    It's an ordinary tool -- its function returns the same numbered block
    ;;    RAG-ASK builds internally, so we can invoke it directly to show the shape.
    (let ((tool (rag:make-retrieval-tool index :k 1)))
      (format t "~&--- retrieval tool ~s ---~%~a"
              (llm:tool-name tool)
              (funcall (llm:tool-function tool) "butterfly mine")))
    ;; => --- retrieval tool "retrieve-context" ---
    ;;    [1] (PFM-1) The PFM-1 is a small scatterable anti-personnel blast mine ...

    ;; 6. Persistence is offline and exact: SAVE-INDEX writes the store (vectors +
    ;;    provenance) to disk; LOAD-INDEX reloads it and reattaches an embedder.
    (let ((path (merge-pathnames "cl-llm-rag-demo.store"
                                 (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (rag:save-index index path)
             (let* ((reloaded (rag:load-index path (rag:make-mock-embedder)))
                    (top (first (rag:retrieve reloaded "butterfly mine" :k 1))))
               (format t "~&--- reloaded from disk ---~%  top hit: ~a~%"
                       (getf (rag:chunk-metadata (rag:hit-chunk top)) :title))))
        (uiop:delete-file-if-exists path)))
    ;; => --- reloaded from disk ---
    ;;      top hit: PFM-1
    )
  (values))

;; (examples/rag-quickstart:run)
