;;;; tests-vivace/store-segment.lisp
;;; RUN THIS SUITE WITH A LARGER HEAP: sbcl --dynamic-space-size 4096.
;;; The vivace suite already retained ~870MB before this file existed -- 87% of
;;; SBCL's 1GB default -- so adding these tests exhausted the heap on roughly
;;; two runs in three.  At 4096 it is 3/3 green.  Bounding graph-db's buffer
;;; pool does NOT fix it (tried both per-graph :buffer-pool-size and a
;;; suite-wide SET-BUFFER-POOL-SIZE, which trims live buffers rather than just
;;; lowering a ceiling; still flaky), so the retention is elsewhere and is
;;; tracked separately.  :BUFFER-POOL-SIZE 1000 below matches what graph-db's
;;; own tests pass and keeps these tests from making the peak worse.

(in-package #:cl-llm.rag.vivace/tests)
(in-suite :cl-llm-rag-vivace)

;;; ---------------------------------------------------------------------------
;;; Helpers for the store-search agreement tests (Task 4).

(defparameter *agreement-corpus-size* 39
  "A MULTIPLE OF THREE, deliberately.  AGREEMENT-CORPUS ties chunks in groups of
three; a size that is not a multiple of three leaves a singleton group, and when
that singleton outranks whole groups it shifts every later group by one so that
the k=10 boundary can land BETWEEN tied groups instead of inside one -- which is
exactly the case a fetch of exactly k already handles correctly.  Observed with
40: query j=5 put the singleton (group 13, the largest component at index 5) at
rank 1, and ranks 10 and 11 then had distinct scores.")

(defun agreement-corpus (n)
  "N chunks with document-ids d000..., including deliberate EXACT-TIE groups:
each consecutive group of three chunks shares one embedding, so the ranking
WITHIN a group is decided purely by the document-id tiebreak.  With k=10 the
tenth result always falls inside such a group (3+3+3+1), which is precisely the
straddling-tie case a fetch of exactly k cannot get right -- see
AGREEMENT-CORPUS-HAS-A-TIE-STRADDLING-K, which asserts that property directly
rather than assuming it."
  (loop for i from 0 below n
        collect (rag:make-chunk (format nil "chunk ~D" i)
                                :document-id (format nil "d~3,'0D" i)
                                :embedding
                                (let ((v (make-array 8 :element-type 'single-float
                                                       :initial-element 0.1)))
                                  ;; group of 3 share a vector -> exact ties
                                  (setf (aref v (mod (floor i 3) 8))
                                        (coerce (1+ (floor i 3)) 'single-float))
                                  v))))

(defun agreement-queries (dim)
  "A handful of queries hitting different regions of the corpus.

UNIT-NORM deliberately (RAG:AS-EMBEDDING).  The two implementations under
comparison score differently by construction: cl-llm's :cache path computes a
BARE DOT product (RAG:COSINE, valid because stored embeddings are L2-normalised
at ingest), while graph-db's segment computes a FULL cosine, i.e. dot divided by
the query's own norm as well.  Those agree on ORDER for any query, but agree on
SCORE only when the query is itself unit-norm -- which is what a real query
vector coming out of RAG:AS-EMBEDDING always is.  A non-unit query here would
make the score-equality assertion fail for a reason that has nothing to do with
the feature under test."
  (loop for j from 0 below dim
        collect (rag:as-embedding
                 (let ((v (make-array dim :element-type 'single-float
                                          :initial-element 0.05)))
                   (setf (aref v j) 1.0)
                   v))))

(defun unit-query (dim value)
  (make-array dim :element-type 'single-float
                  :initial-element (coerce value 'single-float)))

(test agreement-corpus-has-a-tie-straddling-k
  "The agreement corpus is only a proof of the over-fetch if some EXACT-TIE
group is cut by the k boundary -- if the k-th and (k+1)-th best scores were
distinct, fetching exactly k would already be correct and the agreement test
below would pass with or without the over-fetch.

Checked independently of any store: score the corpus with RAG:COSINE directly,
sort by score, and require score[k-1] = score[k] for every query used."
  (let ((k 10))
    (dolist (q (agreement-queries 8))
      (let* ((scores (sort (mapcar (lambda (c)
                                     (rag:cosine q (rag:as-embedding
                                                    (rag:chunk-embedding c))))
                                   (agreement-corpus *agreement-corpus-size*))
                           #'>)))
        (is (> (length scores) k) "corpus too small: ~D scores" (length scores))
        (when (> (length scores) k)
          (is (= (nth (1- k) scores) (nth k scores))
              "no tie straddles the k boundary for query ~S: rank ~D = ~S, rank ~D = ~S"
              q k (nth (1- k) scores) (1+ k) (nth k scores)))))))

(test segment-search-agrees-with-cache-ranking
  "THE CARRYING TEST.  :segment and :cache must return identically ranked
results over the same corpus -- same scores, same order, same ids.

This proves two separate claims at once: that the engine's FULL COSINE and
cl-llm's BARE DOT agree on the unit-normalised vectors cl-llm actually stores
(for unit-norm queries -- see AGREEMENT-QUERIES), and that the over-fetch
re-rank restores cl-llm's document-id tiebreak on top of the engine's node-id
one.

The corpus deliberately includes exact-tie groups (several chunks sharing an
embedding, differing only in document-id), because ties are precisely where the
two tiebreak keys disagree and where a fetch of exactly k would fail.  Set
V::*SEGMENT-OVERFETCH-FACTOR* to 1 and this test fails."
  (with-temp-directory (dir-a)
    (with-temp-directory (dir-b)
      (let* ((chunks (agreement-corpus *agreement-corpus-size*))
             (k 10)
             (graph-a (gdb:make-graph :cl-llm-vg-seg-agree-a dir-a :buffer-pool-size 1000))
             (graph-b (gdb:make-graph :cl-llm-vg-seg-agree-b dir-b :buffer-pool-size 1000))
             (seg (v:make-graph-store graph-a :strategy :segment :dimension 8))
             (cache (v:make-graph-store graph-b :strategy :cache :dimension 8)))
        (unwind-protect
             (progn
               (rag:store-add seg chunks)
               (rag:store-add cache chunks)
               (dolist (q (agreement-queries 8))
                 (let ((a (rag:store-search seg q k))
                       (b (rag:store-search cache q k)))
                   ;; Absolute lengths FIRST: (= (length a) (length b)) alone
                   ;; would pass on two empty results.
                   (is (= k (length a)) "segment returned ~D hits, expected ~D"
                       (length a) k)
                   (is (= k (length b)) "cache returned ~D hits, expected ~D"
                       (length b) k)
                   (when (and (= k (length a)) (= k (length b)))
                     (loop for x in a for y in b
                           do (is (string= (rag:chunk-document-id (rag:hit-chunk x))
                                           (rag:chunk-document-id (rag:hit-chunk y)))
                                  "ranking diverged: segment ~S vs cache ~S"
                                  (rag:chunk-document-id (rag:hit-chunk x))
                                  (rag:chunk-document-id (rag:hit-chunk y)))
                              (is (< (abs (- (rag:hit-score x) (rag:hit-score y))) 1e-5)
                                  "score diverged for ~S: ~S vs ~S"
                                  (rag:chunk-document-id (rag:hit-chunk x))
                                  (rag:hit-score x) (rag:hit-score y)))))))
          (progn (gdb:close-graph graph-a :snapshot-p nil)
                 (gdb:close-graph graph-b :snapshot-p nil)))))))

(test segment-search-dimension-mismatch-errors
  "Parity with scan-graph-store: a wrong-dimension query signals rather than
silently scoring against a prefix."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-dim dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0)))
             (signals rag:llm-rag-error
               (rag:store-search store
                                 (make-array 4 :element-type 'single-float
                                               :initial-element 1.0)
                                 3)))
        (gdb:close-graph graph :snapshot-p nil)))))

(test segment-search-k-larger-than-corpus
  "k above the corpus size returns everything, not an error or a padded list."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-bigk dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0) (test-chunk "b" 8 2.0)))
             (let ((hits (rag:store-search store (unit-query 8 1.0) 25)))
               (is (= 2 (length hits)) "expected 2 hits, got ~D" (length hits))
               (when (= 2 (length hits))
                 (is (every (lambda (h) (typep h 'rag:hit)) hits)
                     "store-search must return RAG:HIT structs, got ~S"
                     (mapcar #'type-of hits))
                 (is (equal '("a" "b")
                            (sort (mapcar (lambda (h)
                                            (rag:chunk-document-id (rag:hit-chunk h)))
                                          hits)
                                  #'string<))
                     "expected chunks a and b, got ~S"
                     (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
                             hits)))))
        (gdb:close-graph graph :snapshot-p nil)))))

(test segment-strategy-selects-the-segment-store
  "make-graph-store and open-graph-store both accept :segment and return the
right class; the other two strategies are unaffected.

Creation must go through GDB:MAKE-GRAPH + V:MAKE-GRAPH-STORE (V:OPEN-GRAPH-STORE
calls GDB:OPEN-GRAPH, which mmaps heap.dat with :CREATE-P NIL and errors on a
directory with no graph in it yet -- see STORE-ADD-POPULATES-THE-SEGMENT in
tests-vivace/schema.lisp). V:OPEN-GRAPH-STORE is exercised below via a genuine
reopen of the graph this test just created."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-select dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8)))
      (is (typep store 'v:segment-graph-store)
          "expected a segment-graph-store, got ~S" (type-of store))
      ;; the other two strategies still select their own, distinct classes
      (let ((scan (v:make-graph-store graph :strategy :scan :dimension 8))
            (cache (v:make-graph-store graph :strategy :cache :dimension 8)))
        (is (typep scan 'v:scan-graph-store)
            "expected a scan-graph-store, got ~S" (type-of scan))
        (is (typep cache 'v:cached-graph-store)
            "expected a cached-graph-store, got ~S" (type-of cache))
        (is (not (typep scan 'v:segment-graph-store)))
        (is (not (typep cache 'v:segment-graph-store))))
      (gdb:close-graph graph :snapshot-p nil))
    ;; reopen the SAME on-disk graph via open-graph-store -- a genuine reopen,
    ;; not a fresh gdb:make-graph -- confirming open-graph-store also accepts
    ;; :segment and returns the same class.
    (let ((store (v:open-graph-store (namestring dir) :name :cl-llm-vg-seg-select
                                                        :strategy :segment :dimension 8)))
      (unwind-protect
           (is (typep store 'v:segment-graph-store)
               "expected a segment-graph-store from open-graph-store, got ~S" (type-of store))
        (gdb:close-graph (v:graph-store-graph store) :snapshot-p nil)))))

(test segment-store-counts-and-deletes
  "store-count and store-delete-documents work on the new store, inheriting the
graph-store base behaviour."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-count dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0)
                                        (test-chunk "b" 8 2.0)
                                        (test-chunk "c" 8 3.0)))
             (is (= 3 (rag:store-count store)) "expected 3, got ~D" (rag:store-count store))
             (rag:store-delete-documents store (list "b"))
             (is (= 2 (rag:store-count store))
                 "expected 2 after delete, got ~D" (rag:store-count store)))
        (gdb:close-graph (v:graph-store-graph store) :snapshot-p nil)))))

(test segment-store-hydrate-records-dimension-from-existing-chunks
  "HYDRATE probes an existing chunk vertex for its dimension when none is
supplied -- a real, specific value (8), not merely non-nil, so this cannot
pass on a broken probe that leaves the slot NIL-checked-truthy by accident."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-hydrate-dim dir :buffer-pool-size 1000))
           (writer (v:make-graph-store graph :strategy :scan :dimension 8)))
      (rag:store-add writer (list (test-chunk "a" 8 1.0)))
      (unwind-protect
           ;; a fresh segment-graph-store, dimension unspecified: hydrate must
           ;; discover it from the chunk already in the graph.
           (let ((store (v:make-graph-store graph :strategy :segment)))
             (is (eql 8 (v:graph-store-dimension store))
                 "expected hydrate to record dimension 8, got ~S"
                 (v:graph-store-dimension store)))
        (gdb:close-graph graph :snapshot-p nil)))))
