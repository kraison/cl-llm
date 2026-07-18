;;;; tests-rag/index.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(test make-index-requires-an-embedder
  (signals error (rag:make-index)))

(test add-documents-chunks-embeds-and-stores
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder))))
    (rag:add-documents index
                       (list (rag:make-document
                              "the TM-62 mine has a pressure fuze that is dangerous"
                              :id "d1" :metadata '(:title "TM-62"))))
    (is (plusp (rag:store-count (rag:index-store index))))
    ;; provenance survives chunking
    (let ((hit (first (rag:retrieve index "TM-62 fuze" :k 1))))
      (is (string= "d1" (rag:chunk-document-id (rag:hit-chunk hit))))
      (is (string= "TM-62" (getf (rag:chunk-metadata (rag:hit-chunk hit)) :title)))
      (is (integerp (getf (rag:chunk-metadata (rag:hit-chunk hit)) :position))))))

(test index-retrieves-the-relevant-document
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder))))
    (rag:add-documents index
                       (list (rag:make-document "anti-tank mines and their fuzes" :id "mines")
                             (rag:make-document "field medical evacuation procedures" :id "medevac")))
    ;; The query shares literal tokens with the "mines" document (the mock
    ;; embedder is a bag-of-words hash with no stemming, so "mine"/"fuze"
    ;; would NOT overlap with "mines"/"fuzes" and both candidates would score
    ;; an exact 0.0 tie against "medevac" -- a degenerate, order-dependent
    ;; assertion rather than a real ranking check).
    (is (string= "mines"
                 (rag:chunk-document-id
                  (rag:hit-chunk (first (rag:retrieve index "anti-tank mines fuzes" :k 1))))))))

;;; A call-counting embedder wrapping a real MOCK-EMBEDDER, used to pin the
;;; performance contract that ADD-DOCUMENTS embeds all chunks across all
;;; documents in exactly one batch EMBED call -- never one call per chunk or
;;; per document. It delegates to the inner mock embedder for the actual
;;; vectors, so tests built on it still exercise real (if fake) retrieval.

(defclass counting-embedder (rag:embedder)
  ((inner :initarg :inner :reader counting-embedder-inner)
   (call-count :initform 0 :accessor counting-embedder-call-count))
  (:documentation "Wraps an embedder and counts how many times EMBED is
called on it, without changing the embeddings it returns."))

(defun make-counting-embedder (&key (inner (rag:make-mock-embedder)))
  (make-instance 'counting-embedder :inner inner))

(defmethod rag:embed ((embedder counting-embedder) input)
  (incf (counting-embedder-call-count embedder))
  (rag:embed (counting-embedder-inner embedder) input))

(test add-documents-embeds-all-chunks-in-a-single-batch-call
  "ADD-DOCUMENTS must embed ALL chunks across ALL documents in ONE batch EMBED
call, not one call per chunk or per document. For a real corpus of thousands
of chunks, a regression to per-chunk embedding would mean thousands of HTTP
calls instead of one."
  (let* ((chunker (lambda (text) (rag:split-text text :size 40 :overlap 10)))
         (ce (make-counting-embedder))
         (index (rag:make-index :embedder ce :chunker chunker))
         (doc1 (rag:make-document
                "the TM-62 anti-tank mine uses a pressure-sensitive fuze and is commonly buried along roads and vehicle tracks in conflict zones"
                :id "d1"))
         (doc2 (rag:make-document
                "field medical evacuation procedures require rapid triage, stable transport routes, and clear radio communication between units"
                :id "d2")))
    (rag:add-documents index (list doc1 doc2))
    ;; sanity: this corpus really does produce multiple chunks across
    ;; multiple documents, else the single-call assertion below is vacuous.
    (is (> (rag:store-count (rag:index-store index)) 2))
    (is (= 1 (counting-embedder-call-count ce))
        "add-documents must call embed exactly once for the whole batch, ~
        not once per chunk or per document")
    ;; the counting embedder still produces real, working embeddings, so the
    ;; single-call count above isn't just counting a broken stub.
    (let ((hit (first (rag:retrieve index "TM-62 pressure fuze" :k 1))))
      (is (string= "d1" (rag:chunk-document-id (rag:hit-chunk hit)))))))

(test add-documents-with-no-chunks-does-not-call-embed
  "An empty document list, or documents that yield no chunks, must not call
EMBED at all -- guarding the (WHEN CHUNKS ...) batch guard against embedding
an empty batch."
  (let* ((ce (make-counting-embedder))
         (index (rag:make-index :embedder ce)))
    (is (eq index (rag:add-documents index nil)))
    (is (= 0 (counting-embedder-call-count ce)))
    (is (eq index (rag:add-documents index (list (rag:make-document "" :id "empty")))))
    (is (= 0 (counting-embedder-call-count ce)))))

(test save-and-load-index-round-trips
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder)))
        (path (merge-pathnames "rag-index-test.dat" (uiop:temporary-directory))))
    (rag:add-documents index (list (rag:make-document "PFM-1 butterfly mine" :id "d")))
    (rag:save-index index path)
    (let ((loaded (rag:load-index path (rag:make-mock-embedder))))
      (is (= (rag:store-count (rag:index-store index))
             (rag:store-count (rag:index-store loaded))))
      (is (string= "d" (rag:chunk-document-id
                        (rag:hit-chunk (first (rag:retrieve loaded "butterfly" :k 1)))))))
    (ignore-errors (delete-file path))))
