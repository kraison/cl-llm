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
        (is (equalp emb (rag:chunk-embedding chunk)))
        ;; NOTE: this checks the specialised type, but is NOT load-bearing for
        ;; the RAG:AS-EMBEDDING coercion in VERTEX->CHUNK: EMB above is
        ;; already a (SIMPLE-ARRAY DOUBLE-FLOAT (*)), and this in-memory graph
        ;; hands back the identical Lisp object with no serialise/deserialise
        ;; step, so the coercion is a no-op here. See
        ;; VERTEX-TO-CHUNK-COERCES-GENERAL-VECTOR-EMBEDDING below for the test
        ;; that actually exercises the coercion (a non-specialised input
        ;; vector). This assertion still guards the value/provenance
        ;; round-trip -- kept for that reason. NOTE: uses TYPEP rather than
        ;; (EQUAL '(SIMPLE-ARRAY DOUBLE-FLOAT (*)) (TYPE-OF ...)) because
        ;; SBCL's TYPE-OF always reports a concrete array dimension (e.g.
        ;; (SIMPLE-ARRAY DOUBLE-FLOAT (3))), never the wildcard (*) -- so an
        ;; EQUAL comparison against the (*) literal can never pass for any
        ;; real array, coerced or not. TYPEP against the wildcard type is the
        ;; portable check, and matches the idiom already used throughout
        ;; tests-rag/embed.lisp.
        (is (typep (rag:chunk-embedding chunk) '(simple-array double-float (*))))))))

(test vertex-to-chunk-coerces-general-vector-embedding
  ;; The round-trip test above stores an already-specialised
  ;; (SIMPLE-ARRAY DOUBLE-FLOAT (*)) embedding, and the in-memory graph hands
  ;; that same Lisp object straight back out (no serialise/deserialise, no
  ;; close/reopen) -- so it never actually exercises VERTEX->CHUNK's
  ;; RAG:AS-EMBEDDING coercion. This test closes that gap without a
  ;; close/reopen cycle: it feeds CHUNK->VERTEX a general (element-type T)
  ;; simple vector -- NOT a (SIMPLE-ARRAY DOUBLE-FLOAT (*)) -- and confirms
  ;; graph-db's in-memory vertex slot stores and returns it faithfully
  ;; (unspecialised), so VERTEX->CHUNK's call to RAG:AS-EMBEDDING is what
  ;; specialises it back to (SIMPLE-ARRAY DOUBLE-FLOAT (*)). Remove the
  ;; RAG:AS-EMBEDDING call from VERTEX->CHUNK and this test fails.
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (let ((emb (make-array 3 :initial-contents '(0.1d0 0.2d0 0.3d0))))
      ;; Sanity-check the fixture itself: this must be a general T-vector,
      ;; not already the specialised type, or the test below proves nothing.
      (is (not (typep emb '(simple-array double-float (*)))))
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
             (chunk (v::vertex->chunk (first verts))))
        (is (= 1 (length verts)))
        (is (equalp emb (rag:chunk-embedding chunk)))
        (is (typep (rag:chunk-embedding chunk) '(simple-array double-float (*))))))))

(test ensure-chunk-schema-is-idempotent
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (v::ensure-chunk-schema g 'rag-chunk)   ; twice must not error
    (is (gdb:lookup-node-type-by-name (v::chunk-type-symbol 'rag-chunk) :vertex :graph g))))
