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
  (dolist (chunk chunks)
    (let ((e (chunk-embedding chunk)))
      (unless e
        (error 'llm-rag-error :message "cannot index a chunk with no embedding"))
      (check-dimension store e)
      (vector-push-extend chunk (store-chunks store))))
  store)

(defmethod store-search ((store memory-store) query-vector k)
  (when (plusp (store-count store))
    (check-dimension store query-vector))
  (let ((hits (loop for chunk across (store-chunks store)
                    collect (make-hit chunk (cosine query-vector (chunk-embedding chunk))))))
    (subseq (sort hits #'> :key #'hit-score) 0 (min k (length hits)))))

(defmethod store-count ((store memory-store))
  (length (store-chunks store)))

;;; Persistence: a readable s-expression with exact double-float round-trip.

(defmethod save-store ((store memory-store) path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*read-default-float-format* 'double-float))
        (prin1 (list :version 1
                     :dimension (store-dimension store)
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
  (let ((data (with-open-file (in path)
                (with-standard-io-syntax
                  (let ((*read-default-float-format* 'double-float))
                    (read in)))))
        (store (make-memory-store)))
    (dolist (row (getf data :chunks) store)
      (destructuring-bind (text doc-id metadata embedding-list) row
        (store-add store
                   (list (make-chunk text :document-id doc-id :metadata metadata
                                          :embedding (as-embedding embedding-list))))))))
