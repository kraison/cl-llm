;;;; vivace/store.lisp -- graph-backed vector stores.

(in-package #:cl-llm.rag.vivace)

(defclass graph-store ()
  ((graph :initarg :graph :reader graph-store-graph)
   (type :initarg :type :initform 'rag-chunk :reader graph-store-type)
   (dimension :initarg :dimension :initform nil :accessor graph-store-dimension))
  (:documentation "Abstract: borrows a caller-owned graph-db graph."))

(defclass scan-graph-store (graph-store) ()
  (:documentation "store-search scans the chunk vertices and computes cosine."))

(defgeneric hydrate (store)
  (:documentation "Initialise a store from chunk vertices already in the graph."))

(defparameter *embedding-migration-policy* :migrate
  "What HYDRATE does with stored embeddings that are not already normalised
single-float arrays.  :MIGRATE rewrites them in place (default).  :ERROR refuses
to open the store.  There is deliberately no :IGNORE -- scoring after Phase 1 is
a bare dot product, so an unnormalised stored vector ranks WRONG rather than
merely slow, and a silent wrong answer is the failure mode this guards.")

(defparameter *embedding-migration-batch-size* 5000
  "Number of victim vertices MIGRATE-EMBEDDINGS rewrites per gdb:with-transaction.
GDB:COPY duplicates the WHOLE vertex -- TEXT and METADATA included, not just the
EMBEDDING slot -- which measured ~40KB/chunk end-to-end (RSS delta / chunk count) on a
real 19,973-chunk legacy store of 1024-dimension double-float embeddings. 5000 chunks
per batch bounds that transient copy overhead to roughly 200MB regardless of corpus
size -- safe on any machine this runs on -- while keeping the transaction count for the
reference corpus to 4 (was 1, and that 1 needed +771MB RSS and ~22.6s) and for the
1M-vector corpus this project targets to ~200 (was 1, and that 1 needed ~38GB and ~19
minutes -- and does not run at all on any machine here). More transactions cost
per-transaction overhead; fewer cost peak memory and a bigger chunk of lost progress if
a later batch fails; 5000 sits comfortably on the safe side of that trade for the
failure mode that matters here -- resumability -- not raw throughput.")

(defun %needs-migration-p (e)
  "T if E needs rewriting: either it is not yet the specialised single-float
array type, or it IS that type but is not unit-norm.  The second disjunct
measures E's OWN norm via RAG:EMBEDDING-NORM -- it must NOT run E through
RAG:AS-EMBEDDING first, since AS-EMBEDDING renormalises its output to ~1.0
for any non-zero input, which would make this check a tautology (always
true-by-~1.0, regardless of E's actual stored norm) and silently skip
migrating any already-single-float, non-unit-norm vector forever.  OR only
evaluates the second disjunct when the first is false, and the first being
false means E is already (simple-array single-float (*)) -- exactly the type
EMBEDDING-NORM declares, so no coercion is needed here."
  (or (not (typep e '(simple-array single-float (*))))
      (> (abs (- 1.0 (rag:embedding-norm e))) 1e-4)))

(defun %migrate-embedding-batch (graph victims start end)
  "Copy-modify-save the vertices at VICTIMS[START,END) (a vector of ids) inside one
gdb:with-transaction. VICTIMS holds ids, not vertex objects (see MIGRATE-EMBEDDINGS);
each vertex is looked up fresh here, inside the transaction, so the read participates
in the transaction's read-set like any other transactional read.

Go through graph-db's copy-modify-save idiom (gdb:copy / gdb:save), NOT a raw
(setf (slot-value ...)) on the live vertex fetched by lookup-vertex: a bare slot-value
setf on an in-place node bypasses the transaction's write-set (populated only by
UPDATE-NODE, which SAVE calls), so it gets no OCC conflict validation and no
replication/txn-log participation, even though it happens to end up on disk via
close-graph's unconditional snapshot in the common single-writer case. COPY registers
a mutable copy with the current transaction; SAVE runs it through UPDATE-NODE like any
other write."
  (let ((gdb:*graph* graph))
    (gdb:with-transaction ()
      (loop for i from start below end
            do (let* ((v (gdb:lookup-vertex (aref victims i) :graph graph))
                      (c (gdb:copy v)))
                 (setf (slot-value c (intern "EMBEDDING" :graph-db))
                       (rag:as-embedding (%slot v "EMBEDDING")))
                 (gdb:save c))))))

(defun migrate-embeddings (store)
  "Rewrite any stored embedding that is not already a normalised single-float array.
Returns the number of chunks rewritten.

Collect victim IDS during the scan, not vertex objects: ids are a few bytes each, so
holding all of them for a million-chunk corpus is negligible, unlike holding the full
vertex objects (which is what made the pre-batching version's peak RSS scale with
corpus size before a single byte was written). Do NOT mutate while map-vertices
iterates -- that's why collection still happens before any write.

Writes happen in batches of *EMBEDDING-MIGRATION-BATCH-SIZE*, one gdb:with-transaction
per batch, committing as it goes: peak memory is bounded by the batch rather than the
whole corpus, and progress from a batch that already committed survives a crash in a
LATER batch. This is deliberately NOT atomic across the whole corpus: an
all-or-nothing transaction across a huge corpus makes a store too large to migrate
atomically PERMANENTLY unopenable (every open re-attempts the identical operation and
fails identically, under either policy), whereas %NEEDS-MIGRATION-P is a per-vector
predicate, so an interrupted batched run is resumable for free -- the next open only
re-migrates whatever is still non-conforming. A half-migrated store is already the
state that exists transiently during any migration; resumability is worth more than
atomicity for this one-way upgrade."
  (let ((graph (graph-store-graph store))
        (victim-ids '()))
    (map-chunk-vertices
     store
     (lambda (vertex)
       (when (%needs-migration-p (%slot vertex "EMBEDDING"))
         (push (gdb:id vertex) victim-ids))))
    (when victim-ids
      (ecase *embedding-migration-policy*
        (:error
         (error 'rag:llm-rag-error
                :message (format nil "~a stored embeddings are not normalised ~
                                      single-float vectors; scoring would rank ~
                                      them incorrectly. Re-embed, or set ~
                                      *embedding-migration-policy* to :migrate."
                                 (length victim-ids))))
        (:migrate
         (let* ((victims (coerce (nreverse victim-ids) 'vector))
                (total (length victims))
                (migrated 0))
           (format t "~&migrate-embeddings: ~d embedding~:p need migration; rewriting ~
                      in batches of ~d~%"
                   total *embedding-migration-batch-size*)
           (finish-output)
           (loop for start from 0 below total by *embedding-migration-batch-size*
                 for end = (min total (+ start *embedding-migration-batch-size*))
                 do (%migrate-embedding-batch graph victims start end)
                    (incf migrated (- end start))
                    (format t "~&migrate-embeddings: ~d/~d migrated~%" migrated total)
                    (finish-output))))))
    (length victim-ids)))

(defun validate-chunks (store chunks)
  "Validate CHUNKS (non-nil embedding + consistent dimension) WITHOUT mutating
the graph, and normalise each chunk's embedding to a conforming
(simple-array single-float (*)) unit vector via RAG:AS-EMBEDDING -- IN PLACE
on the chunk object (SETF RAG:CHUNK-EMBEDDING), so CHUNK->VERTEX (called
afterwards on these same chunk objects by STORE-ADD) writes the normalised
value, not the raw caller-supplied one. This is write-side enforcement: a
chunk added via STORE-ADD after HYDRATE has already run is never touched by
MIGRATE-EMBEDDINGS, so without this a raw double-float or un-normalised
embedding would reach the EMBEDDING slot untouched and later blow up
SCAN-GRAPH-STORE's STORE-SEARCH -- which scores that slot directly under a
(simple-array single-float (*)) declaration -- with a TYPE-ERROR at query
time, far from the STORE-ADD call that caused it. RAG:AS-EMBEDDING already
rejects non-finite input (NaN/infinity) with RAG:LLM-RAG-ERROR (Task 4), so
genuinely bad input is still refused; only fixable input (wrong float type,
non-unit magnitude) is silently corrected. Returns the dimension the batch
establishes. Signals rag:llm-rag-error."
  (let ((dim (graph-store-dimension store)))
    (dolist (chunk chunks)
      (let ((e (rag:chunk-embedding chunk)))
        (unless e
          (error 'rag:llm-rag-error :message "cannot index a chunk with no embedding"))
        (if dim
            (unless (= (length e) dim)
              (error 'rag:llm-rag-error
                     :message (format nil "embedding dimension ~a does not match the ~
                                           store's dimension ~a" (length e) dim)))
            (setf dim (length e)))
        (setf (rag:chunk-embedding chunk) (rag:as-embedding e))))
    dim))

(defmethod rag:store-add ((store graph-store) chunks)
  (when chunks
    (let ((dim (validate-chunks store chunks))       ; validate BEFORE writing
          (graph (graph-store-graph store))
          (type (graph-store-type store)))
      (let ((gdb:*graph* graph))
        (gdb:with-transaction ()
          (dolist (chunk chunks)
            (chunk->vertex graph type chunk))))
      (when (null (graph-store-dimension store))
        (setf (graph-store-dimension store) dim))))
  store)

(defun map-chunk-vertices (store fn)
  "Call FN on each chunk vertex in STORE's graph."
  (gdb:map-vertices fn (graph-store-graph store)
                    :vertex-type (chunk-type-symbol (graph-store-type store))))

(defun graph-store-chunks (store)
  "All chunks currently in STORE's graph, as rag:chunk objects (for building a secondary index)."
  (let ((out '()))
    (map-chunk-vertices store (lambda (v) (push (vertex->chunk v) out)))
    (nreverse out)))

(defun %document-id-set (document-ids)
  "A hash-set of DOCUMENT-IDS for O(1) EQUAL membership during a delete scan."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (id document-ids set)
      (setf (gethash id set) t))))

(defmethod rag:store-delete-documents ((store graph-store) document-ids)
  "Soft-delete every chunk vertex whose DOCUMENT-ID is in DOCUMENT-IDS, atomically.

ONE scan for the whole id set, not one scan per id: a scan is O(corpus), so deleting n
documents one at a time is O(n*corpus).  Refreshing 3220 documents in a 23k-chunk store
that way tracked to ~2 hours against ~8 minutes for the same work as pure adds.

Collect the victims first (do NOT mutate the graph while map-vertices iterates), then
mark-deleted them in one transaction (mark-deleted joins the active tx)."
  (let ((ids (%document-id-set document-ids))
        (victims '()))
    (map-chunk-vertices
     store
     (lambda (vertex)
       (when (gethash (%slot vertex "DOCUMENT-ID") ids)
         (push vertex victims))))
    (when victims
      (let ((gdb:*graph* (graph-store-graph store)))
        (gdb:with-transaction ()
          (dolist (v victims)
            (gdb:mark-deleted v)))))
    (length victims)))

(defmethod rag:store-count ((store scan-graph-store))
  (let ((n 0))
    (map-chunk-vertices store (lambda (v) (declare (ignore v)) (incf n)))
    n))

(defmethod rag:store-search ((store scan-graph-store) query-vector k)
  (when (and (graph-store-dimension store)
             (/= (length query-vector) (graph-store-dimension store)))
    (error 'rag:llm-rag-error
           :message (format nil "query dimension ~a does not match store dimension ~a"
                            (length query-vector) (graph-store-dimension store))))
  ;; Score against the embedding slot only, and build a rag:chunk ONLY for the
  ;; survivors.  vertex->chunk per candidate was the dominant cost: it rebuilt
  ;; text and metadata for every chunk in the corpus to rank five of them.
  (let ((collector (rag::top-k-collector k)))
    (map-chunk-vertices
     store
     (lambda (vertex)
       ;; Score the slot value DIRECTLY.  Do NOT call as-embedding here: after
       ;; Task 4 it allocates and L2-normalises, which would put one allocation,
       ;; one sqrt and DIM divisions in the per-candidate inner loop -- exactly
       ;; the cost Tasks 1-3 exist to remove.  Task 6's migration guarantees the
       ;; slot is already a normalised (simple-array single-float (*)).
       (let ((e (%slot vertex "EMBEDDING")))
         (declare (type (simple-array single-float (*)) e))
         (rag::collect-candidate collector
                                 (rag:cosine query-vector e)
                                 (or (%slot vertex "DOCUMENT-ID") "")
                                 vertex))))
    (mapcar (lambda (pair)
              (rag:make-hit (vertex->chunk (cdr pair)) (car pair)))
            (rag::collector-results collector))))

(defmethod hydrate ((store scan-graph-store))
  (migrate-embeddings store)
  ;; Record the dimension from the first existing chunk, if any. Do NOT do a
  ;; non-local exit out of map-vertices (it may hold locks); iterate and set once.
  (unless (graph-store-dimension store)
    (map-chunk-vertices
     store
     (lambda (vertex)
       (unless (graph-store-dimension store)
         (setf (graph-store-dimension store)
               (length (rag:as-embedding (%slot vertex "EMBEDDING"))))))))
  store)

;; save-store is generic in cl-llm.rag; a graph is self-durable, so this is a
;; documented no-op that returns the store (never closes the borrowed graph).
;; Explicit checkpointing is the caller's (graph-db close-graph / snapshot).
(defmethod rag:save-store ((store graph-store) path)
  (declare (ignore path))
  store)

(defun make-graph-store (graph &key (type 'rag-chunk) (strategy :segment) dimension)
  "Make a graph-backed vector store over the already-open, caller-owned GRAPH.
Self-declares the chunk vertex type and hydrates from any chunks already in the
graph. Never opens or closes GRAPH.

STRATEGY is :segment (default), :cache or :scan.
  :segment  embeddings live in graph-db's mmap vector segment; search never
            materialises a node it will not return, and the corpus need not fit
            in the Lisp heap.  The right default for a persistent graph.
  :cache    an in-RAM index; FASTER than :segment (~15ms vs ~35ms at 20k, because
            the corpus is already in the heap) and the right choice when it fits
            there.  NOT deprecated.
  :scan     no index; scores every chunk vertex per query.  Fallback and
            correctness reference.

All three return the same ranking through the STORE-SEARCH contract.  Scores are
identical too for the unit-norm query vectors RAG:EMBED produces; on a NON-unit
query :segment's score is :cache's divided by the query norm (the engine computes
a full cosine, :cache a bare dot) -- ordering is unaffected.  See
RAG:STORE-SEARCH on SEGMENT-GRAPH-STORE.

The default changed from :cache to :segment: a caller that never passed
:STRATEGY now gets a segment-backed store, which on an existing corpus pays a
one-time migration sweep at open (see HYDRATE on SEGMENT-GRAPH-STORE).  Pass
:STRATEGY :CACHE explicitly to keep the old behaviour."
  (ensure-chunk-schema graph type)
  (let ((store (ecase strategy
                 (:scan (make-instance 'scan-graph-store
                                       :graph graph :type type :dimension dimension))
                 (:cache (make-cached-graph-store graph type dimension))
                 (:segment (make-instance 'segment-graph-store
                                          :graph graph :type type :dimension dimension)))))
    (hydrate store)
    store))

(defclass cached-graph-store (graph-store)
  ((index :initarg :index :reader cache-index))
  (:documentation "Composes a rag:memory-store as an in-RAM search index."))

(defun make-cached-graph-store (graph type dimension)
  (make-instance 'cached-graph-store
                 :graph graph :type type :dimension dimension
                 :index (rag:make-memory-store)))

;; store-add's primary method (on graph-store) validates + writes to the graph;
;; this :after mirrors the same chunks into the in-RAM index for search.
(defmethod rag:store-add :after ((store cached-graph-store) chunks)
  (when chunks
    (rag:store-add (cache-index store) chunks)))

;; Keep the in-RAM index (which store-count/store-search read) in step with the graph delete.
;; This hangs off the PLURAL, which is the primitive: rag:store-delete-document is a default
;; method that delegates to the plural, so a singular delete still syncs the cache exactly
;; once -- whereas an :after on BOTH would sync it twice.
(defmethod rag:store-delete-documents :after ((store cached-graph-store) document-ids)
  (rag:store-delete-documents (cache-index store) document-ids))

(defmethod rag:store-count ((store cached-graph-store))
  (rag:store-count (cache-index store)))

(defmethod rag:store-search ((store cached-graph-store) query-vector k)
  (rag:store-search (cache-index store) query-vector k))

(defmethod hydrate ((store cached-graph-store))
  (migrate-embeddings store)
  (let ((chunks (graph-store-chunks store)))
    (when chunks
      (rag:store-add (cache-index store) chunks)
      ;; Sync the abstract dimension slot so the primary store-add's dimension
      ;; check (which runs BEFORE the graph write) validates post-hydrate adds
      ;; against the hydrated dimension -- otherwise a wrong-dimension chunk could
      ;; reach the graph before the cache's :after catches it.
      (setf (graph-store-dimension store) (rag:store-dimension (cache-index store)))))
  store)

(defclass segment-graph-store (graph-store) ()
  (:documentation "store-search delegates to graph-db's mmap vector segment via
GDB:VECTOR-SEARCH, so ranking never materialises a node it is not going to
return -- node loading was ~92% of the old store-search cost.

Unlike CACHED-GRAPH-STORE there is no in-RAM index to keep in step: the segment
is maintained by the transaction apply path, because the chunk EMBEDDING slot is
declared :VECTOR-INDEX.  That is why STORE-ADD and STORE-DELETE-DOCUMENTS need no
:AFTER methods here -- adding them would be duplicated bookkeeping for a
structure the database already maintains."))

(defmethod rag:store-count ((store segment-graph-store))
  (let ((n 0))
    (map-chunk-vertices store (lambda (v) (declare (ignore v)) (incf n)))
    n))

(defparameter *segment-migration-batch-size* 5000
  "Chunks per progress report while migrating a pre-segment corpus.

The number is inherited from *EMBEDDING-MIGRATION-BATCH-SIZE*'s measurement
(gdb:copy duplicates the WHOLE vertex, ~40KB/chunk, so batching is what keeps a
1M-chunk migration off a ~38GB unbatched transaction), but note what it means
HERE: GDB:REBUILD-VECTOR-SEGMENT-BATCHED writes each vector straight to the mmap
outside any transaction, so this bounds nothing in memory -- it is purely the
cadence at which *SEGMENT-MIGRATION-PROGRESS-FN* is called.  Lower it to hear
from a slow migration more often; it does not change what the migration costs.")

(defparameter *segment-migration-progress-fn*
  (lambda (done seen)
    (format *error-output* "~&; segment migration: ~:D indexed (~:D chunk~:P seen)~%"
            done seen)
    (finish-output *error-output*))
  "Called every *SEGMENT-MIGRATION-BATCH-SIZE* insertions during migration, and
once more at the end for a partial remainder.  A migration of a real corpus
takes minutes and a silent one looks hung.

SEEN IS NOT A TOTAL.  The engine passes the number of conforming nodes
encountered SO FAR IN THIS RUN; there is no cheap way to know the corpus size
ahead of time and the engine does not compute one.  Reporting it as a
denominator would show a progress bar that reads 100% throughout, so it is
phrased as a running count.  Called ONLY for insertions, never for skips, which
is what makes an already-migrated store's HYDRATE silent.")

(defmethod hydrate ((store segment-graph-store))
  "Probe the dimension, then fill the vector segment with any chunk not already
in it.

MIGRATION IS BATCHED AND RESUMABLE, and its resumability comes from the segment
itself rather than from any marker kept here.  GDB:REBUILD-VECTOR-SEGMENT-BATCHED
is additive and skips ids the segment already holds, so an interrupted migration
is completed by the next open and an already-migrated store pays only the skip
scan.  There is deliberately NO progress file, checkpoint or \"migrated\" flag: a
marker that can disagree with the segment -- because the work it claimed was
rolled back, or because the process died between writing the marker and writing
the segment -- is strictly worse than no marker.  The segment is the only source
of truth, which is also why nothing here bothers to DETECT whether migration is
needed: the unconditional call IS the detection, and it is idempotent.

COST, stated plainly: a corpus large enough to matter pays a one-time
multi-minute sweep on the first open after upgrading into the :VECTOR-INDEX
declaration.  It is progress-logged (*SEGMENT-MIGRATION-PROGRESS-FN*) and
resumable, but it is not free, and every later open still pays a full
map-vertices skip scan.

CONCURRENCY: the engine requires that two migrations of the same segment never
run concurrently, so do not construct two :segment stores over one graph from
two threads at once.  Readers are safe -- every segment operation takes the
per-segment rw-lock, so a concurrent GDB:VECTOR-SEARCH sees a consistent, if
incomplete, snapshot.

Iterates FULLY rather than exiting early on the first hit: gdb:map-vertices may
hold locks, so a non-local exit out of it is unsafe.  Same reasoning, and the
same shape, as HYDRATE on SCAN-GRAPH-STORE.

MIGRATE-EMBEDDINGS RUNS FIRST, same as HYDRATE on SCAN-GRAPH-STORE and
CACHED-GRAPH-STORE, and for the same reason: GDB:REBUILD-VECTOR-SEGMENT-BATCHED
filters candidates through the engine's %NODE-SEGMENT-VALUE, which returns NIL
-- silently, no error or warning -- for any embedding that is not already a
conforming (simple-array single-float (*)).  A legacy chunk (e.g. a
double-float vector from before this store existed) would therefore be skipped
by the segment sweep rather than migrated into it, and would stay absent from
every subsequent GDB:VECTOR-SEARCH -- and therefore from every STORE-SEARCH
result -- forever, with no indication anything was dropped.  Calling
MIGRATE-EMBEDDINGS here, exactly as the other two strategies do, makes every
embedding conforming before the segment sweep runs, so :SEGMENT is not a
silent-data-loss upgrade path for a pre-segment corpus.  Respects
*EMBEDDING-MIGRATION-POLICY* like the other two strategies: :MIGRATE rewrites,
:ERROR refuses to open."
  (migrate-embeddings store)
  (unless (graph-store-dimension store)
    (map-chunk-vertices
     store
     (lambda (vertex)
       (unless (graph-store-dimension store)
         (let ((e (%slot vertex "EMBEDDING")))
           (when (typep e '(simple-array single-float (*)))
             (setf (graph-store-dimension store) (length e))))))))
  (multiple-value-bind (inserted skipped)
      (gdb:rebuild-vector-segment-batched
       (graph-store-graph store)
       (chunk-type-symbol (graph-store-type store))
       (intern "EMBEDDING" :graph-db)
       :batch-size *segment-migration-batch-size*
       :progress-fn *segment-migration-progress-fn*)
    (declare (ignorable skipped))
    ;; Say nothing when there was nothing to do: the common case is a store
    ;; that is already migrated, and announcing a no-op migration on every
    ;; open trains operators to ignore the line that matters.
    (when (plusp inserted)
      (format *error-output* "~&; segment migration complete: ~:D chunk~:P indexed~%"
              inserted)
      (finish-output *error-output*)))
  store)

(defparameter *segment-overfetch-factor* 4
  "How many times k to request from GDB:VECTOR-SEARCH before re-ranking.

Why over-fetch at all: the engine ranks score DESC then NODE-ID ASC, while
cl-llm ranks score DESC then DOCUMENT-ID ASC.  Asking for exactly k cannot be
repaired by re-ranking, because the engine may already have truncated a TIED
group at the k boundary using the wrong key -- the chunk cl-llm would have
ranked k-th may never be returned at all.  Over-fetching makes the whole tied
neighbourhood available to the re-rank.

4 is a judgement, not a measurement: it covers tied groups far larger than real
float embeddings produce, while keeping the extra work to a handful of node
loads.  It is exact only if no tied group straddling the k boundary is larger
than (* k (1- *segment-overfetch-factor*)); a pathological corpus of identical
embeddings could still diverge from :cache, which is why the agreement test
uses a corpus with deliberate ties.")

(defmethod rag:store-search ((store segment-graph-store) query-vector k)
  "Rank via the mmap vector segment, then re-rank the survivors with cl-llm's
own collector so the result is identical to :cache -- ties included.

Two properties this method must keep:

 (1) It never materialises a node it is not going to consider.  GDB:VECTOR-SEARCH
     touches only the segment's id array and its contiguous vector block and
     returns (score . node-id) conses; only those ids are turned into vertices
     and then chunks.  Node loading measured ~92% of the old STORE-SEARCH cost,
     which is the entire premise of this strategy.

 (2) It ranks exactly as :cache does.  The engine's tiebreak is node-id, ours is
     document-id, so the engine's own top-k is re-ranked here through
     RAG::TOP-K-COLLECTOR -- the same collector the scan and memory stores use,
     not a second ranking path -- over an over-fetched candidate set (see
     *SEGMENT-OVERFETCH-FACTOR*).

SCORE SCALE, on a NON-UNIT-NORM QUERY-VECTOR.  The score returned here is a FULL
cosine: GDB:SEGMENT-SCAN divides by the query's own norm.  :cache and :scan score
with RAG:COSINE, which is a BARE DOT product (valid as a cosine only because
stored embeddings are unit-norm, and only for a unit-norm query).  So for a query
of norm |q| /= 1 this method returns :cache's score divided by |q|.  ORDER is
unaffected -- 1/|q| is a positive constant across candidates -- so the strategies
are order-identical always, and score-identical exactly when the query is
unit-norm, which is what RAG:EMBED / RAG:AS-EMBEDDING always produce and what
every path in this system passes.

This difference is DELIBERATELY LEFT IN PLACE rather than papered over.
Normalising QUERY-VECTOR here would change nothing: the engine divides by the
query norm regardless, so a pre-normalised query yields the identical score.  The
only way to reproduce :cache's number would be to MULTIPLY the engine's cosine
back up by |q| -- i.e. to reintroduce :cache's non-cosine scaling into the one
strategy that computes a true cosine, so that an out-of-range \"similarity\" > 1
could be reported for an unnormalised query.  Matching a less correct number is
not worth it; the difference is documented instead, and pinned by
SEGMENT-AND-CACHE-SCORES-DIFFER-BY-THE-QUERY-NORM in tests-vivace/."
  (when (and (graph-store-dimension store)
             (/= (length query-vector) (graph-store-dimension store)))
    (error 'rag:llm-rag-error
           :message (format nil "query dimension ~a does not match store dimension ~a"
                            (length query-vector) (graph-store-dimension store))))
  (let* ((graph (graph-store-graph store))
         (type (chunk-type-symbol (graph-store-type store)))
         (hits (gdb:vector-search graph type (intern "EMBEDDING" :graph-db)
                                  query-vector
                                  (* k *segment-overfetch-factor*)))
         (collector (rag::top-k-collector k)))
    (let ((gdb:*graph* graph))
      (dolist (pair hits)
        (let ((vertex (gdb:lookup-vertex (cdr pair) :graph graph)))
          (when vertex
            (let ((chunk (vertex->chunk vertex)))
              (rag::collect-candidate collector
                                      (car pair)
                                      (or (rag:chunk-document-id chunk) "")
                                      chunk))))))
    ;; Same return shape as every other strategy: a list of RAG:HIT, built
    ;; (make-hit chunk score) -- chunk first.  Returning collector-results
    ;; directly would hand callers (score . chunk) conses and break all of them.
    (mapcar (lambda (pair) (rag:make-hit (cdr pair) (car pair)))
            (rag::collector-results collector))))

(defun path->graph-name (path)
  "A stable keyword graph name derived from PATH's last directory component."
  (intern (string-upcase (car (last (pathname-directory (pathname path))))) :keyword))

(defun open-graph-store (path &key (strategy :segment) (type 'rag-chunk) dimension
                                   (name (path->graph-name path)))
  "Open a standalone persistent graph at PATH and return a store over it. For the
RAG-only case with no field-data graph to share. The caller owns closing the graph
(via graph-store-graph).

STRATEGY is :segment (default), :cache or :scan -- see MAKE-GRAPH-STORE, which
this delegates to, for what each one is and when it is right.  In short:
:segment keeps embeddings in graph-db's mmap vector segment (search never
materialises a node it will not return, and the corpus need not fit in the Lisp
heap) and is the right default for a persistent graph; :cache is an in-RAM index
that is FASTER when the corpus fits in the heap and is NOT deprecated; :scan has
no index and rescans every chunk vertex per query (fallback and correctness
reference).

The default changed from :cache to :segment.  Reopening an existing store
without :STRATEGY therefore performs a one-time, resumable segment migration on
the first such open (HYDRATE on SEGMENT-GRAPH-STORE); pass :STRATEGY :CACHE to
keep the old behaviour."
  ;; Declare the chunk vertex class BEFORE gdb:open-graph: open-graph instantiates the persisted
  ;; chunks, which requires the class to exist.  make-graph-store's ensure-chunk-schema would
  ;; declare it -- but AFTER open, which is too late on a FRESH image (a restart), where the class
  ;; does not exist yet.  ensure-chunk-class is idempotent, so this is a no-op in a warm image.
  (ensure-chunk-class type name)
  (make-graph-store (gdb:open-graph name (pathname path))
                    :type type :strategy strategy :dimension dimension))
