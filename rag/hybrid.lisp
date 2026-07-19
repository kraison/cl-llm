;;;; rag/hybrid.lisp -- hybrid dense+sparse retrieval, fused by Reciprocal Rank Fusion.
(in-package #:cl-llm.rag)

(defparameter *rrf-k* 60 "Reciprocal Rank Fusion constant (standard 60).")

(defparameter *backfill-max* 2
  "Dense-preserving fusion: the maximum number of sparse-only recoveries (distinct documents) that
may fill reserved tail slots per query.")

(defun %chunk-key (chunk)
  "Fusion identity for a chunk: (document-id . text).  NOT EQ -- dense and sparse stores hold
DIFFERENT chunk objects for the same underlying slice (each vertex->chunk makes a new one)."
  (cons (chunk-document-id chunk) (chunk-text chunk)))

(defun reciprocal-rank-fusion (ranked-lists &key (k *rrf-k*))
  "Fuse RANKED-LISTS (each a ranked hit list) by RRF on (document-id . text); return one hit list
ordered by fused score.  A chunk's representative hit is taken from the FIRST list it appears in."
  (let ((fused (make-hash-table :test 'equal)))            ; key -> (cons rrf-score representative-hit)
    (dolist (hits ranked-lists)
      (loop for hit in hits for rank from 1
            for key = (%chunk-key (hit-chunk hit))
            for cell = (gethash key fused)
            do (if cell
                   (incf (car cell) (/ 1d0 (+ k rank)))
                   (setf (gethash key fused) (cons (/ 1d0 (+ k rank)) hit)))))
    (let ((merged (loop for cell being the hash-values of fused
                        collect (make-hit (hit-chunk (cdr cell)) (car cell)))))
      (sort merged #'> :key #'hit-score))))

(defclass hybrid-retriever ()
  ((embedder :initarg :embedder :reader retriever-embedder)
   (dense-store :initarg :dense-store :reader hybrid-dense-store)
   (sparse-store :initarg :sparse-store :reader hybrid-sparse-store)
   (candidate-k :initarg :candidate-k :initform 20 :reader hybrid-candidate-k)
   (fusion :initarg :fusion :initform :rrf :reader hybrid-fusion))
  (:documentation "Fuses dense (embedding cosine) + sparse (BM25) retrieval.  FUSION selects the
strategy: :rrf (Reciprocal Rank Fusion -- reorders by fused rank) or :backfill (dense-preserving --
keeps dense's order, sparse only recovers documents dense never surfaced)."))

(defun make-hybrid-retriever (&key embedder dense-store sparse-store (candidate-k 20) (fusion :rrf))
  (make-instance 'hybrid-retriever :embedder embedder :dense-store dense-store
                 :sparse-store sparse-store :candidate-k candidate-k :fusion fusion))

(defmethod retrieve ((r hybrid-retriever) query &key (k 5))
  (let* ((kc (max k (hybrid-candidate-k r)))
         (dense (store-search (hybrid-dense-store r) (embed (retriever-embedder r) query) kc))
         (sparse (sparse-search (hybrid-sparse-store r) query kc)))
    (ecase (hybrid-fusion r)
      (:rrf (let ((fused (reciprocal-rank-fusion (list dense sparse))))
              (subseq fused 0 (min k (length fused)))))
      (:backfill (dense-preserving-fusion dense sparse k :max-backfill *backfill-max*)))))

(defun dense-preserving-fusion (dense-hits sparse-hits k &key (max-backfill *backfill-max*))
  "Fuse by PRESERVING dense's ranking and only BACKFILLING documents dense never surfaced.
DENSE-HITS is dense's full candidate list (cosine order); SPARSE-HITS is BM25 order.  A document is
dense-missed iff none of its chunks appear anywhere in DENSE-HITS.  Up to MAX-BACKFILL dense-missed
documents -- deduped by document-id, in sparse rank order, each contributing its TOP sparse chunk --
fill the last slots; the first (k - n) hits are dense's, in dense order.  When no document qualifies
(n=0) the result is EXACTLY dense's top-k, unchanged.  Returned hits carry a synthetic descending
score monotonic with final position (dense cosine and sparse BM25 are incomparable scales, so native
scores are never mixed into one ranked list)."
  (let ((dense-docs (make-hash-table :test 'equal)))
    (dolist (h dense-hits)
      (setf (gethash (chunk-document-id (hit-chunk h)) dense-docs) t))
    (let ((recoveries '())
          (seen (make-hash-table :test 'equal)))
      (block collect
        (dolist (h sparse-hits)
          (when (>= (length recoveries) max-backfill) (return-from collect))
          (let ((doc (chunk-document-id (hit-chunk h))))
            (unless (or (gethash doc dense-docs) (gethash doc seen))
              (setf (gethash doc seen) t)
              (push h recoveries)))))
      (setf recoveries (nreverse recoveries))
      (let* ((n (min (length recoveries) k))
             (head (subseq dense-hits 0 (min (- k n) (length dense-hits))))
             (chosen (append head (subseq recoveries 0 n)))
             (total (length chosen)))
        (loop for h in chosen
              for i from 0
              collect (make-hit (hit-chunk h) (float (- total i) 1d0)))))))
