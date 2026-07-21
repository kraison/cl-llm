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

(test segment-and-cache-scores-differ-by-the-query-norm
  "PINS THE DOCUMENTED DIFFERENCE (Task 7 decision).  On a query that is NOT
unit-norm, :segment and :cache return the SAME ORDER but different SCORES, and
the difference is exactly the factor 1/|q|: the engine computes a full cosine
(dividing by the query's own norm), while RAG:COSINE -- what :cache and :scan use
-- is a bare dot product.

The decision was to LEAVE this and document it rather than force score equality.
Normalising the query inside SEGMENT-GRAPH-STORE's STORE-SEARCH would change
nothing (the engine divides by the query norm either way); matching :cache's
number would require multiplying the engine's cosine back UP by |q|, i.e.
reintroducing :cache's non-cosine scaling into the strategy that gets it right.
This test exists so that the relationship is a checked property rather than a
claim in a docstring, and so that any future change to either scoring path is
caught here.

Contrast with SEGMENT-SEARCH-AGREES-WITH-CACHE-RANKING above, which asserts
score EQUALITY -- for unit-norm queries, the only kind cl-llm's own pipeline
produces."
  (with-temp-directory (dir-a)
    (with-temp-directory (dir-b)
      (let* ((chunks (agreement-corpus 9))
             (k 5)
             (graph-a (gdb:make-graph :cl-llm-vg-seg-qnorm-a dir-a :buffer-pool-size 1000))
             (graph-b (gdb:make-graph :cl-llm-vg-seg-qnorm-b dir-b :buffer-pool-size 1000))
             (seg (v:make-graph-store graph-a :strategy :segment :dimension 8))
             (cache (v:make-graph-store graph-b :strategy :cache :dimension 8))
             ;; Deliberately NOT unit-norm: |q| = 3 * sqrt(8) ~= 8.485.
             (q (make-array 8 :element-type 'single-float :initial-element 3.0))
             (qnorm (rag:embedding-norm q)))
        (unwind-protect
             (progn
               (is (> (abs (- 1.0 qnorm)) 0.5)
                   "query must be far from unit-norm for this test to mean anything: |q| = ~S"
                   qnorm)
               (rag:store-add seg chunks)
               (rag:store-add cache chunks)
               (let ((a (rag:store-search seg q k))
                     (b (rag:store-search cache q k)))
                 (is (= k (length a)) "segment returned ~D hits, expected ~D" (length a) k)
                 (is (= k (length b)) "cache returned ~D hits, expected ~D" (length b) k)
                 (when (and (= k (length a)) (= k (length b)))
                   ;; (1) Same order.
                   (is (equal (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) a)
                              (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) b))
                       "ranking diverged on an unnormalised query: ~S vs ~S"
                       (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) a)
                       (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) b))
                   ;; (2) The scores are genuinely NOT equal -- otherwise (3)
                   ;; would be satisfiable by two identical scoring paths and
                   ;; would prove nothing about the factor.
                   (is (> (abs (- (rag:hit-score (first a)) (rag:hit-score (first b)))) 1e-3)
                       "scores did not differ at all: segment ~S vs cache ~S"
                       (rag:hit-score (first a)) (rag:hit-score (first b)))
                   ;; (3) ...and they differ by exactly 1/|q|.
                   (loop for x in a for y in b
                         do (is (< (abs (- (* qnorm (rag:hit-score x)) (rag:hit-score y)))
                                   1e-4)
                                "score ratio is not 1/|q| for ~S: segment ~S * ~S /= cache ~S"
                                (rag:chunk-document-id (rag:hit-chunk x))
                                (rag:hit-score x) qnorm (rag:hit-score y))))))
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

;;; ---------------------------------------------------------------------------
;;; Final review item 1 (BLOCKING).  Task 7 made :segment the default strategy
;;; for BOTH constructors, but every :segment test above passes :strategy
;;; explicitly, and the one existing test that touches the default
;;; (STORE-ADD-NORMALISES-NON-CONFORMING-EMBEDDING in tests-vivace/schema.lisp)
;;; asserts on a raw vertex slot that is identical under all three strategies.
;;; So flipping the default back to :cache in both MAKE-GRAPH-STORE and
;;; OPEN-GRAPH-STORE left the whole suite green.  These two tests pin the
;;; default directly, with no :STRATEGY argument at all.

(test make-graph-store-defaults-to-segment
  "V:MAKE-GRAPH-STORE's :STRATEGY defaults to :SEGMENT.  Mutate the default
back to :CACHE in MAKE-GRAPH-STORE (vivace/store.lisp) and this must fail --
verified by hand as part of the final review (see task-7-report.md)."
  (with-temp-directory (dir)
    (let ((graph (gdb:make-graph :cl-llm-vg-default-ctor dir :buffer-pool-size 1000)))
      (unwind-protect
           (is (typep (v:make-graph-store graph) 'v:segment-graph-store)
               "make-graph-store's default strategy is not :segment")
        (gdb:close-graph graph :snapshot-p nil)))))

(test open-graph-store-defaults-to-segment
  "Same pin as MAKE-GRAPH-STORE-DEFAULTS-TO-SEGMENT, through V:OPEN-GRAPH-STORE
on a GENUINE REOPEN of a persisted graph -- not a fresh GDB:MAKE-GRAPH, since
that is the call OPEN-GRAPH-STORE actually makes internally and the one a real
caller reopening a store hits.  Mutate the default back to :CACHE in
OPEN-GRAPH-STORE and this must fail."
  (with-temp-directory (dir)
    (let ((graph (gdb:make-graph :cl-llm-vg-default-open dir :buffer-pool-size 1000)))
      (gdb:close-graph graph :snapshot-p nil))
    (let ((store (v:open-graph-store (namestring dir) :name :cl-llm-vg-default-open)))
      (unwind-protect
           (is (typep store 'v:segment-graph-store)
               "open-graph-store's default strategy is not :segment")
        (gdb:close-graph (v:graph-store-graph store) :snapshot-p nil)))))

;;; ---------------------------------------------------------------------------
;;; Final review item 5.  GDB:VECTOR-SEARCH returns NIL, not a signal, when no
;;; segment exists yet (documented on GDB:VECTOR-SEARCH); nothing pinned that
;;; behaviour reaching STORE-SEARCH unchanged.

(test segment-search-on-an-empty-store-returns-nil
  "A freshly created :segment store with no chunks -- so no segment has ever
been created for it -- must have STORE-SEARCH return NIL, not signal.  Making
GDB:VECTOR-SEARCH (or this method's handling of its result) signal instead of
returning NIL breaks this."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-empty dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (is (= 0 (rag:store-count store))
                 "fixture broken: store is not empty, ~D chunks present"
                 (rag:store-count store))
             (is (null (gethash (cons (v::chunk-type-symbol 'rag-chunk)
                                      (intern "EMBEDDING" :graph-db))
                                (gdb::vector-segments graph)))
                 "fixture broken: a segment already exists on an empty store")
             (let ((hits (rag:store-search store (unit-query 8 1.0) 5)))
               (is (null hits) "expected NIL from an empty store, got ~S" hits)))
        (gdb:close-graph graph :snapshot-p nil)))))

(test segment-search-filters-deleted-vertices
  "GDB:LOOKUP-VERTEX \"returns the vertex regardless of its deleted flag\"
(vertex.lisp), and GDB:REBUILD-VECTOR-SEGMENT-BATCHED is additive -- it never
removes a stale id from the segment.  So a chunk deleted by a writer that
shares the graph but whose class never declared :VECTOR-INDEX on this slot
(an older cl-llm, or another app) leaves the segment un-reconciled: the id
stays present and comes back as a search hit even though the vertex is
deleted.

There is no PUBLIC way to reach that drifted state: every delete this library
performs (RAG:STORE-DELETE-DOCUMENTS -> GDB:MARK-DELETED) goes through the
transaction apply path, and APPLY-TX-WRITE-TO-VECTOR-SEGMENTS
(transactions.lisp) already removes the id from the segment on every delete
of a :VECTOR-INDEX-declared slot -- which this schema's EMBEDDING slot always
is.  So, as the review item anticipates, the drift is built through GDB
internals: mark the vertex's DELETED-P slot directly via a raw SETF, the same
\"bypass the transaction machinery\" idiom already documented and used in
%MIGRATE-EMBEDDING-BATCH's comment above, rather than going through
GDB:MARK-DELETED / a transaction (which would clean the segment itself and
leave nothing to filter). Confirmed to work here because GDB:LOOKUP-VERTEX
returns the SAME live, buffer-pool-cached object on every call within a
process (checked by hand against the running image before writing this
test), so the raw SETF is visible to the vertex STORE-SEARCH itself looks up
-- it is not a mutation of a throwaway copy."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-filter-deleted dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0) (test-chunk "b" 8 1.0)))
             (let* ((verts (gdb:map-vertices (lambda (x) x) graph
                                             :vertex-type (v::chunk-type-symbol 'rag-chunk)
                                             :collect-p t))
                    (victim (find "a" verts
                                  :key (lambda (x) (v::%slot x "DOCUMENT-ID"))
                                  :test #'string=)))
               (is (not (null victim)) "fixture broken: chunk 'a' not found")
               (when victim
                 (setf (gdb:deleted-p victim) t)
                 ;; Fixture check: the id must still be IN the segment -- if it
                 ;; were already gone this test would pass even with the bug
                 ;; reintroduced, proving nothing.
                 (let ((seg (gethash (cons (v::chunk-type-symbol 'rag-chunk)
                                           (intern "EMBEDDING" :graph-db))
                                     (gdb::vector-segments graph))))
                   (is (not (null seg)) "fixture broken: no segment")
                   (when seg
                     (is (not (null (gdb::segment-get seg (gdb:id victim))))
                         "fixture broken: deleted id is no longer in the segment, ~
so this test cannot distinguish filtering from absence")))
                 (let ((hits (rag:store-search store (unit-query 8 1.0) 5)))
                   (is (plusp (length hits))
                       "fixture broken: no hits at all, so the negative assertion ~
below would be vacuous")
                   (is (notany (lambda (h)
                                 (string= "a" (rag:chunk-document-id (rag:hit-chunk h))))
                               hits)
                       "deleted chunk 'a' was returned by store-search: ~S"
                       (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) hits))
                   (is (some (lambda (h)
                               (string= "b" (rag:chunk-document-id (rag:hit-chunk h))))
                             hits)
                       "live chunk 'b' should still be returned: ~S"
                       (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) hits))))))
        (gdb:close-graph graph :snapshot-p nil)))))

;;; ---------------------------------------------------------------------------
;;; Migration of a pre-segment corpus (Task 5).

(defun chunk-segment-key (&optional (type 'rag-chunk))
  (cons (v::chunk-type-symbol type) (intern "EMBEDDING" :graph-db)))

(defun chunk-segment (graph &optional (type 'rag-chunk))
  "The registered vector segment for TYPE's EMBEDDING slot in GRAPH, or NIL."
  (gethash (chunk-segment-key type) (gdb::vector-segments graph)))

(defun chunk-segment-file (graph &optional (type 'rag-chunk))
  (let ((key (chunk-segment-key type)))
    (gdb::%segment-file graph (car key) (cdr key))))

(defun drop-chunk-segment (graph &optional (type 'rag-chunk))
  "Unregister and close GRAPH's chunk-embedding segment, leaving the vertices
alone.  Returns the segment FILE's path -- which is NOT removed here, because
the file is still mmapped until CLOSE-VECTOR-SEGMENT returns and because the
caller must delete it AFTER GDB:CLOSE-GRAPH (see the fixture note in
SEGMENT-STORE-MIGRATES-A-PRE-SEGMENT-CORPUS)."
  (let* ((key (chunk-segment-key type))
         (seg (gethash key (gdb::vector-segments graph)))
         (path (chunk-segment-file graph type)))
    (when seg (gdb::close-vector-segment seg))
    (remhash key (gdb::vector-segments graph))
    path))

(defmacro with-migration-spy ((calls) &body body)
  "Run BODY with V::*SEGMENT-MIGRATION-PROGRESS-FN* rebound to record every
progress call into the list CALLS (each entry a (DONE SEEN) list).

This is the only observable that distinguishes \"the migration skipped
everything already present\" from \"the migration re-did the work\":
GDB:REBUILD-VECTOR-SEGMENT-BATCHED calls the progress function once per
BATCH-SIZE INSERTIONS plus once at the end for a partial remainder, and NOT AT
ALL when it inserted nothing.  A re-insertion of an already-migrated corpus
would therefore produce a call; a pure skip scan produces none.  Counting
vectors cannot tell the two apart -- re-putting an id the segment already holds
overwrites its slot and leaves the live count identical."
  `(let ((,calls '()))
     (macrolet ((spy-calls () '(reverse ,calls)))
       (let ((v::*segment-migration-progress-fn*
               (lambda (done seen) (push (list done seen) ,calls))))
         ,@body))))

(test segment-store-migrates-a-pre-segment-corpus
  "THE OTHER CARRYING TEST.  A store whose chunks were written before the
:vector-index declaration existed must, on open as :segment, migrate and then
return the same results as a natively-built one.

FIXTURE NOTE -- this deliberately does MORE than the plan's snippet, which was
vacuous.  Dropping the segment from the graph's in-RAM VECTOR-SEGMENTS table is
not enough to simulate a pre-declaration corpus: GDB::CLOSE-VECTOR-SEGMENT
stamps the file CLEAN and leaves it on disk holding every vector, and
GDB::RESTORE-VECTOR-SEGMENTS re-registers exactly that file at the next
GDB:OPEN-GRAPH.  The reopened store would then find a full segment and return
its 10 hits WITH THE MIGRATION CALL REMOVED ENTIRELY.  The on-disk state an
upgrading deployment actually has is chunk vertices and NO SEGMENT FILE, so the
file is deleted here as well -- verified below with a PROBE-FILE assertion in
both directions so the fixture cannot silently stop simulating what it claims."
  (with-temp-directory (dir)
    (let ((seg-path nil))
      (let* ((graph (gdb:make-graph :cl-llm-vg-seg-migrate dir :buffer-pool-size 1000))
             (store (v:make-graph-store graph :strategy :scan :dimension 8)))
        (rag:store-add store (agreement-corpus 20))
        (setf seg-path (drop-chunk-segment graph))
        (gdb:close-graph graph :snapshot-p nil))
      ;; The fixture is only a fixture if the file was really there and is
      ;; really gone; assert both rather than trusting DELETE-FILE.
      (is (probe-file seg-path)
          "fixture broken: no segment file at ~A to delete" seg-path)
      (delete-file seg-path)
      (is (null (probe-file seg-path))
          "fixture broken: segment file ~A still present" seg-path)
      (with-migration-spy (calls)
        (let ((store (v:open-graph-store (namestring dir)
                                         :name :cl-llm-vg-seg-migrate
                                         :strategy :segment :dimension 8)))
          (unwind-protect
               (progn
                 ;; The migration actually ran and inserted all 20 -- not merely
                 ;; "some segment exists".
                 (is (equal '((20 20)) (spy-calls))
                     "expected one progress call reporting 20 inserted, got ~S"
                     (spy-calls))
                 (let ((seg (chunk-segment (v:graph-store-graph store))))
                   (is (not (null seg)) "migration created no segment")
                   (when seg
                     (is (= 20 (gdb::segment-live-count seg))
                         "expected 20 vectors in the migrated segment, got ~D"
                         (gdb::segment-live-count seg))))
                 (is (= 20 (rag:store-count store))
                     "expected 20 chunks after migration, got ~D" (rag:store-count store))
                 (let ((hits (rag:store-search store (unit-query 8 1.0) 10)))
                   (is (= 10 (length hits))
                       "migrated store returned ~D hits, expected 10" (length hits))
                   (when (= 10 (length hits))
                     (is (= 10 (length (remove-duplicates
                                        (mapcar (lambda (h)
                                                  (rag:chunk-document-id (rag:hit-chunk h)))
                                                hits)
                                        :test #'string=)))
                         "migration produced duplicate chunks: ~S"
                         (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
                                 hits)))))
            (gdb:close-graph (v:graph-store-graph store) :snapshot-p nil)))))))

(test segment-migration-is-idempotent-on-reopen
  "Opening an already-migrated store must not re-migrate or duplicate anything --
the skip-what-exists property, observed from the cl-llm side.

Counting chunks and hits alone CANNOT prove this: re-putting an id the segment
already holds overwrites the same slot, so a hydrate that blindly re-inserted
the whole corpus on every open would leave the live count, the store count and
the hit list all identical.  The load-bearing assertion is therefore the
progress spy -- GDB:REBUILD-VECTOR-SEGMENT-BATCHED calls the progress function
only for INSERTIONS, so zero calls means zero insertions, i.e. a pure skip
scan.  See WITH-MIGRATION-SPY."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-idem dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8)))
      (rag:store-add store (agreement-corpus 12))
      (is (= 12 (rag:store-count store))
          "fixture broken: ~D chunks written" (rag:store-count store))
      (gdb:close-graph graph :snapshot-p nil))
    (with-migration-spy (calls)
      (let ((store (v:open-graph-store (namestring dir)
                                       :name :cl-llm-vg-seg-idem
                                       :strategy :segment :dimension 8)))
        (unwind-protect
             (progn
               (is (null (spy-calls))
                   "reopen re-inserted into an already-populated segment: ~S"
                   (spy-calls))
               (is (= 12 (rag:store-count store))
                   "expected 12 after reopen, got ~D" (rag:store-count store))
               (let ((seg (chunk-segment (v:graph-store-graph store))))
                 (is (not (null seg)) "no segment after reopen")
                 (when seg
                   (is (= 12 (gdb::segment-live-count seg))
                       "expected 12 vectors in the segment after reopen, got ~D"
                       (gdb::segment-live-count seg))))
               (let ((hits (rag:store-search store (unit-query 8 1.0) 12)))
                 (is (= 12 (length hits)) "expected 12 hits, got ~D" (length hits))
                 (when (= 12 (length hits))
                   (is (= 12 (length (remove-duplicates
                                      (mapcar (lambda (h)
                                                (rag:chunk-document-id (rag:hit-chunk h)))
                                              hits)
                                      :test #'string=)))
                       "reopen duplicated chunks"))))
          (gdb:close-graph (v:graph-store-graph store) :snapshot-p nil))))))

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

;;; ---------------------------------------------------------------------------
;;; Legacy (non-conforming-embedding) corpus, fully searchable under the new
;;; :segment default (shipping-blocker fix on top of Task 7).

(defun %insert-legacy-double-float-chunks (g n dim)
  "Insert N chunk vertices directly into G, each with a boxed T-vector of
DOUBLE-FLOAT as its EMBEDDING slot -- exactly the shape a pre-existing corpus
(recorded: 19,973 chunks of 1024-dimension double-float embeddings) has on
disk. Bypasses RAG:STORE-ADD / VALIDATE-CHUNKS entirely (which now normalises
every embedding on write) so the resulting vertices are genuinely
non-conforming, the way a corpus written before this project existed would
be -- see %INSERT-LEGACY-VERTICES in tests-vivace/store-scan.lisp for the
same idiom used against :scan.

Each chunk gets a distinct DOCUMENT-ID (\"leg-0\" .. \"leg-(N-1)\") and a
one-hot embedding (component (I MOD DIM) set to (1+ I), the rest 0.0d0), so
every chunk is individually identifiable by document-id even though several
may land on the same one-hot position when N > DIM -- irrelevant here since
the test asserts on the SET of document-ids returned, not on ranking order."
  (v::ensure-chunk-schema g 'rag-chunk)
  (let ((gdb:*graph* g))
    (gdb:with-transaction ()
      (dotimes (i n)
        (let ((e (make-array dim :initial-element 0.0d0)))
          (setf (aref e (mod i dim)) (coerce (1+ i) 'double-float))
          (funcall (v::chunk-constructor 'rag-chunk)
                   :text (format nil "legacy chunk ~D" i)
                   :document-id (format nil "leg-~D" i)
                   :metadata nil
                   :embedding e
                   :graph g))))))

(test segment-store-legacy-corpus-fully-searchable
  "SHIPPING-BLOCKING FIX (found reviewing Task 7).  A pre-existing corpus of
non-conforming (here: boxed DOUBLE-FLOAT) embeddings must become FULLY
searchable under the new :segment default -- not merely open without error.

Without HYDRATE on SEGMENT-GRAPH-STORE calling MIGRATE-EMBEDDINGS first,
GDB:REBUILD-VECTOR-SEGMENT-BATCHED filters every candidate through the
engine's %NODE-SEGMENT-VALUE, which returns NIL -- silently, no error or
warning -- for anything that is not already (simple-array single-float (*)).
A legacy chunk would therefore be skipped by the segment sweep, never
indexed, and absent from every STORE-SEARCH result forever. Since :segment is
now what a bare (v:make-graph-store graph) / (v:open-graph-store path) gets
you, this is the naive upgrade path a real user hits, not an edge case.

The assertion is on RESULTS, not merely on open succeeding or STORE-COUNT:
the bug is silent omission from search results specifically, and STORE-COUNT
(a vertex scan, unaffected by the segment) would report the right number of
chunks even with a completely empty segment -- it would not catch this at
all. Guarded against a vacuous pass: the expected count (N) is asserted
before the contents, and the query is built so every one of the N legacy
chunks scores IDENTICALLY against it once migrated to unit-norm (each is a
one-hot vector; the query is uniform, so cosine is 1/sqrt(dim) for all of
them) -- there is no ranking order for a subset of them to hide behind; a
k=n search returns all n or it demonstrably dropped some."
  (with-temp-directory (dir)
    (let* ((dim 8)
           (n 15)
           (expected-ids (sort (loop for i from 0 below n collect (format nil "leg-~D" i))
                               #'string<))
           (graph (gdb:make-graph :cl-llm-vg-seg-legacy dir :buffer-pool-size 1000)))
      (unwind-protect
           (progn
             (%insert-legacy-double-float-chunks graph n dim)
             ;; Open as :segment -- the new default -- and let HYDRATE run the
             ;; migration + segment sweep.
             (let* ((store (v:make-graph-store graph :strategy :segment :dimension dim))
                    (q (make-array dim :element-type 'single-float :initial-element 1.0))
                    (hits (rag:store-search store q n)))
               (is (= n (length hits))
                   "expected all ~D legacy chunks in search results, got ~D -- some ~
were silently dropped by the segment migration" n (length hits))
               (when (= n (length hits))
                 (let ((got-ids (sort (mapcar (lambda (h)
                                                (rag:chunk-document-id (rag:hit-chunk h)))
                                              hits)
                                      #'string<)))
                   (is (equal expected-ids got-ids)
                       "search results do not cover the full legacy corpus: expected ~S, got ~S"
                       expected-ids got-ids)))))
        (gdb:close-graph graph :snapshot-p nil)))))

;;; ---------------------------------------------------------------------------
;;; The performance premise (Task 6): store-search must not materialise the
;;; corpus.

(test segment-search-does-not-materialise-the-corpus
  "THE PERFORMANCE PREMISE, asserted structurally.  Node loading was ~92% of the
old store-search cost; the segment exists so ranking never touches a node it is
not going to return.  A search for k over a corpus of N >> k must build at most
k * *segment-overfetch-factor* chunks -- not N.

Counted, never timed: a timing assertion would be flaky and would not
distinguish 'fast' from 'correct'.

The counter is installed by rebinding V::VERTEX->CHUNK's SYMBOL-FUNCTION --
V:STORE-SEARCH's only call to it is the per-candidate build inside the hit
loop (vivace/store.lisp); HYDRATE/migration never call it (it probes the
dimension via a raw slot read and drives GDB:REBUILD-VECTOR-SEGMENT-BATCHED
instead), so counting only starts AFTER the store is built and populated
below, deliberately outside the counted window."
  (with-temp-directory (dir)
    (let* ((graph (gdb:make-graph :cl-llm-vg-seg-perf dir :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :segment :dimension 8))
           (built 0)
           (k 5)
           (corpus-size 200))
      (unwind-protect
           (progn
             (rag:store-add store (agreement-corpus corpus-size))
             (let ((original (symbol-function 'v::vertex->chunk)))
               (unwind-protect
                    (progn
                      (setf (symbol-function 'v::vertex->chunk)
                            (lambda (vertex) (incf built) (funcall original vertex)))
                      (let ((hits (rag:store-search store (unit-query 8 1.0) k)))
                        (is (= k (length hits)) "expected ~D hits, got ~D" k (length hits))))
                 (setf (symbol-function 'v::vertex->chunk) original)))
             (is (plusp built)
                 "no chunks were built at all -- the counter never fired, so this ~
test proves nothing")
             (is (<= built (* k v::*segment-overfetch-factor*))
                 "materialised ~D chunks for a k=~D search over ~D -- the search is ~
loading nodes it does not return, which is the cost this whole phase exists to ~
remove" built k corpus-size)
             (is (< built corpus-size)
                 "materialised ~D of ~D chunks -- that is a full corpus scan" built corpus-size))
        (gdb:close-graph graph :snapshot-p nil)))))
