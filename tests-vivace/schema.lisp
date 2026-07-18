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
        ;; The load-bearing coercion: back to the specialised type. NOTE: this
        ;; uses TYPEP rather than (EQUAL '(SIMPLE-ARRAY DOUBLE-FLOAT (*)) (TYPE-OF ...))
        ;; because SBCL's TYPE-OF always reports a concrete array dimension (e.g.
        ;; (SIMPLE-ARRAY DOUBLE-FLOAT (3))), never the wildcard (*) -- so an EQUAL
        ;; comparison against the (*) literal can never pass for any real array,
        ;; coerced or not. TYPEP against the wildcard type is the portable check,
        ;; and matches the idiom already used throughout tests-rag/embed.lisp.
        (is (typep (rag:chunk-embedding chunk) '(simple-array double-float (*))))))))

(test ensure-chunk-schema-is-idempotent
  (with-temp-graph (g)
    (v::ensure-chunk-schema g 'rag-chunk)
    (v::ensure-chunk-schema g 'rag-chunk)   ; twice must not error
    (is (gdb:lookup-node-type-by-name (v::chunk-type-symbol 'rag-chunk) :vertex :graph g))))
