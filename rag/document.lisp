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
  "One retrieval result: a CHUNK and its similarity SCORE.
SCORE's float type varies by producer: dense retrieval (COSINE) now yields
SINGLE-FLOAT, while BM25 (sparse.lisp) and RRF/backfill fusion (hybrid.lisp)
yield DOUBLE-FLOAT -- so the slot accepts either rather than picking one."
  (chunk nil)
  ;; :type FLOAT, not SINGLE-FLOAT -- do not tighten this. SCORE is produced
  ;; by three different call sites with three different float types: COSINE
  ;; (store.lisp) yields SINGLE-FLOAT; BM25 term scoring (sparse.lisp) and
  ;; RRF/backfill fusion (hybrid.lisp) both build on 1d0/0.5d0 literals and
  ;; yield DOUBLE-FLOAT. Narrowing to SINGLE-FLOAT would break sparse and
  ;; hybrid retrieval -- a regression no dense-only test would catch.
  (score 0d0 :type float))
