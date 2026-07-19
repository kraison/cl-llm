;;;; tests-vivace/store-cache.lisp

(in-package #:cl-llm.rag.vivace/tests)
(in-suite :cl-llm-rag-vivace)

(defparameter *corpus*
  '(("tm62"  . "the TM-62 is a Soviet anti-tank blast mine with a pressure fuze")
    ("pfm1"  . "the PFM-1 is a small scatterable butterfly anti-personnel mine")
    ("ozm72" . "the OZM-72 is a bounding fragmentation mine")))

(defun load-corpus (store embedder)
  (rag:store-add store
                 (loop for (doc . text) in *corpus*
                       collect (rag:make-chunk text :document-id doc
                                               :embedding (rag:embed embedder text)))))

(test cached-store-add-search-count
  (with-temp-graph (g)
    (let ((emb (rag:make-mock-embedder))
          (store (v:make-graph-store g :strategy :cache)))
      (load-corpus store emb)
      (is (= 3 (rag:store-count store)))
      (let ((hits (rag:store-search store (rag:embed emb "anti-tank mine") 1)))
        (is (string= "tm62" (rag:chunk-document-id (rag:hit-chunk (first hits)))))))))

(test scan-and-cache-return-identical-rankings
  "The load-bearing invariant: strategy is invisible through the contract."
  (let ((emb (rag:make-mock-embedder))
        (queries '("anti-tank mine" "butterfly" "fragmentation bounding")))
    (flet ((rankings (strategy)
             (with-temp-graph (g)
               (let ((store (v:make-graph-store g :strategy strategy)))
                 (load-corpus store emb)
                 (loop for q in queries
                       collect (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
                                       (rag:store-search store (rag:embed emb q) 3)))))))
      (is (equal (rankings :scan) (rankings :cache))))))

(test scan-and-cache-agree-on-tied-scores
  "Exact-tie parity: two chunks with IDENTICAL embeddings (so store-search
must break the tie itself) must rank identically for the scan strategy (live
graph scan, in the graph's own vertex iteration order) and the cache strategy
(hydrated from the graph into insertion order), regardless of what order the
graph itself happens to yield its vertices in. Populating the graph once via
a writer store and then opening two FRESH strategy views on top of it (rather
than two independent single-batch STORE-ADD calls) is what actually exercises
the divergence: within one STORE-ADD batch, SCAN-GRAPH-STORE's PUSH-based
collection and the graph's own traversal order happen to cancel out, masking
the bug; hydrating a cache view from an already-populated graph does not get
that accidental cancellation."
  (let* ((emb (rag:make-mock-embedder))
         (shared-embedding (rag:embed emb "anti-tank blast mine")))
    (with-temp-graph (g)
      ;; Populate the graph once, directly, with two exactly-tied chunks.
      (let ((writer (v:make-graph-store g :strategy :scan)))
        (rag:store-add writer
                       (list (rag:make-chunk "tied chunk b" :document-id "tie-b"
                                              :embedding shared-embedding)
                             (rag:make-chunk "tied chunk a" :document-id "tie-a"
                                              :embedding shared-embedding))))
      ;; Open independent fresh views of the SAME graph under each strategy.
      (let ((scan-view (v:make-graph-store g :strategy :scan))
            (cache-view (v:make-graph-store g :strategy :cache)))
        (flet ((ids (store k)
                 (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
                         (rag:store-search store shared-embedding k))))
          (is (equal (ids scan-view 1) (ids cache-view 1)))
          (is (equal (ids scan-view 2) (ids cache-view 2))))))))

(test cache-store-delete-syncs-cache-and-graph
  (let* ((dir (format nil "/tmp/cl-llm-vg-del-cache-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (let* ((g (gdb:make-graph :cl-llm-vg-del-cache (pathname dir)))
                (store (v:make-graph-store g :strategy :cache)))
           (rag:store-add store (list (rag:make-chunk "a1" :document-id "A"
                                        :embedding (rag:embed emb "a1"))
                                      (rag:make-chunk "b1" :document-id "B"
                                        :embedding (rag:embed emb "b1"))))
           (is (= 2 (rag:store-count store)))
           (is (= 1 (rag:store-delete-document store "A")))
           (is (= 1 (rag:store-count store)) "cache count reflects the delete")   ; :after synced RAM index
           ;; a FRESH store over the same graph hydrates without the deleted doc -> graph delete stuck
           (let ((store2 (v:make-graph-store g :strategy :cache)))
             (is (= 1 (rag:store-count store2)))
             (is (string= "B" (rag:chunk-document-id
                               (rag:hit-chunk (first (rag:store-search store2 (rag:embed emb "b1") 5)))))))
           (gdb:close-graph g))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))

(test cache-store-delete-then-readd-no-resurrection
  "The resurrection-critical invariant: soft-deleted chunks must never be
double-counted or come back to life when a document with the same id is
re-added with different content. If STORE-DELETE-DOCUMENT's :after cache sync
(or the graph's own soft-delete + hydrate exclusion) ever regressed, the old
A1/A2 chunks would still be indexed alongside the new chunk and STORE-COUNT
would read 3, not 1 -- and a fresh hydrate over the same graph would leak the
old text back into search results."
  (let* ((dir (format nil "/tmp/cl-llm-vg-del-readd-cache-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (let* ((g (gdb:make-graph :cl-llm-vg-del-readd-cache (pathname dir)))
                (store (v:make-graph-store g :strategy :cache)))
           (rag:store-add store (list (rag:make-chunk "a1 original" :document-id "A"
                                        :embedding (rag:embed emb "a1 original"))
                                      (rag:make-chunk "a2 original" :document-id "A"
                                        :embedding (rag:embed emb "a2 original"))))
           (is (= 2 (rag:store-count store)))
           (is (= 2 (rag:store-delete-document store "A")))
           (is (= 0 (rag:store-count store)))
           ;; re-add the SAME document-id "A" with DIFFERENT text and only ONE chunk
           (rag:store-add store (list (rag:make-chunk "a3 replacement text" :document-id "A"
                                        :embedding (rag:embed emb "a3 replacement text"))))
           (is (= 1 (rag:store-count store))
               "old soft-deleted A chunks must not be resurrected or double-counted")
           ;; a FRESH store over the SAME still-open graph must hydrate to the
           ;; same count and only ever see the new live chunk's text -- the old
           ;; soft-deleted chunks stay invisible to hydrate.
           (let* ((store2 (v:make-graph-store g :strategy :cache))
                  (hits (rag:store-search store2 (rag:embed emb "a3 replacement text") 5)))
             (is (= 1 (rag:store-count store2)))
             (is (= 1 (length hits)))
             (is (string= "a3 replacement text" (rag:chunk-text (rag:hit-chunk (first hits))))))
           (gdb:close-graph g))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))

(test graph-store-chunks-returns-all
  (let* ((dir (format nil "/tmp/cl-llm-vg-gsc-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (let* ((g (gdb:make-graph :cl-llm-vg-gsc (pathname dir)))
                (store (v:make-graph-store g :strategy :cache)))
           (rag:store-add store (list (rag:make-chunk "a" :document-id "d1" :embedding (rag:embed emb "a"))
                                      (rag:make-chunk "b" :document-id "d2" :embedding (rag:embed emb "b"))))
           (is (= 2 (length (v:graph-store-chunks store))))
           (gdb:close-graph g))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))
