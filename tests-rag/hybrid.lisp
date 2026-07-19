;;;; tests-rag/hybrid.lisp

(in-package #:cl-llm.rag.test)
(in-suite cl-llm-rag-suite)

(defun %hits (docids)   ; make a ranked hit list from doc-ids (score unused by RRF)
  (loop for id in docids for s downfrom 1.0d0
        collect (rag:make-hit (rag:make-chunk (format nil "text-~A" id) :document-id id) s)))

(test rrf-surfaces-sparse-only-doc
  ;; dense ranks a,b,c ; sparse ranks x (dense missed x entirely) -> x must enter the fused top-k
  (let* ((dense (%hits '("a" "b" "c")))
         (sparse (%hits '("x" "a")))
         (fused (rag:reciprocal-rank-fusion (list dense sparse)))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (member "x" ids :test #'string=))                    ; the recall win
    (is (string= "a" (first ids)))))                         ; a is in both -> top

(test hybrid-retriever-recalls-exact-designation
  ;; a mock embedder makes dense USELESS for the designation (all cosine ~equal), but sparse
  ;; recalls the exact-designation doc; hybrid must return it.
  (let* ((emb (rag:make-mock-embedder :dimension 8))
         (chunks (list (rag:make-chunk "the TM-62M anti-tank mine" :document-id "tm62m"
                                       :embedding (rag:embed emb "the TM-62M anti-tank mine"))
                       (rag:make-chunk "general safety notes" :document-id "notes"
                                       :embedding (rag:embed emb "general safety notes"))))
         (dense (rag:make-memory-store))
         (sparse (rag:make-sparse-store)))
    (rag:store-add dense chunks) (rag:store-add sparse chunks)
    (let* ((r (rag:make-hybrid-retriever :embedder emb :dense-store dense :sparse-store sparse))
           (hits (rag:retrieve r "TM-62M" :k 2))
           (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) hits)))
      (is (member "tm62m" ids :test #'string=)))))
