;;;; tests-vivace/schema.lisp

(in-package #:cl-llm.rag.vivace/tests)
(in-suite :cl-llm-rag-vivace)

(defun call-with-temp-memory-graph (fn)
  "Run FN on a fresh in-memory graph in a temp dir; clean up after."
  (let* ((dir (format nil "/tmp/cl-llm-vg-test-~a/" (get-internal-real-time)))
         (graph (gdb::make-memory-graph :cl-llm-vg-test (pathname dir))))
    (unwind-protect (funcall fn graph)
      (ignore-errors (gdb:close-graph graph))
      (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t)))))

(defmacro with-temp-graph ((g) &body body)
  `(call-with-temp-memory-graph (lambda (,g) ,@body)))

(defmacro with-temp-directory ((dir) &body body)
  "Bind DIR to a fresh, not-yet-existing directory pathname under /tmp for the
duration of BODY; delete it (recursively, if anything created it) afterward
regardless of how BODY exits. This only reserves a path -- callers that need an
on-disk graph there still create it themselves (e.g. via gdb:make-graph, which
creates the directory), matching the persistent-graph test idiom used elsewhere
in tests-vivace/ (see tests-vivace/integration.lisp)."
  `(let ((,dir (pathname (format nil "/tmp/cl-llm-vg-test-~a-~a/"
                                 (get-internal-real-time) (random 1000000)))))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,dir :validate t
                                                        :if-does-not-exist :ignore)))))

