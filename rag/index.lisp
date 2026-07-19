;;;; rag/index.lisp -- an index ties an embedder, a store, and a chunker together.

(in-package #:cl-llm.rag)

(defclass index (retriever)
  ((embedder :initarg :embedder :reader index-embedder)
   (store :initarg :store :reader index-store)
   (chunker :initarg :chunker :reader index-chunker))
  (:documentation "A retriever bundling an embedder, a vector-store, and a chunker."))

(defun make-index (&key embedder (store (make-memory-store)) (chunker #'split-text))
  "Make an INDEX. EMBEDDER is required -- there is no universal default embedding
endpoint. STORE defaults to a fresh memory-store; CHUNKER defaults to SPLIT-TEXT."
  (unless embedder
    (error 'llm-rag-error :message "make-index requires an :embedder"))
  (make-instance 'index :embedder embedder :store store :chunker chunker))

(defun document-chunks (document chunker)
  "Chunk DOCUMENT into CHUNKs carrying its provenance and each chunk's :position."
  (loop for (text . position) in (funcall chunker (document-text document))
        collect (make-chunk text
                            :document-id (document-id document)
                            :metadata (append (document-metadata document)
                                              (list :position position)))))

(defparameter *embed-batch* 128
  "Maximum chunks per EMBED request in ADD-DOCUMENTS.  Batches embedding so a very large document
cannot overflow the embedding server with one huge request (some servers 400 on a too-large batch,
e.g. Ollama's /embeddings on a ~900-chunk book).  A small corpus (chunks <= this) still embeds in
one call; only large docs split.  Tunable.")

(defun add-documents (index documents)
  "Chunk each document, embed all chunks (in batches of at most *EMBED-BATCH* to bound request
size), and store them.  Embedding is batched but the STORE-ADD is a single atomic write of the
whole chunk set, so a failure mid-embed stores nothing."
  (let ((chunks (loop for d in documents
                      nconc (document-chunks d (index-chunker index)))))
    (when chunks
      (let ((embedder (index-embedder index))
            (vectors '())
            (n (length chunks)))
        (loop for i from 0 below n by *embed-batch*
              for group = (subseq chunks i (min n (+ i *embed-batch*)))
              do (setf vectors (nconc vectors (embed embedder (mapcar #'chunk-text group)))))
        (loop for chunk in chunks for vector in vectors
              do (setf (chunk-embedding chunk) vector))
        (store-add (index-store index) chunks))))
  index)

(defmethod retrieve ((index index) query &key (k 5))
  (embed-and-search (index-embedder index) (index-store index) query k))

(defun save-index (index path)
  "Persist the index's store to PATH (the embedder is not serialized)."
  (save-store (index-store index) path)
  index)

(defun load-index (path embedder &key (chunker #'split-text))
  "Load an index: the store from PATH, with EMBEDDER reattached."
  (make-instance 'index :embedder embedder :store (load-store path) :chunker chunker))
