;;;; tests-rag/retrieve.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(defun populated-dense-retriever ()
  "A dense-retriever over a mock embedder and three word-overlap chunks."
  (let* ((embedder (rag:make-mock-embedder))
         (store (rag:make-memory-store))
         (texts '("the TM-62 anti-tank mine has a pressure fuze"
                  "the PFM-1 butterfly mine is scattered by rocket"
                  "weather in the oblast is cold and wet")))
    (rag:store-add store
                   (mapcar (lambda (text)
                             (rag:make-chunk text :document-id text
                                             :embedding (rag:embed embedder text)))
                           texts))
    (rag:make-dense-retriever embedder store)))

(test dense-retriever-returns-the-nearest-chunk-first
  (let* ((r (populated-dense-retriever))
         (hits (rag:retrieve r "TM-62 fuze" :k 2)))
    (is (= 2 (length hits)))
    (is (search "TM-62" (rag:chunk-text (rag:hit-chunk (first hits))))
        "the TM-62 chunk should rank first for a TM-62 query")
    (is (typep (rag:hit-score (first hits)) 'double-float))))

(test dense-retriever-hits-carry-provenance
  (let* ((r (populated-dense-retriever))
         (hit (first (rag:retrieve r "butterfly mine" :k 1))))
    (is (search "PFM-1" (rag:chunk-document-id (rag:hit-chunk hit))))))

(test dense-retriever-k-caps-results
  (let ((r (populated-dense-retriever)))
    (is (= 1 (length (rag:retrieve r "mine" :k 1))))
    (is (= 3 (length (rag:retrieve r "mine" :k 10))))))
