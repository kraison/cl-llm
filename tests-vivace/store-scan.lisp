;;;; tests-vivace/store-scan.lisp

(in-package #:cl-llm.rag.vivace/tests)
(in-suite :cl-llm-rag-vivace)

(defun mk-chunk (embedder text &key (doc "d") meta)
  (rag:make-chunk text :document-id doc :metadata meta
                       :embedding (rag:embed embedder text)))

(test scan-store-add-search-count
  (with-temp-graph (g)
    (let* ((emb (rag:make-mock-embedder))
           (store (v:make-graph-store g :strategy :scan))
           (chunks (list (mk-chunk emb "the TM-62 is an anti-tank mine" :doc "tm62")
                         (mk-chunk emb "the PFM-1 is a butterfly mine" :doc "pfm1"))))
      (rag:store-add store chunks)
      (is (= 2 (rag:store-count store)))
      (let* ((q (rag:embed emb "anti-tank mine"))
             (hits (rag:store-search store q 1)))
        (is (= 1 (length hits)))
        (is (string= "tm62" (rag:chunk-document-id (rag:hit-chunk (first hits)))))))))

(test scan-store-dimension-and-nil-embedding-signal
  (with-temp-graph (g)
    (let* ((emb (rag:make-mock-embedder :dimension 8))
           (store (v:make-graph-store g :strategy :scan)))
      (rag:store-add store (list (mk-chunk emb "x")))
      ;; nil embedding
      (signals rag:llm-rag-error
        (rag:store-add store (list (rag:make-chunk "y" :embedding nil))))
      ;; dimension mismatch: a differently-sized embedding
      (signals rag:llm-rag-error
        (rag:store-add store
                       (list (rag:make-chunk "z"
                              :embedding (rag:as-embedding '(1d0 2d0 3d0))))))
      ;; failed batch left the store unchanged
      (is (= 1 (rag:store-count store))))))

(test scan-store-delete-document
  (let* ((dir (format nil "/tmp/cl-llm-vg-del-scan-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (let* ((g (gdb:make-graph :cl-llm-vg-del-scan (pathname dir)))
                (store (v:make-graph-store g :strategy :scan)))
           (rag:store-add store (list (rag:make-chunk "a1" :document-id "A"
                                        :embedding (rag:embed emb "a1"))
                                      (rag:make-chunk "a2" :document-id "A"
                                        :embedding (rag:embed emb "a2"))
                                      (rag:make-chunk "b1" :document-id "B"
                                        :embedding (rag:embed emb "b1"))))
           (is (= 3 (rag:store-count store)))
           (is (= 2 (rag:store-delete-document store "A")))
           (is (= 1 (rag:store-count store)))                    ; re-scan excludes soft-deleted
           (let ((hits (rag:store-search store (rag:embed emb "a1") 5)))
             (is (every (lambda (h) (string= "B" (rag:chunk-document-id (rag:hit-chunk h)))) hits)))
           (gdb:close-graph g))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))

(test scan-store-delete-absent-document-is-a-noop
  (with-temp-graph (g)
    (let* ((emb (rag:make-mock-embedder))
           (store (v:make-graph-store g :strategy :scan)))
      (rag:store-add store (list (mk-chunk emb "the TM-62 is an anti-tank mine" :doc "tm62")
                                 (mk-chunk emb "the PFM-1 is a butterfly mine" :doc "pfm1")))
      (is (= 2 (rag:store-count store)))
      (is (= 0 (rag:store-delete-document store "does-not-exist")))
      (is (= 2 (rag:store-count store))))))
