# Moving the mine-action knowledge base to the `:segment` store

**Audience:** the mine-action team
**Date:** 2026-07-21
**Applies to:** cl-llm `main` at `11570f6` or later, VivaceGraph `experiment` at `278acef` or later

---

## 1. The short version

cl-llm's graph-backed RAG store has a new strategy, `:segment`. Chunk embeddings are kept in a memory-mapped dense-vector index inside the graph itself, and dense search is answered by scanning that block directly — **without loading a single chunk vertex that isn't going to be returned**.

**Nothing about your deployment changes until you decide it does.** You pass `:strategy :cache` explicitly in `src/knowledge-graph.lisp`, so the new default does not reach you. Switching is a one-word edit, and it is reversible.

Read §3 before you decide — the honest answer for *your* setup is more nuanced than "it's faster".

---

## 2. What actually changed

Declaring a slot `:vector-index t` now makes VivaceGraph maintain an mmap-backed vector segment for it automatically, on the ordinary transaction apply path — the same mechanism `:unique` and `:index` use. cl-llm's chunk schema declares its `EMBEDDING` slot that way, so **the segment is already being maintained for `ma-kb-chunk` right now**, whether or not you use it for search. Writing chunks keeps it up to date; nothing extra to call.

Three strategies now exist. They are trades, not a progression:

| strategy | dense search @20k | corpus held in Lisp heap | notes |
| --- | --- | --- | --- |
| `:cache` | ~15 ms | **yes** | Fastest. What you use today. Not deprecated. |
| `:segment` | ~35 ms | no | Pageable; embeddings queryable alongside graph queries. New default. |
| `:scan` | ~2.3 s | no | No index. Correctness reference. |

`:cache` is *faster* than `:segment`, and that is not a defect — the corpus is already in the heap, so there is nothing to decode. `:segment`'s advantage is that the corpus **does not have to be** in the heap.

---

## 3. What you would actually gain — and what you would not

This is the part worth reading twice, because your architecture has a wrinkle.

**You would gain:** the dense index no longer lives in the Lisp heap. Today `:cache` holds a `memory-store` containing every chunk and its embedding; that copy goes away.

**You would not gain as much as that implies**, because `open-knowledge-graph` also does this:

```lisp
(setf sparse (let ((sp (cl-llm.rag:make-sparse-store)))
               (cl-llm.rag:store-add sp (cl-llm.rag.vivace:graph-store-chunks store))
               sp))
```

`graph-store-chunks` materialises **every chunk in the corpus** as a `rag:chunk`, and your BM25 sparse store then retains them for the process lifetime. That happens on every open and is completely independent of the dense strategy.

So switching `:cache` → `:segment` removes *one* full in-memory copy of the corpus, not both. At 1024-dimension embeddings the dense copy is the larger one (4 KB/chunk of float data alone), so the saving is real — but if your goal is "the knowledge base should not have to fit in RAM", the sparse hydration is the next thing to look at, and it is out of scope for this change.

**Straight recommendation:** if your corpus fits comfortably in the heap today and search latency is acceptable, there is no urgency. Switch when you want the embeddings queryable from ordinary graph queries, or when heap pressure starts to matter. Do not switch expecting a speed-up — dense search will get *slower* per query (~15 ms → ~35 ms at 20k), which is almost certainly irrelevant next to LLM latency, but you should know it rather than discover it.

---

## 4. How to switch

One word, in `src/knowledge-graph.lisp`:

```lisp
 (setf store (let ((graph-db:*graph* graph))
               (cl-llm.rag.vivace:make-graph-store graph
-                                                  :type 'ma-kb-chunk :strategy :cache :dimension 1024)))
+                                                  :type 'ma-kb-chunk :strategy :segment :dimension 1024)))
```

Keep passing `:strategy` explicitly even though `:segment` is now the default — an explicit strategy is self-documenting and immune to future default changes.

Nothing else in your code needs to change. `store-search`, `store-add`, `store-delete-documents` and `store-count` all behave the same and return the same shapes (`store-search` still returns a list of `rag:hit`).

