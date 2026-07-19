;;;; tests-rag/sparse.lisp

(in-package #:cl-llm.rag.test)
(in-suite cl-llm-rag-suite)

(test tokenize-preserves-designations
  (is (equal '("tm-62m") (rag:tokenize "TM-62M")))                 ; NOT ("tm" "62m")
  (is (equal '("det-cord") (rag:tokenize "det-cord")))
  (is (equal '("the" "tm-62m" "mine") (rag:tokenize "The TM-62M mine.")))
  (is (equal '("a" "b") (rag:tokenize "a, b!")))                   ; punctuation splits
  (is (equal '("vs-6d") (rag:tokenize "  -VS-6D-  ")))             ; trim leading/trailing dashes
  (is (member "тм-62" (rag:tokenize "мина ТМ-62") :test #'string=))) ; Cyrillic run kept whole

(test bm25-idf-rewards-rarity
  ;; a term in 1 of 100 docs has higher IDF than one in 90 of 100
  (is (> (rag:bm25-idf 100 1) (rag:bm25-idf 100 90))))

(test bm25-term-score-saturates-and-normalizes
  (let ((idf 1d0))
    ;; more tf -> higher score, but sub-linear (saturation)
    (is (> (rag:bm25-term-score idf 3 10d0 10d0) (rag:bm25-term-score idf 1 10d0 10d0)))
    (is (< (- (rag:bm25-term-score idf 3 10d0 10d0) (rag:bm25-term-score idf 2 10d0 10d0))
           (- (rag:bm25-term-score idf 2 10d0 10d0) (rag:bm25-term-score idf 1 10d0 10d0))))
    ;; a longer-than-average doc is penalized vs an average-length one at equal tf
    (is (< (rag:bm25-term-score idf 2 20d0 10d0) (rag:bm25-term-score idf 2 10d0 10d0)))))
