;;;; tests-vivace/integration.lisp

(in-package #:cl-llm.rag.vivace/tests)
(in-suite :cl-llm-rag-vivace)

(test persistent-reopen-and-hydrate
  "A chunk survives close/reopen (serializer round-trip); a new store over the
reopened graph hydrates from it."
  (let* ((dir (format nil "/tmp/cl-llm-vg-persist-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (progn
           ;; Write via a persistent graph, then close (snapshots to disk).
           (let* ((g (gdb:make-graph :cl-llm-vg-persist (pathname dir)))
                  (store (v:make-graph-store g :strategy :scan)))
             (rag:store-add store
                            (list (rag:make-chunk "the TM-62 mine" :document-id "tm62"
                                   :embedding (rag:embed emb "the TM-62 mine"))))
             (is (= 1 (rag:store-count store)))
             (gdb:close-graph g))
           ;; Reopen and attach a fresh store -- it must hydrate + retrieve.
           (let* ((g2 (gdb:open-graph :cl-llm-vg-persist (pathname dir)))
                  (store2 (v:make-graph-store g2 :strategy :cache)))
             (unwind-protect
                  (progn
                    (is (= 1 (rag:store-count store2)))          ; hydrated
                    (let ((hit (first (rag:store-search store2 (rag:embed emb "TM-62") 1))))
                      (is (string= "tm62" (rag:chunk-document-id (rag:hit-chunk hit))))
                      ;; Load-bearing: after a real disk reopen the slot deserializes
                      ;; to a T-vector, so this passes only because vertex->chunk
                      ;; coerces via rag:as-embedding. Use typep, NOT (type-of ...):
                      ;; SBCL's type-of reports a concrete dimension, never (*).
                      (is (typep (rag:chunk-embedding (rag:hit-chunk hit))
                                 '(simple-array double-float (*))))))
               (gdb:close-graph g2))))
      (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t)))))

(test graph-store-drops-into-the-rag-pipeline
  "make-index :store (make-graph-store g) -> add-documents -> rag-ask (mock)."
  (with-temp-graph (g)
    (let* ((emb (rag:make-mock-embedder))
           (index (rag:make-index :embedder emb :store (v:make-graph-store g :strategy :cache)))
           (provider (llm:make-mock-provider
                      :responder (lambda (conv) (declare (ignore conv))
                                   "The TM-62 uses a pressure fuze [1]."))))
      (rag:add-documents index
        (list (rag:make-document "The TM-62 is an anti-tank blast mine with a pressure fuze."
                                 :id "tm62" :metadata '(:title "TM-62"))))
      (multiple-value-bind (answer hits) (rag:rag-ask index "What fuze?" :provider provider)
        (is (search "pressure" answer))
        (is (plusp (length hits)))
        (is (string= "tm62" (rag:chunk-document-id (rag:hit-chunk (first hits)))))))))
