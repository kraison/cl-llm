;;;; rag/answer.lisp -- grounded answering over retrieved context.

(in-package #:cl-llm.rag)

(defvar *grounding-instructions*
  "Answer the question using ONLY the numbered sources provided below. Cite the
sources you use by their number, like [1]. If the answer is not supported by the
sources, say \"not in the provided sources\" and do not guess."
  "The default system prompt enforcing grounding, citation, and abstention.
Rebind to adjust the discipline; RAG-ASK always includes it.")

(defun source-title (hit)
  (or (getf (chunk-metadata (hit-chunk hit)) :title)
      (chunk-document-id (hit-chunk hit))
      "source"))

(defun assemble-context (hits)
  "Render HITS as a numbered, cited context block."
  (with-output-to-string (out)
    (loop for hit in hits for n from 1
          do (format out "[~a] (~a) ~a~%" n (source-title hit)
                     (chunk-text (hit-chunk hit))))))

(defun rag-ask (index question &key (k 5) (provider llm:*provider*) system)
  "Retrieve K passages for QUESTION, then ask the model to answer ONLY from them,
citing sources and abstaining when unsupported. A caller SYSTEM prompt is composed
WITH the grounding instructions, never in place of them. Returns (values answer hits)."
  (let* ((hits (retrieve index question :k k))
         (system-prompt (format nil "~a~@[~%~%~a~]" *grounding-instructions* system))
         (user-prompt (format nil "Sources:~%~a~%Question: ~a"
                              (assemble-context hits) question)))
    (values (llm:ask user-prompt :provider provider :system system-prompt)
            hits)))

(defun make-retrieval-tool (index &key (k 5))
  "Build a cl-llm tool that retrieves cited context from INDEX, for the agentic
path where the model decides whether to retrieve."
  (let ((spec '((query :type string))))
    (make-instance 'llm:tool
                   :name "retrieve-context"
                   :description "Retrieve relevant, cited passages from the knowledge base for a query."
                   :schema (cl-llm::derive-schema spec)
                   :parameter-names '("query")
                   :parameter-specs (mapcar #'cl-llm::parameter-spec-of (remove '&optional spec))
                   :function (lambda (query) (assemble-context (retrieve index query :k k))))))
