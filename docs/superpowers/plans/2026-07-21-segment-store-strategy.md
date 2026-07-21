# `:segment` Store Strategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A third RAG store strategy, `:segment`, that keeps chunk embeddings in VivaceGraph's mmap vector segment and answers `store-search` through `gdb:vector-search` — never materialising a node it is not going to return.

**Architecture:** One declaration (`:vector-index t` on the chunk `EMBEDDING` slot) makes the transaction apply path maintain the segment; a new `segment-graph-store` class implements `store-search` by over-fetching from `gdb:vector-search` and re-ranking with cl-llm's document-id tiebreak. Existing stores migrate on first open via a batched, skip-what-exists rebuild whose resumability comes from the segment itself.

**Tech Stack:** Common Lisp (SBCL), FiveAM, ASDF/Quicklisp, `graph-db` (branch `experiment`), `cl-llm` (branch `main`).

**Design spec:** `docs/superpowers/specs/2026-07-21-segment-store-strategy-design.md` (this repo).
Engine spec: `vivace-graph-v3/docs/superpowers/specs/2026-07-21-vector-segment-query-design.md`.

## Global Constraints

- **SBCL only.** ECL is out of scope for this entire step; do not run it.
- **Lisp indentation is spaces only, never tabs.**
- **Two repos.** Task 1 is in `/Users/kraison/work/vivace-graph-v3` on branch `experiment`. Tasks 2–7 are in `/Users/kraison/work/cl-llm` on branch `main`. Task 1 must land first — Task 5 depends on it.
- **Backward compatibility is a hard requirement.** An existing persistent store must open and return correct results after upgrade. A graph written by the pre-`:vector-index` schema must not fail to open.
- **All three strategies stay.** `:cache` is not removed, not demoted, and keeps working. `:segment` becomes the default only in Task 7.
- **Never materialise a node that is not returned.** Node loading was measured at ~92% of `store-search` cost; that is the premise of the whole phase.
- **Guard every assertion so it cannot pass on NIL or an empty result** — assert `length` first, then guard any ordering loop with `(when (= n (length got)) ...)`. Twelve vacuous or non-discriminating assertions have been caught across this project, two of them originating in spec/plan text rather than implementer code. For each test you write, state in your report what mutation it catches.
- **Never build a test's expected ranking by calling the function under test.** That defect shipped in this project and was caught only by a sabotage run.
- Mutations run inside `gdb:with-transaction`; `update-node` does not exist (copy-modify-save is the idiom).
- If you hit `attempt to redefine STRUCTURE-OBJECT class ... incompatibly`, clear `~/.cache/common-lisp/` once and re-run.

---

## File Structure

| File | Repo | Responsibility |
| --- | --- | --- |
| `segment.lisp` | vivace-graph-v3 | Task 1: batched resumable rebuild |
| `package.lisp` | vivace-graph-v3 | Task 1: export it |
| `tests/segment-integration-tests.lisp` | vivace-graph-v3 | Task 1 tests |
| `vivace/schema.lisp` | cl-llm | Task 2: `:vector-index` declaration; Task 7: retire the read-side coercion |
| `vivace/store.lisp` | cl-llm | Tasks 3–5, 7: the store class, search, migration, default |
| `vivace/packages.lisp` | cl-llm | Task 3: export new symbols |
| `tests-vivace/store-segment.lisp` | cl-llm | **NEW** — Tasks 3–6 tests, mirroring `store-scan.lisp` / `store-cache.lisp` |
| `cl-llm.asd` | cl-llm | Task 3: register `store-segment` in `cl-llm/rag/vivace/tests` |
| `tests-vivace/schema.lisp` | cl-llm | Tasks 2, 7 tests |

**Facts verified against the source — use these, do not re-derive them:**

- The FiveAM suite is **`:cl-llm-rag-vivace`** (`tests-vivace/suite.lisp`). Run it with
  `(fiveam:run! :cl-llm-rag-vivace)` — it is a keyword, not a package-qualified symbol.
- Test files are per-strategy (`store-scan.lisp`, `store-cache.lisp`), so the new tests go
  in **`tests-vivace/store-segment.lisp`**, added to `cl-llm.asd`'s
  `cl-llm/rag/vivace/tests` components **after `store-cache`** (the system is `:serial t`).
- **`store-search` returns a list of `rag:hit` structs, NOT `(score . payload)` conses.**
  `(rag:make-hit chunk score)` — constructor arg order is *chunk first*, accessors
  `rag:hit-chunk` / `rag:hit-score` (`rag/document.lisp:25`). `scan-graph-store`'s method
  ends by mapping `collector-results` through `make-hit`; the new method must return the
  same shape or every caller breaks.
- **Never do a non-local exit out of `gdb:map-vertices`.** The existing
  `hydrate` on `scan-graph-store` carries the comment "Do NOT do a non-local exit out of
  map-vertices (it may hold locks); iterate and set once." Follow that — iterate fully and
  guard with `unless`.

---

### Task 1: Batched, resumable segment rebuild (ENGINE)

**Repo:** `/Users/kraison/work/vivace-graph-v3`, branch `experiment`.

