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
