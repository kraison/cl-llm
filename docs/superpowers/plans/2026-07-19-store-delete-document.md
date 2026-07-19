# `store-delete-document` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add delete-by-document-id to the `cl-llm.rag` store protocol and wire mine-action's ingest to refresh a changed document in place (replacing the "rebuild to refresh" limitation).

**Architecture:** A new `store-delete-document` generic in `cl-llm.rag`, implemented for `memory-store` (in-place vector rebuild) and the vivace stores (scan + `gdb:mark-deleted` in one transaction on the base `graph-store`; a `:after` on `cached-graph-store` syncs the RAM index). mine-action's `kb-ingest-extraction` then deletes+re-adds a doc whose checksum changed.

**Tech Stack:** Common Lisp, SBCL, ASDF, FiveAM. Two repos: `/Users/kraison/work/cl-llm` (the capability) and `/Users/kraison/quicklisp/local-projects/mine-action` (the consumer, uses the local cl-llm checkout via `ql:register-local-projects`).

**Design:** `docs/superpowers/specs/2026-07-19-store-delete-document-design.md` (in cl-llm).

## Global Constraints

- **Delete is by `document-id`, EQUAL-matched**; returns the count removed; deleting an absent doc-id is a no-op returning 0, never an error.
- **Atomic graph delete:** all of a document's chunk vertices are marked deleted in ONE `gdb:with-transaction` (confirmed: `mark-deleted` joins an active `*transaction*` via `ensure-transaction`).
- **Cache coherence:** after a delete, `cached-graph-store`'s `store-count`/`store-search` (which read the RAM `memory-store`) must not return deleted chunks.
- **Do not mutate the graph while `gdb:map-vertices` iterates** — collect matching vertices first, delete after (mirrors the existing `hydrate` caution).
- **Lisp: spaces only, never tabs.** Match each file's existing style.
- **mine-action branch (a)** (new / previously-deferred docs) stays a pure add — no delete on the first-ingest path (a full-scan delete there would make bulk ingest O(n²)).

## File Structure

- **cl-llm** `rag/store.lisp` — new generic + `memory-store` method.
- **cl-llm** `rag/packages.lisp` — export `store-delete-document`.
- **cl-llm** `vivace/store.lisp` — `graph-store` primary method + `cached-graph-store :after`.
- **cl-llm** `tests-rag/store.lisp` — memory-store delete tests.
- **cl-llm** `tests-vivace/store-scan.lisp`, `store-cache.lisp` — vivace delete tests.
- **mine-action** `src/knowledge-ingest.lisp` — rewrite the changed-checksum branch + docstring.

**Test commands:**
- cl-llm rag: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
- cl-llm vivace: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/vivace/tests")'`
- mine-action compile-check: the non-silent `ql:quickload :mine-action` from its CLAUDE.md.

---

### Task 1: `store-delete-document` generic + `memory-store` method (cl-llm rag core)

**Files:**
- Modify: `rag/store.lisp` (generic near the other `defgeneric`s; method after the `memory-store` `store-count` method)
- Modify: `rag/packages.lisp` (export)
- Modify: `tests-rag/store.lisp` (tests)

**Interfaces:**
- Produces: `store-delete-document (store document-id) -> integer`. Consumed by Task 2 (vivace methods) and Task 3 (mine-action).

- [ ] **Step 1: Write the failing tests**

Append to `tests-rag/store.lisp` (package `#:cl-llm.rag.test`, suite `cl-llm-rag-suite`, helper `v` already defined there):