**Files:**
- Modify: `segment.lisp` (add beside `rebuild-vector-segment`, currently at `:423`)
- Modify: `package.lisp` (export, beside `#:vector-search`)
- Test: `tests/segment-integration-tests.lisp`

**Interfaces:**
- Consumes: `segment-get`, `segment-put`, `%vector-index-slot-owner-name`, `vector-segments`, `%ensure-segment` (all internal to `graph-db`).
- Produces: `graph-db:rebuild-vector-segment-batched (graph owner-name slot-name &key (batch-size 5000) progress-fn) → (values inserted-count skipped-count)`. Task 5 calls this.

**Why batched at all:** Phase 1 measured `gdb:copy` duplicating a whole vertex at ~40 KB/chunk, putting a 1M-chunk single-transaction migration at ~38 GB and ~19 minutes, unrecoverable on failure.

**Why resumability is free:** the segment already records which node ids it holds. Skip ids already present and an interrupted run simply re-runs. Do NOT add a progress file or checkpoint record — a marker that can disagree with reality is strictly worse than no marker.

**Difference from `rebuild-vector-segment`:** that one DROPS the existing segment and rebuilds from scratch (correct for recovery). This one is ADDITIVE — it never drops, it fills in what is missing. Both are legitimate; do not merge them.

- [ ] **Step 1: Write the failing tests**

In `tests/segment-integration-tests.lisp`:

```lisp
(test batched-rebuild-fills-missing-and-skips-present
  "Additive: inserts ids the segment lacks, skips ids it already holds, and
reports both counts.  A rebuild that dropped and recreated the segment would
report every id as inserted, which is what distinguishes this from
REBUILD-VECTOR-SEGMENT."
  (with-temp-directory (dir)
    (let ((g (make-graph *integration-graph-name* (namestring dir)
                         :buffer-pool-size 1000)))
      (unwind-protect
           (let ((*graph* g))
             (dotimes (i 6)
               (with-transaction ()
                 (make-si-doc :title (format nil "n~d" i)
                              :embedding (%si-embedding 8 (coerce (1+ i) 'single-float)))))
             ;; everything is already indexed by the live apply path
             (multiple-value-bind (ins skip)
                 (rebuild-vector-segment-batched g 'si-doc 'embedding :batch-size 2)
               (is (= 0 ins) "expected 0 inserted, got ~D" ins)
               (is (= 6 skip) "expected 6 skipped, got ~D" skip))
             ;; drop the segment entirely, then refill it
             (let ((key (cons 'si-doc 'embedding)))
               (let ((s (gethash key (graph-db::vector-segments g))))
                 (when s (graph-db::close-vector-segment s)))
               (remhash key (graph-db::vector-segments g)))
             (multiple-value-bind (ins skip)
                 (rebuild-vector-segment-batched g 'si-doc 'embedding :batch-size 2)
               (is (= 6 ins) "expected 6 inserted after drop, got ~D" ins)
               (is (= 0 skip) "expected 0 skipped after drop, got ~D" skip))
             ;; and the refilled segment answers queries
             (let ((hits (vector-search g 'si-doc 'embedding
                                        (%si-embedding 8 6.0) 3)))
               (is (= 3 (length hits)) "expected 3 hits, got ~S" hits)))
        (close-graph g :snapshot-p nil)))))

(test batched-rebuild-resumes-after-interruption
  "Resumability comes from the segment itself: interrupt a rebuild partway,
re-run it, and the result is complete with nothing duplicated and nothing
missing.  PROGRESS-FN throwing mid-run is the interruption."
  (with-temp-directory (dir)
    (let ((g (make-graph *integration-graph-name* (namestring dir)
                         :buffer-pool-size 1000)))
      (unwind-protect
           (let ((*graph* g))
             (dotimes (i 10)
               (with-transaction ()
                 (make-si-doc :title (format nil "n~d" i)
                              :embedding (%si-embedding 8 (coerce (1+ i) 'single-float)))))
             (let ((key (cons 'si-doc 'embedding)))
               (let ((s (gethash key (graph-db::vector-segments g))))
                 (when s (graph-db::close-vector-segment s)))
               (remhash key (graph-db::vector-segments g)))
             ;; interrupt after the first batch
             (let ((batches 0))
               (ignore-errors
                (rebuild-vector-segment-batched
                 g 'si-doc 'embedding :batch-size 3
                 :progress-fn (lambda (done total)
                                (declare (ignore total))
                                (incf batches)
                                (when (>= batches 1)
                                  (error "simulated interruption after ~D" done))))))
             ;; partial state: some in, some not
             (let ((partial (graph-db::segment-live-count
                             (gethash (cons 'si-doc 'embedding)
                                      (graph-db::vector-segments g)))))
               (is (< 0 partial 10)
                   "expected a PARTIAL segment after interruption, got ~D of 10 ~
-- if this is 0 or 10 the interruption did not land mid-run and the resume ~
below proves nothing" partial))
             ;; re-run completes it
             (multiple-value-bind (ins skip)
                 (rebuild-vector-segment-batched g 'si-doc 'embedding :batch-size 3)
               (is (plusp skip) "expected the resume to SKIP already-done ids, got ~D" skip)
               (is (= 10 (+ ins skip)) "expected 10 total, got ~D + ~D" ins skip))
             (let ((hits (vector-search g 'si-doc 'embedding (%si-embedding 8 10.0) 10)))
               (is (= 10 (length hits)) "expected all 10 ids present, got ~D" (length hits))
               (when (= 10 (length hits))
                 (is (= 10 (length (remove-duplicates (mapcar #'cdr hits) :test #'equalp)))
                     "duplicate ids after resume: ~S" (mapcar #'cdr hits)))))
        (close-graph g :snapshot-p nil)))))
```

