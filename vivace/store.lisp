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

(defparameter *embedding-migration-policy* :migrate
  "What HYDRATE does with stored embeddings that are not already normalised
single-float arrays.  :MIGRATE rewrites them in place (default).  :ERROR refuses
to open the store.  There is deliberately no :IGNORE -- scoring after Phase 1 is
a bare dot product, so an unnormalised stored vector ranks WRONG rather than
merely slow, and a silent wrong answer is the failure mode this guards.")

(defun %needs-migration-p (e)
  (or (not (typep e '(simple-array single-float (*))))
      (> (abs (- 1.0 (rag:embedding-norm (rag:as-embedding e)))) 1e-4)))

(defun migrate-embeddings (store)
  "Rewrite any stored embedding that is not already a normalised single-float
array.  Returns the number of chunks rewritten.  Collect victims first, then
write in one transaction -- do NOT mutate while map-vertices iterates."
  (let ((victims '()))
    (map-chunk-vertices
     store
     (lambda (vertex)
       (when (%needs-migration-p (%slot vertex "EMBEDDING"))
         (push vertex victims))))
    (when victims
      (ecase *embedding-migration-policy*
        (:error
         (error 'rag:llm-rag-error
                :message (format nil "~a stored embeddings are not normalised ~
                                      single-float vectors; scoring would rank ~
                                      them incorrectly. Re-embed, or set ~
                                      *embedding-migration-policy* to :migrate."
                                 (length victims))))
        (:migrate
         ;; Go through graph-db's copy-modify-save idiom (gdb:copy / gdb:save), NOT a raw
         ;; (setf (slot-value ...)) on the live vertex fetched by map-vertices: a bare slot-value
         ;; setf on an in-place node bypasses the transaction's write-set (populated only by
         ;; UPDATE-NODE, which SAVE calls), so it gets no OCC conflict validation and no
         ;; replication/txn-log participation, even though it happens to end up on disk via
         ;; close-graph's unconditional snapshot in the common single-writer case. COPY registers
         ;; a mutable copy with the current transaction; SAVE runs it through UPDATE-NODE like any
         ;; other write.
         (let ((gdb:*graph* (graph-store-graph store)))
           (gdb:with-transaction ()
             (dolist (v victims)
               (let ((c (gdb:copy v)))
                 (setf (slot-value c (intern "EMBEDDING" :graph-db))
                       (rag:as-embedding (%slot v "EMBEDDING")))
                 (gdb:save c))))))))
    (length victims)))

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

(defun graph-store-chunks (store)
  "All chunks currently in STORE's graph, as rag:chunk objects (for building a secondary index)."
  (let ((out '()))
    (map-chunk-vertices store (lambda (v) (push (vertex->chunk v) out)))
    (nreverse out)))

(defmethod rag:store-delete-document ((store graph-store) document-id)
  "Soft-delete every chunk vertex whose DOCUMENT-ID matches, atomically.
Collect the victims first (do NOT mutate the graph while map-vertices iterates),
then mark-deleted them in one transaction (mark-deleted joins the active tx)."
  (let ((victims '()))
    (map-chunk-vertices
     store
     (lambda (vertex)
       (when (equal (%slot vertex "DOCUMENT-ID") document-id)
         (push vertex victims))))
    (when victims
      (let ((gdb:*graph* (graph-store-graph store)))
        (gdb:with-transaction ()
          (dolist (v victims)
            (gdb:mark-deleted v)))))
    (length victims)))

(defmethod rag:store-count ((store scan-graph-store))
  (let ((n 0))
    (map-chunk-vertices store (lambda (v) (declare (ignore v)) (incf n)))
    n))

(defun hit< (a b)
  "Deterministic ranking order: higher score first; ties broken by DOCUMENT-ID.
Mirrors CL-LLM.RAG's memory-store comparator so scan and cache stores (which
iterate chunks in different orders) agree on an exact tie."
  (let ((sa (rag:hit-score a)) (sb (rag:hit-score b)))
    (cond ((> sa sb) t)
          ((< sa sb) nil)
          (t (string< (or (rag:chunk-document-id (rag:hit-chunk a)) "")
                      (or (rag:chunk-document-id (rag:hit-chunk b)) ""))))))

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
    (subseq (stable-sort hits #'hit<) 0 (min k (length hits)))))

(defmethod hydrate ((store scan-graph-store))
  (migrate-embeddings store)
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

;; keep the in-RAM index (which store-count/store-search read) in step with the graph delete
(defmethod rag:store-delete-document :after ((store cached-graph-store) document-id)
  (rag:store-delete-document (cache-index store) document-id))

(defmethod rag:store-count ((store cached-graph-store))
  (rag:store-count (cache-index store)))

(defmethod rag:store-search ((store cached-graph-store) query-vector k)
  (rag:store-search (cache-index store) query-vector k))

(defmethod hydrate ((store cached-graph-store))
  (migrate-embeddings store)
  (let ((chunks (graph-store-chunks store)))
    (when chunks
      (rag:store-add (cache-index store) chunks)
      ;; Sync the abstract dimension slot so the primary store-add's dimension
      ;; check (which runs BEFORE the graph write) validates post-hydrate adds
      ;; against the hydrated dimension -- otherwise a wrong-dimension chunk could
      ;; reach the graph before the cache's :after catches it.
      (setf (graph-store-dimension store) (rag:store-dimension (cache-index store)))))
  store)

(defun path->graph-name (path)
  "A stable keyword graph name derived from PATH's last directory component."
  (intern (string-upcase (car (last (pathname-directory (pathname path))))) :keyword))

(defun open-graph-store (path &key (strategy :cache) (type 'rag-chunk) dimension
                                   (name (path->graph-name path)))
  "Open a standalone persistent graph at PATH and return a store over it. For the
RAG-only case with no field-data graph to share. The caller owns closing the graph
(via graph-store-graph)."
  ;; Declare the chunk vertex class BEFORE gdb:open-graph: open-graph instantiates the persisted
  ;; chunks, which requires the class to exist.  make-graph-store's ensure-chunk-schema would
  ;; declare it -- but AFTER open, which is too late on a FRESH image (a restart), where the class
  ;; does not exist yet.  ensure-chunk-class is idempotent, so this is a no-op in a warm image.
  (ensure-chunk-class type name)
  (make-graph-store (gdb:open-graph name (pathname path))
                    :type type :strategy strategy :dimension dimension))
