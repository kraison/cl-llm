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

(test a-longer-actual-reports-the-added-item-as-the-divergence
  "⚠ LOOP FOR ... IN stops at the shorter list, so a naive walk would
never see this pair -- the outer EQUAL still catches the mismatch, but
the diagnostic would silently degrade to the two whole lists."
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a")) path)
    (multiple-value-bind (ok-p div)
        (re:check-golden (%bundle '("a" "b")) path)
      (is-false ok-p)
      (is (equal (list nil '("b" :dense :indeterminate 1)) div)))))

(test a-shorter-actual-reports-the-missing-item-as-the-divergence
  "⚠ The other direction -- an item dropped, not added.  A fix that
handles only the longer-actual case would still pass that test alone."
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a" "b")) path)
    (multiple-value-bind (ok-p div)
        (re:check-golden (%bundle '("a")) path)
      (is-false ok-p)
      (is (equal (list '("b" :dense :indeterminate 1) nil) div)))))

(defun %fuse-golden-fixture-path ()
  "The COMMITTED golden fixture for %FUSE-FIXTURE-SOURCES, generated
once by WRITE-GOLDEN against an unmodified FUSE. Deliberately NOT
regenerated inside the test below -- a test that wrote and checked its
own golden file in the same run would only prove FUSE deterministic
against itself, which is exactly the gap this fixture exists to close
(see A-REAL-FUSE-BUNDLE-MATCHES-ITS-COMMITTED-GOLDEN's docstring)."
  (merge-pathnames "fixtures/fuse-mine.golden"
                   (asdf:component-pathname
                    (asdf:find-system :cl-llm/rag/eval/tests))))

(test a-real-fuse-bundle-matches-its-committed-golden
  "⚠ THE seam this test file was missing. Every other test here drives
WRITE-GOLDEN/CHECK-GOLDEN against the hand-built %BUNDLE fixture, never
against FUSE's real output, and a same-run write-then-check of FUSE's
own output would only show FUSE agrees with itself -- it would pass
just as happily if FUSE were ablated to always sort by document id,
since both the write and the check would then be sorted the same way.
The COMMITTED fixture (fixtures/fuse-mine.golden, generated once from an
unmodified FUSE) is what makes this a real regression check: a FRESH
FUSE run over %FUSE-FIXTURE-SOURCES must still match evidence captured
before this test existed. Ablating FUSE to SORT its evidence by
document id (verified by hand: temporarily wrapping the EVIDENCE list
in FUSE with (SORT ... #'STRING< :KEY (lambda (e) ...document-id...)))
turns this RED, because the fixture's order (G E F A B C D) is not
alphabetical; reverting FUSE turns it back GREEN. No committed golden
file existed for FUSE's own output before this test.

⚠ C1, cl-llm#13: an earlier version of %FUSE-FIXTURE-SOURCES embedded
only each chunk's distinguishing word, so every dense cosine against
\"mine\" was exactly 0.0 and every BM25 score was exactly equal -- the
fixture measured tiebreaking (document-id order), not ranking, and a
document-id-sort ablation was the ONLY thing it could catch.  Changing
*RRF-K* from 60 to 10 left the order unchanged, proof the fixture was
degenerate.  The rebuilt fixture (suite.lisp) makes every dense cosine
and every BM25 score pairwise distinct, so this DISTINCT-SCORES check
below can never silently regress back to that; and *RRF-K* 60->10 now
DOES change the fused order (verified by hand: f and a swap), which is
the stronger ablation this test could not have passed before."
  (let* ((sources (%fuse-fixture-sources))
         (bundle (rag:fuse sources "mine" :k 7))
         (scores (mapcar #'rag:evidence-score (rag:bundle-evidence bundle))))
    (is (= (length scores) (length (remove-duplicates scores :test #'=))))
    (is-true (re:check-golden bundle (%fuse-golden-fixture-path)))))
