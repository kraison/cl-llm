;;;; tests-rag-eval/suite.lisp

(in-package #:cl-llm.rag.eval.test)

(def-suite cl-llm-rag-eval-suite
  :description "Deterministic bundle scorers.")

(in-suite cl-llm-rag-eval-suite)

(defun %ev (doc-id &key (method :dense) (standing :indeterminate))
  (rag:make-evidence :chunk (rag:make-chunk (format nil "text-~a" doc-id)
                                            :document-id doc-id)
                     :score 1.0d0 :method method :standing standing))

(defun %bundle (doc-ids &key (modes '(:dense)))
  (rag:make-bundle :query "q"
                   :evidence (mapcar #'%ev doc-ids)
                   :modes modes))
