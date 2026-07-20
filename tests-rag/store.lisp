;;;; tests-rag/store.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(defun v (&rest xs)
  "A plain typed-vector constructor -- coerces to single-float, does NOT
normalise. Several tests deliberately feed non-unit vectors."
  (map '(simple-array single-float (*)) (lambda (x) (coerce x 'single-float)) xs))

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
  ;;
  ;; Inputs are unit-length (via AS-EMBEDDING), not raw V vectors: COSINE is
  ;; now a bare dot product, which equals true cosine only for unit-length
  ;; inputs. A raw (v 1 1) "northeast" has norm sqrt(2), so its dot product
  ;; with the query would tie NORTHEAST and EAST at 1.0 -- a tie true cosine
  ;; never has (0.7071 vs 1.0) -- which would test tie-break order instead
  ;; of ranking-by-similarity, the property this test exists to prove.
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "north" :embedding (rag:as-embedding (list 0 1)))
                           (rag:make-chunk "northeast" :embedding (rag:as-embedding (list 1 1)))
                           (rag:make-chunk "east" :embedding (rag:as-embedding (list 1 0)))))
    (let ((hits (rag:store-search s (rag:as-embedding (list 1 0)) 2)))
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

(test store-add-coerces-raw-embedding-so-search-does-not-type-error
  "STORE-ADD on a memory-store must coerce every chunk's embedding through
AS-EMBEDDING before it lands in the store, mirroring VALIDATE-CHUNKS on the
graph-backed store (vivace/store.lisp). Without that, a raw double-float
embedding (a realistic caller mistake -- e.g. reading JSON numbers without
forcing single-float) is accepted silently by STORE-ADD's nil/dimension-only
validation, and then blows up STORE-SEARCH with a TYPE-ERROR the moment COSINE
runs its (simple-array single-float (*)) declaration against it -- far from
the STORE-ADD call that actually caused it. The assertion is on the SEARCH
path, not just on what STORE-ADD accepted, because the search is where the
bug bites."
  (let ((s (rag:make-memory-store))
        (raw (make-array 2 :element-type 'double-float
                            :initial-contents '(1.0d0 0.0d0))))
    (rag:store-add s (list (rag:make-chunk "x" :embedding raw)))
    (let ((hits (rag:store-search s (rag:as-embedding '(1.0 0.0)) 1)))
      (is (= 1 (length hits)))
      (is (string= "x" (rag:chunk-text (rag:hit-chunk (first hits)))))
      (is (< (abs (- 1.0 (rag:hit-score (first hits)))) 1e-5)))))

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
      ;; STORE-ADD normalises embeddings at add-time (mirroring VALIDATE-CHUNKS
      ;; on the graph-backed store) -- (0.5 0.5) is not unit length, so what
      ;; SAVE-STORE serialises is already the normalised vector, not the raw
      ;; fixture. LOAD-STORE then round-trips that through RAG:AS-EMBEDDING
      ;; again, so the loaded embedding has passed through normalisation
      ;; TWICE (once at add-time, once at load-time) plus a single/double
      ;; float coercion in between; that is one more rounding step than a
      ;; single fresh AS-EMBEDDING call, so compare within an epsilon rather
      ;; than exact EQUALP.
      (let ((expected (rag:as-embedding '(0.5d0 0.5d0)))
            (actual (rag:chunk-embedding (rag:hit-chunk (first hits)))))
        (is (= (length expected) (length actual)))
        (dotimes (i (length expected))
          (is (< (abs (- (aref expected i) (aref actual i))) 1e-5))))
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

(test cosine-of-normalised-vectors
  "Cosine of unit vectors: identical = 1, orthogonal = 0, opposed = -1."
  (let ((a (rag:as-embedding '(1.0 0.0)))
        (b (rag:as-embedding '(0.0 1.0)))
        (c (rag:as-embedding '(-1.0 0.0))))
    (is (< (abs (- 1.0 (rag:cosine a a))) 1e-5))
    (is (< (abs (rag:cosine a b)) 1e-5))
    (is (< (abs (- -1.0 (rag:cosine a c))) 1e-5))))

(test cosine-returns-single-float
  "Scoring stays in single-float; no boxing to double."
  (let ((a (rag:as-embedding '(1.0 2.0 3.0))))
    (is (typep (rag:cosine a a) 'single-float))))

(test top-k-collector-keeps-the-best-k
  "A bounded collector returns exactly the k highest scores, best first."
  (let ((c (rag::top-k-collector 3)))
    (dolist (row '((0.1 "a" :a) (0.9 "b" :b) (0.5 "c" :c) (0.7 "d" :d) (0.2 "e" :e)))
      (rag::collect-candidate c (coerce (first row) 'single-float)
                              (second row) (third row)))
    (is (equal '(:b :d :c) (mapcar #'cdr (rag::collector-results c))))))

(test top-k-collector-handles-fewer-than-k
  "Fewer candidates than k returns all of them, still ordered."
  (let ((c (rag::top-k-collector 5)))
    (rag::collect-candidate c 0.2f0 "x" :x)
    (rag::collect-candidate c 0.8f0 "y" :y)
    (is (equal '(:y :x) (mapcar #'cdr (rag::collector-results c))))))

(test top-k-collector-tie-break-is-order-independent
  "A tie at the k-th boundary resolves by document-id, not by insertion order.
This is the regression that keeps scan and cache stores agreeing: they iterate
in different orders, so an order-dependent eviction would make them differ.

The discriminating case is a CHALLENGER that arrives once the buffer is
already full, tied on score with a RESIDENT, and WINNING on tiebreak. A case
where the correct answer happens to be \"reject the challenger\" does not
discriminate: plain score-only `>` also rejects any tied challenger (a tie
never beats the current occupant under strict `>`), so it produces the same
answer by coincidence without ever consulting the tiebreak. Here X must
evict Y (or Y must never evict X) purely because X's document-id sorts
first -- a score-only comparator gets this wrong for whichever of X/Y
happens to arrive second."
  (flet ((collect-in (rows)
           (let ((c (rag::top-k-collector 2)))
             (dolist (row rows)
               (rag::collect-candidate c (coerce (first row) 'single-float)
                                       (second row) (third row)))
             (mapcar #'cdr (rag::collector-results c)))))
    ;; Z clearly wins on score. X and Y tie on score with X's document-id
    ;; sorting before Y's. k=2, so exactly one of {X,Y} survives alongside
    ;; Z, and the correct survivor is always X -- regardless of whether X or
    ;; Y is the resident when the other arrives as the late challenger.
    (let ((forward  (collect-in '((0.9 "z" :z) (0.5 "x" :x) (0.5 "y" :y))))
          (backward (collect-in '((0.9 "z" :z) (0.5 "y" :y) (0.5 "x" :x)))))
      (is (equal '(:z :x) forward))
      (is (equal '(:z :x) backward))
      (is (equal forward backward)
          "eviction depends on insertion order: ~S vs ~S" forward backward))))

(test top-k-collector-k-zero-returns-nothing
  "A collector constructed with k=0 retains nothing, no matter how many
candidates are offered -- no phantom entries from the k=0 buffer path."
  (let ((c (rag::top-k-collector 0)))
    (rag::collect-candidate c 0.9f0 "a" :a)
    (rag::collect-candidate c 0.1f0 "b" :b)
    (is (null (rag::collector-results c)))))

(test top-k-collector-empty-corpus-returns-nothing
  "No candidates offered at all returns NIL, regardless of k."
  (let ((c (rag::top-k-collector 5)))
    (is (null (rag::collector-results c)))))

(test search-matches-brute-force
  "Heap-based search agrees with a full sort on the same corpus, including which
chunk occupies each rank.

The corpus must contain a genuine score TIE, or this test cannot exercise the
tie-break at all: 50 chunks built from (sin i, cos i) for distinct i each get
a distinct cosine against the query, so the reference's document-id tiebreak
would never actually run -- rank-before-p's second clause would be dead code
as far as this test can tell. Instead, each of 25 distinct (sin i, cos i)
points is used for exactly TWO chunks with different document-ids, so every
score in the corpus is genuinely duplicated; the top-5 window straddles at
least one tied pair.

Asserting scores alone is also not enough: a collector that returns the right
SCORES on the WRONG chunks (e.g. it evicted the correct tie-break winner but
kept a same-scored impostor) would still pass a score-only comparison. Assert
chunk-document-id identity too."
  (let ((store (rag:make-memory-store))
        (chunks '()))
    (dotimes (i 25)
      (let ((embedding (rag:as-embedding
                        (list (coerce (sin i) 'single-float)
                              (coerce (cos i) 'single-float)))))
        (push (rag:make-chunk (format nil "chunk ~A-a" i)
                              :document-id (format nil "doc-~A-a" i)
                              :embedding embedding)
              chunks)
        (push (rag:make-chunk (format nil "chunk ~A-b" i)
                              :document-id (format nil "doc-~A-b" i)
                              :embedding embedding)
              chunks)))
    (rag:store-add store chunks)
    (let* ((q (rag:as-embedding '(1.0 0.0)))
           (heap-hits (rag:store-search store q 5))
           ;; Reference must use the SAME total order as the collector (score
           ;; DESC, document-id ASC) -- but it must be RE-IMPLEMENTED here,
           ;; inline, rather than calling RAG::RANK-BEFORE-P: STORE-SEARCH's
           ;; collector consults that same function internally, so if this
           ;; reference called it too, a broken RANK-BEFORE-P would break both
           ;; sides identically and they would still agree by construction --
           ;; the test would keep passing under exactly the mutation it exists
           ;; to catch. Comparing against an independent reimplementation is
           ;; what makes this an actual regression check on RANK-BEFORE-P/the
           ;; collector's tie-break, not a tautology.
           (brute (subseq (sort (mapcar (lambda (c)
                                          (cons (rag:cosine q (rag:chunk-embedding c)) c))
                                        chunks)
                                (lambda (a b)
                                  (let ((sa (car a)) (sb (car b)))
                                    (cond ((> sa sb) t)
                                          ((< sa sb) nil)
                                          (t (string< (or (rag:chunk-document-id (cdr a)) "")
                                                      (or (rag:chunk-document-id (cdr b)) "")))))))
                          0 5)))
      (is (= 5 (length heap-hits)))
      (loop for hit in heap-hits
            for ref in brute
            do (is (< (abs (- (rag:hit-score hit) (car ref))) 1e-5))
               (is (string= (rag:chunk-document-id (rag:hit-chunk hit))
                            (rag:chunk-document-id (cdr ref)))
                   "chunk identity mismatch: got ~A, expected ~A"
                   (rag:chunk-document-id (rag:hit-chunk hit))
                   (rag:chunk-document-id (cdr ref)))))))
