;;;; rag-eval/scorers.lisp -- deterministic scoring of a retrieval bundle.
;;;; Design: docs/superpowers/specs/2026-08-18-evidence-bundle-design.md.

(in-package #:cl-llm.rag.eval)

(defun %bundle-doc-ids (bundle)
  (loop for e in (rag:bundle-evidence bundle)
        for chunk = (rag:evidence-chunk e)
        when chunk collect (rag:chunk-document-id chunk)))

(eval:defscorer bundle-recall-at-k (case bundle)
  "1.0 when every expected document id appears in BUNDLE, else 0.0."
  (let ((expected (eval:case-expected case)))
    (eval:score (if (and bundle
                         (every (lambda (id)
                                  (member id (%bundle-doc-ids bundle)
                                          :test #'equal))
                                expected))
                    1.0d0
                    0.0d0))))

(eval:defscorer bundle-containment (case bundle)
  "1.0 when every evidence item carries a real chunk with a document id.
An item that traces to nothing is a fabricated citation."
  (declare (ignore case))
  (eval:score (if (and bundle
                       (every (lambda (e)
                                (let ((c (rag:evidence-chunk e)))
                                  (and c (rag:chunk-document-id c))))
                              (rag:bundle-evidence bundle)))
                  1.0d0
                  0.0d0)))

(eval:defscorer bundle-standing-well-formed (case bundle)
  "1.0 when every evidence item's STANDING is a member of the vocabulary.
NIL fails: absence must carry a reason (cl-llm#13 unit 1)."
  (declare (ignore case))
  (eval:score (if (and bundle
                       (every (lambda (e)
                                (temporal-extent:standingp
                                 (rag:evidence-standing e)))
                              (rag:bundle-evidence bundle)))
                  1.0d0
                  0.0d0)))

(eval:defscorer bundle-method-attributed (case bundle)
  "1.0 when every evidence item names the mode that produced it."
  (declare (ignore case))
  (eval:score (if (and bundle
                       (every (lambda (e) (rag:evidence-method e))
                              (rag:bundle-evidence bundle)))
                  1.0d0
                  0.0d0)))
