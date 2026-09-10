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
written, :UNSETTLED when the profile outran *EMBED-PASSES*, NIL when
nothing is current (and the stale vector was cleared).

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
dirty for the next drain and :UNSETTLED says so -- the worker logs
that once per endpoint (SS4.3 step 5).  An error from EMBED
propagates, leaving the endpoint dirty."
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
                 (return t))))
        finally (return :unsettled)))

(defun drain-endpoint-vectors (stores &key embed model)
  "Materialise, then embed every dirty endpoint of every store in
STORES with EMBED under MODEL, in the calling thread; => (values
EMBEDDED UNSETTLED), the number embedded and the (NAMESPACE . KEY)
endpoints whose profile outran *EMBED-PASSES*.  An EMBED error
propagates after the endpoints before it were stored.  Trap: the dirty
set is taken once per store, so an endpoint a write creates while the
drain runs is left for the next one -- one call is not promised to
empty the set."
  (let ((n 0) (unsettled '()))
    (dolist (g stores (values n (nreverse unsettled)))
      (materialise-endpoint-vectors g)
      (dolist (ep (dirty-endpoints g model))
        (case (%embed-endpoint g (car ep) (cdr ep) embed model)
          ((t) (incf n))
          (:unsettled (push ep unsettled)))))))

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
  "Clear every vector in STORES, then DRAIN-ENDPOINT-VECTORS, whose
two values it returns: the number embedded and the endpoints that ran
out of passes."
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

;;;; The worker (SS4.3): one thread per process, a sweep at start, a
;;;; drain after every notify, a doubling backoff over an outage.

(defvar *endpoint-indexer* nil
  "This process's worker, or NIL when no embedder is configured.
NOTIFY-ENDPOINT-INDEXER with no argument uses it (SS4.5).")

(defstruct (endpoint-indexer (:constructor %make-endpoint-indexer))
  "One thread draining STORES with EMBED under MODEL.  PENDING says a
notify arrived since the running drain began, IDLE that the last drain
left every store clean; both are read and written under LOCK only.
REPORTED is the worker thread's alone."
  stores embed model thread
  (lock (bt:make-lock "endpoint-indexer"))
  (cv (bt:make-condition-variable :name "endpoint-indexer"))
  (pending t)                 ; T at birth: the start-up sweep
  (idle nil)
  (stop-p nil)
  (embedded 0)
  (backoff 1.0)               ; seconds before the next attempt
  (initial-backoff 1.0)       ; where an outage's doubling starts again
  (max-backoff 60.0)
  (failing nil)               ; T once this outage has been logged
  (reported (make-hash-table :test 'equal)))

(defun %indexer-log (control &rest args)
  "Print one line to *ERROR-OUTPUT*, never signalling: an outage is all
the worker can report, and it must not die reporting it.  Trap: call
it with no lock held -- a stream can block for as long as it likes."
  (ignore-errors
   (apply #'format *error-output* control args)
   (finish-output *error-output*)))

(defun %indexer-await (w delay hard)
  "Block until a notify, DELAY seconds (when non-NIL) or a stop; => T
to drain, NIL to stop.  HARD makes DELAY a deadline the worker sits
out whatever arrives, only a stop cutting it short: a notify must
never cancel an outage's backoff, or an import that notifies per write
would make one failing round trip per write (SS4.3 step 3).  Past the
deadline it drains, notify or not.  PENDING is cleared before the
drain, so a notify arriving during one is kept for the next pass
rather than lost: DRAIN-ENDPOINT-VECTORS takes each store's dirty set
once (SS4.3)."
  (let ((deadline (and delay
                       (+ (get-internal-real-time)
                          (* delay internal-time-units-per-second)))))
    (bt:with-lock-held ((endpoint-indexer-lock w))
      (loop
        (when (endpoint-indexer-stop-p w) (return))
        (let ((left (and deadline
                         (/ (float (- deadline (get-internal-real-time))
                                   1d0)
                            internal-time-units-per-second))))
          (cond ((and left (<= left 0))
                 (setf (endpoint-indexer-pending w) t)
                 (return))
                ((and (endpoint-indexer-pending w) (not hard)) (return))
                ;; A spurious wake re-waits what is left of the
                ;; deadline rather than falling through it.
                (left (bt:condition-wait (endpoint-indexer-cv w)
                                         (endpoint-indexer-lock w)
                                         :timeout left))
                (t (bt:condition-wait (endpoint-indexer-cv w)
                                      (endpoint-indexer-lock w))))))
      (unless (endpoint-indexer-stop-p w)
        (setf (endpoint-indexer-pending w) nil
              (endpoint-indexer-idle w) nil)
        t))))

(defun %indexer-dirty-p (w)
  "T when any store of W still holds an endpoint dirty under its model.
Trap: a second vocabulary pass per drain, the price of never reporting
idle over a dirty store."
  (when (some (lambda (g) (dirty-endpoints g (endpoint-indexer-model w)))
              (endpoint-indexer-stores w))
    t))

(defun %indexer-unsettled-lines (w unsettled)
  "The log lines owed for the endpoints in UNSETTLED that W has not
named yet, marking them named; => a list of (CONTROL . ARGS).  Once
per endpoint per worker, so a permanently unsettled endpoint costs one
line, not one per drain (SS4.3 step 5)."
  (loop for ep in unsettled
        unless (gethash ep (endpoint-indexer-reported w))
          collect (progn
                    (setf (gethash ep (endpoint-indexer-reported w)) t)
                    (list "~&endpoint indexer: ~a ~a still changing ~
                           after ~d passes; it stays dirty~%"
                          (car ep) (cdr ep) *embed-passes*))))

(defun %indexer-pass (w)
  "One drain and its bookkeeping; => (values SECONDS HARD): how long to
wait before the next attempt (NIL to wait for a notify) and whether
that wait is a deadline no notify may cancel.  IDLE is set only when
the drain left every store clean and no notify arrived: an endpoint
whose profile outran *EMBED-PASSES* stays dirty and is retried after
the backoff, so WAIT-ENDPOINT-INDEXER cannot read idle over it.
Recovery is claimed only by a drain that actually embedded something,
so an empty drain mid-outage does not read as the embedder returning.
Every log line is printed after the lock is released (SS4.3)."
  (let ((lines '()) (delay nil) (hard nil))
    (handler-case
        (multiple-value-bind (n unsettled)
            (drain-endpoint-vectors (endpoint-indexer-stores w)
                                    :embed (endpoint-indexer-embed w)
                                    :model (endpoint-indexer-model w))
          (setf lines (%indexer-unsettled-lines w unsettled))
          (let ((dirty (%indexer-dirty-p w)))
            (bt:with-lock-held ((endpoint-indexer-lock w))
              (incf (endpoint-indexer-embedded w) n)
              (when (plusp n)
                (setf (endpoint-indexer-backoff w)
                      (endpoint-indexer-initial-backoff w))
                (when (endpoint-indexer-failing w)
                  (setf (endpoint-indexer-failing w) nil)
                  (push (list "~&endpoint indexer: embedder back~%")
                        lines)))
              ;; A notify outranks both: drain again at once.
              (cond ((endpoint-indexer-pending w))
                    (dirty (setf delay
                                 (endpoint-indexer-initial-backoff w)))
                    (t (setf (endpoint-indexer-idle w) t)
                       (bt:condition-notify (endpoint-indexer-cv w)))))))
      (error (c)
        (bt:with-lock-held ((endpoint-indexer-lock w))
          (unless (endpoint-indexer-failing w)
            (setf (endpoint-indexer-failing w) t)
            (push (list "~&endpoint indexer: embedder failed: ~a; ~
                         retrying with backoff~%" c)
                  lines))
          (setf delay (endpoint-indexer-backoff w)
                hard t
                (endpoint-indexer-backoff w)
                (min (endpoint-indexer-max-backoff w)
                     (* 2 (endpoint-indexer-backoff w)))))))
    (dolist (line lines) (apply #'%indexer-log line))
    (values delay hard)))

(defun %indexer-loop (w)
  "The worker thread's body: await, drain, repeat until stopped."
  (let ((delay nil) (hard nil))
    (loop while (%indexer-await w delay hard)
          do (multiple-value-setq (delay hard) (%indexer-pass w)))))

(defun start-endpoint-indexer (stores &key embed model (backoff 1.0)
                                           (name "endpoint-indexer"))
  "Start the worker over STORES with EMBED (text -> vector) and MODEL:
a sweep at once, then a drain after every NOTIFY-ENDPOINT-INDEXER; an
embedder error is logged once per outage and retried with a doubling
BACKOFF (seconds, capped at 60) that no notify can cut short.  => the
ENDPOINT-INDEXER, also set as *ENDPOINT-INDEXER*.  A worker already in
*ENDPOINT-INDEXER* is stopped and joined first, so a re-entered start
never orphans one.  Trap: stop it before closing the stores."
  (when *endpoint-indexer*
    (stop-endpoint-indexer *endpoint-indexer*))
  (let ((w (%make-endpoint-indexer :stores stores :embed embed
                                   :model model :backoff backoff
                                   :initial-backoff backoff)))
    (setf (endpoint-indexer-thread w)
          (bt:make-thread (lambda () (%indexer-loop w)) :name name))
    (setf *endpoint-indexer* w)))

(defun notify-endpoint-indexer (&optional (indexer *endpoint-indexer*))
  "Wake INDEXER to drain; a no-op when there is none.  The flag is set
and the condition notified under one lock, so a worker on its way into
CONDITION-WAIT cannot miss it.  Trap: it does not shorten an outage's
backoff -- see %INDEXER-AWAIT."
  (when indexer
    (bt:with-lock-held ((endpoint-indexer-lock indexer))
      (setf (endpoint-indexer-pending indexer) t
            (endpoint-indexer-idle indexer) nil)
      (bt:condition-notify (endpoint-indexer-cv indexer))))
  nil)

(defun %indexer-idle-p (w)
  "W's IDLE flag, read under its lock."
  (bt:with-lock-held ((endpoint-indexer-lock w))
    (endpoint-indexer-idle w)))

(defun wait-endpoint-indexer (indexer &key (timeout 10))
  "Block until INDEXER has drained every store clean, or TIMEOUT
seconds; => T when idle, NIL on the timeout.  Polls the flag instead of
waiting on the condition, so a notify cannot be missed here.  For tests
and scripted sessions (SS4.3, SS4.4)."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (%indexer-idle-p indexer) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.05))))

(defun %indexer-join (thread)
  "Join THREAD, => T, or NIL when it died instead of returning -- then
one line says so.  BT:JOIN-THREAD takes no :DEFAULT in the installed
bordeaux-threads (v0.9.4 apiv1), so the default is a handler: a thread
killed or aborted must not make STOP-ENDPOINT-INDEXER signal out of a
caller's cleanup form."
  (handler-case (progn (bt:join-thread thread) t)
    (error (c)
      (%indexer-log "~&endpoint indexer: worker did not return: ~a~%" c)
      nil)))

(defun stop-endpoint-indexer (indexer)
  "Stop INDEXER and join its thread; clears *ENDPOINT-INDEXER* when it
was this one; => NIL.  Idempotent, and never signals.  The stop flag
and the wake go under one lock, so a worker in CONDITION-WAIT -- idle
or mid-backoff -- returns at once rather than after its delay; a
worker mid-drain is joined when that drain ends."
  (when indexer
    (bt:with-lock-held ((endpoint-indexer-lock indexer))
      (setf (endpoint-indexer-stop-p indexer) t)
      (bt:condition-notify (endpoint-indexer-cv indexer)))
    (let ((thread (endpoint-indexer-thread indexer)))
      (when (and thread (bt:thread-alive-p thread))
        (%indexer-join thread)))
    (when (eq indexer *endpoint-indexer*)
      (setf *endpoint-indexer* nil)))
  nil)
