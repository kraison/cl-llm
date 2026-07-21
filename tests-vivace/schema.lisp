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

(test chunk-vertex-round-trips-with-coerced-embedding
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
        ;; EMB is already unit-norm (RAG:AS-EMBEDDING was applied to build it above),
        ;; and VERTEX->CHUNK re-normalises via RAG:AS-EMBEDDING on every read (kept
        ;; deliberately live -- see the comment on VERTEX->CHUNK in
        ;; vivace/schema.lisp). Re-normalising an already-unit vector is NOT
        ;; bit-exact idempotent: the norm computed the second time is a float close
        ;; to but not exactly 1.0, so dividing by it perturbs the last ~1 ULP of
        ;; each component. EQUALP is therefore the wrong check post-Task-4;
        ;; compare elementwise within a tolerance that comfortably covers a few ULP
        ;; of single-float drift.
        (is (every (lambda (a b) (< (abs (- a b)) 1e-6)) emb (rag:chunk-embedding chunk))
            "round-tripped embedding drifted beyond tolerance: ~S vs ~S"
            emb (rag:chunk-embedding chunk))
        ;; NOTE: this checks the specialised type, but is NOT load-bearing for
        ;; the RAG:AS-EMBEDDING coercion in VERTEX->CHUNK: EMB above is
        ;; already a (SIMPLE-ARRAY SINGLE-FLOAT (*)) (RAG:AS-EMBEDDING has
        ;; produced single-float since Task 4), and this in-memory graph
        ;; hands back the identical Lisp object with no serialise/deserialise
        ;; step, so the TYPE coercion is a no-op here (only the VALUE changes,
        ;; per the drift above). See
        ;; VERTEX-TO-CHUNK-COERCES-GENERAL-VECTOR-EMBEDDING below for the test
        ;; that actually exercises the coercion (a non-specialised input
        ;; vector). This assertion still guards the value/provenance
        ;; round-trip -- kept for that reason. NOTE: uses TYPEP rather than
        ;; (EQUAL '(SIMPLE-ARRAY SINGLE-FLOAT (*)) (TYPE-OF ...)) because
        ;; SBCL's TYPE-OF always reports a concrete array dimension (e.g.
        ;; (SIMPLE-ARRAY SINGLE-FLOAT (3))), never the wildcard (*) -- so an
        ;; EQUAL comparison against the (*) literal can never pass for any
        ;; real array, coerced or not. TYPEP against the wildcard type is the
        ;; portable check, and matches the idiom already used throughout
        ;; tests-rag/embed.lisp.
        (is (typep (rag:chunk-embedding chunk) '(simple-array single-float (*))))))))

(test vertex-to-chunk-coerces-general-vector-embedding
  ;; The round-trip test above stores an already-specialised
  ;; (SIMPLE-ARRAY SINGLE-FLOAT (*)) embedding, and the in-memory graph hands
  ;; that same Lisp object straight back out (no serialise/deserialise, no
  ;; close/reopen) -- so it never actually exercises VERTEX->CHUNK's
  ;; RAG:AS-EMBEDDING coercion. This test closes that gap without a
  ;; close/reopen cycle: it feeds CHUNK->VERTEX a general (element-type T)
  ;; simple vector -- NOT a (SIMPLE-ARRAY SINGLE-FLOAT (*)) -- and confirms
  ;; graph-db's in-memory vertex slot stores and returns it faithfully
  ;; (unspecialised), so VERTEX->CHUNK's call to RAG:AS-EMBEDDING is what
  ;; specialises it back to (SIMPLE-ARRAY SINGLE-FLOAT (*)). Remove the
  ;; RAG:AS-EMBEDDING call from VERTEX->CHUNK and this test fails.
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (let ((emb (make-array 3 :initial-contents '(0.1d0 0.2d0 0.3d0))))
      ;; Sanity-check the fixture itself: this must be a general T-vector,
      ;; not already the specialised type, or the test below proves nothing.
      (is (not (typep emb '(simple-array single-float (*)))))
      (let ((gdb:*graph* g))
        (gdb:with-transaction ()
          (v::chunk->vertex g 'rag-chunk
                            (rag:make-chunk "world"
                                            :document-id "doc2"
                                            :metadata '(:title "T2" :position 1)
                                            :embedding emb))))
      (let* ((verts (gdb:map-vertices (lambda (x) x) g
                                      :vertex-type (v::chunk-type-symbol 'rag-chunk)
                                      :collect-p t))
             (chunk (v::vertex->chunk (first verts)))
             (out (rag:chunk-embedding chunk)))
        (is (= 1 (length verts)))
        ;; EMB is raw and non-unit-norm; VERTEX->CHUNK L2-normalises it via
        ;; RAG:AS-EMBEDDING (Task 4), so OUT can never be bit-equal to EMB --
        ;; asserting EQUALP would be asserting a falsehood by design. What must
        ;; actually hold is the pair of properties normalisation is supposed to
        ;; guarantee, checked INDEPENDENTLY of the function under test (recomputing
        ;; the expectation with RAG:AS-EMBEDDING itself would trivially pass even if
        ;; normalisation were broken, since it would just compare a function to
        ;; itself):
        ;;   (a) OUT is unit-norm (within tolerance), and
        ;;   (b) OUT points in the SAME direction as EMB, i.e. every component's
        ;;       ratio to EMB's corresponding component is the same constant
        ;;       (within tolerance) -- OUT = k * EMB for some k > 0.
        ;; This is a STRONGER check than the original bit-equality assertion.
        (is (< (abs (- 1.0 (rag:embedding-norm out))) 1e-5)
            "coerced embedding is not unit-norm: ~S" out)
        (let* ((ratios (map 'list (lambda (o i) (/ o (coerce i 'single-float))) out emb))
               (k (first ratios)))
          (is (every (lambda (r) (< (abs (- r k)) 1e-5)) ratios)
              "coerced embedding is not proportional to the input: ratios ~S" ratios))
        (is (typep out '(simple-array single-float (*))))))))

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
