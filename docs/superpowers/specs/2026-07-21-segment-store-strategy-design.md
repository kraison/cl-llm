# The `:segment` store strategy (Phase 2, Step 5) — design

Date: 2026-07-21
Status: approved design, not yet planned
Repos: `cl-llm` (this work) and `vivace-graph-v3` (one small engine addition, branch `experiment`)
Follows: Phase 2 Steps 1–4 in `vivace-graph-v3`, which built the mmap vector segment and its
query layer (`docs/superpowers/specs/2026-07-21-vector-segment-query-design.md` there).

## 1. Summary

A third RAG store strategy, `:segment`, that keeps chunk embeddings in VivaceGraph's
mmap-backed vector segment and answers `store-search` through `gdb:vector-search` — so
dense retrieval never materialises a node it is not going to return, and embedding queries
compose with ordinary graph queries against the same store.

This is the step that connects the engine work to the RAG path. Everything below it is
built, merged and pushed on `experiment`; nothing in cl-llm uses it yet.

## 2. What the engine already provides

Exported from `graph-db` (as of `ff8e3f1`): `vector-search`, `segment-scan`,
`segment-score-subset`. Declaring a slot `:vector-index t` makes the transaction apply path
maintain a segment for it automatically; one segment per **declaring (owner) class**, keyed
`(owner-name . slot-name)`, spanning subclasses (Model B).

Measured (dim 1024, SBCL, macOS arm64): ~1.85 ms per 1k vectors while the block stays in
page cache. Full cosine, ranked score DESC then node-id ASC, deterministic across rebuilds,
and safe under concurrent writes (a per-segment rw-lock, proven at every entry point).

**Known scaling shape** (engine spec §13/§13.1): cost is linear while the block
(`live × dim × 4` bytes) fits available page cache and falls off a cliff past it. The
deployment host `odm` has 192 GB, putting that cliff near ~48M vectors — irrelevant here.
The binding constraint on odm is CPU: ~1.9 s per query at 1M vectors even fully resident.
**That is the number this step should surface, and it is why ANN is the eventual answer at
1M+, not a bigger machine.**

## 3. Where `:segment` sits among the strategies

All three stay. They are not a progression; they are different trades.

| strategy | search cost | holds corpus in Lisp heap | notes |
| --- | --- | --- | --- |
| `:cache` | ~15 ms @ 20k | **yes** | Fastest. Right for corpora that fit in the heap. |
| `:segment` | ~35 ms @ 20k | no | Pageable, composes with graph queries. **New default for persistent graphs.** |
| `:scan` | ~2.3 s @ 20k | no | No index. Fallback and correctness reference. |

`:cache` is deliberately **not** demoted or removed: it is the fastest option and remains
supported. `:segment`'s advantage over it is not latency — it is that the corpus does not
have to live in the Lisp heap, and that the embeddings are queryable alongside the rest of
the graph. `:segment` becomes the default in `make-graph-store` / `open-graph-store`;
callers who passed `:strategy` explicitly are unaffected.

## 4. Schema change

`ensure-chunk-class` (vivace/schema.lisp) gains `:vector-index t` on the `EMBEDDING` slot.

This is the whole mechanism: with the slot declared, every `store-add` maintains the
segment through the ordinary transaction apply path. No parallel write path, no hook, no
cache invalidation — the same property that makes `:unique` and `:index` work.

**Backward compatibility is a hard requirement.** Adding the declaration must not prevent
an existing graph from opening, and an existing graph's chunks predate any segment. That is
what §5 handles. A graph opened by an older cl-llm (without the declaration) keeps working;
the slot option is additive.

## 5. Migration: batched and resumable

An existing store has chunk vertices and no segment. `open-graph-store` detects this
(chunks present, segment absent or short) and migrates.

**Resumability is nearly free and must be exploited rather than bolted on.** The segment
already records which node ids it holds, so the migration is: sweep chunk vertices, skip any
id already in the segment, insert the rest, committing every N. An interrupted run re-runs
and skips everything it already did. No progress file, no checkpoint record, no way for the
marker to disagree with reality.

This needs **one small engine addition** on `experiment`, because it must reach segment
internals that cl-llm should not: a batched, skip-what-exists rebuild entry point alongside
`rebuild-vector-segment`. Reasons it belongs in the engine: it touches `segment-get` /
`segment-put`; it must respect the same locking discipline as the apply path; and the
existing one-shot `rebuild-vector-segment` is the natural place for its sibling. cl-llm
calls it and supplies the batch size.

Rationale for batching at all: Phase 1 measured `gdb:copy` duplicating a whole vertex at
~40 KB/chunk, which put a 1M-chunk single-transaction migration at ~38 GB and ~19 minutes,
unrecoverable on failure. That lesson applies unchanged here.

Sizing must be honest: a 1M-chunk corpus pays a one-time multi-minute migration on first
open after upgrade. It is progress-logged, and it is resumable, but it is not free and the
docstring should say so plainly.

## 6. `store-search` and the ranking contract

