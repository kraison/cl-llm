;;;; rag-eval/golden.lisp -- capture-and-diff over a bundle's stable
;;;; projection.  Design: docs/superpowers/specs/2026-08-18-evidence-bundle-
;;;; design.md.

(in-package #:cl-llm.rag.eval)

(defun bundle-projection (bundle)
  "BUNDLE reduced to what is stable across runs: (DOCUMENT-ID METHOD
STANDING RANK) per item, in order.  Scores and text are deliberately absent
-- floats drift and would make the diff fail for reasons nobody cares about.
⚠ RANK duplicates list position on purpose -- do not drop it as redundant.
It is what keeps ordering checkable even if a later comparison sorts
before diffing."
  (loop for e in (rag:bundle-evidence bundle)
        for rank from 0
        collect (list (let ((c (rag:evidence-chunk e)))
                        (and c (rag:chunk-document-id c)))
                      (rag:evidence-method e)
                      (rag:evidence-standing e)
                      rank)))

(defun write-golden (bundle path)
  "Write BUNDLE's projection to PATH.  Called explicitly to (re)generate a
golden file; CHECK-GOLDEN never calls it."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-readably* nil) (*print-pretty* t))
        (print (bundle-projection bundle) out)
        (terpri out))))
  path)

(defun check-golden (bundle path)
  "Compare BUNDLE's projection against the golden file at PATH.
Two values: whether they match, and the first differing (expected actual)
pair.  ⚠ Never rewrites PATH -- a self-healing golden file proves nothing."
  (let ((expected (with-open-file (in path) (read in)))
        (actual (bundle-projection bundle)))
    (if (equal expected actual)
        (values t nil)
        ;; `loop for ... in' over two lists stops at the shorter one, so
        ;; a length mismatch (item added/dropped) would never surface an
        ;; element-level pair.  Walk to the longer length via NTH instead
        ;; -- O(n^2) but these lists are tens of items.
        (values nil
                (loop for i from 0 below (max (length expected)
                                              (length actual))
                      for e = (nth i expected)
                      for a = (nth i actual)
                      unless (equal e a) return (list e a)
                        finally (return (list expected actual)))))))
