;;;; tests-rag/store.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(defun v (&rest xs)
  (map '(simple-array double-float (*)) (lambda (x) (coerce x 'double-float)) xs))

(test cosine-basics
  (is (< (abs (- 1d0 (rag:cosine (v 1 0) (v 1 0)))) 1d-9))
  (is (< (abs (rag:cosine (v 1 0) (v 0 1))) 1d-9))
  (is (= 0d0 (rag:cosine (v 0 0) (v 1 1))) "zero-norm is safe, not a divide error"))

(test store-add-and-count
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "a" :embedding (v 1 0))
                           (rag:make-chunk "b" :embedding (v 0 1))))
    (is (= 2 (rag:store-count s)))))

(test store-search-ranks-by-cosine
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "east" :embedding (v 1 0))
                           (rag:make-chunk "north" :embedding (v 0 1))
                           (rag:make-chunk "northeast" :embedding (v 1 1))))
    (let ((hits (rag:store-search s (v 1 0) 2)))
      (is (= 2 (length hits)))
      (is (string= "east" (rag:chunk-text (rag:hit-chunk (first hits)))))
      (is (>= (rag:hit-score (first hits)) (rag:hit-score (second hits)))))))

(test store-dimension-mismatch-signals
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "a" :embedding (v 1 0 0))))
    (signals rag:llm-rag-error
      (rag:store-add s (list (rag:make-chunk "b" :embedding (v 1 0)))))
    (signals rag:llm-rag-error (rag:store-search s (v 1 0) 1))))

(test store-search-on-empty-returns-nil
  (is (null (rag:store-search (rag:make-memory-store) (v 1 0) 3))))

(test store-save-load-round-trips
  (let ((s (rag:make-memory-store))
        (path (merge-pathnames "rag-store-test.dat"
                               (uiop:temporary-directory))))
    (rag:store-add s (list (rag:make-chunk "hello" :document-id "d1"
                                           :metadata '(:title "T") :embedding (v 0.5 0.5))))
    (rag:save-store s path)
    (let* ((loaded (rag:load-store path))
           (hits (rag:store-search loaded (v 0.5 0.5) 1)))
      (is (= 1 (rag:store-count loaded)))
      (is (string= "hello" (rag:chunk-text (rag:hit-chunk (first hits)))))
      (is (string= "d1" (rag:chunk-document-id (rag:hit-chunk (first hits)))))
      (is (equal '(:title "T") (rag:chunk-metadata (rag:hit-chunk (first hits)))))
      (is (equalp (v 0.5 0.5) (rag:chunk-embedding (rag:hit-chunk (first hits))))))
    (ignore-errors (delete-file path))))
