;;;; tests-rag/document.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(test make-document-fields
  (let ((d (rag:make-document "hello" :id "d1" :metadata '(:title "Greeting"))))
    (is (string= "hello" (rag:document-text d)))
    (is (string= "d1" (rag:document-id d)))
    (is (equal '(:title "Greeting") (rag:document-metadata d)))))

(test make-chunk-carries-provenance
  (let ((ch (rag:make-chunk "piece" :document-id "d1" :metadata '(:title "T" :position 0))))
    (is (string= "piece" (rag:chunk-text ch)))
    (is (string= "d1" (rag:chunk-document-id ch)))
    (is (equal '(:title "T" :position 0) (rag:chunk-metadata ch)))
    (is (null (rag:chunk-embedding ch)))))

(test split-text-no-overlap-tiles-the-text
  (let ((pieces (rag:split-text "abcdefghij" :size 5 :overlap 0)))
    (is (equal '(("abcde" . 0) ("fghij" . 5)) pieces))))

(test split-text-overlap-shares-a-tail
  (let ((pieces (rag:split-text "abcdefghij" :size 5 :overlap 2)))
    ;; windows start at 0, 3, 6, 9 (advance by size-overlap = 3)
    (is (equal 0 (cdr (first pieces))))
    (is (equal 3 (cdr (second pieces))))
    (is (string= "abcde" (car (first pieces))))
    (is (string= "defgh" (car (second pieces))))))

(test split-text-shorter-than-size-is-one-piece
  (is (equal '(("hi" . 0)) (rag:split-text "hi" :size 100 :overlap 10))))

(test split-text-empty-is-empty
  (is (null (rag:split-text "" :size 100 :overlap 10))))

(test split-text-rejects-nonsensical-overlap
  (signals rag:llm-rag-error (rag:split-text "abc" :size 5 :overlap 5))
  (signals rag:llm-rag-error (rag:split-text "abc" :size 5 :overlap 9)))
