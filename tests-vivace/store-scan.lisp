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

(test migrates-legacy-double-t-vector-embeddings
  "A chunk stored as a T-vector of doubles is rewritten to a normalised
single-float array on hydrate."
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (let ((legacy (vector 3.0d0 4.0d0)))   ; unnormalised, boxed, T-vector
      (let ((gdb:*graph* g))
        (gdb:with-transaction ()
          (funcall (v::chunk-constructor 'rag-chunk)
                   :text "legacy" :document-id "doc-legacy"
                   :metadata nil :embedding legacy :graph g))))
    (let ((store (v:make-graph-store g :strategy :scan))
          (vertices '()))
      (v::map-chunk-vertices store (lambda (vx) (push vx vertices)))
      (let ((e (v::%slot (first vertices) "EMBEDDING")))
        (is (typep e '(simple-array single-float (*)))
            "embedding was not migrated: ~S" (type-of e))
        (is (< (abs (- 1.0 (rag:embedding-norm e))) 1e-5)
            "embedding was not normalised")))))

(test migration-policy-error-refuses-instead-of-migrating
  "With :error policy, a legacy store signals rather than silently rewriting."
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (let ((cl-llm.rag.vivace::*embedding-migration-policy* :error))
      (let ((gdb:*graph* g))
        (gdb:with-transaction ()
          (funcall (v::chunk-constructor 'rag-chunk)
                   :text "legacy" :document-id "doc-legacy"
                   :metadata nil :embedding (vector 3.0d0 4.0d0) :graph g)))
      (signals rag:llm-rag-error (v:make-graph-store g :strategy :scan)))))

(test migrates-single-float-non-unit-embeddings
  "A chunk whose embedding is ALREADY (simple-array single-float (*)) but not
unit-norm is still rewritten to unit-norm on hydrate. This is the case a naive
(embedding-norm (as-embedding e)) check cannot catch: as-embedding always
renormalises its OWN output to ~1.0, so measuring the norm of as-embedding's
result is a tautology regardless of e's actual stored norm -- it never fires.
Unlike the raw-T-vector legacy case (which the TYPE check alone catches),
this vector already passes the type check, so only a correct norm check on E
ITSELF (not on (as-embedding e)) catches it."
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (let ((non-unit (make-array 2 :element-type 'single-float
                                   :initial-contents '(2.0 0.0))))
      (let ((gdb:*graph* g))
        (gdb:with-transaction ()
          (funcall (v::chunk-constructor 'rag-chunk)
                   :text "non-unit" :document-id "doc-non-unit"
                   :metadata nil :embedding non-unit :graph g))))
    (let ((store (v:make-graph-store g :strategy :scan))
          (vertices '()))
      (v::map-chunk-vertices store (lambda (vx) (push vx vertices)))
      ;; Assert on the STORED SLOT directly via %slot, NOT on what
      ;; vertex->chunk returns -- vertex->chunk re-normalises on every read
      ;; and would show unit-norm either way, masking a broken migration
      ;; exactly the way it did before this was caught.
      (let ((e (v::%slot (first vertices) "EMBEDDING")))
        (is (typep e '(simple-array single-float (*))))
        (is (< (abs (- 1.0 (rag:embedding-norm e))) 1e-5)
            "already-single-float, non-unit-norm embedding was not migrated: norm ~a"
            (rag:embedding-norm e))))))

(test migrate-embeddings-is-a-noop-on-a-conforming-store
  "A store whose embeddings are already normalised single-float is left
alone: MIGRATE-EMBEDDINGS rewrites nothing and returns 0. Without this, a
future change that makes the tolerance too tight would silently rewrite
every vector on every open, forever, and nothing would notice."
  (with-temp-graph (g)
    (let* ((emb (rag:make-mock-embedder))
           (store (v:make-graph-store g :strategy :scan)))
      (rag:store-add store (list (mk-chunk emb "the TM-62 is an anti-tank mine" :doc "tm62")
                                 (mk-chunk emb "the PFM-1 is a butterfly mine" :doc "pfm1")))
      (is (= 0 (v::migrate-embeddings store))
          "a conforming store's embeddings were rewritten when they should not have been"))))
