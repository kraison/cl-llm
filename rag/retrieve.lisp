;;;; rag/retrieve.lisp -- the retriever protocol and dense retrieval.

(in-package #:cl-llm.rag)

(defgeneric retrieve (retriever query &key k)
  (:documentation "Return up to K HITs for QUERY, most relevant first."))

(defun embed-and-search (embedder store query k)
  "Embed QUERY and search STORE. Shared by dense-retriever and index."
  (store-search store (embed embedder query) k))

(defclass retriever () ()
  (:documentation "Abstract: maps a query to ranked HITs."))

(defclass dense-retriever (retriever)
  ((embedder :initarg :embedder :reader retriever-embedder)
   (store :initarg :store :reader retriever-store))
  (:documentation "Dense retrieval: embed the query, cosine-search the store."))

(defun make-dense-retriever (embedder store)
  (make-instance 'dense-retriever :embedder embedder :store store))

(defmethod retrieve ((retriever dense-retriever) query &key (k 5))
  (embed-and-search (retriever-embedder retriever) (retriever-store retriever) query k))
