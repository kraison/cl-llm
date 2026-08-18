# The evidence bundle and its scoring

**Date:** 2026-08-18
**Status:** Shipped — cl-llm#13, unit 1 of the retrieval-fusion epic
**Relationship:** Design:
`docs/superpowers/specs/2026-08-18-evidence-bundle-design.md`. Builds on
the reciprocal-rank fusion already shipped in `rag/hybrid.lisp` (`##
Retrieval (RAG)` in the README). Extracted enough of the standing/extent
vocabulary to `cl-temporal-extent` that this system can use it without
depending on vivace-graph.

## 1. What a bundle is, and why not prose

The epic (#13) fuses five retrieval modes — vector, sparse, spatial,
temporal, and claim traversal — into one ranked answer. Two shapes could
carry that: a narrated paragraph an LLM judge grades, or a structured list
a program can check. Judge-based grading is real but noisy — prior
evaluation work on this programme measured LLM-judge dimensions at
roughly 15% run-to-run variance. A structured artifact lets the
dimensions that do not need judgment — did the known-relevant document
surface, does every item trace to a real chunk, does every item carry a
reason for its evidentiary status — be checked deterministically instead,
which is what makes an embedder or fusion-strategy bake-off trustworthy.

A **bundle** is that structure: one query and its ranked evidence, in the
order retrieval produced it. It is the artifact the rest of the epic
measures against; narration (unit 4) is built *from* a bundle, not the
other way round.

## 2. The `evidence` record

Defined in `rag/bundle.lisp`, alongside `hit` (which stays exactly as it
is — `store-search` still returns `rag:hit`, and nothing existing
changes):

```lisp
(defstruct evidence
  (chunk nil)                 ; the retrieved CHUNK
  (score 0.0d0)                ; fused rank score
  (method nil)                 ; :DENSE :SPARSE :SPATIAL :TEMPORAL :CLAIM
  (source nil)                 ; source identity, or NIL
  (confidence nil)             ; number, or NIL
  (precision nil)              ; spatial precision, or NIL
  (extent nil)                 ; a TEMPORAL-EXTENT:TEMPORAL-EXTENT, or NIL
  (standing :indeterminate))   ; a standing keyword -- NEVER NIL
```

`method` is the only one of the six provenance fields fully known in unit
1 — dense and sparse are the only sources that exist yet. `source`,
`confidence` and `precision` are `NIL` until the modes that populate them
land. `extent` holds the library's own `temporal-extent:temporal-extent`
struct rather than a re-encoding of it — a real struct, not a shadow copy,
which is what extracting the vocabulary into `cl-temporal-extent` bought
(§7).

**`method` names the first source that offered a chunk, not every source
that found it.** `fuse` (§4) fills its lookup with `(unless (gethash key
by-key) …)` across each source's evidence in the order the caller listed
them, so a chunk both `dense-source` and `sparse-source` return is
attributed to whichever of the two the caller put first — `method` reads
`:dense` even though `:sparse` also matched. This is a known limitation
(§8), not a bug fixed by reordering `sources`; changing which source
"wins" a shared chunk is a design question a later unit owns.

**`standing` is never `NIL`.** The slot defaults to `:indeterminate`, so a
caller who builds an `evidence` without naming a standing gets a value
that still says something, rather than an absence that says nothing. The
struct itself does not *refuse* an explicit `:standing nil` — that is a
different layer's job, on purpose: `bundle-standing-well-formed` (§5) is
what makes the rule mechanical, so a scorer that quietly passed on `NIL`
would be worse than no scorer at all. `NIL` is a construction mistake
this system is built to catch, not one it makes impossible to make.

`bundle` sits beside `evidence`:

```lisp
(defstruct bundle
  (query "")
  (evidence nil)   ; ordered list of EVIDENCE -- ORDER IS THE CONTRACT
  (modes nil))     ; the methods that actually contributed
```

`evidence`'s order is the bundle's contract — see §6 for what enforces
that in practice, which is narrower than it sounds.

## 3. Absence carries a reason

`standing` distinguishes two facts that a `NIL` cannot tell apart:

- **`:indeterminate`** — nobody has looked. No claim-graph traversal has
  been consulted for this piece of evidence.
- **`:searched-empty`** — somebody looked, and found nothing. This is a
  later unit's outcome (claim expansion, unit 3), not this one's.

**Unit 1 produces only `:indeterminate`.** Both `dense-source` and
`sparse-source` mark every item they emit `:indeterminate`, because
neither one is a claim search — there is no claim-graph query happening
at all yet, so "found nothing" is not a fact unit 1 is in a position to
report. Do not read `:indeterminate` in a unit-1 bundle as "no claims
exist"; it means "no claim was consulted," full stop. When unit 3 adds
claim traversal as a third `collect-evidence` method, an item it produces
that finds nothing becomes `:searched-empty`, and only then does that
distinction become live in a running bundle.

The full standing vocabulary (`cl-temporal-extent`'s `+standings+`) is
`:observed :inferred :asserted :searched-empty :determined-empty
:uncovered :indeterminate`; `bundle-standing-well-formed` (§5) checks
membership in exactly this list.

## 4. `collect-evidence` — the extension seam

```lisp
(defgeneric collect-evidence (source query &key k bounds)
  (:documentation "Return a list of EVIDENCE for QUERY, best first."))
```

One generic, mirroring how `retriever` and `store` are already shaped.
Unit 1 ships two methods:

- **`dense-source`** (`embedder` + `store`) — embeds `query` and calls
  `store-search`; each hit becomes `evidence` with `:method :dense`.
- **`sparse-source`** (`store`) — calls `sparse-search`; each hit becomes
  `evidence` with `:method :sparse`.

Both wrap a `hit` via `%hit->evidence`, which is also where the
`:indeterminate` standing described in §3 is set. Both methods declare
`bounds` and ignore it — literally `(declare (ignore bounds))` in each
`defmethod`.

**`bounds` is accepted now and used later.** It is the one piece of
forward shape built ahead of need: unit 2's planner is what supplies it,
and adding a keyword parameter to a generic *after* methods already exist
means touching every one of them. Nothing else speculative is built —
there is no `plan` stage and no `expand` stage in unit 1, because their
signatures are exactly what units 2 and 3 exist to work out, and
designing them now, with nothing to check them against, is how a
signature comes out wrong. Unit 3's claim expansion becomes a third
`collect-evidence` method on this same generic.

`fuse` is what turns several sources into one bundle:

```lisp
(fuse sources query &key (k 5))   ; => a BUNDLE
```

It runs `collect-evidence` on each source, converts each source's
evidence list to `hit`s, and re-fuses them with the existing
`reciprocal-rank-fusion` (`rag/hybrid.lisp`) — so the sources' native
scores, which are on incomparable scales, never have to be compared
directly. The fused `hit` order then drives a lookup back to the
`evidence` that produced each chunk. That lookup is keyed by
`%chunk-key` (`(document-id . text)`), the same identity
`reciprocal-rank-fusion` itself uses — **not** by `document-id` alone,
which would collapse a document's separate chunks into copies of
whichever evidence was seen first (fixed during implementation; see
`rag/bundle.lisp`'s `fuse`). `bundle-modes` is the set of methods whose
source lists were non-empty.

**`fuse` truncates its result to `:k`.** Each source is asked for `:k`
candidates, so the deduplicated union can hold up to (num-sources * k)
items before truncation; `fuse` cuts it down to `:k`, matching `retrieve`
(`rag/hybrid.lisp`, which does `(subseq fused 0 (min k …))`) — the same
keyword otherwise meant two different things depending which function a
caller read (cl-llm#13, I3). Sources still receive `:k` as their own
candidate depth, unchanged.

## 5. The four scorers

`cl-llm/rag/eval` (new system, depending on both `cl-llm/rag` and
`cl-llm/eval`, so neither of those widens to know about the other) adds
four `eval:defscorer`s, each of signature `(case bundle)`:

| scorer | what it catches |
|---|---|
| `bundle-recall-at-k` | the known-relevant document failed to surface anywhere in the bundle |
| `bundle-containment` | an evidence item that traces to no real chunk (no chunk, or a chunk with no document id) — a fabricated citation, caught rather than merely discouraged |
| `bundle-standing-well-formed` | a standing outside the vocabulary, or `NIL` — the absence discipline of §2–3, enforced mechanically instead of by review |
| `bundle-method-attributed` | an item that does not name the mode that produced it |

`bundle-recall-at-k` and `bundle-containment` are the two dimensions the
epic names as trustworthy enough to have driven real decisions (e.g. an
embedder bake-off) without a judge.

**`bundle-recall-at-k` signals rather than scoring 1.0 on an unpopulated
case.** A case built with no `:expected` document ids has nothing to
recall — `every` over an empty expectation list is vacuously true, which
would make an eval-harness bug (nobody filled in the fixture) look like a
perfect score. `bundle-recall-at-k` therefore signals
`eval:llm-eval-error` when `case-expected` is `NIL`, the same discipline
`exact-match` (`eval/scorer.lisp`) already uses. Recall against nothing is
not a measurement.

**The other three scorers are vacuously true on an *empty bundle*, and
that is intentional, not a gap.** `every` over `nil` evidence is `t`, so
`bundle-containment`, `bundle-standing-well-formed` and
`bundle-method-attributed` all score `1.0` when a bundle has no evidence
at all (I4, cl-llm#13). This is a different case from the empty `:expected`
above: an unpopulated `:expected` is a *definition* mistake — nobody
finished writing the eval case — which is why `bundle-recall-at-k`
signals. An **empty bundle** is a legitimate *retrieval outcome* — a query
that genuinely found nothing — and turning that into an error would
convert a real, if unhelpful, answer into a crash. `bundle-recall-at-k`
is what still catches it: an empty bundle can never contain an expected
document id, so recall drops to `0.0` even while the three hygiene
scorers read `1.0`. Relatedly, `(bundle-projection <empty bundle>)` is
`nil`, so a golden file holding `nil` (§6) matches *any* empty bundle,
not just the one it was generated from.

### Driving scorers through the harness: `run-fn`

`cl-llm/eval`'s `run-cell` used to only know how to call `llm:ask`: build
a prompt, get a reply, grade the reply. Grading a bundle needed a second
path. `variant` gained an optional `run-fn`:

```lisp
(eval:defsuite my-suite
  :dataset (list (eval:make-case "q" :expected '("doc-1")))
  :variants ((:run-fn (lambda (case)
                        (rag:fuse sources (eval:case-input case)))))
  :scorers (re:bundle-recall-at-k re:bundle-containment
            re:bundle-standing-well-formed re:bundle-method-attributed))
```

When a variant carries a `run-fn`, `run-cell` calls it with the case and
scores its return value directly — no model call happens, so there is no
`ask` reply to build a prompt for. When a variant has no `run-fn`, the
existing `ask` path runs exactly as before; this is additive, not a
replacement.

**The error-handling asymmetry is deliberate.** An `ask` failure becomes
an error cell — an HTTP outage is something to record and keep running
past. A `run-fn` error is not converted the same way: it propagates
uncaught out of `run-cell`. The failure modes are different in kind — a
`run-fn` failing means the harness itself, or the thing under test, is
broken (a bad fixture, a bundle-construction bug), which is a definition
mistake that should stop the run and surface immediately, not something
to tally alongside API outages and average over.

## 6. Capture-and-diff, and the trap in it

A raw `bundle` is not stable across runs — scores are floats and
embeddings can drift — so the golden-file harness (`rag-eval/golden.lisp`)
never compares bundles directly. It compares a **projection**:

```lisp
(bundle-projection bundle)
;; => a list of (document-id method standing rank), one per item, in order
```

Scores and chunk text are deliberately absent: neither is a regression
contract, and including them would make the harness fail for reasons
nobody cares about. `rank` is included even though it duplicates each
item's position in the list — that duplication is the point, not
redundancy to be tidied away. It is what keeps the comparison
order-sensitive even if some later change compared projections a
different way (e.g. after sorting them first); dropping `rank` as
"redundant with the index" is exactly the change that would defeat
ordering detection.

**Ordering is the contract, and the golden file is the only thing that
enforces it — but "the golden file" is the mechanism, not any single
test, and which test actually stands guard took two passes to get
right.** `a-reordering-fails-the-golden-file` proves the mechanism
*can* catch a reordering, but it drives `write-golden`/`check-golden`
against the hand-built `%bundle` fixture (see §5's `%bundle`), never
against `fuse`. So do every other test in the unit: the determinism
test (`fusion-order-is-deterministic`) compares two runs of `fuse`
against *each other*, which a consistently-wrong order would still
pass; the fusion tests (`fuse-names-every-mode-that-contributed`,
`fuse-keeps-distinct-chunks-of-the-same-document`) check membership,
not position; and the record-level ordering test
(`a-bundle-is-ordered-and-names-its-modes`) builds a `bundle` directly
and never calls `fuse` at all. A first attempt at closing this wrote a
bundle's golden file and checked it against a second `fuse` call in the
*same* test run — which turned out to prove nothing beyond "`fuse`
agrees with itself": both calls would sort identically even under a
`fuse` ablated to always sort by document id, since the same ablated
code produces both the write and the check.

What actually closes the gap is a **committed** golden fixture,
`tests-rag-eval/fixtures/fuse-mine.golden`, generated once (by
`write-golden`, run by hand, against an unmodified `fuse`) and checked
into the repository rather than written inside the test. The test
`a-real-fuse-bundle-matches-its-committed-golden`
(`tests-rag-eval/golden.lisp`) builds the same seven-chunk, two-source
fixture (`%fuse-fixture-sources`, `tests-rag-eval/suite.lisp`) the golden
file was generated from, calls `fuse` fresh, and checks the result
against that committed file — so a later `fuse` has to agree with
evidence captured *before* that later change existed, not with itself.
This was verified, not assumed: temporarily changing `fuse` to sort its
evidence by document id (the fixture's real RRF order is `(g e f a b c
d)`, not the alphabetical order a document-id sort would produce) turns
this one test red with the rest of the suite still green; reverting turns
it back green. That is the test standing between a reordering regression
and a green suite.

**A fixture built of exact ties can only catch tiebreak changes, not
ranking changes (C1, cl-llm#13).** The unit's first version of
`%fuse-fixture-sources` embedded only each chunk's distinguishing word
(e.g. `"alpha"`, not the full `"alpha mine"` chunk text) while querying
`"mine"`, so every dense cosine against the query was exactly `0.0`; and
with one occurrence of `"mine"` per chunk and equal chunk lengths, every
BM25 score was exactly equal too. Both modes' order then came entirely
from tiebreaking (`top-k-collector`'s document-id order for dense, hash
iteration plus a non-guaranteed-stable `sort` for sparse) — real, but not
what `fuse`'s ranking exists to test. Changing `*rrf-k*` from 60 to 10 left
the fused order unchanged, which is what exposed the degeneracy: RRF's
`k` only matters when items are ranked by more than one score, and a
tiebreak-only ordering has none. The rebuilt fixture embeds each chunk's
own full text and varies how many times `"mine"` occurs and how many
filler words surround it, so all seven dense cosines and all seven BM25
scores are pairwise distinct — asserted directly in the test as well, on
the fused bundle's scores, so this cannot silently regress back. Under
the rebuilt fixture, `*rrf-k*` 60→10 *does* change the fused order
(`f` and `a` swap) — verified the same way, by hand, reverted after — so
this test is now evidence the fixture measures ranking, not just
tiebreaking.

Two functions, deliberately asymmetric:

- **`write-golden`** — writes a bundle's projection to a path. Called
  explicitly, to (re)generate a golden file.
- **`check-golden`** — reads the golden file at a path and compares it
  against a bundle's current projection. Returns two values: whether they
  match, and — on a mismatch — the first differing `(expected actual)`
  pair (walked out to the length of the longer list, since `loop for ...
  in` over two lists of different lengths stops at the shorter one and
  would otherwise hide an added or dropped item as a false full match).
  **`check-golden` never writes.** A golden file that rewrites itself
  when it disagrees would prove nothing about regressions — it's the
  obvious convenience someone could add later, which is exactly why this
  design calls it out here: regenerating the golden file is
  `write-golden`, called deliberately, never something `check-golden`
  does on your behalf.

Fixtures for this harness are small and hand-built (or, for
`fuse-mine.golden`, generated once from a small hand-built source
fixture), with known-relevant answers, in `cl-llm/rag`'s and
`cl-llm/rag/eval`'s offline suites: fast and hermetic. Scoring against the
real corpus is intentionally a separate opt-in suite, following the
existing `cl-llm/live` pattern — not built in this unit (see §8).

## 7. Dependencies: `cl-temporal-extent`, and no graph

`cl-llm/rag` must stay free of any graph dependency — vivace-graph
integration is `cl-llm/rag/vivace`, a separate system that layers on top,
never the other way round. The bundle nonetheless needs to carry temporal
extents and standings, and those are not graph concepts: they now live in
[cl-temporal-extent](https://github.com/kraison/cl-temporal-extent),
extracted from vivace-graph for exactly this reason
(vivace-graph#159), and its own dependency is `local-time` alone.

`cl-llm.asd` records this directly:

```lisp
(defsystem "cl-llm/rag"
  :depends-on ("cl-llm" "cl-temporal-extent")
  ...)

(defsystem "cl-llm/rag/eval"
  :depends-on ("cl-llm/rag" "cl-llm/eval")
  ...)
```

Neither depends on `graph-db`; only `cl-llm/rag/vivace` and its test
system do. This is why `cl-llm/rag` loading with no graph system present
is a real configuration and not a degraded one: the bundle holds actual
`temporal-extent:temporal-extent` structs and actual standing keywords,
with the full vocabulary and its `standingp` check available, in a
process that never loaded vivace-graph at all. A consumer who only wants
literature retrieval — no field-data graph — gets the whole evidence
model, not a stub of it.

## 8. What unit 1 does not do

- **No spatial, temporal, or claim-traversal retrieval modes.** Only
  `dense-source` and `sparse-source` exist; `method` can only ever be
  `:dense` or `:sparse` in a bundle this unit produces, even though the
  slot's vocabulary already includes `:spatial :temporal :claim` for the
  units that add them.
- **No planner.** `bounds` is threaded through `collect-evidence` and
  every method ignores it; there is no code that produces or consumes a
  region/window yet.
- **No narration, and no LLM judge.** The four scorers are all
  deterministic; grading a narrated answer against a bundle is unit 4.
- **No enrichment of `hit`.** `evidence` and `bundle` are new, distinct
  records sitting beside `hit`; `store-search` and everything else that
  returns or consumes a `hit` is untouched. Decorating `hit` instead
  would have baked in "the bundle is dense output with extra fields,"
  which is precisely what claim expansion (unit 3) has to undo once it
  starts producing evidence that was never a dense hit at all.
- **No real-corpus offline scoring.** The fixtures-only harness described
  in §6 is what unit 1 ships; a `cl-llm/live`-style opt-in suite scoring
  against the real corpus is left to unit 3, once there is something
  (claim expansion) that fixtures cannot show.
- **`method` attribution on a shared chunk is first-source-wins, not
  every-source-that-matched (I5, cl-llm#13).** When both `dense-source`
  and `sparse-source` return the same chunk, `fuse` (§2, §4) attributes it
  to whichever source appears first in the caller's `sources` list; the
  other source's contribution to that chunk's evidence is not recorded
  anywhere. This is a known limitation, not a bug — deciding how a
  multiply-found chunk should report its provenance is a design question
  a later unit owns, not something this unit's `fuse` should guess at.
