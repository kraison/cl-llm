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

(test sparse-store-add-count-search
  (let ((s (rag:make-sparse-store)))
    (rag:store-add s (list (rag:make-chunk "The TM-62M anti-tank mine has a metal body" :document-id "a")
                           (rag:make-chunk "The PFM-1 is a scatterable mine" :document-id "b")
                           (rag:make-chunk "general notes about mines and safety" :document-id "c")))
    (is (= 3 (rag:store-count s)))
    ;; an exact-designation query surfaces the doc that literally contains it, first
    (let ((hits (rag:sparse-search s "TM-62M" 3)))
      (is (>= (length hits) 1))
      (is (string= "a" (rag:chunk-document-id (rag:hit-chunk (first hits))))))
    ;; a query term in every doc ("mine") must not outweigh a rare exact term
    (let ((hits (rag:sparse-search s "PFM-1 mine" 3)))
      (is (string= "b" (rag:chunk-document-id (rag:hit-chunk (first hits))))))))

(test sparse-store-delete-document
  (let ((s (rag:make-sparse-store)))
    (rag:store-add s (list (rag:make-chunk "TM-62M mine" :document-id "a")
                           (rag:make-chunk "PFM-1 mine" :document-id "b")))
    (is (= 1 (rag:store-delete-document s "a")))
    (is (= 1 (rag:store-count s)))
    (is (null (rag:sparse-search s "TM-62M" 3)))))           ; "a" gone -> no match for its term

(test sparse-search-empty-and-no-overlap
  (let ((s (rag:make-sparse-store)))
    (is (null (rag:sparse-search s "anything" 3)))          ; empty store
    (rag:store-add s (list (rag:make-chunk "TM-62M" :document-id "a")))
    (is (null (rag:sparse-search s "zzz-nonexistent" 3)))))  ; no term overlap -> no hits