```lisp
(test store-delete-document-removes-matching-chunks
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "a1" :document-id "A" :embedding (v 1 0))
                           (rag:make-chunk "a2" :document-id "A" :embedding (v 1 1))
                           (rag:make-chunk "b1" :document-id "B" :embedding (v 0 1))))
    (is (= 3 (rag:store-count s)))
    (is (= 2 (rag:store-delete-document s "A")) "returns the number removed")
    (is (= 1 (rag:store-count s)))
    ;; only B remains -- a search never returns an A chunk
    (let ((hits (rag:store-search s (v 1 0) 5)))
      (is (= 1 (length hits)))
      (is (string= "B" (rag:chunk-document-id (rag:hit-chunk (first hits))))))))

(test store-delete-absent-document-is-a-noop
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "b1" :document-id "B" :embedding (v 0 1))))
    (is (= 0 (rag:store-delete-document s "NOPE")))
    (is (= 1 (rag:store-count s)))))

(test store-delete-then-readd-refreshes
  ;; the mine-action refresh scenario: same doc-id, different chunks
  (let ((s (rag:make-memory-store)))
    (rag:store-add s (list (rag:make-chunk "old" :document-id "A" :embedding (v 1 0))))
    (rag:store-delete-document s "A")
    (rag:store-add s (list (rag:make-chunk "new" :document-id "A" :embedding (v 0 1))))
    (is (= 1 (rag:store-count s)))
    (is (string= "new" (rag:chunk-text (rag:hit-chunk (first (rag:store-search s (v 0 1) 1))))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
Expected: FAIL — `store-delete-document` is an undefined function (unexported / undefined).

- [ ] **Step 3: Add the generic + export**

In `rag/store.lisp`, after the `save-store` defgeneric (with the other protocol generics):

```lisp
(defgeneric store-delete-document (store document-id)
  (:documentation "Remove every indexed chunk whose DOCUMENT-ID matches (EQUAL).
Returns the number of chunks removed (0 if none matched -- deleting an absent
document is a no-op, never an error)."))
```

In `rag/packages.lisp`, add `#:store-delete-document` to the export list line that currently reads
`#:store-add #:store-search #:store-count #:save-store #:load-store`:

```lisp
   #:store-add #:store-search #:store-count #:store-delete-document #:save-store #:load-store
```

- [ ] **Step 4: Implement the `memory-store` method**

In `rag/store.lisp`, after `(defmethod store-count ((store memory-store)) ...)`:

```lisp
(defmethod store-delete-document ((store memory-store) document-id)
  "Rebuild the backing vector in place, dropping chunks whose DOCUMENT-ID matches."
  (let* ((chunks (store-chunks store))
         (kept (remove document-id chunks :key #'chunk-document-id :test #'equal))
         (removed (- (length chunks) (length kept))))
    (setf (fill-pointer chunks) 0)
    (loop for c across kept do (vector-push-extend c chunks))
    removed))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
Expected: PASS — the three new tests plus the existing rag suite all green.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kraison/work/cl-llm add rag/store.lisp rag/packages.lisp tests-rag/store.lisp
git -C /Users/kraison/work/cl-llm commit -m "feat(rag): store-delete-document generic + memory-store impl"
```

---

### Task 2: vivace graph-store delete (scan + mark-deleted) + cache sync

**Files:**
- Modify: `vivace/store.lisp` (primary method on `graph-store`; `:after` on `cached-graph-store`)
- Modify: `tests-vivace/store-scan.lisp`, `tests-vivace/store-cache.lisp` (tests)

**Interfaces:**
- Consumes: Task 1's `rag:store-delete-document` generic; the existing `map-chunk-vertices`, `%slot`, `graph-store-graph`, `cache-index`, `gdb:mark-deleted`, `gdb:with-transaction`.
- Produces: `store-delete-document` working on `scan-graph-store` and `cached-graph-store`.

- [ ] **Step 1: Write the failing tests**

Append to `tests-vivace/store-scan.lisp` (package `#:cl-llm.rag.vivace/tests`, suite `:cl-llm-rag-vivace`, nicknames `v`=vivace, `rag`=cl-llm.rag, `gdb`=graph-db; follow the existing in-memory-graph pattern in that file — a `gdb:make-graph` with a unique `/tmp` dir + `rag:make-mock-embedder`):

```lisp
(test scan-store-delete-document
  (let* ((dir (format nil "/tmp/cl-llm-vg-del-scan-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (let* ((g (gdb:make-graph :cl-llm-vg-del-scan (pathname dir)))
                (store (v:make-graph-store g :strategy :scan)))
           (rag:store-add store (list (rag:make-chunk "a1" :document-id "A"
                                        :embedding (rag:embed emb "a1"))
                                      (rag:make-chunk "a2" :document-id "A"
                                        :embedding (rag:embed emb "a2"))
                                      (rag:make-chunk "b1" :document-id "B"
                                        :embedding (rag:embed emb "b1"))))
           (is (= 3 (rag:store-count store)))
           (is (= 2 (rag:store-delete-document store "A")))
           (is (= 1 (rag:store-count store)))                    ; re-scan excludes soft-deleted
           (let ((hits (rag:store-search store (rag:embed emb "a1") 5)))
             (is (every (lambda (h) (string= "B" (rag:chunk-document-id (rag:hit-chunk h)))) hits)))
           (gdb:close-graph g))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))
```

Append to `tests-vivace/store-cache.lisp` (same package/suite):

```lisp
(test cache-store-delete-syncs-cache-and-graph
  (let* ((dir (format nil "/tmp/cl-llm-vg-del-cache-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (let* ((g (gdb:make-graph :cl-llm-vg-del-cache (pathname dir)))
                (store (v:make-graph-store g :strategy :cache)))
           (rag:store-add store (list (rag:make-chunk "a1" :document-id "A"
                                        :embedding (rag:embed emb "a1"))
                                      (rag:make-chunk "b1" :document-id "B"
                                        :embedding (rag:embed emb "b1"))))
           (is (= 2 (rag:store-count store)))
           (is (= 1 (rag:store-delete-document store "A")))
           (is (= 1 (rag:store-count store)) "cache count reflects the delete")   ; :after synced RAM index
           ;; a FRESH store over the same graph hydrates without the deleted doc -> graph delete stuck
           (let ((store2 (v:make-graph-store g :strategy :cache)))
             (is (= 1 (rag:store-count store2)))
             (is (string= "B" (rag:chunk-document-id
                               (rag:hit-chunk (first (rag:store-search store2 (rag:embed emb "b1") 5)))))))
           (gdb:close-graph g))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/vivace/tests")'`
Expected: FAIL — no `store-delete-document` method for the vivace stores (the base `graph-store` has none; `no-applicable-method`).

- [ ] **Step 3: Implement the primary method + cache `:after`**

In `vivace/store.lisp`, after the `graph-store` `store-add` primary method (and its `map-chunk-vertices` helper):

```lisp
(defmethod rag:store-delete-document ((store graph-store) document-id)
  "Soft-delete every chunk vertex whose DOCUMENT-ID matches, atomically.
Collect the victims first (do NOT mutate the graph while map-vertices iterates),
then mark-deleted them in one transaction (mark-deleted joins the active tx)."
  (let ((victims '()))
    (map-chunk-vertices
     store
     (lambda (vertex)
       (when (equal (%slot vertex "DOCUMENT-ID") document-id)
         (push vertex victims))))
    (when victims
      (let ((gdb:*graph* (graph-store-graph store)))
        (gdb:with-transaction ()
          (dolist (v victims)
            (gdb:mark-deleted v)))))
    (length victims)))
```

After the `cached-graph-store` `store-add :after` method:

```lisp
;; keep the in-RAM index (which store-count/store-search read) in step with the graph delete
(defmethod rag:store-delete-document :after ((store cached-graph-store) document-id)
  (rag:store-delete-document (cache-index store) document-id))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/vivace/tests")'`
Expected: PASS — both new tests plus the existing vivace suite green. (Confirms: scan re-scan excludes soft-deleted; cache `:after` keeps `store-count` right; the graph delete persists to a freshly-hydrated store.)

- [ ] **Step 5: Commit**

```bash
git -C /Users/kraison/work/cl-llm add vivace/store.lisp tests-vivace/store-scan.lisp tests-vivace/store-cache.lisp
git -C /Users/kraison/work/cl-llm commit -m "feat(vivace): store-delete-document (scan+mark-deleted, cache :after sync)"
```

---

### Task 3: wire mine-action ingest to refresh in place

**Files:**
- Modify: `/Users/kraison/quicklisp/local-projects/mine-action/src/knowledge-ingest.lisp` (the changed-checksum branch + docstring)

**Interfaces:**
- Consumes: `cl-llm.rag:store-delete-document` (Tasks 1-2), the existing `%kb-record->document`, `add-documents`, `store-count`, `kb-registry-upsert`, `%kb-record->source`.

- [ ] **Step 1: Rewrite the changed-checksum branch**

In `src/knowledge-ingest.lisp`, replace the third text-row `cond` branch (the one that currently warns
`"...v1 has no chunk-delete so its stored chunks are now STALE -- rebuild the knowledge graph to refresh it"`
and upserts with the OLD chunk-count) with a delete-then-re-add:

```lisp
                      ;; text row, already ingested, checksum CHANGED -> drop the stale chunks and
                      ;; re-ingest fresh (cl-llm.rag now supports delete-by-document-id).
                      ((string= triage "text")
                       (cl-llm.rag:store-delete-document store doc-id)
                       (let* ((doc (%kb-record->document rec))
                              (before (cl-llm.rag:store-count store)))
                         (cl-llm.rag:add-documents index (list doc))
                         (let ((added (- (cl-llm.rag:store-count store) before)))
                           (incf ingested) (incf chunks added)
                           (kb-registry-upsert registry
                             (%kb-record->source rec :ingest-status :ingested :chunk-count added)))))
```

(Leave branch (a) — the "not yet ingested" branch — and branch (b) — "checksum unchanged, idempotent" — exactly as they are.)

- [ ] **Step 2: Update the docstring**

In the `kb-ingest-extraction` docstring, remove the "v1 limitation (no delete-by-doc-id) ... rebuild the knowledge graph to refresh it" paragraph and replace it with a one-line note that a changed-checksum `:text` row now deletes its stale chunks and re-ingests in place (the deferred→text path is unchanged). Keep the "malformed lines are skipped" note.

- [ ] **Step 3: Non-silent compile-check**

Run (from the mine-action dir):
```bash
sbcl --non-interactive --eval '(ql:register-local-projects)' \
     --eval '(handler-case (progn (ql:quickload :mine-action) (format t "~&OK~%")) (error (e) (format t "~&ERR ~A~%" e)))'
```
Expected: `OK`, no undefined-function warning for `store-delete-document` (confirms mine-action sees the new cl-llm export via the local checkout).

- [ ] **Step 4: Commit (mine-action repo)**

```bash
git -C /Users/kraison/quicklisp/local-projects/mine-action add src/knowledge-ingest.lisp
git -C /Users/kraison/quicklisp/local-projects/mine-action commit -m "feat(kb): refresh a changed doc in place via store-delete-document (was: rebuild-to-refresh)"
```

---

### Task 4: batched restart + live refresh verification (operational — controller-driven)

**This is a manual/operational step, not a TDD unit.** Performed by the controller driving the live dev-hub server, batched with the pending code-hardening restart so Kevin's SLIME on 4007 drops once.

**Files:** none (operates on the live server).

- [ ] **Step 1: Clean restart** — SIGTERM the running sbcl (clean shutdown: snapshots, clears `.dirty`), then relaunch `tools/run-server.sh` (no `--rebuild` — the existing knowledge graph and its 8,577 chunks are preserved; the restart just loads the new code: hardening + `store-delete-document`). Confirm the server is back (SWANK 4007, `/api/kb/registry` responds).

- [ ] **Step 2: Verify the refresh path live** — pick an already-ingested `:text` doc, produce an extraction row for it with a CHANGED checksum + different text (a scratch `extraction.jsonl` with a single edited row is enough), and run `kb-ingest-extraction` on it via the SWANK client. Confirm: `store-count` ends unchanged-net or reflects the new chunk count for that doc (NOT old+new — i.e. no duplication), a warning is NOT emitted, and a query for the new text retrieves the fresh content while the old content is gone. Record before/after counts.

- [ ] **Step 3: Record the outcome** in the finishing summary. No commit (operates on the live graph).

---

## Self-Review (completed by plan author)

- **Spec coverage:** generic+export (T1) · memory-store (T1) · graph-store scan+mark-deleted atomic (T2) · cached `:after` sync (T2) · mine-action refresh branch (T3) · restart+live verify (T4) · all test scenarios from spec §6 (memory add/delete/absent/refresh in T1; scan re-scan-excludes + cache-sync + fresh-hydrate-persists in T2) — mapped.
- **Type consistency:** `store-delete-document (store document-id) -> integer` identical at the generic, both cl-llm methods, and the mine-action call site; `map-chunk-vertices`/`%slot`/`cache-index`/`graph-store-graph` are the real existing vivace symbols; `mark-deleted`/`with-transaction`/`*graph*` are the real graph-db symbols.
- **No placeholders:** every code step carries the actual code and the exact test command with expected result.
- **Constraint checks:** branch (a) left as pure add (no O(n²) on bulk ingest); victims collected before mutating (no mutate-during-map); single-transaction atomic delete; cache kept coherent via `:after`.
