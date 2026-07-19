# Dense-Preserving (Backfill) Fusion for `hybrid-retriever` — Design

**Date:** 2026-07-19
**Status:** Approved (design). Branch of record (cl-llm): `feat/hybrid-retrieval`.
**Consumer:** mine-action's knowledge substrate.
**Supersedes (for this consumer):** the RRF fusion path chosen in
[`2026-07-19-hybrid-retrieval-design.md`](2026-07-19-hybrid-retrieval-design.md), which a live
recall measurement showed regresses at the deployed operating point (see §1).

---

## 1. Purpose & motivation

The hybrid retriever (RRF fusion of dense cosine + sparse BM25) was built and, on the dev hub,
re-measured against the vetted 24-case gold set. The result was a **tradeoff, not a clean win**:

| retriever | recall@5 | recall@8 | recall@20 |
|---|---|---|---|
| dense (baseline) | 0.875 | **0.917** | 0.917 |
| hybrid (RRF) | 0.750 | **0.875** | **0.958** |

RRF raised the recall **ceiling** 0.917 → 0.958 — it recovered the Cooper/PFAS-Explosives
textbook that dense **never** surfaces at any k (`"What is det-cord"`: dense rank NIL → RRF #2).
But at the **deployed operating point `*kb-default-k*` = 8**, RRF recall (0.875) fell **below** the
dense baseline (0.917) **and below the KB eval gate's 0.9 recall floor**. RRF's rank fusion demoted
gold documents that dense had ranked well out of the shallow top-8 — `PFM-1S self-destruct` #3→#12,
`shaped charge` #6→#9 — because common designations (many `PFM-1` documents) flood the sparse side
and pull unrelated chunks up the fused ranking.

This is **structural, not a tuning artifact**: a live sweep of `*rrf-k*` ∈ {60, 120, 240, 480}
changed recall@8 by nothing, and raising `candidate-k` to 40 made it *worse* (0.833).

The lexical signal is genuinely valuable — it recalls documents dense cannot — but full rank
fusion pays for that recall by reshuffling documents dense already ranked well. The fix is a fusion
that **only adds** what dense missed, and **never reorders** what dense found: **dense-preserving
(backfill) fusion**.

## 2. Decisions (from the design discussion)

| Decision | Choice |
|---|---|
| **Strategy** | **Dense-preserving backfill** — keep dense's ranking; reserve a small number of tail slots for documents dense never surfaced, filled from sparse. |
| **What qualifies as a recovery** | **Dense-missed, sparse-ranked**: a document qualifies only if it is **absent from dense's entire candidate list** (dense never surfaced it, not merely ranked it below k) **and** appears in sparse's candidates. The tightest "sparse only *adds* recall dense couldn't" rule. |
| **API surface** | A **`fusion` slot on the existing `hybrid-retriever`** (`:rrf` \| `:backfill`) + a standalone `dense-preserving-fusion` function beside `reciprocal-rank-fusion`. **Default `:rrf`** (backward-compatible; the RRF code + tests stay intact). mine-action opts into `:backfill`. |
| **Reserved slots** | `*backfill-max*` defparameter, **default 2**, tunable. Backfill is **opportunistic**: a tail slot is displaced only when a qualifying recovery exists, so queries needing no help keep dense's top-k untouched. |

## 3. Architecture

### 3.1 `dense-preserving-fusion` (`cl-llm.rag`, new — `rag/hybrid.lisp`)

```lisp
(dense-preserving-fusion dense-hits sparse-hits k &key (max-backfill *backfill-max*)) → hits
```

- **`dense-hits`** is dense's full candidate list (the `candidate-k`-deep `store-search` result),
  in cosine order. **`sparse-hits`** is the `sparse-search` result, in BM25 order. **`k`** is the
  number of hits to return.
- **Dense-document set:** every `document-id` appearing in **any** `dense-hits` chunk. A document is
  *dense-missed* iff none of its chunks appear anywhere in `dense-hits` (membership keyed on
  `chunk-document-id`, so a document dense buried at rank 15 is **not** missed — consistent with the
  "dense never surfaced it" rule; that document would already appear if k reached its rank).
- **Recoveries:** `sparse-hits` whose `document-id` is dense-missed, walked in **sparse rank order**,
  **deduped by `document-id`** (each recovered document contributes its top sparse chunk once),
  capped at `max-backfill`.
- **Assembly:** `n = min(max-backfill, |recoveries|, k)`. The result is **dense's first `(k − n)`
  hits, in dense order**, followed by the `n` recoveries. **When `n = 0`, the result is exactly
  dense's top-k, byte-for-byte unchanged** — the no-regression guarantee for queries that need no
  help. When dense has fewer than `(k − n)` hits, its hits are used as-is and the recoveries appended.
- **Scores:** each returned hit is rebuilt carrying its **representative chunk** (a dense hit keeps
  its dense chunk and full metadata; a recovery carries its sparse chunk) and a **synthetic
  descending score monotonic with final position**, so any downstream sort-by-`hit-score`
  reproduces the intended order — the same ordering property `reciprocal-rank-fusion`'s output has.
  (Dense cosine and sparse BM25 live on incomparable scales, so native scores must **not** be mixed
  into one ranked list.)

### 3.2 `hybrid-retriever` fusion slot (`cl-llm.rag`, modify)

- Add a slot **`fusion`** (`:initarg :fusion`, `:reader hybrid-fusion`, **`:initform :rrf`**).
  `make-hybrid-retriever` gains a `fusion` keyword defaulting to `:rrf`.
- `retrieve` fetches dense + sparse candidates exactly as today
  (`kc = max(k, candidate-k)`), then **`ecase`-dispatches on `(hybrid-fusion r)`**:
  - `:rrf` → the existing path: `(subseq (reciprocal-rank-fusion (list dense sparse)) 0 (min k …))`.
  - `:backfill` → `(dense-preserving-fusion dense sparse k :max-backfill *backfill-max*)`
    (the fusion itself returns ≤ k hits — it needs `k` to size the reserved slots).
- Exports (`rag/packages.lisp`): `#:dense-preserving-fusion #:*backfill-max*`. (`hybrid-fusion` is
  internal; the slot is set via the `:fusion` initarg.)

### 3.3 mine-action integration

`knowledge-index` (in `src/knowledge-answer.lisp`) passes `:fusion :backfill` when it builds the
hybrid retriever:

```lisp
(cl-llm.rag:make-hybrid-retriever :embedder embedder :dense-store store
                                  :sparse-store sparse :fusion :backfill)
```

Nothing else changes. `*kb-default-k*` **stays 8** — backfill makes hybrid@8 a net improvement over
dense@8, so the operating point chosen in the hybrid-retrieval plan is now correct. The sparse-store
lifecycle, delete fan-out, and open-time hydrate are unchanged.

## 4. Testing

Deterministic, offline (no model, no graph) unit tests in the cl-llm rag suite
(`tests-rag/hybrid.lisp`), following TDD:

- **Recovery + preservation:** dense = [a b c], sparse = [x …] with `x` dense-missed, `k = 3`,
  `max-backfill = 2` → result `[a b x]`: `x` (the recall win) is present **and** dense's top docs
  `a`, `b` keep their order and positions; dense's tail `c` is the only thing displaced.
- **No-regression guard:** dense = [a b c], sparse = [a b] (no dense-missed doc) → result is
  **exactly [a b c]**, unchanged. This is the property RRF failed.
- **Dedup by document:** two sparse hits that are different chunks of the **same** dense-missed
  document consume **one** slot, not two.
- **Cap respected:** more qualifying recoveries than `max-backfill` → only `max-backfill` enter, in
  sparse rank order; `k` is never exceeded.
- **`hybrid-retriever` end-to-end (`:backfill`):** a `:backfill` retriever over a mock embedder +
  tiny corpus surfaces the dense-missed exact-designation document while leaving the dense-ranked
  documents in place — mirroring the existing `:rrf` end-to-end test, which stays green (default
  is still `:rrf`).

### mine-action acceptance (the real proof — dev hub, live)

Re-measure recall over the vetted 24-case gold set with `knowledge-index` now `:backfill`:
- **recall@8 ≥ dense's 0.917**, with the Cooper/det-cord document recovered (target ≈ **0.958**);
- **no per-case regression vs dense at k=8** — every gold document dense ranked ≤ 8 is still within
  the backfill top-8.
- The SpotlightAI gold document (its `gold_source` is a truncated title `"…(compressed"`) remains a
  **separate, pre-existing gap** — it does not surface in sparse either, is orthogonal to fusion,
  and is explicitly **out of scope** here.

**Caveat — "no per-case regression" is structural only for `n = 0`.** When no document qualifies
(`n = 0`) the result is *provably* dense's top-k unchanged. When a recovery exists (`n ≥ 1`), the
last `n` dense slots are displaced to make room; if a *gold* document sat in that displaced dense
tail while a *different* dense-missed gold document is recovered, that specific gold doc regresses
out of top-k even though aggregate recall is unchanged or higher. On the current 24-case gold set
this never happens (measured: zero per-case regression at k=5 and k=8), but that is an **empirical**
property of this gold set, not an invariant. **Re-measure recall@k whenever the gold set changes**,
and do not treat "no per-case regression" as a structural promise for `n ≥ 1`.

**Measurement note.** Backfill is **k-dependent** — the reserved recovery slots sit at the *tail of
the requested k*, so `retrieve @k` is **not** the first k of `retrieve @k'` (k' > k). Recall@k must
be measured by retrieving **separately at each k**, never by slicing a single deeper retrieval by
rank (doing so understates backfill's recall at small k).

## 5. Non-goals (YAGNI)

- **No removal of RRF** — it stays as the default `:rrf` fusion and a general-purpose option; this
  design adds `:backfill` beside it.
- **No score-threshold or "outside dense top-k" recovery rules** — the tight "dense never surfaced
  it" (absent from the full dense candidate list) rule was chosen deliberately over looser
  alternatives.
- **No fix for the SpotlightAI title-match gap** — separate concern (see §4).
- **No change to `*kb-default-k*`, the sparse-store lifecycle, the delete fan-out, or the open-time
  hydrate** — all unchanged from the hybrid-retrieval work.
- **No weighted/learned fusion, cross-encoder re-rank, or query expansion** — out of scope, as in
  the hybrid-retrieval design.

## 6. Process / deployment

- Develop in `/Users/kraison/work/cl-llm` on `feat/hybrid-retrieval`; FiveAM offline tests
  (`asdf:test-system "cl-llm/rag/tests"`).
- mine-action change is the one `:fusion :backfill` keyword; needs a dev-hub server restart (clean
  SIGTERM + relaunch `tools/run-server.sh`, no `--rebuild` — the sparse index rebuilds at open).
- Acceptance = the re-measured recall@8 improves to ≥ 0.917 with det-cord recovered and no per-case
  k=8 regression.
- Nothing is merged or pushed without Kevin's explicit approval.

## Related documents

- [`2026-07-19-hybrid-retrieval-design.md`](2026-07-19-hybrid-retrieval-design.md) — the hybrid
  retriever + RRF this extends; §1 here records why its RRF path underperforms at the operating point.
- mine-action `docs/superpowers/specs/2026-07-19-kb-eval-maturation-design.md` — the eval whose
  deterministic recall metric measures both.
