;;;; tests-agent/extract-tests.lisp -- the key extractor (#64 SS4.1).

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %vocab (&rest endpoints)
  (mem:make-vocabulary :endpoints endpoints))

(test the-extractor-tokenises-lowercase-runs-of-three-or-more
  (is (equal '("ledger" "freeze" "2026")
             (agent::%tokens "Ledger-Freeze 2026/05 r2 a")))
  (is (equal '("ledger") (agent::%tokens "ledger, LEDGER, ledger"))
      "distinct, first occurrence kept")
  (is (null (agent::%tokens "?? !!"))))

(test the-extractor-scores-endpoints-by-key-tokens
  (let* ((v (%vocab '(:decision . "drop-nightly-reindex")
                    '(:project . "harbor-ledger")
                    '(:incident . "ledger-freeze-2026-05-22-r2")
                    '(:incident . "ledger-freeze-2026-05-22")))
         (x (agent:make-key-extractor v)))
    ;; two tokens beat one; equal scores: the shorter key first
    (is (equal '((:incident . "ledger-freeze-2026-05-22")
                 (:incident . "ledger-freeze-2026-05-22-r2")
                 (:project . "harbor-ledger"))
               (funcall x "Why did the ledger freeze back in May?")))
    (is (equal '((:decision . "drop-nightly-reindex"))
               (funcall x "do we still run the nightly reindex")))
    (is (null (funcall x "anything at all")))
    (is (null (funcall x "incident")) "a namespace name alone selects nothing")
    (is (equal '((:project . "harbor-ledger")
                 (:incident . "ledger-freeze-2026-05-22")
                 (:incident . "ledger-freeze-2026-05-22-r2"))
               (funcall x "harbor-ledger"))
        "both tokens score the hyphenated key; a shared token still ranks")))

(test the-extractor-prefers-a-named-namespace-and-caps
  (let* ((v (%vocab '(:person . "ledger") '(:project . "ledger")))
         (x (agent:make-key-extractor v :cap 1)))
    (is (equal '((:project . "ledger")) (funcall x "the project ledger")))
    (is (equal '((:person . "ledger")) (funcall x "ledger"))
        "no namespace hit: alphabetical on namespace:key")
    (is (= 2 (length (funcall (agent:make-key-extractor v) "ledger"))))))

;;; #78 R2: the hybrid extractor -- lexical first, then the dense fill.

(test the-hybrid-extractor-is-lexical-first-then-dense-fill
  "#78 R2: lexical hits keep their order and come first; dense
candidates above the floor fill the cap, best first; the identifier in
the query is never displaced by a decoy whose profile embeds nearer."
  (with-stores (w p)
    (declare (ignore p))
    (%belief w "root-cause" '(:cause . "replica-checksum-mismatch")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (%belief w "root-cause" '(:cause . "rollback-reverted-deploy")
             :subject '(:incident . "sigil-fb73e8e9e67"))
    (let ((ee (%embedder)))
      (%drain (list w) ee)
      (mem:with-scope-snapshots ((list w))
        (let* ((v (mem:vocabulary w))
               (x (agent:make-hybrid-key-extractor w v ee :cap 4))
               (lexical (agent:make-key-extractor v :cap 4)))
          ;; The decoy embeds nearest this query (cos .56 against .24)
          ;; and is a lexical hit too, on "reverted"; the identifier
          ;; scores two tokens, so it still leads.
          (is (equal '((:incident . "sigil-fb73e8e9e67")
                       (:cause . "rollback-reverted-deploy"))
                     (funcall x "why was sigil-fb73e8e9e67 reverted"))
              "the exact identifier is first although the decoy embeds ~
               nearer")
          (let ((q "why was the deployment rolled back in august"))
            (is (null (funcall lexical q))
                "control: no key token of any endpoint is in the query")
            ;; Best first, floor 0.3: the decoy .47, the incident .35;
            ;; the other two endpoints are .26 and .24.
            (is (equal '((:cause . "rollback-reverted-deploy")
                         (:incident . "ledger-rollback-2026-08-30"))
                       (funcall x q))
                "the paraphrase routes: ~s" (funcall x q)))
          (is (null (funcall x "pelican migration"))
              "below the floor: nothing")
          (let ((q "why did the ledger get rolled back"))
            (is (equal '((:incident . "ledger-rollback-2026-08-30"))
                       (funcall lexical q))
                "control: one lexical hit, on the token ledger")
            (is (equal '((:incident . "ledger-rollback-2026-08-30")
                         (:cause . "rollback-reverted-deploy"))
                       (funcall x q))
                "the lexical hit leads, the dense candidate fills: ~s"
                (funcall x q))))))))

(test the-hybrid-extractor-without-an-embedder-is-the-lexical-one
  (with-stores (w p)
    (declare (ignore p))
    (%belief w "root-cause" '(:cause . "bad-deploy")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (mem:with-scope-snapshots ((list w))
      (let ((v (mem:vocabulary w)))
        (is (equal (funcall (agent:make-key-extractor v) "ledger rollback")
                   (funcall (agent:make-hybrid-key-extractor w v nil)
                            "ledger rollback")))))))

(test make-endpoint-embedder-requires-a-model-and-a-floor
  "#78 R3: the index records a model per vector, so an embedder that
names none is refused; the floor is required and bounded."
  (signals error
    (agent:make-endpoint-embedder (rag:make-mock-embedder) :floor 0.5))
  (signals error
    (agent:make-endpoint-embedder (make-instance '%synonym-embedder)))
  (signals error
    (agent:make-endpoint-embedder (make-instance '%synonym-embedder)
                                  :floor 1.5))
  (let ((ee (agent:make-endpoint-embedder
             (make-instance '%synonym-embedder) :floor 0.4)))
    (is (string= "synonym-test" (agent:endpoint-embedder-model ee)))
    (is (= 0.4 (agent:endpoint-embedder-floor ee)))
    (is (typep (agent:endpoint-embedder-embedder ee) '%synonym-embedder))
    (is (= +embed-dimension+
           (length (funcall (agent:endpoint-embedder-embed ee) "x"))))))
