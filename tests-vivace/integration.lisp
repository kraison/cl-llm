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
                      ;; single-float, not double-float: RAG:AS-EMBEDDING has produced
                      ;; single-float unconditionally since Task 4.
                      (is (typep (rag:chunk-embedding (rag:hit-chunk hit))
                                 '(simple-array single-float (*))))))
               (gdb:close-graph g2))))
      (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t)))))

(test open-graph-store-reopens-in-a-fresh-image
  "REGRESSION: open-graph-store must declare the chunk vertex class BEFORE gdb:open-graph, so a
persisted store reopens in a FRESH image (a process restart) where the class is not defined yet.
persistent-reopen-and-hydrate above only exercises a SAME-image reopen (the class persists from
the first make-graph-store), so it never caught this.  Simulate a fresh image by undefining the
chunk class + constructor after close, then reopen via open-graph-store."
  (let ((dir (format nil "/tmp/cl-llm-vg-freshimg-~a/" (get-internal-real-time)))
        (emb (rag:make-mock-embedder))
        (tsym (intern "RAG-CHUNK" :graph-db))
        (ctor (intern "MAKE-RAG-CHUNK" :graph-db)))
    (unwind-protect
         (progn
           (let ((g (gdb:make-graph :cl-llm-vg-freshimg (pathname dir))))
             (rag:store-add (v:make-graph-store g :strategy :cache)
                            (list (rag:make-chunk "the TM-62 mine" :document-id "tm62"
                                   :embedding (rag:embed emb "the TM-62 mine"))))
             (gdb:close-graph g))
           ;; simulate a fresh image: the chunk class + constructor do not exist yet
           (when (find-class tsym nil) (setf (find-class tsym) nil))
           (when (fboundp ctor) (fmakunbound ctor))
           (is (null (find-class tsym nil)) "precondition: chunk class is undefined")
           ;; open-graph-store must re-declare the class before open, then hydrate from disk
           (let ((store (v:open-graph-store dir :name :cl-llm-vg-freshimg :strategy :cache)))
             (unwind-protect
                  (is (= 1 (rag:store-count store))
                      "a fresh-image reopen hydrates the persisted chunk")
               (gdb:close-graph (v:graph-store-graph store)))))
      ;; restore the class for any later test even if the reopen (regression) failed
      (ignore-errors (v:ensure-chunk-class 'rag-chunk :cl-llm-vg-freshimg))
      (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t)))))

(define-condition induced-migration-failure (error) ()
  (:documentation "A deliberately-signalled failure, used to simulate a migration that
dies partway through (OOM, kill, timeout) so the resumability test can observe what
survives."))

(defvar *induce-save-failure-on-call* nil
  "When bound to a positive integer N, the Nth call to GDB:SAVE (across all vertices,
counting from 1) signals INDUCED-MIGRATION-FAILURE instead of writing. NIL disables
the hook entirely (the default -- must never leak into other tests).")

(defvar *save-call-count* 0)

(defmethod gdb:save :around ((vertex gdb:vertex) &key (graph gdb:*graph*))
  (when *induce-save-failure-on-call*
    (incf *save-call-count*)
    (when (= *save-call-count* *induce-save-failure-on-call*)
      (error 'induced-migration-failure)))
  (call-next-method vertex :graph graph))

(test migrate-embeddings-resumes-after-a-partial-failure
  "The property batching exists for: if MIGRATE-EMBEDDINGS dies partway through (OOM,
kill, timeout -- simulated here by making the 3rd vertex's write signal), the batches
that already committed stay migrated -- durably, verified by closing and reopening the
graph, not just by the failed call's in-memory side effects -- and a subsequent
MIGRATE-EMBEDDINGS call finishes the rest and leaves the whole store conforming."
  (let ((dir (format nil "/tmp/cl-llm-vg-resume-~a/" (get-internal-real-time)))
        (name :cl-llm-vg-resume))
    (unwind-protect
         (progn
           ;; Write 5 legacy (unnormalised, boxed double-float) vertices to a REAL
           ;; persistent graph, then close it -- so the reopen below is a genuine disk
           ;; round-trip, not just continued in-process state.
           (let ((g (gdb:make-graph name (pathname dir))))
             (%insert-legacy-vertices g 5)
             (gdb:close-graph g))
           ;; Reopen, and rig the 3rd GDB:SAVE call (batch size 2: batch 1 is vertices
           ;; 1-2 and commits in full; batch 2 starts with vertex 3, whose SAVE is the
           ;; 3rd call overall and fails, rolling back all of batch 2 -- so exactly 2
           ;; victims end up durably migrated) to signal instead of writing.
           (let* ((g2 (gdb:open-graph name (pathname dir)))
                  (cl-llm.rag.vivace::*embedding-migration-batch-size* 2)
                  (*save-call-count* 0)
                  (*induce-save-failure-on-call* 3))
             (unwind-protect
                  (signals induced-migration-failure
                    (v:make-graph-store g2 :strategy :scan))
               (setf *induce-save-failure-on-call* nil)
               (gdb:close-graph g2)))
           ;; Reopen again (no induced failure this time) and confirm: (b) the batch
           ;; that already committed survived the crash durably, and the rest did not
           ;; get silently lost or corrupted -- exactly 2 of 5 are conforming before any
           ;; further migration runs.
           (let* ((g3 (gdb:open-graph name (pathname dir)))
                  (store3 (make-instance 'v:scan-graph-store :graph g3 :type 'rag-chunk))
                  (conforming 0))
             (unwind-protect
                  (progn
                    (v::map-chunk-vertices
                     store3
                     (lambda (vx)
                       (unless (v::%needs-migration-p (v::%slot vx "EMBEDDING"))
                         (incf conforming))))
                    (is (= 2 conforming)
                        "expected exactly the first committed batch (2 victims) to have \
survived the induced failure durably; got ~d" conforming)
                    ;; (c) a subsequent MIGRATE-EMBEDDINGS completes the remainder and
                    ;; leaves everything conforming.
                    (is (= 3 (v::migrate-embeddings store3))
                        "the resuming migration should only need to rewrite the 3 \
victims the failed run never reached")
                    (let ((remaining 0))
                      (v::map-chunk-vertices
                       store3
                       (lambda (vx)
                         (when (v::%needs-migration-p (v::%slot vx "EMBEDDING"))
                           (incf remaining))))
                      (is (= 0 remaining)
                          "the store must be fully conforming after the resuming migration")))
               (gdb:close-graph g3))))
      (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t)))))

(defun %refresh-chunk (emb doc-id text)
  (rag:make-chunk text :document-id doc-id :embedding (rag:embed emb text)))

(test delete-then-readd-survives-reopen
  "REGRESSION (issue #8): refresh a document -- delete by id, then re-add -- and assert the
count AFTER REOPENING THE STORE FROM DISK.

The pre-existing delete tests assert only in-memory state, which is exactly what hid the
production failure: the in-RAM index looked correct while the graph kept the stale chunk, so a
refreshed corpus silently GREW (+1 chunk per refreshed document) instead of being replaced.
The count only ever looked bigger, never wrong, and nothing signalled.  Only a reopen sees it."
  (let* ((dir (format nil "/tmp/cl-llm-vg-refresh-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder))
         (name :cl-llm-vg-refresh))
    (unwind-protect
         (progn
           ;; 1. initial ingest
           (let* ((g (gdb:make-graph name (pathname dir)))
                  (store (v:make-graph-store g :strategy :cache)))
             (rag:store-add store (list (%refresh-chunk emb "d1" "revision one")))
             (is (= 1 (rag:store-count store)))
             (gdb:close-graph g))
           ;; 2. refresh: delete by doc-id, then re-add the new revision
           (let ((store (v:open-graph-store dir :name name :strategy :cache)))
             (unwind-protect
                  (progn
                    (is (= 1 (rag:store-delete-document store "d1"))
                        "delete must report the victim it found")
                    (rag:store-add store (list (%refresh-chunk emb "d1" "revision two")))
                    (is (= 1 (rag:store-count store)) "in-memory: replaced, not duplicated"))
               (gdb:close-graph (v:graph-store-graph store))))
           ;; 3. the assertion that actually matters -- reopen from disk
           (let ((store (v:open-graph-store dir :name name :strategy :cache)))
             (unwind-protect
                  (progn
                    (is (= 1 (rag:store-count store))
                        "reopened store must hold ONE chunk; a stale survivor means the graph \
delete did not persist and the refresh DUPLICATED the document")
                    (let ((hit (first (rag:store-search store
                                                        (rag:embed emb "revision two") 1))))
                      (is (string= "revision two" (rag:chunk-text (rag:hit-chunk hit)))
                          "the survivor must be the REPLACEMENT, not the stale original")))
               (gdb:close-graph (v:graph-store-graph store)))))
      (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t)))))

(test bulk-delete-documents-survives-reopen
  "The bulk primitive on the graph store: one scan removes every id in the set, and the
removal persists across a reopen."
  (let* ((dir (format nil "/tmp/cl-llm-vg-bulk-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder))
         (name :cl-llm-vg-bulk))
    (unwind-protect
         (progn
           (let* ((g (gdb:make-graph name (pathname dir)))
                  (store (v:make-graph-store g :strategy :cache)))
             (rag:store-add store (list (%refresh-chunk emb "a" "alpha mine")
                                        (%refresh-chunk emb "b" "bravo mine")
                                        (%refresh-chunk emb "c" "charlie mine")))
             (is (= 3 (rag:store-count store)))
             (is (= 2 (rag:store-delete-documents store (list "a" "c")))
                 "one scan removes both ids")
             (is (= 1 (rag:store-count store)) "cache synced by the plural :after")
             (gdb:close-graph g))
           (let ((store (v:open-graph-store dir :name name :strategy :cache)))
             (unwind-protect
                  (progn
                    (is (= 1 (rag:store-count store)) "bulk delete persisted across reopen")
                    (let ((hit (first (rag:store-search store (rag:embed emb "bravo mine") 1))))
                      (is (string= "b" (rag:chunk-document-id (rag:hit-chunk hit))))))
               (gdb:close-graph (v:graph-store-graph store)))))
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
