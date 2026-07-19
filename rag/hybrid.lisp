;;;; rag/hybrid.lisp -- hybrid dense+sparse retrieval, fused by Reciprocal Rank Fusion.
(in-package #:cl-llm.rag)

(defparameter *rrf-k* 60 "Reciprocal Rank Fusion constant (standard 60).")

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
   (candidate-k :initarg :candidate-k :initform 20 :reader hybrid-candidate-k))
  (:documentation "Fuses dense (embedding cosine) + sparse (BM25) retrieval via RRF."))

(defun make-hybrid-retriever (&key embedder dense-store sparse-store (candidate-k 20))
  (make-instance 'hybrid-retriever :embedder embedder :dense-store dense-store
                 :sparse-store sparse-store :candidate-k candidate-k))

(defmethod retrieve ((r hybrid-retriever) query &key (k 5))
  (let* ((kc (max k (hybrid-candidate-k r)))
         (dense (store-search (hybrid-dense-store r) (embed (retriever-embedder r) query) kc))
         (sparse (sparse-search (hybrid-sparse-store r) query kc))
         (fused (reciprocal-rank-fusion (list dense sparse))))
    (subseq fused 0 (min k (length fused)))))
