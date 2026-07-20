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

;;; Write-side enforcement: VALIDATE-CHUNKS normalises every embedding via
;;; RAG:AS-EMBEDDING before it reaches CHUNK->VERTEX, so a chunk added via
;;; STORE-ADD after HYDRATE can never leave a non-conforming value on the
;;; EMBEDDING slot -- closing the gap where SCAN-GRAPH-STORE's STORE-SEARCH
;;; direct-slot (simple-array single-float (*)) declaration would otherwise
;;; TYPE-ERROR on exactly this vertex, at query time, far from the STORE-ADD
;;; call that wrote it.

(defun make-nan-single-float ()
  #+sbcl (sb-kernel:make-single-float #x7fc00000)
  #+ecl (coerce (ext:nan) 'single-float)
  #-(or sbcl ecl) (error "no portable NaN constructor for this Lisp implementation"))

(test scan-store-add-after-hydrate-normalises-raw-embedding
  "A chunk added via STORE-ADD after HYDRATE, with a raw un-normalised
double-float embedding, must (a) not signal, (b) leave a conforming
normalised (simple-array single-float (*)) on the STORED slot -- asserted
via %SLOT directly, not via VERTEX->CHUNK, which re-normalises on every read
and would mask a broken write the same way it would mask a broken
migration -- and (c) be searchable afterwards without a TYPE-ERROR. (c) is
the actual regression this guards: before write-side normalisation, this
exact vertex would blow up STORE-SEARCH's direct-slot scoring at query
time."
  (with-temp-graph (g)
    (let ((store (v:make-graph-store g :strategy :scan)))
      ;; HYDRATE has already run (inside MAKE-GRAPH-STORE, on an empty
      ;; graph); this STORE-ADD happens strictly after it and is never
      ;; touched by MIGRATE-EMBEDDINGS.
      (let ((raw (make-array 2 :element-type 'double-float
                                :initial-contents '(3.0d0 4.0d0))))
        (finishes
          (rag:store-add store (list (rag:make-chunk "legacy-write"
                                       :document-id "doc-raw"
                                       :embedding raw)))))
      (let ((vertices '()))
        (v::map-chunk-vertices store (lambda (vx) (push vx vertices)))
        (let* ((target (find "doc-raw" vertices
                             :key (lambda (vx) (v::%slot vx "DOCUMENT-ID"))
                             :test #'equal))
               (e (v::%slot target "EMBEDDING")))
          (is (typep e '(simple-array single-float (*)))
              "stored embedding was not coerced to single-float: ~S" (type-of e))
          (is (< (abs (- 1.0 (rag:embedding-norm e))) 1e-5)
              "stored embedding was not normalised: norm ~a" (rag:embedding-norm e))))
      ;; the actual bug: STORE-SEARCH must not TYPE-ERROR on this vertex.
      (let ((hits (finishes (rag:store-search store (rag:as-embedding '(1.0 0.0)) 5))))
        (is (= 1 (length hits)))
        (is (string= "doc-raw" (rag:chunk-document-id (rag:hit-chunk (first hits)))))))))

(test scan-store-add-rejects-nan-embedding-as-llm-rag-error
  "Write-side normalisation must still refuse genuinely bad input: a NaN
component signals RAG:LLM-RAG-ERROR specifically (not a bare arithmetic
error), confirming normalise-don't-reject did not start swallowing garbage."
  (with-temp-graph (g)
    (let ((store (v:make-graph-store g :strategy :scan)))
      (signals rag:llm-rag-error
        (rag:store-add store
                       (list (rag:make-chunk "bad" :document-id "doc-nan"
                              :embedding (list (make-nan-single-float) 3.0)))))
      (is (= 0 (rag:store-count store))))))

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

(defun %insert-legacy-vertices (g n)
  "Insert N legacy chunk vertices directly (raw, unnormalised, boxed double-float
T-vector embeddings -- bypassing all write-side normalisation), each with a
distinct DOCUMENT-ID, so MIGRATE-EMBEDDINGS has N victims to work through."
  (v::ensure-chunk-schema g 'rag-chunk)
  (let ((gdb:*graph* g))
    (gdb:with-transaction ()
      (dotimes (i n)
        (funcall (v::chunk-constructor 'rag-chunk)
                 :text (format nil "legacy-~d" i)
                 :document-id (format nil "doc-~d" i)
                 :metadata nil
                 :embedding (vector (coerce (1+ i) 'double-float) 0.0d0)
                 :graph g)))))

(test migrate-embeddings-batches-across-multiple-transactions
  "With a small batch size, MIGRATE-EMBEDDINGS still migrates EVERY victim and
returns the correct total count -- more victims than fit in one batch, so this
exercises more than one gdb:with-transaction. Without this, batching is
untested at more than one batch: a bug that dropped or double-counted victims
across batch boundaries would not be caught by the single-batch tests above."
  (with-temp-graph (g)
    (%insert-legacy-vertices g 5)
    (let ((cl-llm.rag.vivace::*embedding-migration-batch-size* 2)
          (store (make-instance 'v:scan-graph-store :graph g :type 'rag-chunk)))
      (is (= 5 (v::migrate-embeddings store))
          "batched migration did not report the full victim count")
      (let ((vertices '()))
        (v::map-chunk-vertices store (lambda (vx) (push vx vertices)))
        (is (= 5 (length vertices)))
        (dolist (vx vertices)
          (let ((e (v::%slot vx "EMBEDDING")))
            (is (typep e '(simple-array single-float (*)))
                "vertex ~a was not migrated: ~S" (v::%slot vx "DOCUMENT-ID") (type-of e))
            (is (< (abs (- 1.0 (rag:embedding-norm e))) 1e-5)
                "vertex ~a was not normalised" (v::%slot vx "DOCUMENT-ID"))))))))
