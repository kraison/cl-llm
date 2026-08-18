# The retrieval planner — design (cl-llm #13, unit 2)

**Unit 2 of the retrieval-fusion epic (#13), phase 3 of the spatiotemporal
substrate programme.** Unit 1 shipped the evidence bundle and its
deterministic scoring, and threaded a `bounds` parameter through
`collect-evidence` which every method accepts and ignores. This unit gives
that parameter a value and a meaning.

## What it is for

The epic's argument:

> Expansion is weighted by spatial precision and temporal relation, not by
> hop count. Graph distance and relevance diverge badly here: a record one
> hop away via a registration claim may be years and tens of kilometres
> away. A deterministic planner bounds the region and window first, so that
> inside that scope hop count is no longer being asked to approximate
> relevance.

So the planner's output is a **scope**, not a ranking. Ranking within the
scope is unit 3's problem; this unit decides what is in play at all.

One constraint from the epic shapes the interface more than anything else:

> This layer's planner internals become that tool surface later, so the
> capstone inherits them rather than replacing them.

The planner is therefore a small set of **separately callable, nameable
operations**, not one opaque function — because "bound the region" and
"bound the window" are the two things an LLM-directed agent will later
invoke as distinct tools, behind the constraint validator.

## Where it lives, and the asymmetry that decides the shape

`cl-llm/rag` stays free of any graph dependency. The two halves of a bound
are not equally easy there, and the difference is load-bearing:

- **Temporal is solved.** `cl-temporal-extent` (vivace-graph#159) gives real
  extents and the full Allen algebra with no engine, so the window is a
  genuine `temporal-extent` the graph-free layer can build and compare.
- **Spatial is not.** The `geometry` struct lives in the `graph-db` package
  and its bridge is FFI-coupled — 18 references to the GEOS FFI — so it
  cannot follow the temporal layer out. **Verified, not assumed**: the same
  check that found the temporal layer separable finds this one is not.

The spatial half is therefore a **bounding box of four numbers**:
`(min-lon min-lat max-lon max-lat)`. Plain data, no dependency, and the
graph-free layer can both derive one and test against it. Coarse by design —
a box is the standard first pass for scoping, and a graph-backed source may
refine it with real geometry when unit 3 arrives.

## The record

```lisp
(defstruct bounds
  (box nil)                     ; (min-lon min-lat max-lon max-lat), or NIL
  (box-standing :indeterminate)
  (window nil)                  ; a TEMPORAL-EXTENT, or NIL
  (window-standing :indeterminate))
```

**Each half carries its own reason.** They genuinely differ: a document
corpus has no spatial facet at all while having perfectly good validity
time. A single shared standing would force a lie about one of them.

Both default to `:indeterminate` — nothing consulted — matching how
`evidence`'s `standing` defaults in unit 1.

## Deriving a bound, and what each reason means

Two operations, each returning a value and a reason:

```lisp
(temporal-bound evidence)   ; => (values <temporal-extent or NIL> <standing>)
(spatial-bound  evidence)   ; => (values <box or NIL> <standing>)
```

| outcome | standing | meaning |
|---|---|---|
| some evidence carries the facet | `:inferred` | the bound was **derived**, not observed |
| evidence exists, none carries it | `:searched-empty` | we looked and found none |
| no evidence at all | `:indeterminate` | there was nothing to look at |
| the caller supplied it | `:asserted` | the caller asserts this scope |

Every member of that table does real work. A consumer can distinguish "we
derived this window from the evidence" from "these documents have no time
at all" from "you gave us nothing to plan over" — three situations a `NIL`
collapses into one.

The temporal union is the enclosing interval: earliest start to latest end,
with `:unbounded` handled by `cl-temporal-extent`'s own bound arithmetic.
The spatial union is the enclosing box.

## Combining

```lisp
(plan-bounds evidence &key box window)   ; => a BOUNDS
```

**Supplied wins, and is marked `:asserted`.** Each half resolves
independently, so a caller may pin the window and let the region be
inferred — which is the common agent case, and the reason the two bounders
are separate operations rather than one.

## Applying a bound: absence is never exclusion

**A bound excludes only what is *known* to fall outside it.** Evidence whose
facet is absent is never excluded.

This is the rule the map-less tenant depends on. S3 exists to prove the
spatial facets are genuinely optional; if a bound rejected unknowns, then
the moment any spatial bound existed a document corpus with no geometry
would return nothing — and the tenant built to prove optionality would be
the one it broke.

It is the same distinction `:indeterminate` versus `:searched-empty` carries
in unit 1, applied one layer out.

## Making it exercisable, which is the part worth arguing about

As originally scoped this unit would ship a mechanism **nothing exercises**.
Dense and sparse sources set `extent` and `precision` to `NIL`, so
derivation would always return `:searched-empty` and filtering would always
exclude nothing. It would go live only when unit 3 produced evidence with
real facets.

That is exactly the shape of the defect that survived four reviews in unit
1: a mechanism built in one unit, relied on by another, with nothing
spanning the join. So this unit is widened to close it.

**Chunk metadata may carry two optional keys**, both plain data so they
survive persistence through any store:

- `:extent` — the versioned extent **sexp**, which is what `extent->sexp`
  exists for, decoded via `sexp->extent`.
- `:box` — four numbers.

The dense and sparse sources populate the evidence record from them when
present. This requires one additive change:

**`evidence` gains a `box` slot** beside `extent`. Filtering then reads
evidence fields uniformly whether the facet arrived from chunk metadata
(this unit) or from a claim (unit 3), rather than one path reading the
record and the other reaching back into the chunk. The constructor is
keyword-based, so the addition breaks nothing.

With this, the planner is exercisable end to end against a corpus that has
real validity times — which the document tenant does, in its supersession
ledger.

## Testing

Each item is a property that must fail for a stated reason, and a test whose
whole value is that it would go red must be **shown** to go red.

1. Each of the four standings is produced by the situation that warrants it.
   In particular `:searched-empty` (evidence existed, none carried the
   facet) and `:indeterminate` (no evidence at all) must be distinguished —
   they are the pair most easily conflated, and conflating them is the
   failure this vocabulary exists to prevent.
2. A derived window encloses every seed extent, and a derived box encloses
   every seed box.
3. Supplied values win over derivable ones and are marked `:asserted`.
4. The two halves resolve independently — a supplied window with a derived
   box yields `:asserted` and `:inferred` respectively.
5. **Evidence with an absent facet survives a bound that would exclude it if
   the facet were known.** Ablate by making the filter reject unknowns and
   confirm this goes red; it is the map-less tenant's guarantee in
   miniature.
6. Evidence whose facet is known and outside the bound *is* excluded —
   otherwise the filter does nothing at all and test 5 passes vacuously.
7. A source populates `evidence-extent` and `evidence-box` from chunk
   metadata when the keys are present, and leaves them `NIL` when absent.
8. A malformed `:extent` sexp in metadata signals rather than silently
   yielding `NIL` — a corrupt facet is a definition mistake, not an absence.

## Acceptance criteria

- `plan-bounds` returns a `bounds` whose every standing is a member of the
  vocabulary, for every combination of supplied and derivable facets.
- The dense and sparse sources honour a bound, excluding only known-outside
  evidence.
- A corpus whose chunks carry no facets behaves exactly as it does today —
  no bound derived, nothing excluded, no error.
- `cl-llm/rag` still depends on `cl-temporal-extent` and no graph system.

## What this unit deliberately does not do

- **No ranking.** The bound decides what is in play; weighting by spatial
  precision and temporal relation is unit 3.
- **No real geometry.** A box, not a polygon. Precise containment needs the
  engine and belongs with the claim traversal that already does.
- **No query parsing.** The planner is deterministic; deriving bounds from
  the text of a question is an LLM's job and lands, if ever, behind the
  validator in the capstone.
- **No claim traversal.** Seeds come from the two modes that exist.
