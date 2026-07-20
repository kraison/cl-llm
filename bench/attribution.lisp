;;;; bench/attribution.lisp -- decompose store-search cost into loading vs scoring.
;;;;
;;;; See docs/superpowers/specs/2026-07-20-vector-segments-design.md sec 10.
;;;; A/B/C/D are all WARM: %collect-embeddings scans every vertex before A is
;;;; timed, and A's own warm-up scans again, so by the time B runs the graph's
;;;; per-graph node cache is primed.  That is a deliberate steady-state reading,
;;;; but read alone it biases against segments (see E's docstring), so:
;;;; A: full store-search                       -- the number to improve, warm
;;;; B: load vertices + touch the slot           -- node loading, warm
;;;; C: score a vector-of-vectors already in RAM -- float work, scattered, warm
;;;; D: score ONE contiguous simple-array        -- what a segment would cost, warm
;;;; E: cold-start full store-search, ONE sample -- first touch after a fresh
;;;;    process-level graph reopen; see %COLD-START-SEARCH for exactly what
;;;;    "cold" does and does not mean here.

(in-package #:cl-llm.bench)

(defun %ms (fn)
  "Milliseconds FN takes to run once."
  (let ((start (get-internal-real-time)))
    (funcall fn)
    (/ (* 1000.0 (- (get-internal-real-time) start))
       internal-time-units-per-second)))

(defun %median-ms (fn runs)
  "Median milliseconds over RUNS calls, after one discarded warm-up.
Median, not mean, and never a single sample: a lone measurement of a noisy
operation is how this project previously reached two opposite confident
conclusions about the same code."
  (funcall fn)                          ; warm-up, discarded
  (let ((times (sort (loop repeat runs collect (%ms fn)) #'<)))
    (nth (floor runs 2) times)))

(defun %collect-embeddings (store)
  "Every embedding in STORE as a simple-vector of (simple-array single-float (*))."
  (let ((out (make-array 0 :adjustable t :fill-pointer 0)))
    (v::map-chunk-vertices
     store (lambda (vx) (vector-push-extend (v::%slot vx "EMBEDDING") out)))
    (coerce out 'simple-vector)))

(defun %flatten-embeddings (vectors dim)
  "Pack VECTORS into ONE contiguous (simple-array single-float (* )) of
 (length VECTORS) * DIM -- the layout a segment would use."
  (let* ((n (length vectors))
         (flat (make-array (* n dim) :element-type 'single-float)))
    (dotimes (i n flat)
      (let ((v (aref vectors i)))
        (declare (type (simple-array single-float (*)) v))
        (dotimes (j dim)
          (setf (aref flat (+ (* i dim) j)) (aref v j)))))))

(defun %score-flat (flat query n dim)
  "Score N vectors packed contiguously in FLAT against QUERY, returning the best
score.  Strides the block; no per-candidate indirection."
  (declare (type (simple-array single-float (*)) flat query)
           (type fixnum n dim)
           (optimize (speed 3) (safety 1)))
  (let ((best -2.0))
    (declare (type single-float best))
    (dotimes (i n best)
      (let ((sum 0.0) (base (* i dim)))
        (declare (type single-float sum) (type fixnum base))
        (dotimes (j dim)
          (incf sum (* (aref flat (+ base j)) (aref query j))))
        (when (> sum best) (setf best sum))))))

(defun %cold-start-search (graph dir query dim)
  "Close GRAPH, reopen the SAME on-disk graph as a genuinely fresh graph
object, build a fresh :SCAN store DIRECTLY over it (bypassing HYDRATE -- see
below), and time ONE first STORE-SEARCH.  A single sample, not a median -- a
cold read is only cold once.  Returns (values TIME-MS FRESH-GRAPH) so the
caller can hand FRESH-GRAPH to TEARDOWN-CORPUS instead of the now-closed
original.

Why bypass HYDRATE: V:MAKE-GRAPH-STORE calls HYDRATE, which runs
MIGRATE-EMBEDDINGS (a full scan touching every vertex's EMBEDDING slot --
the SAME materialising read measurement B uses) and then a second full scan
to infer the dimension, BOTH before this function's timer starts.  By the
time the timed STORE-SEARCH ran, every vertex was already materialised into
the fresh graph's node cache -- that measured a warm search mislabeled cold
(and the graph's node cache is :WEAKNESS :VALUE, so whether GC had reclaimed
those hydrate-warmed entries before the timed call varied run to run, which
is why early versions of this measurement swung between ~A and ~5xA).
Constructing the SCAN-GRAPH-STORE directly, with :DIMENSION supplied, skips
both untimed scans entirely, so the timed call is the FIRST touch of every
vertex.  This is safe: the corpus was written through STORE-ADD during
BUILD-CORPUS, so on disk every embedding is already a normalised
single-float array -- MIGRATE-EMBEDDINGS would find zero victims regardless
of whether HYDRATE ran.

What \"cold\" means here: a fresh GDB:GRAPH instance gets a fresh, empty
per-graph node cache (the weak-value id-table graph-db materialises vertices
into) and a freshly-established mmap, so every visited vertex must be
re-materialised from its serialised bytes -- none of the warmth A/B/C/D
accumulated (from %COLLECT-EMBEDDINGS's pre-scan and A's own warm-up) carries
over, and now (post-fix) neither does any hydrate-time warming.  What it
does NOT mean: true disk-cold I/O.  The OS page cache independently keeps
the mmap'd file's pages resident in RAM across the close/reopen, and this
process cannot drop that without root (macOS's `purge` requires sudo, which
this harness deliberately does not invoke).  So E is \"first touch after a
process-level graph reopen\", not \"first touch after a cold disk\" -- read
it as a lower bound on the true cold-start penalty, not the number itself."
  (let ((name (gdb:graph-name graph)))
    (gdb:close-graph graph :snapshot-p nil)
    (v:ensure-chunk-class 'rag-chunk name)
    (let* ((fresh-graph (gdb:open-graph name (pathname dir)))
           (fresh-store (make-instance 'v:scan-graph-store
                                        :graph fresh-graph :type 'rag-chunk
                                        :dimension dim)))
      (values (%ms (lambda () (rag:store-search fresh-store query 10)))
              fresh-graph))))

(defun run-attribution (n dim &key (runs 5))
  "Build an N x DIM corpus, take the four warm timings plus one cold-start
timing, tear down, return a plist."
  (format t "~&=== building corpus: n=~a dim=~a ===~%" n dim)
  (multiple-value-bind (store graph dir) (build-corpus n dim)
    (unwind-protect
         (let* ((query (random-unit-vector dim))
                (vectors (%collect-embeddings store))
                (flat (%flatten-embeddings vectors dim))
                (a (%median-ms (lambda () (rag:store-search store query 10)) runs))
                (b (%median-ms
                    (lambda ()
                      ;; Accumulate something so the slot read cannot be elided.
                      (let ((acc 0))
                        (declare (type fixnum acc))
                        (v::map-chunk-vertices
                         store (lambda (vx)
                                 (incf acc (length (v::%slot vx "EMBEDDING")))))
                        acc))
                    runs))
                (c (%median-ms
                    (lambda ()
                      (let ((best -2.0))
                        (declare (type single-float best))
                        (loop for v across vectors
                              for s = (rag:cosine query v)
                              do (when (> s best) (setf best s)))
                        best))
                    runs))
                (d (%median-ms (lambda () (%score-flat flat query n dim)) runs))
                (e nil))
           ;; E must run LAST among the timed measurements: it closes and
           ;; reopens GRAPH, invalidating STORE/VECTORS bookkeeping tied to the
           ;; old graph object.  It hands back the fresh graph so cleanup below
           ;; closes the right one.
           (multiple-value-bind (e-ms fresh-graph) (%cold-start-search graph dir query dim)
             (setf e e-ms)
             (setf graph fresh-graph))
           (list :n n :dim dim :a a :b b :c c :d d :e e))
      (teardown-corpus graph dir))))

(defun report-attribution (results)
  "Print RESULTS and the interpretation the spec commits to in advance."
  (destructuring-bind (&key n dim a b c d e) results
    (format t "~&~%=== attribution: n=~a dim=~a ===~%" n dim)
    (format t "-- WARM (buffer pool primed by the collection scan + A's warm-up) --~%")
    (format t "A  full store-search        ~,1f ms~%" a)
    (format t "B  load + slot, no scoring  ~,1f ms  (~,0f%% of A)~%" b (* 100 (/ b a)))
    (format t "C  score, scattered vectors ~,1f ms  (~,0f%% of A)~%" c (* 100 (/ c a)))
    (format t "D  score, contiguous block  ~,1f ms  (~,0f%% of A)~%" d (* 100 (/ d a)))
    (format t "-- COLD (single first search after a fresh process-level graph reopen) --~%")
    (format t "E  cold-start full search   ~,1f ms~%" e)
    (format t "   (E is a single sample; the OS page cache is not controlled, so read~%")
    (format t "   E as a LOWER BOUND on true disk-cold I/O, not the number itself)~%")
    (format t "~%predicted segment latency  ~,1f ms~%" d)
    (format t "predicted win (A - D)      ~,1f ms~%" (- a d))
    (format t "cold-start penalty (E - A) ~,1f ms~%" (- e a))
    (format t "~%interpretation:~%")
    (format t "  loading dominates?   ~a  (B >= 60%% of A)~%"
            (if (>= b (* 0.6 a)) "YES -- attribution holds" "NO"))
    (format t "  scoring dominates?   ~a  (C >= 60%% of A)~%"
            (if (>= c (* 0.6 a)) "YES -- REVISIT THE DESIGN (spec sec 10)" "NO"))
    (format t "  contiguity matters?  ~a  (D <= 70%% of C)~%"
            (if (<= d (* 0.7 c)) "YES" "NO -- segment's win is resident memory, not scan speed"))
    results))
