;;;; bench/corpus.lisp -- synthetic chunk corpora for benchmarking.

(in-package #:cl-llm.bench)

(defparameter *chunk-text-length* 800
  "Characters of body text per synthetic chunk.  Real mine-action chunks run
several hundred to a couple of thousand characters; the point is that loading a
vertex must cost something realistic, because that cost is what measurement B
exists to expose.  A corpus of empty-text chunks would understate it.")

(defun random-unit-vector (dim)
  "A random L2-normalised (simple-array single-float (DIM))."
  (let ((raw (make-array dim :element-type 'single-float)))
    (dotimes (i dim)
      (setf (aref raw i) (- (random 2.0) 1.0)))
    (rag:as-embedding raw)))

(defun %filler-text (i)
  (let ((s (make-string *chunk-text-length*)))
    (dotimes (j *chunk-text-length* s)
      (setf (char s j) (code-char (+ 97 (mod (+ i j) 26)))))))

(defun build-corpus (n dim &key (batch 1000))
  "Create a temp graph holding N chunks of DIM dimensions and return
 (values STORE GRAPH DIR).  Chunks are added in batches of BATCH -- one
transaction per batch, not per chunk (too slow) and not one for all N (peak
memory).  The store uses :SCAN, because :CACHE would mirror everything into RAM
and measurement A is meant to exercise the graph path."
  ;; GET-INTERNAL-REAL-TIME has finer-than-a-second resolution (unlike
  ;; GET-UNIVERSAL-TIME); the dir and name derive from the SAME seed so two
  ;; builds started within the same wall-clock second (Task 3 sweeps several
  ;; corpus sizes back to back) never collide on either path or graph name.
  (let* ((seed (get-internal-real-time))
         (dir (format nil "/var/tmp/cl-llm-bench-~a/" seed))
         (name (intern (format nil "BENCH-~a" seed) :keyword)))
    (ensure-directories-exist dir)
    (v:ensure-chunk-class 'rag-chunk name)
    (let* ((graph (gdb:make-graph name (pathname dir) :buffer-pool-size 1000))
           (store (v:make-graph-store graph :strategy :scan)))
      (let ((pending '()) (pending-count 0) (added 0))
        (dotimes (i n)
          (push (rag:make-chunk (%filler-text i)
                                :document-id (format nil "doc-~7,'0d" i)
                                :embedding (random-unit-vector dim))
                pending)
          (incf pending-count)
          (when (= pending-count batch)
            (rag:store-add store (nreverse pending))
            (incf added batch)
            (setf pending '())
            (setf pending-count 0)
            (format t "~&  built ~a/~a~%" added n)
            (finish-output)))
        (when pending
          (rag:store-add store (nreverse pending))))
      (values store graph dir))))

(defun teardown-corpus (graph dir)
  "Close GRAPH and delete its directory."
  (ignore-errors (gdb:close-graph graph :snapshot-p nil))
  (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t))
  nil)
