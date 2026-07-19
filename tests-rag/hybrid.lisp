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

(test backfill-recovers-dense-missed-and-preserves-dense
  ;; dense ranks a,b,c ; sparse ranks x (dense-missed) then a. k=3, max-backfill=2.
  ;; -> dense top-(k-1)=[a b] then recovery x; dense's tail c is displaced, a/b keep order.
  (let* ((dense (%hits '("a" "b" "c")))
         (sparse (%hits '("x" "a")))
         (fused (rag:dense-preserving-fusion dense sparse 3 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (equal '("a" "b" "x") ids))
    ;; scores strictly descending with final position
    (is (apply #'> (mapcar #'rag:hit-score fused)))))

(test backfill-no-recovery-returns-dense-topk-unchanged
  ;; sparse overlaps dense entirely -> no dense-missed doc -> result IS dense's top-k (the RRF regression guard).
  (let* ((dense (%hits '("a" "b" "c" "d")))
         (sparse (%hits '("b" "a")))
         (fused (rag:dense-preserving-fusion dense sparse 3 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (equal '("a" "b" "c") ids))))

(test backfill-dedups-recoveries-by-document
  ;; two sparse hits are different chunks of the SAME dense-missed doc "x" -> ONE slot, its top chunk.
  (let* ((dense (%hits '("a" "b" "c")))
         (sparse (list (rag:make-hit (rag:make-chunk "chunk one of x" :document-id "x") 2d0)
                       (rag:make-hit (rag:make-chunk "chunk two of x" :document-id "x") 1d0)))
         (fused (rag:dense-preserving-fusion dense sparse 3 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (equal '("a" "b" "x") ids))
    (is (string= "chunk one of x" (rag:chunk-text (rag:hit-chunk (third fused)))))))

(test backfill-caps-at-max-backfill
  ;; three dense-missed docs, max-backfill 2, k 4 -> only top-2 recoveries; k never exceeded.
  (let* ((dense (%hits '("a" "b" "c" "d")))
         (sparse (%hits '("x" "y" "z")))
         (fused (rag:dense-preserving-fusion dense sparse 4 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (= 4 (length fused)))
    (is (equal '("a" "b" "x" "y") ids))))

(test backfill-max-backfill-zero-yields-dense-topk
  ;; max-backfill 0 disables backfill entirely: even a dense-missed sparse doc is NOT admitted;
  ;; result is exactly dense's top-k. (Boundary of the cap.)
  (let* ((dense (%hits '("a" "b" "c")))
         (sparse (%hits '("x" "y")))
         (fused (rag:dense-preserving-fusion dense sparse 3 :max-backfill 0))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (equal '("a" "b" "c") ids))))
