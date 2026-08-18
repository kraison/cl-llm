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

(defun %fuse-fixture-sources ()
  "Five chunks over dense + sparse stores, real sources -- not the
%BUNDLE fixture.  FUSE's RRF ordering over these is empirically (A E B D
C), not the alphabetical (A B C D E) a document-id-sort regression would
produce, so the two are guaranteed to diverge (verified by direct probe,
not assumed -- see the golden fixture below, generated from this exact
function by an unmodified FUSE)."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store))
         (sparse-store (rag:make-sparse-store))
         (chunks
           (list (rag:make-chunk "alpha mine" :document-id "a"
                                 :embedding (rag:embed embedder "alpha"))
                 (rag:make-chunk "beta mine" :document-id "b"
                                :embedding (rag:embed embedder "beta"))
                 (rag:make-chunk "gamma mine" :document-id "c"
                                :embedding (rag:embed embedder "gamma"))
                 (rag:make-chunk "delta mine" :document-id "d"
                                :embedding (rag:embed embedder "delta"))
                 (rag:make-chunk "epsilon mine" :document-id "e"
                                :embedding (rag:embed embedder "epsilon")))))
    (rag:store-add dense-store chunks)
    (rag:store-add sparse-store chunks)
    (list (rag:make-dense-source embedder dense-store)
          (rag:make-sparse-source sparse-store))))

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
turns this RED, because the fixture's order (A E B D C) is not
alphabetical; reverting FUSE turns it back GREEN. No committed golden
file existed for FUSE's own output before this test."
  (let ((sources (%fuse-fixture-sources)))
    (is-true (re:check-golden (rag:fuse sources "mine" :k 5)
                              (%fuse-golden-fixture-path)))))
