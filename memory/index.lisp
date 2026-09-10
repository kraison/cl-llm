;;;; memory/index.lisp -- the semantic endpoint index: nearest by
;;;; vector, the materialise-then-drain over the derived dirty set, the
;;;; rebuild and the start-time segment reset (#78 SS3.3, SS4).
;;;; The embedder is a FUNCTION (text -> vector) plus a model name: this
;;;; system never depends on cl-llm/rag (SS5).

(in-package #:cl-llm.memory)

(defun nearest-endpoints (graph query-vector &key (k 10) model)
  "The endpoints of GRAPH whose profile vectors are nearest
QUERY-VECTOR by cosine, as ((NAMESPACE . KEY) . COSINE) best first, at
most K; a vertex that is deleted, holds no vector, or (with MODEL) was
embedded by another model is skipped.  NIL when no segment exists yet.
One hit per endpoint, keeping the best: without a DEF-UNIQUE an
endpoint may have more than one live vertex (SS2.5).  Trap: K bounds
the segment hits, so a filtered or duplicated hit costs an endpoint --
ask for more than the cap."
  (let ((seen (make-hash-table :test 'equal))
        (hits '()))
    (loop for (score . id) in (gdb:vector-search graph 'endpoint-vector
                                                 'embedding query-vector k)
          for ev = (gdb:lookup-vertex id :graph graph)
          when (and ev (not (gdb:deleted-p ev))
                    (endpoint-vector-value ev)
                    (or (null model) (string= model (ev-model ev))))
            do (let ((ep (cons (ev-namespace ev) (ev-key ev))))
                 (unless (gethash ep seen)
                   (setf (gethash ep seen) t)
                   (push (cons ep score) hits))))
    (nreverse hits)))

(defun dirty-endpoints (graph &optional model)
  "The endpoints of GRAPH that need embedding under MODEL (SS4.1), from
the vocabulary (count-index backed, #70).  Trap: opens a read snapshot,
so it must not be called inside a transaction."
  (with-scope-snapshots ((list graph))
    (remove-if-not (lambda (ep)
                     (endpoint-dirty-p graph (car ep) (cdr ep) model))
                   (vocabulary-endpoints (vocabulary graph)))))

(defun materialise-endpoint-vectors (graph)
  "Create a vector-less ENDPOINT-VECTOR (EV-MODEL \"\") for every
vocabulary endpoint of GRAPH that has none, in one transaction; => the
number created.  The drain runs this first so that in steady state both
it and TOUCH-ENDPOINTS only ever UPDATE an existing node, which is what
makes a touch racing a drain a write-write conflict (SS4.3 step 2).
Trap: the survey reads committed state outside the transaction, so a
concurrent first touch of the same endpoint can leave two vertices --
benign, there is no unique constraint (SS2.5)."
  (let ((missing (with-scope-snapshots ((list graph))
                   (remove-if (lambda (ep)
                                (endpoint-vector-of graph (car ep)
                                                    (cdr ep)))
                              (vocabulary-endpoints (vocabulary graph))))))
    (when missing
      (gdb:with-transaction (:graph graph)
        (dolist (ep missing)
          (make-endpoint-vector :graph graph :ev-namespace (car ep)
                                :ev-key (cdr ep) :ev-model ""))))
    (length missing)))

(defun %store-vector (graph namespace key vector model)
  "Write VECTOR and MODEL on the endpoint's vertex, inside the caller's
transaction.  Look up, update when found, else create: INDEX-LOOKUP
reads committed state only, so a vertex created by this very
transaction is invisible here.  After MATERIALISE-ENDPOINT-VECTORS that
can only happen for an endpoint first written and drained
concurrently, and a duplicate vertex is benign (SS2.5)."
  (let ((ev (endpoint-vector-of graph namespace key)))
    (if ev
        (let ((c (gdb:copy ev)))
          (setf (embedding c) vector (ev-model c) model)
          (gdb:save c))
        (make-endpoint-vector :graph graph :ev-namespace namespace
                              :ev-key key :ev-model model
                              :embedding vector))))

(defparameter *embed-passes* 4
  "Render-embed-store passes one endpoint gets before the drain leaves
it dirty for the next one (SS4.3 step 2).")

(defun %clear-one-endpoint (graph namespace key)
  "Clear the vector of every live vertex of the endpoint that holds
one; => T when it wrote, NIL when there was nothing to clear (and then
no transaction was opened).  Nothing is current, so nothing may stay
searchable (SS4.1)."
  (when (find-if #'endpoint-vector-value
                 (%endpoint-vectors-of graph namespace key))
    (gdb:with-transaction (:graph graph)
      (dolist (ev (%endpoint-vectors-of graph namespace key) t)
        (when (endpoint-vector-value ev)
          (let ((c (gdb:copy ev)))
            (setf (embedding c) nil (ev-model c) "")
            (gdb:save c)))))))

(defun %embed-endpoint (graph namespace key embed model)
  "Render, embed and store one endpoint; => T when a vector was
written, NIL when nothing is current or the profile kept changing.

The EMBED call runs OUTSIDE every transaction (SS4.3 step 2): an
embedder is a network round trip, and the engine's ninth attempt at a
transaction runs the body under the GLOBAL transaction-manager lock,
which would stall every writer in the image -- and a hot endpoint
would be billed for up to nine embeddings.  So each pass is: render
under a read snapshot, embed outside, then in ONE transaction
re-render and store only when the text is unchanged.  The re-render
records its reads and the store writes the vertex, so a touch that
commits before the re-render changes the text and a touch that commits
after it fails the commit's validation -- which is why TOUCH-ENDPOINTS
saves every live vertex, vector or not.  A changed profile is embedded
again, at most *EMBED-PASSES* times, after which the endpoint stays
dirty for the next drain.  An error from EMBED propagates, leaving the
endpoint dirty."
  (loop repeat *embed-passes*
        do (let ((text (with-scope-snapshots ((list graph))
                         (endpoint-profile graph namespace key))))
             (unless text
               (%clear-one-endpoint graph namespace key)
               (return nil))
             (let ((vector (funcall embed text)))
               (when (eq t (gdb:with-transaction (:graph graph)
                             (if (string= text (endpoint-profile
                                                graph namespace key))
                                 (progn
                                   (%store-vector graph namespace key
                                                  vector model)
                                   t)
                                 :changed)))
                 (return t))))))

(defun drain-endpoint-vectors (stores &key embed model)
  "Materialise, then embed every dirty endpoint of every store in
STORES with EMBED under MODEL, in the calling thread; => the number
embedded.  An EMBED error propagates after the endpoints before it were
stored.  Traps: the dirty set is taken once per store, so an endpoint a
write creates while the drain runs is left for the next one; and an
endpoint whose profile changes under every one of *EMBED-PASSES*
passes is left dirty rather than embedded from a text it no longer
has."
  (let ((n 0))
    (dolist (g stores n)
      (materialise-endpoint-vectors g)
      (dolist (ep (dirty-endpoints g model))
        (when (%embed-endpoint g (car ep) (cdr ep) embed model)
          (incf n))))))

(defun %clear-endpoint-vectors (graph)
  "Clear the vector and model of every live ENDPOINT-VECTOR of GRAPH,
in one transaction; => the number cleared.  Collects the vertices
first, then writes: MAP-VERTICES scans under a read pin."
  (gdb:with-transaction (:graph graph)
    (let ((evs (gdb:map-vertices #'identity graph :collect-p t
                                 :vertex-type 'endpoint-vector))
          (n 0))
      (dolist (ev evs n)
        (when (endpoint-vector-value ev)
          (let ((c (gdb:copy ev)))
            (setf (embedding c) nil (ev-model c) "")
            (gdb:save c)
            (incf n)))))))

(defun rebuild-endpoint-vectors (stores &key embed model)
  "Clear every vector in STORES, then DRAIN-ENDPOINT-VECTORS; => the
number embedded."
  (dolist (g stores)
    (%clear-endpoint-vectors g))
  (drain-endpoint-vectors stores :embed embed :model model))

(defun %endpoint-segment (graph)
  "GRAPH's vector segment for ENDPOINT-VECTOR.EMBEDDING, or NIL.
Engine internals (facts E3): VECTOR-SEGMENTS is an EQUAL table keyed
(owner-name . slot-name) by GRAPH-DB::%SEGMENT-KEY, and ENDPOINT-VECTOR
declares EMBEDDING, so it is its own owner.  An export is asked of the
engine (kraison/vivace-graph, exported segment reset)."
  (gethash '(endpoint-vector . embedding)
           (graph-db::vector-segments graph)))

(defun reset-endpoint-segment (graph dimension)
  "When GRAPH's endpoint segment exists with a dimension other than
DIMENSION, clear every vector and drop the segment so vectors of
DIMENSION are accepted; => T when it reset, NIL otherwise -- with no
segment nothing is indexed and the next write fixes the dimension.  An
empty segment keeps its dimension, so clearing alone is not enough (E3).
Must run before anything can search -- at start, before the listener
and the worker (SS4.3 step 4): the engine's rebuild is documented
unsafe against a concurrent VECTOR-SEARCH."
  (let ((seg (%endpoint-segment graph)))
    (when (and seg (/= dimension (graph-db::segment-dimension seg)))
      (%clear-endpoint-vectors graph)
      ;; With every vector cleared this creates no segment at all: it
      ;; closes the old one, drops the file, and the next conforming
      ;; write fixes the new dimension (E3).
      (graph-db::rebuild-vector-segment graph 'endpoint-vector 'embedding)
      t)))
