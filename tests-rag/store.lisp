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
  ;; The true nearest match ("east") is inserted LAST, not first, so a
  ;; broken implementation that skips sorting and just truncates to
  ;; insertion order would fail this test.
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "north" :embedding (v 0 1))
                           (rag:make-chunk "northeast" :embedding (v 1 1))
                           (rag:make-chunk "east" :embedding (v 1 0))))
    (let ((hits (rag:store-search s (v 1 0) 2)))
      (is (= 2 (length hits)))
      (is (string= "east" (rag:chunk-text (rag:hit-chunk (first hits)))))
      (is (>= (rag:hit-score (first hits)) (rag:hit-score (second hits)))))))

(test store-add-atomic-on-invalid-embedding
  ;; A mid-batch chunk with no embedding must abort the WHOLE batch --
  ;; the earlier, already-valid chunks must not be indexed either.
  (let ((s (rag:make-memory-store)))
    (signals rag:llm-rag-error
      (rag:store-add s (list (rag:make-chunk "good1" :embedding (v 1 0))
                             (rag:make-chunk "bad" :embedding nil)
                             (rag:make-chunk "good2" :embedding (v 0 1)))))
    (is (= 0 (rag:store-count s)))))

(test store-add-atomic-on-self-inconsistent-batch
  ;; A batch that disagrees with itself on dimension (into an empty store,
  ;; so there's no store dimension yet to check against) must be rejected
  ;; in full, not partially indexed up to the bad chunk.
  (let ((s (rag:make-memory-store)))
    (signals rag:llm-rag-error
      (rag:store-add s (list (rag:make-chunk "a" :embedding (v 1 0))
                             (rag:make-chunk "b" :embedding (v 1 0 0)))))
    (is (= 0 (rag:store-count s)))))

(test store-add-atomic-on-store-dimension-conflict
  ;; A batch that conflicts with an already-populated store's dimension
  ;; must leave that store exactly as it was.
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "a" :embedding (v 1 0))))
    (let ((count-before (rag:store-count s)))
      (signals rag:llm-rag-error
        (rag:store-add s (list (rag:make-chunk "b" :embedding (v 1 0))
                               (rag:make-chunk "c" :embedding (v 1 0 0)))))
      (is (= count-before (rag:store-count s))))))

(test store-add-valid-batch-adds-all
  ;; Regression: a fully-valid multi-chunk batch still adds every chunk.
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "a" :embedding (v 1 0))
                           (rag:make-chunk "b" :embedding (v 0 1))
                           (rag:make-chunk "c" :embedding (v 1 1))))
    (is (= 3 (rag:store-count s)))))

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
      ;; LOAD-STORE round-trips embeddings through RAG:AS-EMBEDDING, which
      ;; L2-normalises -- (0.5 0.5) is not unit length, so the loaded chunk's
      ;; embedding is the normalised vector, not the raw fixture. Compare
      ;; against the real coercion, not a hand-computed magic number.
      (is (equalp (rag:as-embedding '(0.5d0 0.5d0))
                  (rag:chunk-embedding (rag:hit-chunk (first hits)))))
      (is (= (rag:store-dimension s) (rag:store-dimension loaded))
          "round trip re-derives the same store-dimension"))
    ;; The persisted plist must not carry a stray :DIMENSION key -- it is
    ;; dead data that LOAD-STORE never reads (dimension is re-derived from
    ;; the chunks via STORE-ADD), and could silently drift from reality.
    (let ((data (with-open-file (in path)
                  (with-standard-io-syntax
                    (let ((*read-default-float-format* 'double-float))
                      (read in))))))
      (is (getf data :chunks) "sanity: :chunks key is present")
      (is (null (getf data :dimension)) "no stray :dimension key is persisted"))
    (ignore-errors (delete-file path))))

(test load-store-missing-file-signals-llm-rag-error
  (let ((path (merge-pathnames "rag-store-does-not-exist.dat"
                               (uiop:temporary-directory))))
    (ignore-errors (delete-file path))
    (signals rag:llm-rag-error (rag:load-store path))))

(test store-delete-document-removes-matching-chunks
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "a1" :document-id "A" :embedding (v 1 0))
                           (rag:make-chunk "a2" :document-id "A" :embedding (v 1 1))
                           (rag:make-chunk "b1" :document-id "B" :embedding (v 0 1))))
    (is (= 3 (rag:store-count s)))
    (is (= 2 (rag:store-delete-document s "A")) "returns the number removed")
    (is (= 1 (rag:store-count s)))
    ;; only B remains -- a search never returns an A chunk
    (let ((hits (rag:store-search s (v 1 0) 5)))
      (is (= 1 (length hits)))
      (is (string= "B" (rag:chunk-document-id (rag:hit-chunk (first hits))))))))

(test store-delete-absent-document-is-a-noop
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "b1" :document-id "B" :embedding (v 0 1))))
    (is (= 0 (rag:store-delete-document s "NOPE")))
    (is (= 1 (rag:store-count s)))))

(test store-delete-then-readd-refreshes
  ;; the mine-action refresh scenario: same doc-id, different chunks
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "old" :document-id "A" :embedding (v 1 0))))
    (rag:store-delete-document s "A")
    (rag:store-add s (list (rag:make-chunk "new" :document-id "A" :embedding (v 0 1))))
    (is (= 1 (rag:store-count s)))
    (is (string= "new" (rag:chunk-text (rag:hit-chunk (first (rag:store-search s (v 0 1) 1))))))))
