# `store-delete-document` — Design

**Date:** 2026-07-19
**Status:** Approved (design). Branch of record (cl-llm): `feat/store-delete-document`.
**Consumer:** mine-action's knowledge substrate — turns the current "rebuild to refresh" limitation
into an in-place document refresh (`kb-ingest-extraction`).

---

## 1. Purpose

Add a **delete-by-document-id** capability to the `cl-llm.rag` store protocol so a document's chunks
can be removed from a vector store, then re-added with fresh content. Today the protocol is add-only
(`store-add` / `store-search` / `store-count` / `save-store`) with no removal path, which forces the
mine-action ingest loop to warn *"rebuild the knowledge graph to refresh"* whenever an already-ingested
document's content (checksum) changes. This closes that gap.

A `chunk` (`rag/document.lisp`) carries a `document-id` but no chunk-level primary key, so the natural
and only sensible unit of deletion is **the document** — remove every chunk sharing a `document-id`.

## 2. Decisions (this brainstorm)

| Decision | Choice |
|---|---|
| **Unit of deletion** | By `document-id` (a chunk's only identity field). Delete all chunks of a doc. |
| **Finding a doc's chunks** | **Full scan** (`map-chunk-vertices` / vector walk), no new `document-id` index. Refreshes are rare and a scan matches the existing `store-search`/`store-count` cost. A `def-view` secondary index is a deferred optimization (YAGNI). |
| **Graph deletion primitive** | graph-db's exported `mark-deleted` (soft-delete; deleted vertices are skipped by `map-vertices` by default). Accept soft-delete: dead vertices stay on disk, reclaimed on a full rebuild. |
| **Cache coherence** | `cached-graph-store` keeps the RAM index in sync via a `store-delete-document :after` method — symmetric with the existing `store-add :after` write-through — rather than a full re-hydrate. |
| **mine-action** | Wire the refresh now: the "checksum changed, already ingested" branch becomes delete-then-re-add. |

## 3. The new protocol generic (`cl-llm.rag`)

`rag/store.lisp`:
```lisp
(defgeneric store-delete-document (store document-id)
  (:documentation "Remove every indexed chunk whose DOCUMENT-ID matches (EQUAL).
Returns the number of chunks removed (0 if none matched -- deleting an absent
document is a no-op, never an error)."))
```
Exported from `rag/packages.lisp` (added to the `#:store-add #:store-search #:store-count …` line).

**`memory-store` method** (`rag/store.lisp`) — rebuild the backing vector in place (its `chunks` slot
is an adjustable fill-pointer vector, reader-only; reset the fill-pointer and re-push the survivors,
so no slot writer is needed):
```lisp
(defmethod store-delete-document ((store memory-store) document-id)
  (let* ((chunks (store-chunks store))
         (kept (remove document-id chunks :key #'chunk-document-id :test #'equal))
         (removed (- (length chunks) (length kept))))
    (setf (fill-pointer chunks) 0)
    (loop for c across kept do (vector-push-extend c chunks))
    removed))
```
(The store's `dimension` slot is left as-is — it records the enforced embedding dimension, which does
not change when chunks are removed.)

## 4. The vivace graph stores (`cl-llm.rag.vivace`)

Three store classes exist; deletion needs a **primary method on the base `graph-store`** (handles both
`scan-graph-store` and `cached-graph-store`, since both subclass it) plus a **cache-sync `:after` on
`cached-graph-store`** — the exact split `store-add` already uses.

**Primary method on `graph-store`** (`vivace/store.lisp`) — collect matching vertices during the map
(do **not** mutate the graph while `map-vertices` iterates — it may hold locks; mirror the existing
`hydrate` caution), then soft-delete them in one transaction:
```lisp
(defmethod rag:store-delete-document ((store graph-store) document-id)
  (let ((victims '()))
    (map-chunk-vertices
     store
     (lambda (vertex)
       (when (equal (%slot vertex "DOCUMENT-ID") document-id)
         (push vertex victims))))
    (when victims
      (let ((gdb:*graph* (graph-store-graph store)))
        (gdb:with-transaction ()
          (dolist (v victims) (gdb:mark-deleted v)))))
    (length victims)))
```
**Transaction primitive — verify during implementation:** `gdb:mark-deleted` is documented as wrapping
its own transaction. Calling it inside an explicit `gdb:with-transaction` must nest cleanly (join the
outer tx) for the batch to be atomic; if graph-db does not support that nesting, call the lower-level
exported `gdb:delete-node` per victim inside the single `with-transaction` instead (the victims come
from a fresh scan, so they are all live — the `deleted-p` guard `mark-deleted` adds is not needed).
Consult the graph-db MVCC contract guide (referenced from vivace-graph-v3's memory) to pick correctly.
The intent is fixed: **all of a document's chunks are marked deleted in a single transaction.**

**Cache-sync `:after` on `cached-graph-store`** — apply the same delete to the composed
`rag:memory-store` so `store-count`/`store-search` (which read the RAM index) stop returning the
deleted chunks:
```lisp
(defmethod rag:store-delete-document :after ((store cached-graph-store) document-id)
  (rag:store-delete-document (cache-index store) document-id))
```
The `:after` runs after the primary graph delete and does not alter the primary method's return value
(the graph-side removed-count). `scan-graph-store` needs no `:after` — it re-scans the graph on every
`store-count`/`store-search`, and `map-vertices` already skips soft-deleted vertices.

## 5. mine-action consumption (`src/knowledge-ingest.lisp`)

`kb-ingest-extraction`'s cond currently has three text-row branches: (a) new / previously-deferred →
ingest; (b) already ingested, checksum unchanged → idempotent keep; (c) already ingested, checksum
**changed** → warn "rebuild to refresh" (the v1 limitation). Change **only branch (c)** to
delete-then-re-add:
```lisp
;; text row, already ingested, checksum CHANGED -> drop the stale chunks and re-ingest fresh.
((string= triage "text")
 (let ((doc (%kb-record->document rec)))
   (cl-llm.rag:store-delete-document store doc-id)      ; remove the old chunks
   (let ((before (cl-llm.rag:store-count store)))
     (cl-llm.rag:add-documents index (list doc))         ; re-embed + re-add
     (let ((added (- (cl-llm.rag:store-count store) before)))
       (incf ingested) (incf chunks added)
       (kb-registry-upsert registry
         (%kb-record->source rec :ingest-status :ingested :chunk-count added))))))
```
Update the `kb-ingest-extraction` docstring to drop the "no delete → rebuild required" caveat.

**Branch (a) is deliberately left as a pure add — no delete.** Deleting is a full scan; adding a
delete to the brand-new/first-ingest path would make a bulk corpus ingest pay one full-store scan per
document (O(n²)). Branch (c) is rare (a document's content actually changed), so its per-refresh scan
is acceptable.

**Atomicity note (accepted):** the refresh is delete-then-add across two store operations, so a
concurrent reader could briefly observe the document absent between them. Ingest is a single-writer
maintenance path, not a hot query path, so this window is acceptable; a fully-atomic
delete+add is a future refinement if ingest ever runs concurrently with live queries.

## 6. Testing

**cl-llm (`tests-rag` + `tests-vivace`, FiveAM):**
- `memory-store`: add chunks for docs A and B → `store-delete-document A` returns A's count, `store-count`
  drops by exactly that, a search no longer returns A's chunks, B's remain.
- `store-delete-document` of an absent document-id → returns 0, store unchanged.
- `scan-graph-store` (real graph in a temp dir): add → delete-by-doc → `store-count` and `store-search`
  both exclude the deleted doc (verifies the soft-deleted vertices are skipped by the re-scan).
- `cached-graph-store`: add → delete-by-doc → the RAM cache AND a fresh `hydrate` of a new store over
  the same graph both agree the doc is gone (verifies the `:after` cache sync AND the graph-side delete).
- Round-trip refresh: add doc A (chunks X), delete A, add doc A with different chunks (Y) → only Y is
  retrievable, `store-count` reflects Y not X+Y (the mine-action refresh scenario end-to-end).

**mine-action:** verify branch (c) live after the batched restart — re-ingest an extraction where one
already-ingested doc's checksum changed; confirm its chunk count is replaced (not duplicated) and the
new content retrieves. (No automated framework; compile-check + a driven ingest, as usual.)

## 7. Process / deployment

- Develop in `/Users/kraison/work/cl-llm` on `feat/store-delete-document`; run its FiveAM suite. Same
  flow as PR #7 (`fix/vivace-reopen-fresh-image`) — Kevin decides the merge/PR.
- mine-action consumes the local cl-llm checkout (`ql:register-local-projects`), no version pin.
- The mine-action change needs a server restart; **batch it with the pending code-hardening restart**
  so Kevin's SLIME on 4007 drops once. The existing live knowledge graph is unaffected until an actual
  changed-checksum re-ingest triggers branch (c).

## 8. Non-goals (YAGNI)

- **No `document-id` index** (a graph-db `def-view`) — scan is adequate for rare refreshes; note it as
  the optimization to reach for if per-doc refresh becomes frequent at scale.
- **No chunk-level delete** — chunks have no primary key; document-id is the unit.
- **No hard delete / graph compaction** — soft-delete is graph-db's model; a full rebuild reclaims dead
  vertices.
- **No general `store-delete(store predicate)`** — only the document-id form the consumer needs.

## Related documents

- [`2026-07-18-cl-llm-rag-design.md`](2026-07-18-cl-llm-rag-design.md) — the store protocol this extends.
- [`2026-07-18-cl-llm-rag-vivace-design.md`](2026-07-18-cl-llm-rag-vivace-design.md) — the graph-store
  strategies (`:cache`/`:scan`) and the chunk vertex schema this deletes from.
- mine-action `docs/superpowers/specs/2026-07-18-knowledge-substrate-design.md` — the ingest loop and
  the "no delete-by-document-id → rebuild to refresh" limitation this removes.
