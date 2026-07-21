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