```lisp
(defmethod rag:store-search ((store segment-graph-store) query-vector k)
  ;; 1. dimension check, matching scan-graph-store's error
  ;; 2. (gdb:vector-search graph type 'embedding query-vector fetch-k) -> ((score . node-id) ...)
  ;; 3. resolve the surviving node-ids to vertices -- ONLY the survivors
  ;; 4. re-rank by cl-llm's total order, truncate to k
  )
```

**Over-fetch and re-rank (decided).** The engine breaks tied scores by node-id ascending;
cl-llm breaks them by document-id. To make `:segment` return *identically ranked* results to
`:cache` — including ties — this asks the engine for more than `k`, applies cl-llm's
document-id tiebreak, and truncates. The over-fetch factor is a named constant, not a magic
number, and its choice is documented: ties in real float embeddings are rare, but exact
strategy interchangeability is the property being bought, and a fetch of `k` alone cannot
deliver it because the engine may have already truncated a tied group at the `k` boundary
using the wrong key.

**Full cosine vs bare dot.** The engine computes full cosine `dot/(|q|·|v|)`; cl-llm's
`rag:cosine` is a bare dot. These are *equal on unit-normalised vectors*, which is all
cl-llm ever stores (`validate-chunks` normalises write-side, and Phase 1's migration
normalised what was already there). Equality on the data that actually flows is a claim to
**test**, not to assert: a ranking-agreement test between `:segment` and `:cache` over the
same corpus is the load-bearing check of this step.

**No node materialisation for non-survivors.** The point of the whole phase. Step 1 measured
node loading at ~92% of `store-search` cost; `vector-search` returns `(score . node-id)`, and
only the ids that survive top-k are turned into vertices and then chunks.

## 7. Retiring the read-side coercion

`vertex->chunk` calls `rag:as-embedding` on every read. Since `validate-chunks` normalises
in place before `chunk->vertex` ever sees an embedding, write-side enforcement has replaced
what this read-side coercion guarded, and it now only re-normalises already-conforming
values — costing an allocation, a sqrt, N divisions and ~1 ULP of drift per chunk read.

Retire it. `CHUNK-VERTEX-COERCES-GENERAL-VECTOR-EMBEDDING` (tests-vivace/schema.lisp) exists
specifically to exercise the coercion; **repurpose it** to assert the write-side enforcement
that replaced it — that a non-conforming embedding cannot reach a vertex through `store-add`
— rather than deleting it and losing the only coverage of non-conforming input.
`CHUNK-VERTEX-ROUND-TRIPS-WITH-COERCED-EMBEDDING` documents the drift and should be revisited
in the same change.

## 8. Testing

Mechanical: strategy selection and defaulting; dimension-mismatch error parity with
`scan-graph-store`; `store-count` / `store-delete-documents` on the new store; empty store;
`k` larger than the corpus; a store opened, closed and reopened.

The three that carry the step:

- **Ranking agreement `:segment` vs `:cache`** over the same corpus and queries — identical
  ordering including ties. This is what proves full-cosine-vs-bare-dot equivalence on real
  data and that the over-fetch re-rank works.
- **Migration correctness and resumability** — a store built under the old schema, opened
  under the new one, must return the same results as one built natively; and a migration
  interrupted partway must complete correctly on re-open, with no duplicated or missing
  chunks.
- **No node materialisation for non-survivors** — the performance premise, asserted
  structurally rather than by timing (e.g. count vertex loads during a search, or assert the
  search touches no more nodes than it returns). A latency assertion would be flaky; a
  counting assertion is not.

**Standing discipline (twelve vacuous or non-discriminating assertions have been caught
across this project, two of them in spec/fixture text rather than implementer code):** every
ranking assertion is guarded so it cannot pass on NIL or an empty result — assert length
first, then guard the ordering loop. For each test, state what mutation it catches. The
ranking-agreement test in particular must not build its expected order by calling the same
function it is testing.

## 9. Scope

- **In:** the `segment-graph-store` class and its `store-*` methods; `:vector-index` on the
  chunk schema; `:segment` as the default strategy; the batched resumable migration (plus its
  one engine entry point); retiring the read-side coercion; the tests above.
- **Out:** ANN/HNSW (the eventual answer at 1M+, and `segment-score-subset` is already the
  seam for it); int8 quantization (wrong lever at 192 GB — see engine spec §13.1); removing
  or demoting `:cache`; any change to the hybrid/sparse retrieval path; a REST or Prolog
  surface for vector search.
- **SBCL only**, consistent with the engine step.

## 10. Risks

- **The migration is the risk.** It runs on first open after upgrade, against real data, and
  a corpus large enough to matter is large enough for the operator to think it has hung.
  Mitigations: resumability by construction (§5), progress logging, and an honest docstring.
- **Ranking divergence from `:cache`** would be a silent correctness regression — a user
  swapping strategies gets different answers. The agreement test is the gate; it must compare
  against independently computed expectations, not against the implementation.
- **Default change.** `:segment` becoming the default alters behaviour for callers who never
  passed `:strategy`. It is the right default, but it should be called out in the changelog
  rather than discovered.
- **The 1M latency reality.** At odm's scale `:segment` is ~1.9 s/query at 1M vectors,
  CPU-bound. That is a correct implementation meeting an algorithmic limit, not a defect, and
  the step should report it rather than let it surprise someone later.
