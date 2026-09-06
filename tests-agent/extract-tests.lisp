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
        "both tokens score the whole key; a shared token still ranks")))

(test the-extractor-prefers-a-named-namespace-and-caps
  (let* ((v (%vocab '(:person . "ledger") '(:project . "ledger")))
         (x (agent:make-key-extractor v :cap 1)))
    (is (equal '((:project . "ledger")) (funcall x "the project ledger")))
    (is (equal '((:person . "ledger")) (funcall x "ledger"))
        "no namespace hit: alphabetical on namespace:key")
    (is (= 2 (length (funcall (agent:make-key-extractor v) "ledger"))))))
