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
(defgeneric store-delete-document (store document-id)
  (:documentation "Remove every indexed chunk whose DOCUMENT-ID matches (EQUAL).
Returns the number of chunks removed (0 if none matched -- deleting an absent
document is a no-op, never an error)."))

(defun cosine (a b)
  "Cosine similarity of two embedding vectors, 0 on a zero-norm vector."
  (let ((dot 0d0) (na 0d0) (nb 0d0))
    (loop for x across a for y across b
          do (incf dot (* x y)) (incf na (* x x)) (incf nb (* y y)))
    (if (or (zerop na) (zerop nb))
        0d0
        (/ dot (* (sqrt na) (sqrt nb))))))

(defclass memory-store ()
  ((chunks :initform (make-array 0 :adjustable t :fill-pointer 0) :reader store-chunks)
   (dimension :initform nil :accessor store-dimension))
  (:documentation "A flat in-memory vector of chunks; brute-force exact cosine."))

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
      ;; Pass 2: the whole batch is valid -- commit it.
      (dolist (chunk chunks)
        (vector-push-extend chunk (store-chunks store)))
      (when (null (store-dimension store))
        (setf (store-dimension store) dimension))))
  store)

(defun hit< (a b)
  "Deterministic ranking order: higher score first; ties broken by DOCUMENT-ID
so scan and cache strategies (which iterate chunks in different orders) agree
on an exact tie."
  (let ((sa (hit-score a)) (sb (hit-score b)))
    (cond ((> sa sb) t)
          ((< sa sb) nil)
          (t (string< (or (chunk-document-id (hit-chunk a)) "")
                      (or (chunk-document-id (hit-chunk b)) ""))))))

(defmethod store-search ((store memory-store) query-vector k)
  (when (plusp (store-count store))
    (check-dimension store query-vector))
  (let ((hits (loop for chunk across (store-chunks store)
                    collect (make-hit chunk (cosine query-vector (chunk-embedding chunk))))))
    (subseq (stable-sort hits #'hit<) 0 (min k (length hits)))))

(defmethod store-count ((store memory-store))
  (length (store-chunks store)))

(defmethod store-delete-document ((store memory-store) document-id)
  "Rebuild the backing vector in place, dropping chunks whose DOCUMENT-ID matches."
  (let* ((chunks (store-chunks store))
         (kept (remove document-id chunks :key #'chunk-document-id :test #'equal))
         (removed (- (length chunks) (length kept))))
    (setf (fill-pointer chunks) 0)
    (loop for c across kept do (vector-push-extend c chunks))
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
