;;;; tests-vivace/heap.lisp -- the suite stays inside SBCL's default heap
;;;; (#11).  Loaded LAST: the canary at the end reads what the whole run left.

(in-package #:cl-llm.rag.vivace/tests)
(in-suite :cl-llm-rag-vivace)

(defun %retained-bytes ()
  "Bytes of dynamic space still live after a full GC; NIL off SBCL."
  #+sbcl (progn (sb-ext:gc :full t) (sb-kernel:dynamic-usage))
  #-sbcl nil)

(defun %graph-lifetime (i)
  "One test-shaped graph lifetime: a uniquely named graph (on disk for an
even I, in memory for an odd one), a :segment store over it with 20
chunks, one search, then close and delete.  Unique names on purpose: the
suite names every graph differently, and a per-name registry was one of
#11's suspects."
  (with-system-directory ()
    (let* ((dir (pathname (format nil "/tmp/cl-llm-vg-heap-~a-~a/"
                                  (get-internal-real-time) i)))
           (name (intern (format nil "CL-LLM-VG-HEAP-~D" i) :keyword))
           (graph (if (evenp i)
                      (gdb:make-graph name dir)
                      (gdb::make-memory-graph name dir))))
      (unwind-protect
           (let ((store (v:make-graph-store graph :strategy :segment
                                                  :dimension 8)))
             (rag:store-add store (agreement-corpus 20))
             (rag:store-search store (unit-query 8 1.0) 5))
        (gdb:close-graph graph :snapshot-p nil)
        (ignore-errors (uiop:delete-directory-tree dir :validate t))))))

(defparameter *graph-lifetimes* 20)

(defparameter *lifetime-retention-allowance* (* 4 1024 1024)
  "Bytes the GC'd heap may grow over *GRAPH-LIFETIMES* lifetimes.  Measured
noise is +-40 KB per lifetime.  Keeping every closed graph reachable grew
20 lifetimes by 12 MB (a disk graph ~1.4 MB, a memory graph far less), and
the retention #11 reported was ~20 MB per test graph.")

(test graph-lifetimes-do-not-retain-heap
  "REGRESSION #11: opening, using, closing and deleting graphs the way the
suite does must leave the GC'd heap where it was.  One warm-up lifetime
first: the first graph of an image pays ~4 MB once (caches, the pool)."
  #-sbcl (skip "heap accounting here is SBCL-specific")
  #+sbcl
  (progn
    (%graph-lifetime 0)
    (let ((before (%retained-bytes)))
      (loop for i from 1 to *graph-lifetimes* do (%graph-lifetime i))
      (let ((grown (- (%retained-bytes) before)))
        (is (< grown *lifetime-retention-allowance*)
            "~D graph lifetimes retained ~:D bytes (~,2F MB each); ~
             allowed ~:D in all"
            *graph-lifetimes* grown
            (/ grown *graph-lifetimes* 1048576.0)
            *lifetime-retention-allowance*)))))

(defparameter *suite-retention-ceiling* (* 512 1024 1024)
  "Half of SBCL's default 1 GB heap.  #11's suite left ~870 MB live.")

(test suite-retention-fits-the-default-heap
  "CANARY for #11, defined last so the rest of the suite has run before it:
what the run leaves live after a full GC must fit well inside SBCL's
default 1 GB heap, and graph-db's pool must be the small one the fixtures
pin -- a graph opened before the pin sizes it at 100000, ~300 MB.  Run
alone this test proves nothing; it bites only after the rest."
  (is (<= gdb:*buffer-pool-size* *test-buffer-pool-size*)
      "graph-db's buffer pool is ~:D, not the ~:D the suite pins (#11)"
      gdb:*buffer-pool-size* *test-buffer-pool-size*)
  #-sbcl (skip "heap accounting here is SBCL-specific")
  #+sbcl
  (let ((live (%retained-bytes)))
    (is (< live *suite-retention-ceiling*)
        "the suite left ~:D bytes live after a full GC; ceiling ~:D (#11)"
        live *suite-retention-ceiling*)))
