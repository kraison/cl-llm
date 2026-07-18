;;;; vivace/store.lisp -- graph-backed vector stores.

(in-package #:cl-llm.rag.vivace)

(defclass graph-store ()
  ((graph :initarg :graph :reader graph-store-graph)
   (type :initarg :type :initform 'rag-chunk :reader graph-store-type)
   (dimension :initarg :dimension :initform nil :accessor graph-store-dimension))
  (:documentation "Abstract: borrows a caller-owned graph-db graph."))

(defclass scan-graph-store (graph-store) ()
  (:documentation "store-search scans the chunk vertices and computes cosine."))

(defgeneric hydrate (store)
  (:documentation "Initialise a store from chunk vertices already in the graph."))

(defun validate-chunks (store chunks)
  "Validate CHUNKS (non-nil embedding + consistent dimension) WITHOUT mutating
the graph. Returns the dimension the batch establishes. Signals rag:llm-rag-error."
  (let ((dim (graph-store-dimension store)))
    (dolist (chunk chunks)
      (let ((e (rag:chunk-embedding chunk)))
        (unless e
          (error 'rag:llm-rag-error :message "cannot index a chunk with no embedding"))
        (if dim
            (unless (= (length e) dim)
              (error 'rag:llm-rag-error
                     :message (format nil "embedding dimension ~a does not match the ~
                                           store's dimension ~a" (length e) dim)))
            (setf dim (length e)))))
    dim))

(defmethod rag:store-add ((store graph-store) chunks)
  (when chunks
    (let ((dim (validate-chunks store chunks))       ; validate BEFORE writing
          (graph (graph-store-graph store))
          (type (graph-store-type store)))
      (let ((gdb:*graph* graph))
        (gdb:with-transaction ()
          (dolist (chunk chunks)
            (chunk->vertex graph type chunk))))
      (when (null (graph-store-dimension store))
        (setf (graph-store-dimension store) dim))))
  store)

(defun map-chunk-vertices (store fn)
  "Call FN on each chunk vertex in STORE's graph."
  (gdb:map-vertices fn (graph-store-graph store)
                    :vertex-type (chunk-type-symbol (graph-store-type store))))

(defmethod rag:store-count ((store scan-graph-store))
  (let ((n 0))
    (map-chunk-vertices store (lambda (v) (declare (ignore v)) (incf n)))
    n))

(defmethod rag:store-search ((store scan-graph-store) query-vector k)
  (when (and (graph-store-dimension store)
             (/= (length query-vector) (graph-store-dimension store)))
    (error 'rag:llm-rag-error
           :message (format nil "query dimension ~a does not match store dimension ~a"
                            (length query-vector) (graph-store-dimension store))))
  (let ((hits '()))
    (map-chunk-vertices
     store
     (lambda (vertex)
       (let ((chunk (vertex->chunk vertex)))
         (push (rag:make-hit chunk (rag:cosine query-vector (rag:chunk-embedding chunk)))
               hits))))
    (subseq (sort hits #'> :key #'rag:hit-score) 0 (min k (length hits)))))

(defmethod hydrate ((store scan-graph-store))
  ;; Record the dimension from the first existing chunk, if any. Do NOT do a
  ;; non-local exit out of map-vertices (it may hold locks); iterate and set once.
  (unless (graph-store-dimension store)
    (map-chunk-vertices
     store
     (lambda (vertex)
       (unless (graph-store-dimension store)
         (setf (graph-store-dimension store)
               (length (rag:as-embedding (%slot vertex "EMBEDDING"))))))))
  store)

;; save-store is generic in cl-llm.rag; a graph is self-durable, so this is a
;; documented no-op that returns the store (never closes the borrowed graph).
;; Explicit checkpointing is the caller's (graph-db close-graph / snapshot).
(defmethod rag:save-store ((store graph-store) path)
  (declare (ignore path))
  store)

(defun make-graph-store (graph &key (type 'rag-chunk) (strategy :cache) dimension)
  "Make a graph-backed vector store over the already-open, caller-owned GRAPH.
STRATEGY is :cache (default) or :scan. Self-declares the chunk vertex type and
hydrates from any chunks already in the graph. Never opens or closes GRAPH."
  (ensure-chunk-schema graph type)
  (let ((store (ecase strategy
                 (:scan (make-instance 'scan-graph-store
                                       :graph graph :type type :dimension dimension))
                 (:cache (make-cached-graph-store graph type dimension)))))
    (hydrate store)
    store))

(defclass cached-graph-store (graph-store)
  ((index :initarg :index :reader cache-index))
  (:documentation "Composes a rag:memory-store as an in-RAM search index."))

(defun make-cached-graph-store (graph type dimension)
  (make-instance 'cached-graph-store
                 :graph graph :type type :dimension dimension
                 :index (rag:make-memory-store)))

;; store-add's primary method (on graph-store) validates + writes to the graph;
;; this :after mirrors the same chunks into the in-RAM index for search.
(defmethod rag:store-add :after ((store cached-graph-store) chunks)
  (when chunks
    (rag:store-add (cache-index store) chunks)))

(defmethod rag:store-count ((store cached-graph-store))
  (rag:store-count (cache-index store)))

(defmethod rag:store-search ((store cached-graph-store) query-vector k)
  (rag:store-search (cache-index store) query-vector k))

(defmethod hydrate ((store cached-graph-store))
  (let ((chunks '()))
    (map-chunk-vertices store (lambda (v) (push (vertex->chunk v) chunks)))
    (when chunks
      (rag:store-add (cache-index store) (nreverse chunks))
      ;; Sync the abstract dimension slot so the primary store-add's dimension
      ;; check (which runs BEFORE the graph write) validates post-hydrate adds
      ;; against the hydrated dimension -- otherwise a wrong-dimension chunk could
      ;; reach the graph before the cache's :after catches it.
      (setf (graph-store-dimension store) (rag:store-dimension (cache-index store)))))
  store)
