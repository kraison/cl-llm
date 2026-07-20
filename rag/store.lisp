;;;; rag/store.lisp -- the vector-store protocol and a brute-force memory store.

(in-package #:cl-llm.rag)

(defgeneric store-add (store chunks)
  (:documentation "Index CHUNKS (each carrying a non-nil EMBEDDING)."))
(defgeneric store-search (store query-vector k)
  (:documentation "Return up to K HITs, highest cosine first."))
(defgeneric store-count (store)
  (:documentation "How many chunks are indexed."))
(defgeneric save-store (store path)
  (:documentation "Persist STORE to PATH."))
(defgeneric store-delete-documents (store document-ids)
  (:documentation "Remove every indexed chunk whose DOCUMENT-ID is in DOCUMENT-IDS
(compared with EQUAL). Returns the number of chunks removed (0 if none matched --
deleting absent documents is a no-op, never an error).

This is the PRIMITIVE every store implements; STORE-DELETE-DOCUMENT is its
one-element case. Two reasons it is the primitive rather than a loop over the
singular:

  - Cost. A store's delete is a rebuild, so deleting n of m documents one at a
    time is O(n*m). Refreshing 3220 documents in a 23k-chunk store that way took
    ~2 hours against ~8 minutes for the same work as pure adds. Taking a SET of
    ids means one pass regardless of n.
  - One implementation per store. Singular and plural rebuilds that drift apart
    is exactly the kind of divergence that hides a data-integrity bug."))

(defgeneric store-delete-document (store document-id)
  (:documentation "Remove every indexed chunk whose DOCUMENT-ID matches (EQUAL).
Returns the number of chunks removed (0 if none matched -- deleting an absent
document is a no-op, never an error)."))

(defmethod store-delete-document (store document-id)
  "The one-element case of STORE-DELETE-DOCUMENTS, which is the primitive."
  (store-delete-documents store (list document-id)))

(defun %id-set (document-ids)
  "A hash-set of DOCUMENT-IDS for O(1) EQUAL membership during a delete scan."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (id document-ids set)
      (setf (gethash id set) t))))

(declaim (inline dot))
(defun dot (a b)
  "Dot product of two equal-length single-float vectors."
  (declare (type (simple-array single-float (*)) a b)
           (optimize (speed 3) (safety 1)))
  (let ((sum 0f0))
    (declare (type single-float sum))
    (dotimes (i (length a) sum)
      (incf sum (* (aref a i) (aref b i))))))

(defun cosine (a b)
  "Cosine similarity of two embedding vectors, 0 on a zero-norm vector.
Embeddings are L2-normalised at ingest (AS-EMBEDDING), so this is a plain dot
product -- no per-candidate norm recomputation, no sqrt."
  (declare (type (simple-array single-float (*)) a b))
  (if (or (zerop (length a)) (zerop (length b)))
      0f0
      (dot a b)))

;;; A bounded top-k collector.  The point is to never materialise a hit per
;;; corpus entry: at 1M chunks the old build-everything-then-stable-sort path
;;; conses 1M objects and sorts them to keep 5.  K is small, so a linear scan of
;;; the k-element buffer beats the bookkeeping of a real heap.
;;;
;;; Cost is O(k) per candidate once full (%TOP-K-WORST-INDEX rescans the buffer).
;;; That is the right trade at the k values we actually use -- production k is 8
;;; -- but K IS CALLER-SUPPLIED.  A real binary heap becomes worth its bookkeeping
;;; somewhere around k >= 64; past that, most candidates fail a single compare
;;; against the root instead of scanning k slots.  Revisit if a caller passes a
;;; large k, which today none does.
;;;
;;; Ordering is (score DESC, tiebreak ASC) -- the same total order as HIT<.  The
;;; tiebreak MUST be carried through eviction, not applied only at the end:
;;; scan and cache stores iterate in different orders, so an order-dependent
;;; eviction at the k-th boundary would make them disagree on a tie.

(defstruct (top-k (:constructor %make-top-k))
  (k 0 :type fixnum)
  (count 0 :type fixnum)
  (scores nil :type (or null (simple-array single-float (*))))
  (tiebreaks nil :type (or null simple-vector))
  (payloads nil :type (or null simple-vector)))

(defun top-k-collector (k)
  (%make-top-k :k k
               :scores (make-array (max k 1) :element-type 'single-float)
               :tiebreaks (make-array (max k 1) :initial-element "")
               :payloads (make-array (max k 1) :initial-element nil)))

(defun rank-before-p (s1 t1 s2 t2)
  "True when (S1,T1) ranks ahead of (S2,T2): higher score first, ties by
tiebreak ascending.  The same total order as HIT<."
  (declare (type single-float s1 s2))
  (cond ((> s1 s2) t)
        ((< s1 s2) nil)
        (t (string< t1 t2))))

(defun %top-k-worst-index (c)
  "Index of the slot that ranks LAST under RANK-BEFORE-P."
  (let ((scores (top-k-scores c))
        (tiebreaks (top-k-tiebreaks c))
        (worst 0))
    (declare (type (simple-array single-float (*)) scores))
    (dotimes (i (top-k-count c) worst)
      (when (rank-before-p (aref scores worst) (aref tiebreaks worst)
                           (aref scores i) (aref tiebreaks i))
        (setf worst i)))))

(defun collect-candidate (c score tiebreak payload)
  "Offer a candidate to the collector; keep it only if it outranks the current worst.
TIEBREAK is the candidate's document-id (or \"\" when it has none)."
  (declare (type single-float score))
  (let ((scores (top-k-scores c))
        (tiebreaks (top-k-tiebreaks c))
        (payloads (top-k-payloads c))
        (tb (or tiebreak "")))
    (cond ((< (top-k-count c) (top-k-k c))
           (setf (aref scores (top-k-count c)) score
                 (aref tiebreaks (top-k-count c)) tb
                 (aref payloads (top-k-count c)) payload)
           (incf (top-k-count c)))
          (t
           (let ((worst (%top-k-worst-index c)))
             (when (rank-before-p score tb
                                  (aref scores worst) (aref tiebreaks worst))
               (setf (aref scores worst) score
                     (aref tiebreaks worst) tb
                     (aref payloads worst) payload))))))
  c)

(defun collector-results (c)
  "The retained candidates as (score . payload) conses, best-ranked first."
  (let ((out '()))
    (dotimes (i (top-k-count c))
      (push (list (aref (top-k-scores c) i)
                  (aref (top-k-tiebreaks c) i)
                  (aref (top-k-payloads c) i))
            out))
    (mapcar (lambda (row) (cons (first row) (third row)))
            (sort out (lambda (a b)
                        (rank-before-p (first a) (second a)
                                       (first b) (second b)))))))

(defclass memory-store ()
  ((chunks :initform (make-array 0 :adjustable t :fill-pointer 0) :accessor store-chunks)
   (dimension :initform nil :accessor store-dimension))
  (:documentation "A flat in-memory vector of chunks; brute-force exact cosine.
CHUNKS is an ACCESSOR, not a bare reader, because a delete PUBLISHES a freshly
built replacement vector rather than rebuilding the live one in place -- see
STORE-DELETE-DOCUMENTS."))

(defun make-memory-store () (make-instance 'memory-store))

(defun check-dimension (store vector)
  "Enforce a single embedding dimension across a store; signal on mismatch."
  (let ((d (length vector)))
    (cond ((null (store-dimension store)) (setf (store-dimension store) d))
          ((/= d (store-dimension store))
           (error 'llm-rag-error
                  :message (format nil "embedding dimension ~a does not match the ~
                                        store's dimension ~a (indexing and querying ~
                                        must use the same embedding model)"
                                   d (store-dimension store)))))))

(defmethod store-add ((store memory-store) chunks)
  ;; Atomic per call: validate the ENTIRE batch first, then mutate the
  ;; store only if every chunk passed. This avoids leaving a partial add
  ;; behind when a chunk in the middle of the batch is bad -- a caller
  ;; that retries the same batch after fixing the offending chunk must
  ;; not find the earlier chunks already indexed (and double-indexed).
  (when chunks
    (let ((dimension (store-dimension store)))
      ;; Pass 1: check every chunk without touching the store. DIMENSION
      ;; starts as the store's existing dimension (if any); otherwise the
      ;; first chunk of this batch establishes it for the rest of the batch.
      (dolist (chunk chunks)
        (let ((e (chunk-embedding chunk)))
          (unless e
            (error 'llm-rag-error :message "cannot index a chunk with no embedding"))
          (let ((d (length e)))
            (if dimension
                (unless (= d dimension)
                  (error 'llm-rag-error
                         :message (format nil "embedding dimension ~a does not match the ~
                                               store's dimension ~a (indexing and querying ~
                                               must use the same embedding model)"
                                          d dimension)))
                (setf dimension d)))))
      ;; Pass 2: the whole batch is valid -- commit it. Coerce each chunk's
      ;; embedding through AS-EMBEDDING first, mirroring VALIDATE-CHUNKS on
      ;; the graph-backed store (vivace/store.lisp): COSINE/DOT now declare
      ;; (simple-array single-float (*)) on their arguments, so a raw
      ;; caller-supplied vector of the wrong float type (e.g. double-float)
      ;; would type-error inside STORE-SEARCH, far from this call and long
      ;; after the bad chunk was accepted here. AS-EMBEDDING already rejects
      ;; non-finite input; this only fixes up float type / normalisation.
      (dolist (chunk chunks)
        (setf (chunk-embedding chunk) (as-embedding (chunk-embedding chunk)))
        (vector-push-extend chunk (store-chunks store)))
      (when (null (store-dimension store))
        (setf (store-dimension store) dimension))))
  store)

(defmethod store-search ((store memory-store) query-vector k)
  (when (plusp (store-count store))
    (check-dimension store query-vector))
  ;; Bounded collection: one hit per SURVIVOR, not one per corpus entry.
  (let ((c (top-k-collector k)))
    (loop for chunk across (store-chunks store)
          do (collect-candidate c
                                (cosine query-vector (chunk-embedding chunk))
                                (or (chunk-document-id chunk) "")
                                chunk))
    (mapcar (lambda (pair) (make-hit (cdr pair) (car pair)))
            (collector-results c))))

(defmethod store-count ((store memory-store))
  (length (store-chunks store)))

(defmethod store-delete-documents ((store memory-store) document-ids)
  "Build the replacement vector, then PUBLISH it with a single SETF.

Never rebuild the live vector in place. STORE-COUNT and STORE-SEARCH read that
same vector, so the old truncate-then-refill (setf fill-pointer 0, then push the
survivors back) made any concurrent reader observe a partially refilled store --
and a rebuild interrupted part-way (a killed worker) left it truncated for real.
Both were seen in production: a mid-refresh sample reported 10,626 chunks against
a true 23,192, which reads exactly like catastrophic data loss and is not.

Copy-and-swap removes the window entirely: a reader either holds the old vector
(a consistent pre-delete snapshot) or reads the new one, never a half-built one."
  (let* ((chunks (store-chunks store))
         (ids (%id-set document-ids))
         (kept (remove-if (lambda (chunk)
                            (gethash (chunk-document-id chunk) ids))
                          chunks))
         (removed (- (length chunks) (length kept))))
    ;; Nothing matched: return without allocating or swapping, so an absent-id
    ;; delete leaves the store (and the vector's identity) completely untouched.
    (when (plusp removed)
      (let ((new (make-array (length kept) :adjustable t :fill-pointer (length kept))))
        (replace new kept)
        (setf (store-chunks store) new)))
    removed))

;;; Persistence: a readable s-expression with exact double-float round-trip.

(defmethod save-store ((store memory-store) path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*read-default-float-format* 'double-float))
        (prin1 (list :version 1
                     :chunks (map 'list
                                  (lambda (chunk)
                                    (list (chunk-text chunk)
                                          (chunk-document-id chunk)
                                          (chunk-metadata chunk)
                                          (coerce (chunk-embedding chunk) 'list)))
                                  (store-chunks store)))
               out))))
  store)

(defun load-store (path)
  "Load a memory-store previously written by SAVE-STORE."
  (let ((data (handler-case
                  (with-open-file (in path)
                    (with-standard-io-syntax
                      (let ((*read-default-float-format* 'double-float))
                        (read in))))
                (file-error (condition)
                  (error 'llm-rag-error
                         :message (format nil "could not load store from ~a: ~a"
                                          path condition)))))
        (store (make-memory-store)))
    (dolist (row (getf data :chunks) store)
      (destructuring-bind (text doc-id metadata embedding-list) row
        (store-add store
                   (list (make-chunk text :document-id doc-id :metadata metadata
                                          :embedding (as-embedding embedding-list))))))))