**Your `ensure-chunk-class` call must stay where it is.** You already call it before `graph-db:open-graph`, with the comment explaining why. That ordering is now load-bearing for a second reason: at open, the engine only re-registers an existing segment file if the owning class is defined *and finalized*. Your code does this correctly today — do not "tidy" it into `make-graph-store`.

---

## 5. What happens on the first open after the switch

Your existing graph has chunk vertices whose embeddings were written before any of this existed, so the segment may be empty or partial. On the first open as `:segment`, `hydrate` fills it.

The migration:

- **Is batched.** Default 5000 chunks per progress report.
- **Is resumable, by construction.** The segment records which chunk ids it already holds; a re-run skips those. There is deliberately no progress file or "migrated" flag — a marker that can disagree with the segment is worse than no marker, because it can claim work that was rolled back. If the migration is interrupted, just open again.
- **Normalises legacy embeddings first.** If any stored embedding is not already a normalised `(simple-array single-float (*))` — e.g. an old `double-float` vector — it is rewritten in place first, honouring `cl-llm.rag.vivace:*embedding-migration-policy*` (`:migrate` by default; `:error` refuses to open). This matters: the segment silently ignores non-conforming vectors, so without this step those chunks would be missing from search results with no error at all.
- **Logs progress** to `*error-output*`. A migration over a large corpus takes minutes and a silent one looks hung.

**Expect the first open to be slow, once.** Subsequent opens do a skip-scan (cheap per chunk, but it does walk the corpus — see §8).

**Rough sizing:** the vector block is `chunks × dimension × 4` bytes. At your 1024 dimensions that is **4 KB per chunk** — 20k chunks ≈ 80 MB, 250k ≈ 1 GB, 1M ≈ 4 GB. On disk, inside the graph directory. We have not measured migration wall-clock on your corpus; run it on a copy first and time it (§9).

---

## 6. Rolling back

Change `:segment` back to `:cache` and restart. That is the whole rollback.

The segment is a derived index, not a source of truth — your chunk vertices are untouched by any of this, and `:cache` rebuilds its in-RAM index from them exactly as it does today. The segment file stays on disk and keeps being maintained; it costs disk space and does no harm.

### Back up by copying the directory, not by snapshot

