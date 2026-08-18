# The evidence bundle and its scoring — design (cl-llm #13, unit 1)

**Unit 1 of the retrieval-fusion epic (#13), phase 3 of the spatiotemporal
substrate programme.**

The epic fuses five retrieval modes — vector, sparse, spatial, temporal and
claim traversal — into one ranked evidence bundle. This unit builds the
bundle and the instrument that measures it, fed by the two modes that
already work. It adds no new retrieval mode.

## Why this unit first

The epic's own argument is that the bundle is the artifact and that most of
this layer's correctness is therefore **deterministically checkable**, with
an LLM judge only ever grading the narration. Prior evaluation work here
measured LLM-judge dimensions at roughly 15% run-to-run variance, against
deterministic dimensions trustworthy enough to drive an embedder bake-off.

That argument only pays if the instrument exists before the things it is
meant to measure. Build the planner or the claim expansion first and there
is no way to tell whether either helped. Unit 1 is the instrument, and it is
buildable entirely from what ships today: `rag/hybrid.lisp` already fuses
dense and sparse with reciprocal-rank fusion.

## Scope

**In:** the `evidence` and `bundle` records; a source protocol that produces
evidence; fusion into one ordered bundle; four deterministic scorers; a
capture-and-diff harness with ordering as the contract; a small
generalisation of the eval runner so it can grade something other than a
model reply.

**Out:** spatial, temporal and claim-traversal modes (units 2-3); the
planner (unit 2); narration and the LLM judge (unit 4); scoring against the
real corpus in the offline suite.

## Where it lives, and the dependency that follows

`cl-llm/rag` must stay free of any graph dependency; only the vivace-backed
subsystem may depend on the engine. The bundle nonetheless carries temporal
extents and standings.

Those are not graph concepts. They now live in
[cl-temporal-extent](https://github.com/kraison/cl-temporal-extent),
extracted for exactly this reason (vivace-graph#159), and depend on
`local-time` alone. **`cl-llm/rag` therefore gains a dependency on
`cl-temporal-extent` and on nothing else.** The bundle holds real extent
structs and real standings, and the graph-free configuration is a fully
supported one rather than a degraded one.

The scorers cannot live in `cl-llm/eval` without teaching it about
retrieval, nor in `cl-llm/rag` without teaching it about evaluation. They go
in a new system, **`cl-llm/rag/eval`**, depending on both. Neither existing
system widens.

## The records

Both are new and sit **beside** `hit`, which is documented public API
(`store-search` returns `rag:hit`; the examples use `hit-chunk` and
`hit-score`). Nothing existing changes.

```lisp
(defstruct evidence
  chunk        ; the retrieved CHUNK
  score        ; fused rank score
  method       ; :DENSE :SPARSE :SPATIAL :TEMPORAL :CLAIM
  source       ; source identity, or NIL
  confidence   ; number, or NIL
  precision    ; spatial precision, or NIL
  extent       ; a TEMPORAL-EXTENT:TEMPORAL-EXTENT, or NIL
  standing)    ; a standing keyword -- NEVER NIL

(defstruct bundle
  query        ; the query string
  evidence     ; ordered list of EVIDENCE -- ORDER IS THE CONTRACT
  modes)       ; list of the methods that actually contributed
```

`method` is the only one of the six provenance fields fully known in unit 1.
`extent` is a real struct rather than a re-encoding, which is what the
library extraction bought.

## Absence carries a reason

`standing` is never `NIL`. In unit 1 dense and sparse evidence is
`:indeterminate` — **we have not looked for claims**. When unit 3 looks and
finds none, that becomes `:searched-empty`.

The distinction is the point. "Nobody looked" and "we looked and found
nothing" are different facts, and a bundle full of `NIL` cannot tell a
reader which it is. This is the same discipline the standing vocabulary
exists for elsewhere in the programme, now available graph-free.

`extent`, `source`, `confidence` and `precision` may be `NIL` in unit 1;
`standing` says why.

## Producing a bundle

One generic, mirroring how `retriever` and `store` are already shaped:

```lisp
(defgeneric collect-evidence (source query &key k bounds)
  (:documentation "Return a list of EVIDENCE for QUERY."))
```

Unit 1 ships two methods — `dense-source` (embedder + store) and
`sparse-source` — and a `fuse` function that merges their output with the
existing `reciprocal-rank-fusion` and returns a `bundle`.

`bounds` is **accepted and ignored** in unit 1. It is the one piece of
forward shape built now, because unit 2's planner supplies it and adding a
parameter to a generic later means touching every method that exists by
then. Nothing else speculative is built: there is no `plan` stage and no
`expand` stage, because their signatures are exactly what units 2 and 3 are
for, and designing them with nothing to check against is how they come out
wrong.

Unit 3's claim expansion becomes a third `collect-evidence` method.

## Measuring it

`cl-llm/eval`'s `run-cell` currently calls `llm:ask` directly: a variant
builds a prompt, the model answers, scorers grade the reply. There is no
path for "run retrieval, grade the bundle."

**The generalisation:** `variant` gains an optional `run-fn`. When present,
`run-cell` calls it with the case and uses its value as the response;
otherwise the existing `ask` path runs unchanged. Additive, and it makes the
harness usable for any gradeable artifact rather than only for model calls.

Four deterministic scorers, in `cl-llm/rag/eval`:

| scorer | what it catches |
|---|---|
| `bundle-recall-at-k` | the known-relevant evidence failed to surface in the top k |
| `bundle-containment` | an evidence item that traces to no real chunk — a fabricated citation, caught rather than discouraged |
| `bundle-standing-well-formed` | a standing outside the vocabulary, or `NIL` — the absence discipline enforced mechanically instead of by review |
| `bundle-method-attributed` | an item that does not name the mode that produced it |

The first two are the dimensions the epic names as trustworthy enough to
have driven real decisions.

## Capture-and-diff, and the trap in it

**A raw bundle is not stable.** Scores are floats, embeddings drift, and
comparing bundles directly would produce a harness that fails for reasons
nobody cares about.

The golden file therefore stores a **projection**: `(document-id method
standing rank)` per item, in order. No scores, no text, no embeddings.
Ordering is the contract — a reordering is a real regression and must fail.

**Regeneration is explicit and never automatic.** A golden file that
rewrites itself when it does not match proves nothing, and it is the obvious
convenience for someone to add later. The spec names it here so that adding
it is a visible decision rather than a tidy-up.

Fixtures are small and hand-built, with known-relevant answers, in
`cl-llm/rag`'s offline suite: fast and hermetic. Scoring against the real
corpus is a separate opt-in suite following the existing `cl-llm/live`
pattern — two harnesses, each honest about what it proves.

## Files

| file | change |
|---|---|
| `rag/bundle.lisp` | new — the records, `collect-evidence`, the two sources, `fuse` |
| `rag/packages.lisp` | export the new names |
| `cl-llm.asd` | `bundle` component; `cl-temporal-extent` on `cl-llm/rag`; new `cl-llm/rag/eval` system and its test system |
| `eval/suite.lisp` | `run-fn` slot on `variant` |
| `eval/run.lisp` | `run-cell` uses `run-fn` when present |
| `rag-eval/` | new — the four scorers and the golden-file harness |
| `tests-rag/bundle.lisp` | new — the records and fusion |
| `tests-rag-eval/` | new — the scorers and capture-and-diff |

## Testing

Each item is a property that must fail for a stated reason. A test whose
whole value is that it would go red must be **shown** to go red.

1. A bundle from dense and sparse carries every item's `method`, and `modes`
   names both.
2. Every item's `standing` is a vocabulary member; none is `NIL`. Ablate by
   returning `NIL` for one item and confirm `bundle-standing-well-formed`
   goes red — this scorer exists to make the discipline mechanical, so a
   version of it that passes on `NIL` is worse than none.
3. Fusion order is deterministic across runs on identical input.
4. `bundle-recall-at-k` distinguishes a bundle that surfaced the known
   answer from one that did not. Ablate by removing the relevant chunk.
5. `bundle-containment` catches an evidence item whose chunk is not in the
   corpus. Construct one directly; it cannot arise from the sources.
6. The golden-file harness fails on a **reordering**, not merely on a
   changed membership — ordering is the contract, and a comparison that
   sorts before diffing would silently pass.
7. Regeneration does not happen implicitly: a mismatch fails and leaves the
   golden file untouched.
8. A variant with no `run-fn` still runs through `llm:ask` exactly as
   before — the eval generalisation must not change existing behaviour.
9. `cl-llm/rag` compiles with no graph system present. This is the seam, and
   it is mechanically checkable because the system definition does not
   depend on `graph-db`.

## Acceptance criteria

- One ordered bundle from the two working modes, every item carrying its
  method and a non-`NIL` standing.
- The four scorers run under the existing eval harness through a variant's
  `run-fn`, with no change to how model-based variants behave.
- Capture-and-diff fails on a reordering and does not self-heal.
- `cl-llm/rag` depends on `cl-temporal-extent` and on no graph system.
- Offline suites stay hermetic; real-corpus scoring is opt-in and separate.

## What this deliberately does not do

- **No new retrieval mode.** Spatial, temporal and claim traversal are units
  2-3. Unit 1 would be dishonest to claim a five-mode fusion.
- **No planner.** `bounds` is threaded and ignored.
- **No narration, no judge.** Unit 4.
- **No scores in golden files.** Floats are not a regression contract.
- **No enrichment of `hit`.** The bundle is a distinct artifact; decorating
  `hit` would bake in "the bundle is dense output with extra fields", which
  is precisely what unit 3 has to undo when expansion starts producing
  evidence that was never a dense hit.
