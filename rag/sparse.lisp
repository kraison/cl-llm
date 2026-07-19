;;;; rag/sparse.lisp -- lexical (BM25) retrieval: a designation-preserving tokenizer, BM25 scoring,
;;;; and a sparse-store (in-RAM inverted index) complementing the dense stores.
(in-package #:cl-llm.rag)

(defun tokenize (text)
  "Lowercase TEXT -> tokens: maximal runs of alphanumeric chars (Unicode-aware via ALPHANUMERICP,
so Cyrillic counts) plus INTERNAL hyphens/slashes, so a designation like \"TM-62M\" stays ONE
token \"tm-62m\" (not \"tm\"/\"62m\") and \"det-cord\" stays whole.  Leading/trailing -/ are
stripped per token."
  (let ((tokens '()) (cur (make-string-output-stream)))
    (flet ((flush ()
             (let ((tok (string-trim "-/" (get-output-stream-string cur))))
               (when (plusp (length tok)) (push tok tokens)))))
      (loop for ch across (string-downcase (or text "")) do
        (if (or (alphanumericp ch) (char= ch #\-) (char= ch #\/))
            (write-char ch cur)
            (flush)))
      (flush))
    (nreverse tokens)))

(defparameter *bm25-k1* 1.2d0 "BM25 term-frequency saturation parameter.")
(defparameter *bm25-b* 0.75d0 "BM25 document-length normalization parameter.")

(defun bm25-idf (n df)
  "Okapi BM25 IDF for a term present in DF of N documents."
  (log (+ 1d0 (/ (+ (- n df) 0.5d0) (+ df 0.5d0)))))

(defun bm25-term-score (idf tf doc-len avgdl)
  "BM25 contribution of one query term: IDF * saturated tf with length normalization."
  (let ((k1 *bm25-k1*) (b *bm25-b*))
    (* idf (/ (* tf (+ k1 1d0))
              (+ tf (* k1 (+ (- 1d0 b) (* b (/ (float doc-len 1d0) avgdl)))))))))

(defclass sparse-store ()
  ((chunks :initform (make-array 0 :adjustable t :fill-pointer 0) :reader store-chunks)
   (postings :initform (make-hash-table :test 'equal) :reader %postings)   ; token -> list of (idx . tf)
   (doc-lengths :initform (make-array 0 :adjustable t :fill-pointer 0) :reader %doc-lengths)
   (total-length :initform 0 :accessor %total-length))
  (:documentation "In-RAM BM25 inverted index over chunk text; complements a dense store."))

(defun make-sparse-store () (make-instance 'sparse-store))

(defun %index-chunk (store chunk idx)
  (let ((tf (make-hash-table :test 'equal)) (n 0))
    (dolist (tok (tokenize (chunk-text chunk))) (incf (gethash tok tf 0)) (incf n))
    (maphash (lambda (tok f) (push (cons idx f) (gethash tok (%postings store)))) tf)
    (vector-push-extend n (%doc-lengths store))
    (incf (%total-length store) n)))

(defmethod store-add ((store sparse-store) chunks)
  (dolist (chunk chunks)
    (vector-push-extend chunk (store-chunks store))
    (%index-chunk store chunk (1- (fill-pointer (store-chunks store)))))
  store)

(defmethod store-count ((store sparse-store)) (length (store-chunks store)))

(defmethod store-delete-document ((store sparse-store) document-id)
  "Rebuild the index excluding chunks whose DOCUMENT-ID matches; return the count removed."
  (let* ((old (store-chunks store))
         (kept (remove document-id old :key #'chunk-document-id :test #'equal))
         (removed (- (length old) (length kept))))
    (setf (fill-pointer old) 0 (fill-pointer (%doc-lengths store)) 0 (%total-length store) 0)
    (clrhash (%postings store))
    (store-add store (coerce kept 'list))
    removed))

(defun %avgdl (store)
  (let ((n (store-count store))) (if (zerop n) 1d0 (/ (float (%total-length store) 1d0) n))))

(defgeneric sparse-search (store query-string k)
  (:documentation "Up to K HITs for QUERY-STRING by BM25, highest score first."))

(defmethod sparse-search ((store sparse-store) query-string k)
  (let ((n (store-count store)) (scores (make-hash-table :test 'eql)))
    (when (plusp n)
      (let ((avgdl (%avgdl store)) (lengths (%doc-lengths store)))
        (dolist (tok (remove-duplicates (tokenize query-string) :test #'equal))
          (let ((postings (gethash tok (%postings store))))
            (when postings
              (let ((idf (bm25-idf n (length postings))))
                (dolist (p postings)
                  (incf (gethash (car p) scores 0d0)
                        (bm25-term-score idf (cdr p) (aref lengths (car p)) avgdl)))))))))
    (let ((hits (loop for idx being the hash-keys of scores using (hash-value sc)
                      collect (make-hit (aref (store-chunks store) idx) sc))))
      (subseq (sort hits #'> :key #'hit-score) 0 (min k (length hits))))))
