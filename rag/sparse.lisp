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

(defun %empty-vec () (make-array 0 :adjustable t :fill-pointer 0))

(defstruct (sparse-index (:constructor %make-sparse-index))
  "The four correlated pieces of a BM25 index, held together so they can be PUBLISHED AS ONE.
POSTINGS maps token -> list of (chunk-index . term-frequency), and those indices address
CHUNKS, so the pieces are only meaningful as a set: swapping them into the store one slot at a
time would let a concurrent reader catch new CHUNKS against old POSTINGS and index OUT OF
BOUNDS -- not merely read stale data.  A delete therefore builds a whole new SPARSE-INDEX and
swaps it in with a single SETF."
  (chunks (%empty-vec))
  (postings (make-hash-table :test 'equal))    ; token -> list of (idx . tf)
  (doc-lengths (%empty-vec))
  (total-length 0))

(defclass sparse-store ()
  ((index :initform (%make-sparse-index) :accessor %index))
  (:documentation "In-RAM BM25 inverted index over chunk text; complements a dense store.
All index state lives in ONE slot so a rebuild is published atomically; every reader takes a
single snapshot of that slot and works from it."))

(defun make-sparse-store () (make-instance 'sparse-store))

(defmethod store-chunks ((store sparse-store))
  (sparse-index-chunks (%index store)))

(defun %index-chunk (index chunk idx)
  "Fold CHUNK, sitting at position IDX of INDEX's CHUNKS, into INDEX's postings."
  (let ((tf (make-hash-table :test 'equal)) (n 0))
    (dolist (tok (tokenize (chunk-text chunk))) (incf (gethash tok tf 0)) (incf n))
    (maphash (lambda (tok f) (push (cons idx f) (gethash tok (sparse-index-postings index)))) tf)
    (vector-push-extend n (sparse-index-doc-lengths index))
    (incf (sparse-index-total-length index) n)))

(defun %build-sparse-index (chunks)
  "A COMPLETE, freshly built SPARSE-INDEX over CHUNKS (a sequence).  Used by delete, which
publishes the result in one SETF rather than mutating the live index."
  (let ((index (%make-sparse-index)))
    (map nil
         (lambda (chunk)
           (vector-push-extend chunk (sparse-index-chunks index))
           (%index-chunk index chunk (1- (fill-pointer (sparse-index-chunks index)))))
         chunks)
    index))

(defmethod store-add ((store sparse-store) chunks)
  "Append to the CURRENT index in place.  Adds are append-only -- they never invalidate an
existing (idx . tf) posting -- so a reader mid-add sees a consistent prefix.  Copy-on-write
here would make every add O(n); only DELETE, which does invalidate indices, copies."
  (let ((index (%index store)))
    (dolist (chunk chunks)
      (vector-push-extend chunk (sparse-index-chunks index))
      (%index-chunk index chunk (1- (fill-pointer (sparse-index-chunks index))))))
  store)

(defmethod store-count ((store sparse-store))
  (length (sparse-index-chunks (%index store))))

(defmethod store-delete-documents ((store sparse-store) document-ids)
  "Build a whole new index over the survivors, then PUBLISH it with a single SETF.

The old version truncated CHUNKS and DOC-LENGTHS, zeroed TOTAL-LENGTH and CLRHASHed POSTINGS
before re-adding the survivors.  Because SPARSE-SEARCH resolves postings by indexing into
CHUNKS, a reader arriving mid-rebuild could index OUT OF BOUNDS, and an interrupted rebuild
left the index genuinely empty.  Rebuilding off to the side and swapping removes the window."
  (let* ((index (%index store))
         (old (sparse-index-chunks index))
         (ids (%id-set document-ids))
         (kept (remove-if (lambda (chunk) (gethash (chunk-document-id chunk) ids)) old))
         (removed (- (length old) (length kept))))
    (when (plusp removed)
      (setf (%index store) (%build-sparse-index kept)))
    removed))

(defun %avgdl (index)
  (let ((n (length (sparse-index-chunks index))))
    (if (zerop n) 1d0 (/ (float (sparse-index-total-length index) 1d0) n))))

(defgeneric sparse-search (store query-string k)
  (:documentation "Up to K HITs for QUERY-STRING by BM25, highest score first."))

(defmethod sparse-search ((store sparse-store) query-string k)
  ;; Take ONE snapshot of the index slot and read everything -- postings, lengths, chunks,
  ;; total-length -- from it.  That is what makes a search consistent: a delete publishing a
  ;; replacement index mid-search cannot make the postings' indices disagree with the chunks
  ;; vector they address (which is how the pre-swap version could index out of bounds).
  (let* ((index (%index store))
         (chunks (sparse-index-chunks index))
         (lengths (sparse-index-doc-lengths index))
         (postings-table (sparse-index-postings index))
         (n (length chunks))
         (scores (make-hash-table :test 'eql)))
    (when (plusp n)
      (let ((avgdl (%avgdl index)))
        (dolist (tok (remove-duplicates (tokenize query-string) :test #'equal))
          (let ((postings (gethash tok postings-table)))
            (when postings
              (let ((idf (bm25-idf n (length postings))))
                (dolist (p postings)
                  (incf (gethash (car p) scores 0d0)
                        (bm25-term-score idf (cdr p) (aref lengths (car p)) avgdl)))))))))
    (let ((hits (loop for idx being the hash-keys of scores using (hash-value sc)
                      collect (make-hit (aref chunks idx) sc))))
      (subseq (sort hits #'> :key #'hit-score) 0 (min k (length hits))))))