(defun test-chunk (text dim value)
  "A rag:chunk whose embedding is DIM copies of VALUE (pre-normalisation)."
  (rag:make-chunk text
                  :document-id text
                  :embedding (make-array dim :element-type 'single-float
                                             :initial-element (coerce value 'single-float))))

(test chunk-vertex-round-trips-embedding-exactly
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (let ((emb (rag:as-embedding '(0.1d0 0.2d0 0.3d0))))
      (let ((gdb:*graph* g))
        (gdb:with-transaction ()
          (v::chunk->vertex g 'rag-chunk
                            (rag:make-chunk "hello"
                                            :document-id "doc1"
                                            :metadata '(:title "T" :position 0)
                                            :embedding emb))))
      (let* ((verts (gdb:map-vertices (lambda (x) x) g
                                      :vertex-type (v::chunk-type-symbol 'rag-chunk)
                                      :collect-p t))
             (chunk (v::vertex->chunk (first verts))))
        (is (= 1 (length verts)))
        (is (string= "hello" (rag:chunk-text chunk)))
        (is (string= "doc1" (rag:chunk-document-id chunk)))
        (is (equal '(:title "T" :position 0) (rag:chunk-metadata chunk)))
        ;; KEPT AND TIGHTENED (Task 7).  This test previously asserted only a
        ;; 1e-6 tolerance, because VERTEX->CHUNK re-normalised via
        ;; RAG:AS-EMBEDDING on every read and re-normalising an already-unit
        ;; vector is not bit-exact idempotent (the norm computed the second time
        ;; is close to but not exactly 1.0, so the divide perturbs the last ~1
        ;; ULP of each component).  That coercion is gone -- VERTEX->CHUNK reads
        ;; the slot directly -- so the drift it documented no longer exists and
        ;; the assertion becomes BIT-EXACT equality.  That is strictly stronger,
        ;; and it is what pins the removal: put the RAG:AS-EMBEDDING call back
        ;; and this fails on the ULP drift.  Hence updated rather than deleted.
        (is (plusp (length (rag:chunk-embedding chunk)))
            "round-tripped embedding is empty: ~S" (rag:chunk-embedding chunk))
        (is (equalp emb (rag:chunk-embedding chunk))
            "round-tripped embedding is not bit-identical: ~S vs ~S"
            emb (rag:chunk-embedding chunk))
        ;; NOTE: this checks the specialised type, which under the current
        ;; contract is the WRITE side's doing (VALIDATE-CHUNKS), not the read
        ;; side's -- see STORE-ADD-NORMALISES-NON-CONFORMING-EMBEDDING below for
        ;; the test that exercises non-conforming input end to end. Here EMB is
        ;; already a (SIMPLE-ARRAY SINGLE-FLOAT (*)) and the in-memory graph
        ;; hands back the identical Lisp object, so this guards the
        ;; value/provenance round-trip. NOTE: uses TYPEP rather than
        ;; (EQUAL '(SIMPLE-ARRAY SINGLE-FLOAT (*)) (TYPE-OF ...)) because
        ;; SBCL's TYPE-OF always reports a concrete array dimension (e.g.
        ;; (SIMPLE-ARRAY SINGLE-FLOAT (3))), never the wildcard (*) -- so an
        ;; EQUAL comparison against the (*) literal can never pass for any
        ;; real array, coerced or not. TYPEP against the wildcard type is the
        ;; portable check, and matches the idiom already used throughout
        ;; tests-rag/embed.lisp.
        (is (typep (rag:chunk-embedding chunk) '(simple-array single-float (*))))))))

(test store-add-normalises-non-conforming-embedding
  "WRITE-SIDE ENFORCEMENT, end to end: a chunk whose embedding is neither a
(SIMPLE-ARRAY SINGLE-FLOAT (*)) nor unit-norm, added through the ordinary
RAG:STORE-ADD path, must land in the vertex's EMBEDDING slot already coerced and
normalised.

This test replaces VERTEX-TO-CHUNK-COERCES-GENERAL-VECTOR-EMBEDDING, which
exercised the RAG:AS-EMBEDDING call VERTEX->CHUNK used to make on every read.
That call is gone (Task 7); VALIDATE-CHUNKS (vivace/store.lisp) now normalises in
place BEFORE CHUNK->VERTEX ever sees the value, so the property that used to be
restored on the way OUT is enforced on the way IN.  This is the only coverage of
non-conforming input in the suite, which is why it was repurposed rather than
deleted.

It asserts against the RAW VERTEX SLOT (V::%SLOT), not against VERTEX->CHUNK's
output: VERTEX->CHUNK is now a plain slot read, so going through it would prove
nothing extra, while the slot is the thing STORE-SEARCH scores under a
(SIMPLE-ARRAY SINGLE-FLOAT (*)) declaration.

Makes VALIDATE-CHUNKS skip normalisation and this test fails on the type
assertion (verified as Task 7's sabotage proof).

Uses the DEFAULT strategy deliberately -- no :STRATEGY argument -- so it also
covers the write path under the new :segment default."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-writeside dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph))
           ;; A general (element-type T) vector of DOUBLE-FLOATs, non-unit-norm:
           ;; non-conforming on both counts.  RAW keeps the original values for
           ;; the direction check, since STORE-ADD normalises the chunk IN PLACE.
           (emb (make-array 3 :initial-contents '(0.1d0 0.2d0 0.3d0)))
           (raw (copy-seq emb)))
      (unwind-protect
           (progn
             ;; Sanity-check the fixture: if it were already conforming the test
             ;; below would prove nothing.
             (is (not (typep emb '(simple-array single-float (*))))
                 "fixture is already conforming: ~S" (type-of emb))
             (is (> (abs (- 1.0 (sqrt (reduce #'+ (map 'list (lambda (x) (* x x)) emb)))))
                    0.1)
                 "fixture is already ~~unit-norm, so normalisation would be invisible: ~S"
                 emb)
             (rag:store-add store (list (rag:make-chunk "world"
                                                        :document-id "doc2"
                                                        :metadata '(:title "T2")
                                                        :embedding emb)))
             (let ((verts (gdb:map-vertices (lambda (x) x) graph
                                            :vertex-type (v::chunk-type-symbol 'rag-chunk)
                                            :collect-p t)))
               (is (= 1 (length verts)) "expected exactly 1 chunk vertex, got ~D"
                   (length verts))
               (when (= 1 (length verts))
                 (let ((out (v::%slot (first verts) "EMBEDDING")))
                   (is (not (null out)) "EMBEDDING slot is NIL")
                   (is (typep out '(simple-array single-float (*)))
                       "stored embedding was not coerced: type ~S" (type-of out))
                   (when (typep out '(simple-array single-float (*)))
                     (is (= 3 (length out)) "stored embedding has length ~D" (length out))
                     ;; The two properties normalisation must give, checked
                     ;; INDEPENDENTLY of RAG:AS-EMBEDDING (recomputing the
                     ;; expectation with the function under test would pass even
                     ;; if it were broken):
                     ;;   (a) unit-norm, and
                     ;;   (b) same direction as the input -- every component's
                     ;;       ratio to the raw input is the same constant.
                     (is (< (abs (- 1.0 (rag:embedding-norm out))) 1e-5)
                         "stored embedding is not unit-norm: ~S" out)
                     (let* ((ratios (map 'list
                                         (lambda (o i) (/ o (coerce i 'single-float)))
                                         out raw))
                            (k (first ratios)))
                       (is (and (plusp k)
                                (every (lambda (r) (< (abs (- r k)) 1e-5)) ratios))
                           "stored embedding is not a positive multiple of the input: ~S"
                           ratios)))))))
        (gdb:close-graph graph :snapshot-p nil)))))

(test ensure-chunk-schema-is-idempotent
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (v::ensure-chunk-schema g 'rag-chunk)   ; twice must not error
    (is (gdb:lookup-node-type-by-name (v::chunk-type-symbol 'rag-chunk) :vertex :graph g))))

;;; Vector-index declaration on the EMBEDDING slot (Task 2 of the :segment store
;;; strategy plan). ENSURE-CHUNK-CLASS's DEF-VERTEX form declares EMBEDDING
;;; :VECTOR-INDEX T; graph-db's apply path then maintains a dense-vector segment
;;; for it automatically -- no parallel write path, no cache to invalidate. This
;;; is the single piece of write-side mechanism later tasks (segment-graph-store,
;;; store-search) build on; without it they are inert.

(test chunk-class-declares-embedding-vector-indexed
  "The EMBEDDING slot carries :vector-index, which is what makes the apply path
maintain a segment for it.  Without this declaration every later task in this
step is inert -- store-add would write vertices and no segment would exist."
  (let ((graph-name :vector-index-decl-test))
    (v::ensure-chunk-class 'rag-chunk graph-name)
    (let ((slots (gdb::node-vector-index-slots
                  (find-class (v::chunk-type-symbol 'rag-chunk)))))
      (is (member (intern "EMBEDDING" :graph-db) slots)
          "EMBEDDING is not vector-indexed; declared slots were ~S" slots))))

(test store-add-populates-the-segment
  "End-to-end proof the declaration is live: adding chunks through the ordinary
store-add path makes the segment hold them, with no explicit indexing call.

Builds the on-disk graph with GDB:MAKE-GRAPH (not V:OPEN-GRAPH-STORE) and
attaches a store with V:MAKE-GRAPH-STORE: V:OPEN-GRAPH-STORE calls
GDB:OPEN-GRAPH, which mmaps heap.dat with :CREATE-P NIL and errors on a
directory that was never GDB:MAKE-GRAPH'd -- confirmed by hand against a fresh
WITH-TEMP-DIRECTORY path (\"mmap-file: ... does not exist and create-p is not
true\"). GDB:MAKE-GRAPH + V:MAKE-GRAPH-STORE is the same first-open idiom
examples/rag-vivace.lisp and tests-vivace/integration.lisp already use;
V:OPEN-GRAPH-STORE is for REOPENING a graph a prior GDB:MAKE-GRAPH created."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-vecidx-add dir))
           (store (v:make-graph-store graph :strategy :scan :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0)
                                        (test-chunk "b" 8 2.0)))
             (let ((seg (gethash (cons (v::chunk-type-symbol 'rag-chunk)
                                       (intern "EMBEDDING" :graph-db))
                                 (gdb::vector-segments (v:graph-store-graph store)))))
               (is (not (null seg)) "no segment was created by store-add")
               (when seg
                 (is (= 2 (gdb::segment-live-count seg))
                     "expected 2 vectors in the segment, got ~D"
                     (gdb::segment-live-count seg)))))
        (gdb:close-graph (v:graph-store-graph store) :snapshot-p nil)))))

(test existing-store-reopens-after-declaration
  "Backward compatibility is a hard requirement: a persisted store must open and
read correctly under the new declaration.

See STORE-ADD-POPULATES-THE-SEGMENT above for why the first phase uses
GDB:MAKE-GRAPH + V:MAKE-GRAPH-STORE rather than V:OPEN-GRAPH-STORE; the second
phase reopens via V:OPEN-GRAPH-STORE, the same reopen path exercised by
TESTS-VIVACE/INTEGRATION.LISP's PERSISTENT-REOPEN-AND-HYDRATE."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-vecidx-reopen dir))
           (store (v:make-graph-store graph :strategy :scan :dimension 8)))
      (rag:store-add store (list (test-chunk "a" 8 1.0) (test-chunk "b" 8 2.0)))
      (gdb:close-graph graph :snapshot-p nil))
    (let ((store (v:open-graph-store (namestring dir) :name :cl-llm-vg-vecidx-reopen
                                                        :strategy :scan :dimension 8)))
      (unwind-protect
           (is (= 2 (rag:store-count store))
               "reopened store lost chunks: count ~D" (rag:store-count store))
        (gdb:close-graph (v:graph-store-graph store) :snapshot-p nil)))))
