;;;; tests-rag-eval/golden.lisp

(in-package #:cl-llm.rag.eval.test)
(in-suite cl-llm-rag-eval-suite)

(defmacro with-temp-golden ((var) &body body)
  `(let ((,var (merge-pathnames (format nil "golden-~a.sexp" (random 100000))
                                #p"/tmp/")))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(test a-projection-omits-scores-and-text
  "⚠ Scores are floats and text is large; neither is a regression contract.
The projection is what stays stable across runs."
  (let ((p (re:bundle-projection (%bundle '("a" "b")))))
    (is (equal '(("a" :dense :indeterminate 0)
                 ("b" :dense :indeterminate 1))
               p))))

(test a-matching-bundle-passes-the-golden-file
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a" "b")) path)
    (is-true (re:check-golden (%bundle '("a" "b")) path))))

(test a-reordering-fails-the-golden-file
  "⚠ THE contract.  A comparison that sorted before diffing would pass this
and catch nothing."
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a" "b")) path)
    (is-false (re:check-golden (%bundle '("b" "a")) path))))

(test a-failed-check-does-not-rewrite-the-golden-file
  "⚠ A golden file that heals itself proves nothing.  Regeneration is
explicit, and this test exists so making it implicit is a visible change."
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a" "b")) path)
    (let ((before (uiop:read-file-string path)))
      (re:check-golden (%bundle '("b" "a")) path)
      (is (string= before (uiop:read-file-string path))))))