**Do not rely on `snapshot`/`replay` to back up this knowledge base.** VivaceGraph
[issue #56](https://github.com/kraison/vivace-graph/issues/56): `backup` writes slot values as
Lisp text, and the restore reader coerces every `#(...)` it reads to a byte vector — it has to,
because node ids are byte vectors and it cannot tell an id from slot data. A `single-float`
embedding therefore fails on restore with `The value 1.0 is not of type (UNSIGNED-BYTE 8)`.

It fails loudly rather than restoring corrupted data, so you will not silently lose content —
but a graph full of embeddings cannot currently be restored from a snapshot at all. This is
**not new** and is not caused by the `:segment` change; it applies to your `:cache` deployment
today just as much. It is worth knowing because your knowledge base is almost entirely
embeddings.

Until #56 is fixed: **back up by copying the graph directory** with the graph closed.

The one thing that is *not* reversible is the embedding normalisation in §5, because it rewrites the stored slot. That has been the case for `:cache` and `:scan` since Phase 1, so it is not new — but if you want a true point-in-time rollback, **take a copy of the graph directory before the first `:segment` open.** Do that regardless; it is cheap insurance.

---

## 7. Do results change?

**Ranking: no.** `:segment` returns the same order as `:cache`, including ties. It over-fetches from the engine and re-ranks with cl-llm's own document-id tiebreak, because the engine's internal tiebreak is by node id. There is a test comparing the two strategies over a corpus built with deliberate exact-tie groups.

**Scores: only if you pass an unnormalised query.** The engine computes full cosine (dividing by the query norm); `:cache` computes a bare dot product. On unit-length vectors these are identical, and every embedder you use returns unit-length vectors, so in practice you will see the same numbers. If you ever hand-build a query vector that is not unit length, `:segment` returns the true cosine and `:cache` returns a value scaled by ‖q‖ — same order, different magnitude. `:segment` is the mathematically correct one.

**Deleted chunks:** filtered from `:segment` results, as with the other strategies.

---

## 8. Gotchas specific to your setup

**Every open walks the corpus.** `hydrate` checks whether migration is needed by sweeping chunk vertices, because the engine has no cheap per-type count. This was a deliberate choice — the alternatives risk a store that is silently half-indexed after an interrupted migration — but it means open cost is O(corpus) for `:segment`. In your case you were already paying that: `graph-store-chunks` for BM25 walks the whole corpus anyway.

**Test heap.** If you run cl-llm's own vivace test suite, use `sbcl --dynamic-space-size 4096`. That suite retains ~870 MB and exhausts SBCL's 1 GB default on roughly two runs in three. It is a pre-existing condition of the test suite, not of the library, and it does not affect your application. Tracked as cl-llm#11.

**Dimension is fixed at first write.** The segment takes its dimension from the first vector stored (1024 for you) and rejects anything else. If you ever change embedding models to a different dimensionality, you need a rebuild, not a migration.

**Concurrency.** Searching while a migration runs is safe — readers take a per-segment read lock and see a consistent, if incomplete, snapshot. Do not run two migrations of the same store concurrently; in practice that means don't open the same graph directory from two processes at once, which was already true.

---

## 9. Suggested rollout

1. **Copy the graph directory.** Migration rewrites legacy embeddings in place.
2. On the copy, switch to `:strategy :segment`, open, and **time the first open**. That number is your production migration window.
3. Confirm `store-count` matches, and spot-check that a handful of known queries return the same documents as before. Ranking should be identical; if it isn't, stop and tell us — that would be a bug, not a tuning issue.
4. Watch the migration log line on `*error-output*` so you can tell "working" from "hung".
5. Open a second time and confirm it is fast — that proves the skip path works and the migration is complete.
6. Then do it for real.

---

## 10. Scale, honestly

Measured on a 1024-dimension corpus (SBCL, Apple M3):

| chunks | dense search | notes |
| --- | --- | --- |
| 100k | 192 ms | CPU-bound |
| 250k | 453 ms | CPU-bound |
| 500k | 940 ms | CPU-bound |
| 1M | 11.3 s | **on an 18 GB laptop — I/O-bound, see below** |

The jump at 1M is not a scaling curve, it is a cliff: the vector block is `chunks × 4 KB`, so 1M chunks is 4 GB, and once that exceeds available page cache every query re-reads it from disk. **On odm (192 GB) that cliff sits around 48M chunks and is irrelevant to you.**

What *does* bind on odm is CPU: roughly **1.9 s per query at 1M chunks** even fully resident, because a brute-force scan is a brute-force scan. If your corpus heads toward that scale and you need interactive latency, the answer is an approximate index (ANN/HNSW), not more RAM. The engine already has the extension seam for it (`segment-score-subset` scores a candidate set exactly), so adding one later does not disturb any of this. That work has not been done.

Caveat worth stating: the 1.9 s figure is derived from the CPU-bound regime measured on a laptop, **not measured on odm**. Treat it as an estimate until someone runs it there.

---

## 11. Known issues

| Issue | Impact on you |
| --- | --- |
| [cl-llm#11](https://github.com/kraison/cl-llm/issues/11) | Test suite needs a 4 GB heap. No application impact. |
| [vivace-graph#54](https://github.com/kraison/vivace-graph/issues/54) | Rebuilding a segment while queries run against it is unsafe. Not reachable through normal open/close. |
| [vivace-graph#56](https://github.com/kraison/vivace-graph/issues/56) | `snapshot`/`replay` cannot round-trip embeddings; fails loudly. **Back up by copying the directory.** | **Yes — affects you today, `:cache` included** |
| [vivace-graph#55](https://github.com/kraison/vivace-graph/issues/55) | A segment file that exists but isn't registered at open can be overwritten. Not reachable given your `ensure-chunk-class`-before-open ordering — another reason to leave that alone. |

---

## 12. Questions worth asking us

- Migration wall-clock on a corpus your size — we have not measured it and would rather you didn't guess.
- Whether the BM25 sparse hydration (§3) should also move off the heap. That is a real piece of work, not a flag.
- Whether you want ANN before your corpus grows, rather than after it hurts.
