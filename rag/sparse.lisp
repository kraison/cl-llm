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