`%si-embedding (dim base)` is the existing helper in that file (`tests/segment-integration-tests.lisp:52`), and `si-doc` / `si-sub` are the schema already declared there — reuse both rather than adding new ones. The suite is `segment-integration-suite`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sbcl --non-interactive --eval '(ql:quickload :graph-db/test)' --eval '(fiveam:run! (quote graph-db/test::segment-integration-suite))'`
Expected: FAIL — `REBUILD-VECTOR-SEGMENT-BATCHED` undefined (a package error at load is acceptable evidence here, as in earlier tasks).

- [ ] **Step 3: Implement**

In `segment.lisp`, after `rebuild-vector-segment`:

```lisp
(defun rebuild-vector-segment-batched (graph owner-name slot-name
                                       &key (batch-size 5000) progress-fn)
  "ADDITIVELY fill the (OWNER-NAME, SLOT-NAME) segment from live nodes, in
batches of BATCH-SIZE, skipping ids the segment already holds.  Returns
 (values INSERTED SKIPPED).

Distinct from REBUILD-VECTOR-SEGMENT, which DROPS the existing segment and
rebuilds from scratch: that is the right shape for recovery, this is the right
shape for migration.  Do not merge them.

RESUMABLE BY CONSTRUCTION.  The segment itself records which ids it holds, so
an interrupted run leaves a partial segment and a re-run skips exactly what it
already did.  There is deliberately NO progress file or checkpoint record: a
marker that can disagree with the segment is worse than no marker, because it
can claim work that was rolled back.

PROGRESS-FN, if given, is called as (funcall progress-fn done total) once per
batch -- a migration of a real corpus takes minutes and a silent one looks
hung."
  (let* ((owner (%vector-index-slot-owner-name owner-name slot-name))
         (segment (%ensure-segment graph owner slot-name))
         (inserted 0)
         (skipped 0)
         (pending '())
         (pending-count 0)
         (total 0))
    (declare (ignorable segment))
    (flet ((flush ()
             (when pending
               (dolist (pair (nreverse pending))
                 (let ((seg (%ensure-segment graph owner slot-name)))
                   (segment-put seg (car pair) (cdr pair))
                   (incf inserted)))
               (setf pending '() pending-count 0)
               (when progress-fn
                 (funcall progress-fn (+ inserted skipped) total)))))
      (map-vertices
       (lambda (v)
         (let ((value (ignore-errors (slot-value v slot-name))))
           (when (typep value '(simple-array single-float (*)))
             (incf total)
             (let ((seg (%ensure-segment graph owner slot-name)))
               (if (segment-get seg (id v))
                   (incf skipped)
                   (progn
                     (push (cons (id v) value) pending)
                     (incf pending-count)
                     (when (>= pending-count batch-size)
                       (flush))))))))
       graph :vertex-type owner-name)
      (flush))
    (values inserted skipped)))
```

Note `:vertex-type owner-name` with `map-vertices`' default `:include-subclasses-p t` — Model B means the owner's segment spans subclasses, and this must match what the live apply path does. Getting this wrong produced a real LIVE-1-vs-REBUILT-2 divergence in an earlier step.

- [ ] **Step 4: Export it**

In `package.lisp`, beside `#:vector-search`:

```lisp
           #:rebuild-vector-segment-batched
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the `segment-integration-suite` command from Step 2. Expected: PASS.
Then the full suite: `sbcl --non-interactive --eval '(ql:quickload :graph-db/test)' --eval '(fiveam:run! (quote graph-db/test::graph-db-suite))'` — currently 2449/2449; report the new count.

- [ ] **Step 6: Sabotage proof**

Change `(if (segment-get seg (id v)) (incf skipped) ...)` to always take the insert branch (i.e. drop the skip check). Re-run: `batched-rebuild-fills-missing-and-skips-present` must FAIL on its `(= 0 ins)` assertion. Restore, verify `git diff` is clean, re-run green. Report the failure output.

- [ ] **Step 7: Commit**

```bash
git add segment.lisp package.lisp tests/segment-integration-tests.lisp
git commit -m "feat(segment): additive batched resumable rebuild for migration"
```

---

### Task 2: Declare the embedding slot `:vector-index`

**Repo:** `/Users/kraison/work/cl-llm`, branch `main`. All remaining tasks are here.

**Files:**
- Modify: `vivace/schema.lisp` (`ensure-chunk-class`)
- Test: `tests-vivace/schema.lisp`

**Interfaces:**
- Produces: chunk vertices whose `EMBEDDING` slot is segment-maintained by the apply path. Tasks 3–5 depend on this.

This one declaration is the entire write-side mechanism — there is no parallel write path and no cache to invalidate, exactly as `:unique` and `:index` work.

- [ ] **Step 1: Write the failing tests**

```lisp
(test chunk-class-declares-embedding-vector-indexed
  "The EMBEDDING slot carries :vector-index, which is what makes the apply path
maintain a segment for it.  Without this declaration every later task in this
step is inert -- store-add would write vertices and no segment would exist."
  (let ((graph-name :vector-index-decl-test))
    (ensure-chunk-class 'rag-chunk graph-name)
    (let ((slots (gdb::node-vector-index-slots
                  (find-class (chunk-type-symbol 'rag-chunk)))))
      (is (member (intern "EMBEDDING" :graph-db) slots)
          "EMBEDDING is not vector-indexed; declared slots were ~S" slots))))

(test store-add-populates-the-segment
  "End-to-end proof the declaration is live: adding chunks through the ordinary
store-add path makes the segment hold them, with no explicit indexing call."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :scan :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0)
                                        (test-chunk "b" 8 2.0)))
             (let ((seg (gethash (cons (chunk-type-symbol 'rag-chunk)
                                       (intern "EMBEDDING" :graph-db))
                                 (gdb::vector-segments (graph-store-graph store)))))
               (is (not (null seg)) "no segment was created by store-add")
               (when seg
                 (is (= 2 (gdb::segment-live-count seg))
                     "expected 2 vectors in the segment, got ~D"
                     (gdb::segment-live-count seg)))))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))
```

`test-chunk` is a helper: if `tests-vivace/` already has one that builds a `rag:chunk` with a constant embedding of given dimension, use it verbatim; otherwise add:

```lisp
(defun test-chunk (text dim value)
  "A rag:chunk whose embedding is DIM copies of VALUE (pre-normalisation)."
  (rag:make-chunk text
                  :document-id text
                  :embedding (make-array dim :element-type 'single-float
                                             :initial-element (coerce value 'single-float))))
```

- [ ] **Step 2: Run to verify they fail**

Run: `sbcl --non-interactive --eval '(ql:quickload :cl-llm/rag/vivace/tests)' --eval '(fiveam:run! (quote cl-llm.rag.vivace.tests::vivace-suite))'`
(Confirm the suite's real name from the test files before running; use whatever `tests-vivace/` actually defines.)
Expected: FAIL — `EMBEDDING` is not in the vector-index slot list.

- [ ] **Step 3: Implement**

In `vivace/schema.lisp`, in `ensure-chunk-class`'s `def-vertex` form, change the embedding slot:

```lisp
                  (,(intern "EMBEDDING" :graph-db)
                   :type (simple-array single-float (*))
                   :vector-index t)
```

- [ ] **Step 4: Run to verify they pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Backward-compatibility check**

Prove an existing graph still opens. Build a store, add chunks, close it; then reopen and confirm the chunks are readable and `store-count` is right. Add:

```lisp
(test existing-store-reopens-after-declaration
  "Backward compatibility is a hard requirement: a persisted store must open and
read correctly under the new declaration."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :scan :dimension 8)))
      (rag:store-add store (list (test-chunk "a" 8 1.0) (test-chunk "b" 8 2.0)))
      (gdb:close-graph (graph-store-graph store) :snapshot-p nil))
    (let ((store (open-graph-store (namestring dir) :strategy :scan :dimension 8)))
      (unwind-protect
           (is (= 2 (rag:store-count store))
               "reopened store lost chunks: count ~D" (rag:store-count store))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))
```

- [ ] **Step 6: Commit**

```bash
git add vivace/schema.lisp tests-vivace/schema.lisp
git commit -m "feat(rag): declare the chunk embedding slot :vector-index"
```

---

### Task 3: The `segment-graph-store` class

**Files:**
- Modify: `vivace/store.lisp`, `vivace/packages.lisp`
- Test: `tests-vivace/store.lisp`

**Interfaces:**
- Consumes: `graph-store` (base class, `vivace/store.lisp:5`), `hydrate` (`:14`), `make-graph-store` (`:265`).
- Produces: `segment-graph-store`; `(make-graph-store g :strategy :segment)`; `(open-graph-store path :strategy :segment)`. Task 4 adds its `store-search`; Task 7 makes it the default.

`store-add`, `store-delete-documents` and `save-store` are already defined on the `graph-store` base and need no override — the segment is maintained by the apply path, so unlike `cached-graph-store` there is no in-RAM index to keep in step. **Do not add `:after` methods mirroring `cached-graph-store`'s;** that would be duplicated bookkeeping for a structure the database already maintains.

- [ ] **Step 1: Write the failing tests**

```lisp
(test segment-strategy-selects-the-segment-store
  "make-graph-store and open-graph-store both accept :segment and return the
right class; the other two strategies are unaffected."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8)))
      (unwind-protect
           (is (typep store 'segment-graph-store)
               "expected a segment-graph-store, got ~S" (type-of store))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))

(test segment-store-counts-and-deletes
  "store-count and store-delete-documents work on the new store, inheriting the
graph-store base behaviour."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0)
                                        (test-chunk "b" 8 2.0)
                                        (test-chunk "c" 8 3.0)))
             (is (= 3 (rag:store-count store)) "expected 3, got ~D" (rag:store-count store))
             (rag:store-delete-documents store (list "b"))
             (is (= 2 (rag:store-count store))
                 "expected 2 after delete, got ~D" (rag:store-count store)))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — `SEGMENT-GRAPH-STORE` undefined / `:segment` not an accepted strategy (`ecase` error).

- [ ] **Step 3: Implement**

In `vivace/store.lisp`, beside `cached-graph-store`:

```lisp
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
```

Extend `make-graph-store`'s `ecase` with:

```lisp
                 (:segment (make-instance 'segment-graph-store
                                          :graph graph :type type :dimension dimension))
```

and update its docstring to name all three strategies.

Add a `hydrate` method. For now it only records the dimension the way the other stores do; Task 5 adds migration to it:

```lisp
(defmethod hydrate ((store segment-graph-store))
  "Record the store's dimension from a chunk vertex, if not supplied.
Task 5 extends this to migrate a pre-segment corpus.

Iterates FULLY rather than exiting early on the first hit: gdb:map-vertices may
hold locks, so a non-local exit out of it is unsafe.  Same reasoning, and the
same shape, as HYDRATE on SCAN-GRAPH-STORE."
  (unless (graph-store-dimension store)
    (map-chunk-vertices
     store
     (lambda (vertex)
       (unless (graph-store-dimension store)
         (let ((e (%slot vertex "EMBEDDING")))
           (when (typep e '(simple-array single-float (*)))
             (setf (graph-store-dimension store) (length e))))))))
  store)
```

Note this deliberately does NOT use `return-from` to stop at the first vertex — see the
verified-facts block above. Read the existing `hydrate` methods and match their conventions;
if they factor the dimension probe into a shared helper, reuse it rather than duplicating.

- [ ] **Step 4: Export**

In `vivace/packages.lisp`, export `#:segment-graph-store` alongside the existing store class exports.

- [ ] **Step 5: Run to verify they pass**, then the whole vivace suite.

- [ ] **Step 6: Commit**

```bash
git add vivace/store.lisp vivace/packages.lisp tests-vivace/store.lisp
git commit -m "feat(rag): segment-graph-store class and :segment strategy"
```

---

### Task 4: `store-search` — over-fetch and re-rank

**Files:**
- Modify: `vivace/store.lisp`
- Test: `tests-vivace/store.lisp`

**Interfaces:**
- Consumes: `gdb:vector-search (graph class-name slot-name query-vector k) → ((score . node-id) ...)`; `gdb:lookup-vertex (id &key (graph *graph*))` (an `array` method takes the raw 16-byte id); `rag::top-k-collector`, `rag::collect-candidate`, `rag::collector-results` (`rag/store.lisp`).
- Produces: `store-search` on `segment-graph-store`, returning what every other strategy returns.

**The ranking contract.** The engine ranks score DESC then **node-id** ASC; cl-llm ranks score DESC then **document-id** ASC. Fetching exactly `k` cannot be re-ranked into agreement, because the engine may already have truncated a tied group at the `k` boundary using the wrong key. So over-fetch, then re-rank with cl-llm's own collector, then truncate.

`rag::collect-candidate` already implements the document-id tiebreak — reuse it. Do not write a second ranking path.

- [ ] **Step 1: Write the failing tests**

```lisp
(defparameter *agreement-corpus-size* 40)

(test segment-search-agrees-with-cache-ranking
  "THE CARRYING TEST.  :segment and :cache must return identically ranked
results over the same corpus -- same scores, same order, same ids.

This is what proves two separate claims at once: that the engine's FULL COSINE
and cl-llm's BARE DOT agree on the unit-normalised vectors cl-llm actually
stores, and that the over-fetch re-rank restores cl-llm's document-id tiebreak
on top of the engine's node-id one.

The corpus deliberately includes exact-tie groups (several chunks sharing an
embedding, differing only in document-id), because ties are precisely where the
two tiebreak keys disagree and where a fetch of exactly k would fail."
  (with-temp-directory (dir-a)
    (with-temp-directory (dir-b)
      (let* ((chunks (agreement-corpus *agreement-corpus-size*))
             (seg (open-graph-store (namestring dir-a) :strategy :segment :dimension 8))
             (cache (open-graph-store (namestring dir-b) :strategy :cache :dimension 8)))
        (unwind-protect
             (progn
               (rag:store-add seg chunks)
               (rag:store-add cache chunks)
               (dolist (q (agreement-queries 8))
                 (let ((a (rag:store-search seg q 10))
                       (b (rag:store-search cache q 10)))
                   (is (= (length b) (length a))
                       "length mismatch for query ~S: segment ~D vs cache ~D"
                       q (length a) (length b))
                   (when (= (length a) (length b))
                     (loop for x in a for y in b
                           do (is (string= (rag:chunk-document-id (rag:hit-chunk x))
                                           (rag:chunk-document-id (rag:hit-chunk y)))
                                  "ranking diverged: segment ~S vs cache ~S"
                                  (rag:chunk-document-id (rag:hit-chunk x))
                                  (rag:chunk-document-id (rag:hit-chunk y)))
                              (is (< (abs (- (rag:hit-score x) (rag:hit-score y))) 1e-5)
                                  "score diverged for ~S: ~S vs ~S"
                                  (rag:chunk-document-id (rag:hit-chunk x))
                                  (rag:hit-score x) (rag:hit-score y))))))
               (is t "agreement test ran"))
          (progn (gdb:close-graph (graph-store-graph seg) :snapshot-p nil)
                 (gdb:close-graph (graph-store-graph cache) :snapshot-p nil)))))))

(test segment-search-dimension-mismatch-errors
  "Parity with scan-graph-store: a wrong-dimension query signals rather than
silently scoring against a prefix."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0)))
             (signals rag:llm-rag-error
               (rag:store-search store
                                 (make-array 4 :element-type 'single-float
                                               :initial-element 1.0)
                                 3)))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))

(test segment-search-k-larger-than-corpus
  "k above the corpus size returns everything, not an error or a padded list."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (rag:store-add store (list (test-chunk "a" 8 1.0) (test-chunk "b" 8 2.0)))
             (let ((hits (rag:store-search store (unit-query 8 1.0) 25)))
               (is (= 2 (length hits)) "expected 2 hits, got ~D" (length hits))))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))
```

Helpers to add beside `test-chunk`:

```lisp
(defun agreement-corpus (n)
  "N chunks with document-ids d000..., including deliberate EXACT-TIE groups:
every third chunk shares its neighbour's embedding, so the ranking of those
groups is decided purely by the document-id tiebreak."
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
  "A handful of queries hitting different regions of the corpus."
  (loop for j from 0 below dim
        collect (let ((v (make-array dim :element-type 'single-float
                                         :initial-element 0.05)))
                  (setf (aref v j) 1.0)
                  v)))

(defun unit-query (dim value)
  (make-array dim :element-type 'single-float
                  :initial-element (coerce value 'single-float)))
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — no `store-search` method for `segment-graph-store`, so the generic errors.

- [ ] **Step 3: Implement**

```lisp
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
    ;; Materialise ONLY the over-fetched survivors -- never the corpus.  This is
    ;; the premise of the whole phase: node loading was ~92% of the old cost.
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
```

`gdb:lookup-vertex` has an `array` method (`vertex.lisp:100`) that takes the raw 16-byte id,
which is exactly what `vector-search` returns in the `cdr`.

- [ ] **Step 4: Run to verify they pass**, then the whole vivace suite.

- [ ] **Step 5: Sabotage proof**

Set `*segment-overfetch-factor*` to 1 and re-run. `segment-search-agrees-with-cache-ranking` should FAIL on a tied group. **If it does not fail, the corpus does not contain a tie that straddles the k boundary and the test is not proving the over-fetch is needed** — strengthen the corpus until it does, or report honestly that you could not construct one and explain why. Restore the factor afterwards.

- [ ] **Step 6: Commit**

```bash
git add vivace/store.lisp tests-vivace/store.lisp
git commit -m "feat(rag): segment store-search with over-fetch and document-id re-rank"
```

---

### Task 5: Batched resumable migration on open

**Files:**
- Modify: `vivace/store.lisp` (the `hydrate` method from Task 3)
- Test: `tests-vivace/store.lisp`

**Interfaces:**
- Consumes: `gdb:rebuild-vector-segment-batched` from Task 1.
- Produces: a `:segment` store that opens correctly over a corpus written before the declaration existed.

**The scenario:** a graph holds chunk vertices written by an older cl-llm, so no segment exists for them. `hydrate` must notice and fill it.

**Detection:** compare the segment's live count against the chunk count. Absent segment, or a segment holding fewer vectors than there are conforming chunks, means migration is needed. Do not use a flag or a marker file — the segment is the source of truth (Task 1's whole design).

- [ ] **Step 1: Write the failing tests**

```lisp
(test segment-store-migrates-a-pre-segment-corpus
  "THE OTHER CARRYING TEST.  A store whose chunks were written before the
:vector-index declaration existed must, on open as :segment, migrate and then
return the same results as a natively-built one.

The pre-segment state is simulated by dropping the segment from an
already-populated graph -- which is exactly the on-disk state an upgrading
deployment has: chunk vertices present, no segment file."
  (with-temp-directory (dir)
    (let* ((chunks (agreement-corpus 20))
           (store (open-graph-store (namestring dir) :strategy :scan :dimension 8)))
      (rag:store-add store chunks)
      ;; simulate "written before the declaration": drop the segment, keep the chunks
      (let* ((g (graph-store-graph store))
             (key (cons (chunk-type-symbol 'rag-chunk) (intern "EMBEDDING" :graph-db)))
             (seg (gethash key (gdb::vector-segments g))))
        (when seg (gdb::close-vector-segment seg))
        (remhash key (gdb::vector-segments g)))
      (gdb:close-graph (graph-store-graph store) :snapshot-p nil))
    ;; reopen as :segment -- hydrate must migrate
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (is (= 20 (rag:store-count store))
                 "expected 20 chunks after migration, got ~D" (rag:store-count store))
             (let ((hits (rag:store-search store (unit-query 8 1.0) 10)))
               (is (= 10 (length hits))
                   "migrated store returned ~D hits, expected 10" (length hits))
               (when (= 10 (length hits))
                 (is (= 10 (length (remove-duplicates
                                    (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
                                            hits)
                                    :test #'string=)))
                     "migration produced duplicate chunks: ~S"
                     (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) hits)))))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))

(test segment-migration-is-idempotent-on-reopen
  "Opening an already-migrated store must not re-migrate or duplicate anything --
the skip-what-exists property, observed from the cl-llm side."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8)))
      (rag:store-add store (agreement-corpus 12))
      (gdb:close-graph (graph-store-graph store) :snapshot-p nil))
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8)))
      (unwind-protect
           (progn
             (is (= 12 (rag:store-count store))
                 "expected 12 after reopen, got ~D" (rag:store-count store))
             (let ((hits (rag:store-search store (unit-query 8 1.0) 12)))
               (is (= 12 (length hits)) "expected 12 hits, got ~D" (length hits))
               (when (= 12 (length hits))
                 (is (= 12 (length (remove-duplicates
                                    (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
                                            hits)
                                    :test #'string=)))
                     "reopen duplicated chunks"))))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))
```

- [ ] **Step 2: Run to verify they fail**

Expected: the migration test FAILS — the reopened store finds an empty segment and returns 0 hits.

- [ ] **Step 3: Implement**

Extend the Task 3 `hydrate` method:

```lisp
(defparameter *segment-migration-batch-size* 5000
  "Chunks per transaction when migrating a pre-segment corpus.  Matches
*EMBEDDING-MIGRATION-BATCH-SIZE*'s reasoning: gdb:copy duplicates the WHOLE
vertex, measured at ~40KB/chunk, so an unbatched 1M-chunk migration would be
~38GB in one transaction and unrecoverable on failure.")

(defparameter *segment-migration-progress-fn*
  (lambda (done total)
    (when (and total (plusp total) (zerop (mod done 50000)))
      (format *error-output* "~&; segment migration: ~:D/~:D chunks~%" done total)))
  "Called once per migration batch.  A migration of a real corpus takes minutes
and a silent one looks hung.")

(defmethod hydrate ((store segment-graph-store))
  "Probe the dimension, then migrate any chunks not yet in the segment.

MIGRATION IS BATCHED AND RESUMABLE, and its resumability comes from the segment
itself rather than from any marker this code keeps: REBUILD-VECTOR-SEGMENT-BATCHED
skips ids the segment already holds, so an interrupted migration completes on the
next open and an already-migrated store does no work beyond the skip scan.

COST, stated plainly: a corpus large enough to matter pays a one-time multi-minute
migration on the first open after upgrade.  It is progress-logged and resumable,
but it is not free."
  (unless (graph-store-dimension store)
    (block probe
      (map-chunk-vertices
       store
       (lambda (vertex)
         (let ((e (%slot vertex "EMBEDDING")))
           (when (typep e '(simple-array single-float (*)))
             (setf (graph-store-dimension store) (length e))
             (return-from probe)))))))
  (multiple-value-bind (inserted skipped)
      (gdb:rebuild-vector-segment-batched
       (graph-store-graph store)
       (chunk-type-symbol (graph-store-type store))
       (intern "EMBEDDING" :graph-db)
       :batch-size *segment-migration-batch-size*
       :progress-fn *segment-migration-progress-fn*)
    (declare (ignorable skipped))
    (when (plusp inserted)
      (format *error-output* "~&; segment migration complete: ~:D chunk~:P indexed~%"
              inserted)))
  store)
```

- [ ] **Step 4: Run to verify they pass**, then the whole vivace suite.

- [ ] **Step 5: Sabotage proof**

Comment out the `rebuild-vector-segment-batched` call in `hydrate`. `segment-store-migrates-a-pre-segment-corpus` must FAIL. Restore and re-run green. Report the output.

- [ ] **Step 6: Commit**

```bash
git add vivace/store.lisp tests-vivace/store.lisp
git commit -m "feat(rag): batched resumable segment migration on hydrate"
```

---

### Task 6: Prove no node is materialised for non-survivors

**Files:**
- Test only: `tests-vivace/store.lisp`

**Interfaces:** consumes everything from Tasks 3–5.

This is the performance premise of the entire phase, and nothing yet asserts it. **Assert it structurally by counting, not by timing** — a latency assertion would be flaky and would not distinguish "fast" from "correct".

Approach: count how many chunk vertices get built into `rag:chunk`s during one `store-search` over a corpus much larger than `k`. With over-fetch factor F, exactly `min(corpus, k*F)` vertices should be loaded — **not** the whole corpus. Counting via a rebinding of `vertex->chunk` is acceptable; if the codebase offers a cleaner seam (a counter in the store, a trace), prefer it. Do not measure time.

- [ ] **Step 1: Write the failing test**

```lisp
(test segment-search-does-not-materialise-the-corpus
  "THE PERFORMANCE PREMISE, asserted structurally.  Node loading was ~92% of the
old store-search cost; the segment exists so ranking never touches a node it is
not going to return.  A search for k over a corpus of N >> k must build at most
k * *segment-overfetch-factor* chunks -- not N.

Counted, never timed: a timing assertion would be flaky and would not
distinguish 'fast' from 'correct'."
  (with-temp-directory (dir)
    (let ((store (open-graph-store (namestring dir) :strategy :segment :dimension 8))
          (built 0))
      (unwind-protect
           (progn
             (rag:store-add store (agreement-corpus 200))
             (let ((original (symbol-function 'vertex->chunk)))
               (unwind-protect
                    (progn
                      (setf (symbol-function 'vertex->chunk)
                            (lambda (v) (incf built) (funcall original v)))
                      (let ((hits (rag:store-search store (unit-query 8 1.0) 5)))
                        (is (= 5 (length hits)) "expected 5 hits, got ~D" (length hits))))
                 (setf (symbol-function 'vertex->chunk) original)))
             (is (plusp built)
                 "no chunks were built at all -- the counter never fired, so this ~
test proves nothing")
             (is (<= built (* 5 *segment-overfetch-factor*))
                 "materialised ~D chunks for a k=5 search over 200 -- the search is ~
loading nodes it does not return, which is the cost this whole phase exists to ~
remove" built)
             (is (< built 200)
                 "materialised ~D of 200 chunks -- that is a full corpus scan" built))
        (gdb:close-graph (graph-store-graph store) :snapshot-p nil)))))
```

- [ ] **Step 2: Run it**

It should PASS if Task 4 is correct. **That is the wrong order for TDD, so verify it is discriminating instead:** temporarily change Task 4's `store-search` to load every chunk vertex before ranking (e.g. call `map-chunk-vertices` building a chunk for each, then rank), re-run, and confirm this test FAILS on the `<= built` assertion. Restore. Report both runs. A test that cannot fail is the thirteenth vacuous assertion.

- [ ] **Step 3: Commit**

```bash
git add tests-vivace/store.lisp
git commit -m "test(rag): assert segment search never materialises the corpus"
```

---

### Task 7: Make `:segment` the default; retire the read-side coercion

**Files:**
- Modify: `vivace/store.lisp` (`make-graph-store`, `open-graph-store` defaults)
- Modify: `vivace/schema.lisp` (`vertex->chunk`)
- Modify: `tests-vivace/schema.lisp` (repurpose the coercion test)
- Modify: `CHANGELOG.md` if the repo keeps one

**Interfaces:** consumes everything above.

- [ ] **Step 1: Change the defaults**

In `make-graph-store` and `open-graph-store`, change `(strategy :cache)` to `(strategy :segment)`, and update both docstrings to describe the three strategies and when each is right:

```
STRATEGY is :segment (default), :cache or :scan.
  :segment  embeddings live in graph-db's mmap vector segment; search never
            materialises a node it will not return, and the corpus need not fit
            in the Lisp heap.  The right default for a persistent graph.
  :cache    an in-RAM index; FASTER than :segment (the corpus is already in the
            heap) and the right choice when it fits there.
  :scan     no index; scores every chunk vertex per query.  Fallback and
            correctness reference.
```

- [ ] **Step 2: Retire the read-side coercion**

In `vivace/schema.lisp`, `vertex->chunk`: drop the `rag:as-embedding` call, reading the slot directly. Replace the long historical docstring with a short statement of the current contract — that `validate-chunks` normalises write-side before `chunk->vertex`, so a non-conforming embedding cannot reach a vertex, and the read side therefore does not re-normalise (saving an allocation, a sqrt, N divisions and ~1 ULP of drift per chunk read). Keep a one-line pointer to the history rather than the full narrative.

- [ ] **Step 3: Repurpose the coercion test**

`CHUNK-VERTEX-COERCES-GENERAL-VECTOR-EMBEDDING` (`tests-vivace/schema.lisp`) exists to exercise the coercion being removed. Rewrite it to assert the **write-side enforcement that replaced it** — that a chunk with a non-conforming embedding, added through `store-add`, results in a vertex whose slot is a conforming normalised `(simple-array single-float (*))`. Rename it accordingly (e.g. `store-add-normalises-non-conforming-embedding`). Do not delete it: it is the only coverage of non-conforming input.

Also revisit `CHUNK-VERTEX-ROUND-TRIPS-WITH-COERCED-EMBEDDING`, which documents the re-normalisation drift that no longer occurs; update or remove it as the change dictates, and say which you did and why.

- [ ] **Step 4: Run the full test suites**

Run every cl-llm suite that touches the RAG/vivace path, not just the vivace one — the default change affects any caller that never passed `:strategy`. Report each suite's counts, and call out any test that had to change because of the new default.

- [ ] **Step 5: Sabotage proof for the repurposed test**

Temporarily make `validate-chunks` skip normalisation; the repurposed test must FAIL. Restore. Report the output. This confirms the replacement test guards what the removed coercion used to.

- [ ] **Step 6: Commit**

```bash
git add vivace/store.lisp vivace/schema.lisp tests-vivace/
git commit -m "feat(rag)!: default to :segment; retire the read-side embedding coercion"
```

---

## Verification Checklist

- [ ] `graph-db-suite` green in vivace-graph-v3 (was 2449/2449)
- [ ] All cl-llm suites green
- [ ] Every sabotage proof in Tasks 1, 4, 5, 6, 7 demonstrated failing then restored
- [ ] An existing persistent store opens, migrates, and answers correctly
- [ ] `:cache` and `:scan` still work and are still tested
- [ ] The changelog records the default change
