;;;; tests-rag-eval/scorers.lisp

(in-package #:cl-llm.rag.eval.test)
(in-suite cl-llm-rag-eval-suite)

(test recall-at-k-distinguishes-a-hit-from-a-miss
  (let ((case (eval:make-case "q" :expected '("b"))))
    (is (= 1.0d0 (eval:score-value
                  (re:bundle-recall-at-k case (%bundle '("a" "b" "c"))))))
    (is (= 0.0d0 (eval:score-value
                  (re:bundle-recall-at-k case (%bundle '("a" "c"))))))))

(test recall-at-k-signals-on-a-case-with-no-expected
  "⚠ A dataset/harness mistake -- an eval case nobody populated -- must
signal, not silently score 1.0d0 (EVERY over NIL expected is vacuously
true).  Same principle as EXACT-MATCH (eval/scorer.lisp)."
  (let ((case (eval:make-case "q")))
    (signals eval:llm-eval-error
      (re:bundle-recall-at-k case (%bundle '("a"))))))

(test containment-catches-evidence-with-no-real-chunk
  "⚠ A fabricated citation must be catchable deterministically, not merely
instructed against."
  (let* ((case (eval:make-case "q" :expected '("a")))
         (good (%bundle '("a")))
         (bad (rag:make-bundle
               :query "q"
               :evidence (list (rag:make-evidence :chunk nil :score 1.0d0
                                                  :method :dense
                                                  :standing :indeterminate))
               :modes '(:dense))))
    (is (= 1.0d0 (eval:score-value (re:bundle-containment case good))))
    (is (= 0.0d0 (eval:score-value (re:bundle-containment case bad))))))

(test containment-catches-a-chunk-with-no-document-id
  "⚠ The other half of the guard: a chunk that EXISTS but carries no
document id is just as fabricated as no chunk at all."
  (let* ((case (eval:make-case "q" :expected '("a")))
         (bad (rag:make-bundle
               :query "q"
               :evidence (list (rag:make-evidence
                                :chunk (rag:make-chunk "text"
                                                       :document-id nil)
                                :score 1.0d0 :method :dense
                                :standing :indeterminate))
               :modes '(:dense))))
    (is (= 0.0d0 (eval:score-value (re:bundle-containment case bad))))))

(test standing-well-formed-rejects-nil-and-non-vocabulary
  "⚠ This scorer is what makes the absence discipline mechanical.  A version
that passes on NIL is worse than none."
  (let ((case (eval:make-case "q")))
    (is (= 1.0d0 (eval:score-value
                  (re:bundle-standing-well-formed case (%bundle '("a"))))))
    (is (= 0.0d0
           (eval:score-value
            (re:bundle-standing-well-formed
             case (rag:make-bundle :query "q"
                                   :evidence (list (%ev "a" :standing nil))
                                   :modes '(:dense))))))
    (is (= 0.0d0
           (eval:score-value
            (re:bundle-standing-well-formed
             case (rag:make-bundle
                   :query "q"
                   :evidence (list (%ev "a" :standing :probably))
                   :modes '(:dense))))))))

(test method-attributed-rejects-an-unattributed-item
  (let ((case (eval:make-case "q")))
    (is (= 1.0d0 (eval:score-value
                  (re:bundle-method-attributed case (%bundle '("a"))))))
    (is (= 0.0d0
           (eval:score-value
            (re:bundle-method-attributed
             case (rag:make-bundle :query "q"
                                   :evidence (list (%ev "a" :method nil))
                                   :modes '(:dense))))))))

(test all-four-scorers-run-over-a-real-fuse-bundle
  "⚠ I2, cl-llm#13: every test above grades the hand-built %BUNDLE fixture;
none ever hands a scorer FUSE's real output.  Build the real sources,
FUSE them, and score the result -- the third instance of a guarantee
stated in one task (the scorers work on a BUNDLE) and assumed by another
(FUSE produces one) with nothing spanning the join."
  (let* ((sources (%fuse-fixture-sources))
         (bundle (rag:fuse sources "mine" :k 7))
         (case (eval:make-case "mine" :expected '("a"))))
    (is (= 1.0d0 (eval:score-value (re:bundle-recall-at-k case bundle))))
    (is (= 1.0d0 (eval:score-value (re:bundle-containment case bundle))))
    (is (= 1.0d0
           (eval:score-value (re:bundle-standing-well-formed case bundle))))
    (is (= 1.0d0
           (eval:score-value (re:bundle-method-attributed case bundle))))))

;;; The seam Task 3 exists for: a variant's RUN-FN, driven by the harness's
;;; own RUN-SUITE, feeding a BUNDLE straight into all four scorers -- the
;;; spec's acceptance criterion (cl-llm#13 unit 1), not exercised anywhere
;;; else in this plan.

(test run-fn-bundle-scored-by-all-four-through-run-suite
  "⚠ Task 3 tested RUN-FN's plumbing in isolation (the key stripped, the
reader works). This is the only place RUN-FN is driven end to end through
EVAL:RUN-SUITE with real scorers."
  (eval:defsuite rag-eval-run-fn-suite
    :dataset (list (eval:make-case "q" :expected '("a")))
    :variants ((:run-fn (lambda (case)
                          (declare (ignore case))
                          (%bundle '("a")))))
    :scorers (re:bundle-recall-at-k re:bundle-containment
              re:bundle-standing-well-formed re:bundle-method-attributed))
  (let* ((result (eval:run-suite 'rag-eval-run-fn-suite))
         (cell (first (eval:result-cells result))))
    (is (= 1 (length (eval:result-cells result))))
    (is (= 4 (/ (length (eval:cell-scores cell)) 2)))
    (is (= 1.0d0 (eval:score-value
                  (eval:cell-score cell "bundle-recall-at-k"))))
    (is (= 1.0d0 (eval:score-value
                  (eval:cell-score cell "bundle-containment"))))
    (is (= 1.0d0 (eval:score-value
                  (eval:cell-score cell "bundle-standing-well-formed"))))
    (is (= 1.0d0 (eval:score-value
                  (eval:cell-score cell "bundle-method-attributed"))))))
