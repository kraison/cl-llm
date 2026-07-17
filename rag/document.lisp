;;;; rag/document.lisp -- documents, chunks, hits (provenance is structural).

(in-package #:cl-llm.rag)

(defstruct (document (:constructor %make-document (id text metadata)))
  "A source unit. METADATA is a plist (conventionally :title :source :language)."
  (id nil)
  (text "" :type string)
  (metadata nil :type list))

(defun make-document (text &key id metadata)
  (%make-document id text metadata))

(defstruct (chunk (:constructor %make-chunk (text document-id metadata embedding)))
  "A retrievable slice carrying its parent document's provenance plus :position.
EMBEDDING is an EMBEDDING vector once indexed, or NIL."
  (text "" :type string)
  (document-id nil)
  (metadata nil :type list)
  (embedding nil))

(defun make-chunk (text &key document-id metadata embedding)
  (%make-chunk text document-id metadata embedding))

(defstruct (hit (:constructor make-hit (chunk score)))
  "One retrieval result: a CHUNK and its similarity SCORE."
  (chunk nil)
  (score 0d0 :type double-float))
