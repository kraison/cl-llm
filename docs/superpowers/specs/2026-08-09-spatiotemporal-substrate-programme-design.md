# SpatioTemporal substrate (B + C) — programme design

**Date:** 2026-08-09
**Status:** decomposition and phasing agreed in brainstorming. No unit is specced or
planned; each gets its own spec → plan → build cycle.
**Scope:** the whole programme. Deliberately *not* a spec for any single unit.
**Origin:** `docs/notes/2026-08-06-spatiotemporal-graphrag-BC-handoff.md`.
**Tracking:** cl-llm#15, board https://github.com/users/kraison/projects/1.

## 1. What this is

SpatioTemporalGraphRAG as a **generic system** — directions **B** (a general
agent-memory substrate) and **C** (a reasoning engine for a knowledge base) — as
distinct from the mine-action domain agent, which is direction A and already shipped as
Stage A.

mine-action is the existence proof and the first tenant. It is **not** the requirement.

## 2. The thesis: B and C share a first brick

The handoff named the first question as whether B and C share a first brick or genuinely
fork. They share one, and it is neither of the two candidates the handoff proposed.

**B and C are two consumers of one record.** B asks *"can an agent trust and cite
this?"* C asks *"can a reasoner derive and check this?"* Both questions are answered by
the same fact record: identity, extent, time with provenance, method, confidence,
standing.

Therefore the temporal facility is not B's first brick — it is *part of* the record. And
Prolog revival is not C's first brick — it is a *consumer* of the record.

## 3. The three findings, verified 2026-08-09

The handoff's framing claims were re-checked against the code, and two changed.

**The logic engine is idle, and more built than the handoff says.** `grep` for
`graph-db:select|select-flat|?-` across mine-action's `src/` returns **0 call sites**.
But vivace-graph #45 phases 0 and 1 are complete and merged to master: control-flow
core, `call/N`, `findall`/`bagof`/`setof` with free-var grouping, resource bounds,
effect partitioning, snapshot query mode, `def-query`, the JSON pattern DSL, `catch/3`
with ISO balls, NDJSON streaming. **C is a formalism over an existing engine, not a
revival.** What is missing is Phase 2 indexing — vivace-graph #102: *"General ordered
index is unreachable from Prolog: no index-backed generator predicate."*

**The engine has no notion of time.** No `allen`, no valid-time, no transaction-time, no
interval index anywhere in `~/work/vivace-graph-v3/*.lisp`; two incidental `interval`
mentions. The entire temporal algebra is `mine-action/src/spine-time.lisp` — **87
lines**, a struct and one relation function.

**Stage A's prototype is small at the core and fat at the edges.** `spine-time.lisp` 87,
`spine-place.lisp` 86, `spine-graph.lisp` 104, `spine-query.lisp` 106,
`spine-schema.lisp` 269 — against `spine-register.lisp` **858** and
`spine-backfill.lisp` **683**, of 2,226 total. The generic part is tiny and the
app-specific part is most of the code. That is the encouraging shape for an extraction.

### 3.1 What changed since the handoff was written

- **vivace-graph #53 is CLOSED as completed** (`3f7ba97`). The multi-graph node-escape
  class is fixed structurally: `maybe-init-node-data` resolves `(heap (node-home-graph
  node graph))`, so all thirteen call sites are correct at once and a future one is
  correct by default. The concern that a cross-graph claim layer would re-arm that SEGV
  is retired.
- **It grew into a shipped multi-graph contract for 3.0**, which constrains this design
  directly. See §6.2.
- **The general ordered index v1 shipped** and is merged to `experiment`, single-slot.
- #93, #94, #102, #104, #105 remain open.

## 4. The record

```
claim
  subject      (namespace, external-key)
  object       (namespace, external-key)     ; optional -- unary claims exist
  relation     open vocabulary
  method       open vocabulary
  standing     observed | inferred | asserted | searched-empty
               | uncovered | indeterminate
  confidence
  precision    inherited from the weaker endpoint
  fraction     partial / traversing registration
  rule-version
  extent       temporal-extent               ; optional
  geometry                                    ; optional
```

Reifying the relation rather than making it an edge buys three properties, each
load-bearing: contradictions survive instead of being resolved away; claims can be
superseded and versioned, so a rule change is a regeneration rather than a migration;
and claims are regenerable and therefore disposable.

`temporal-extent` is Stage A §3.3 unchanged: interval (an instant is a degenerate
interval), precision, semantics as an open vocabulary, standing. Relations between
extents are **computed, never materialised** — the algebra is closed and cheap and
nothing can go stale — and standing propagates, so a relation inherits the weaker
standing of its two endpoints.

### 4.1 The one generalisation beyond Stage A

Stage A carries `provenance: derived|asserted` on claims and `observed|inferred` on
extents. `standing` merges those and adds the three cases mine-action handled per-app
and got wrong repeatedly:

- `searched-empty` — the source looked and found nothing;
- `uncovered` — no source covers this;
- `indeterminate` — we could not find out.

**These are a type, not a convention.** The absence-vs-value defect class has seven-plus
confirmed instances, silent every time: `%report-metric` coercing a never-computed gap
to `0d0` so an undesignated site reported 0 ha unsurveyed and prose called a
4.1%-surveyed site "essentially the whole site covered"; `accuracy_m = 0` meaning
*unpopulated*; classification state read as a contamination fact. The API must make the
collapse **unrepresentable**, not merely reviewed against. This is the single most
valuable thing Stage A produced and it generalises directly to B.

## 5. Layering

```
graph-db/core                    neutral engine -- storage, txn, index, Prolog
  |- graph-db/spacetime          NEW - extent, Allen, standing, claim, registration
       |- graph-db/ontology      NEW - formalism + validator            (C)
       |- cl-llm/rag/vivace      fusion retrieval over claims           (B, retrieval)
       |    |- cl-llm/memory     NEW - agent-memory API                 (B, capstone)
       |- mine-action            first tenant -- spine-* becomes an adapter
```

The substrate goes into vivace-graph as an **opt-in ASDF subsystem** beside
`graph-db/geos` and `graph-db/replication`, not into cl-llm. The deciding argument: the
engine must eventually be able to *index* a temporal extent, and an index cannot
accelerate a type it cannot see. A type living above VG could only be indexed by VG
depending upwards.

`cl-llm` core does not depend on `graph-db` today — only `cl-llm/rag/vivace` does — and
this programme must not widen that.

### 5.1 Boundary rules (PR review checklist, not aspirations)

1. Nothing in `graph-db/spacetime` may name a mine-action concept.
2. Anything needing an LLM lives above `cl-llm`, never in `graph-db/*`.
3. Sources declare through the onboarding contract; the substrate holds no per-source
   code, and every facet supports an explicit "none" so a missing declaration is a
   contract violation rather than a silently non-registering source.
4. `graph-db/core` gains nothing from this programme except, eventually, an interval
   index — and only once measured.

A decision justified **only** by what mine-action needs belongs in mine-action.

## 6. The namespace design, folded in

`vivace-graph/docs/namespace-design-discussion.md` is not adjacent work. Its point 4
*is* this substrate's claim store: *"Cross-namespace edges exist only in a derived
namespace. Cross-source relations are reified as claim nodes."* Its own handoff says the
mine-action spine is "the derived, disposable namespace this design predicted, built for
real."

### 6.1 The endpoint abstraction

`claim-subject` / `claim-object`, and the inverse *"which claims touch this vertex?"*,
are an **interface with two implementations**:

- **today** — `(namespace, external-key)`, resolved by lookup, no edges;
- **after namespaces** — real edges to the endpoints, one snapshot clock, resolution by
  traversal.

Stage A §3.5 states the invariant that makes deferral safe: the semantics are identical
either way; only the physical representation of a claim's endpoints changes. This is why
the substrate does not block on the namespace work, and why the namespace work is a peer
unit the substrate designs *toward* rather than waits *on*.

### 6.2 Constraints inherited from the shipped 3.0 multi-graph contract

Hard requirements on the substrate's API:

- **A read-write transaction is single-graph.** Touching a foreign node signals
  `cross-graph-transaction-error` at `lookup-object`, `create-node`, `save`,
  `update-node`, `delete-node` and `mark-deleted`. Therefore **claim generation resolves
  its endpoints before opening its write transaction.** Stage A's external-key endpoints
  already satisfy this; now it has a stated reason.
- **Cross-graph reads are legal only from a read-only snapshot or outside a
  transaction.** `with-read-snapshot` records per graph and several compose. Therefore
  **bundle assembly runs under composed read snapshots**, one per namespace touched —
  per-namespace consistency, but not one instant.
- Class names are already globally unique across graphs: a down payment on global
  type-ids.

### 6.3 One epoch is a correctness gate for C

"Derived and checkable" across five graphs with five snapshot clocks is not checkable: a
derivation can observe an inconsistent instant and `rule-version` provenance will not
record that it did. So the split is — the **validator** runs per-namespace and needs
nothing from the namespace work; **inference spanning namespaces**, and the agent-memory
capstone, need the single epoch (vivace-graph #94).

### 6.4 Asserted claims

Namespace design point 5, carried into the substrate: an operator assertion is a node in
the **source** namespace keyed by external identity, with only intra-namespace edges;
its claim in the derived namespace is a materialisation like any other. An authored
cross-boundary link cannot be regenerated from a rule, so a dangle there would be data
loss rather than staleness. A node id is a location; an external key is an identity.

## 7. Multi-slot indexing

The general ordered index v1 is merged, single-slot. `def-index` (`index.lisp:421`)
declares in its own docstring (`index.lisp:431`) that it "is the home for future
composite / multi-slot indexes"; the design memo records composite as *"deferred but
designed-for: codec already polymorphic — `less-than` orders lists, so it's additive;
the deferred part is query-planner leading-prefix matching."* Composite `(user-key .
node-id)` is already **the** indexing idiom across views, `:unique` and the spatial
index.

This programme needs it in three places:

1. **The inbound query is a two-slot equality lookup** — `(subject-namespace,
   subject-key)`. That is the retrieval and agent-memory hot path, and the namespace
   design's open item 2.
2. **Claim identity becomes enforceable.** Identity is `(subject, object, relation,
   rule-version)`, and regeneration must upsert rather than duplicate at 300k+. A view
   cannot enforce: per the `:unique` design (#6), enforcement is a commit-boundary check
   inside `%commit`'s single `with-transaction-manager-lock` region — check
   pre-durability for a clean abort, maintain post-durability so it is
   journal-replayable — and that is exactly what **sidesteps #7, since views are
   post-durability**. A multi-slot unique index is the only route to an arbitrary
   composite key under the transaction system's protection.
3. **Leading-prefix ordering is the spatiotemporal access path.** `(place, valid-start)`
   — equality on the leading component, range on the trailing — answers "claims about
   place P overlapping window W" in one cursor. This may remove the case for a dedicated
   interval index; measure before building one.

The historical argument is the strongest: six real hromadas share `(oblast, raion,
name)` and differ only by `hromada-type`; discarding it made the second row upsert over
the first and **silently overwrite its KATOTTH code**, so those hromadas never entered
the graph and could never be alerted. A multi-slot unique index turns that into a
`unique-constraint-violation` at the commit boundary.

**What it does not replace:** views key on arbitrary computation; `def-index` keys on
slot values. Without expression indexes, views keep the derived-key cases and multi-slot
takes the tuple-of-raw-slots cases — which is most identity lookup, and the set that
wants enforcement. This resolves the apparent conflict between Stage A §8.2 ("views
already exist, no prerequisite work") and the namespace design's open item 3 ("the slots
must be indexed or an assertion resolves by scan"): both are right about different
questions.

**One trap:** `:unique` and `def-index` are NULL-exempt today. For a tuple, the rule
for an absent component must be chosen deliberately — indexed, unindexed, or an error.
`(namespace, external-key)` with a NIL key means *this endpoint has no external
identity*, which must not collapse into a shared key. That is the absence-vs-value
defect class reappearing inside the index design.

## 8. The units

| | Unit | Repo | Issue |
|---|---|---|---|
| M | Multi-slot indexes | vivace-graph | #107 |
| S1 | `graph-db/spacetime` — claim + time substrate | vivace-graph | #108 |
| S2 | First tenant: spine becomes a tenant | mine-action | #55 |
| S3 | Document validity-time + supersession (map-less tenant) | cl-llm | #12 |
| S4 | `graph-db/ontology` — formalism + validator | vivace-graph | #109 |
| S5 | Retrieval fusion | cl-llm | #13 |
| S0 | Namespaces | vivace-graph | #110 |
| S6 | Agent memory + decision trace | cl-llm | #14 |

Dependencies: M → S1 → {S2 ‖ S3} → S5; S1 → S4; {S4, S5, S0} → S6.

## 9. Phasing

Bands, not a serial chain. The concurrency is load-bearing.

**P1 Foundations** (vivace-graph) — M, then S1. M first because it is small and additive
and S1's identity scheme depends on it; S1 is designed concurrently. **P1 is not
declared done here.**

**P2 Proof by two tenants** (mine-action ‖ cl-llm) — S2 and S3, concurrently. These
**are the acceptance test for P1**, not consumers of it. A substrate with one tenant
becomes that tenant's library no matter how carefully it is reviewed; genericity has to
be forced structurally. S3 is the only thing proving the spatial facets are genuinely
optional rather than merely defaulted. Nothing is built on top until both land. Running
them sequentially would bake in mine-action's assumptions before the map-less tenant
could object.

**P3 B and C fork** — S4 (reasoning) ‖ S5 (retrieval) ‖ S0 begins. Having shared the
brick, the directions now genuinely diverge.

**P4 Namespaces complete** — S0. Sequenced to finish late so the epoch, the detached
bulk-load path and the inbound lookup are sized against **measurements rather than
estimates**; started early because it is the long pole. Its handoff says to brainstorm
the open items, not re-derive the agreed shape.

⚠ Deployment gate: a type-id migration lands on a production host running an older
engine, already behind mine-action's `7ac1458` floor.

**P5 Capstone** — S6. LLM-directed traversal lands here and **only** here, behind S4's
validator; building the traversal first and the guardrail second is building the
dangerous half first. Cross-namespace inference unlocks here too, gated on #94 and #102.

**E Orthogonal, pulled by measurement** — #102 (an index-backed generator predicate: on
S5's path, and gating any Datalog — see §12.1), #104/#105 closure, and a dedicated
interval index *only if* §7's composite index does not already serve the temporal access
path.

## 10. Cross-repo mechanics

**A VG change reaches production in five steps** — `experiment` → green on SBCL → merged
to `master` → released → consumer's version floor bumped → production deployed. No phase
may assume that is instant. Every phase touching vivace-graph states its version floor
and whether production must be bumped.

Engine work is on `experiment`; ECL is demoted to periodic — verify on SBCL and say
explicitly when ECL was skipped.

## 11. Testing and measurement discipline

Each of these was earned by a specific failure.

- **Contract conformance per source** — identity, space, time, attribution, sensitivity,
  registration, indexed text; each declared, each exercised, including the explicit
  "none".
- **Absence-vs-value conformance** — a standing test category. For every gatherer field,
  a test that its never-measured state is distinguishable from a real zero.
- **Sensitivity and path-matching rules proven against the real corpus, never synthetic
  fixtures.** The provenance rule that excluded a set of restricted photographs was a
  silent no-op on the real filesystem for NFC/NFD reasons, and its unit tests passed its
  entire life because the fixtures used the same string literals the code did.
- **Bundle regression is capture-and-diff, with ordering as the contract.**
- **Deterministic scoring of bundle correctness; LLM-judge scoring confined to
  narration.** Prior eval work measured LLM-judge dimensions at roughly 15% run-to-run
  variance with a strong judge, while deterministic dimensions were trustworthy enough
  to drive an embedder bake-off.
- **Every performance figure names its host and is the third run.** Every figure in this
  project that was assumed rather than measured has been wrong, twice by quoting a cold
  reading as steady state. The dev hub does not characterise production.

## 12. Deferred and still open

- **Cross-namespace inference** — C's second half. Gated on #94 and #102, and on
  vivace-graph #45 Phase 3. See §12.1.
- **Expression / computed-key indexes.** Views keep the derived-key cases for now.
- **Automatic index selection in the Prolog compiler** (scan-and-filter rewritten to an
  index range scan) — separately deferred, not required by this programme.
- **A dedicated interval index** — contingent on §7's measurement.
- **Registration of coarse points to fine places** (Stage A open question 5) — whether a
  coarse centroid registers to the containing place, to every place its uncertainty
  radius touches, or to the smallest place wholly containing that radius. Affects claim
  volume and honesty. Inherited unresolved.
- **Spine memory footprint at full source scale, measured per host** (Stage A open
  question 4).
- **The tuple-NULL rule** for composite indexes (§7) — to be decided in M, not
  inherited.
- **ANN / HNSW** — considered 2026-08-09 and **not on the path**. See §12.2.

### 12.1 vivace-graph #45 phase accounting

How much of the Prolog roadmap this programme needs. The short answer: **about half of
Phase 2, one bullet of Phase 4, and nothing else** — until C's inference half.

| #45 phase | Programme need |
|---|---|
| **0** Control-flow core | **None — done and merged.** Inherited free. |
| **1** Safety / web-enablement | **None — done and merged.** Inherited free. |
| **2a** Clause indexing for asserted clauses | **Conditional** — only if S4 compiles the ontology into many asserted clauses. See the gate below. |
| **2b** Index-aware predicate resolution (#102) | **A narrow slice**, for S5. |
| **3** Datalog stratum + tabling | **None for this programme.** All of it for C's inference half, sequenced after P5. |
| **4** Cost-based join reordering | **None.** Pure optimisation. |
| **4** `shortest_path` / `reachable` / k-hop | **None.** `reachable` overlaps Phase 3; S5's weighted expansion is planner-bounded and belongs in Lisp. |
| **4** Spatial/temporal predicates pushed into indexes | **Yes** — the same work as #102, for S5. |
| **4** First-class aggregation | **Weak form already shipped** (`findall` + length). Strong form is a want, not a need. |

Phases 0 and 1 being already paid for is the single largest reason C is cheaper than the
handoff implied: the substrate inherits a correct, composable, bounded, effect-gated,
snapshot-capable engine at no cost. One residual to carry: deep-recursion safety was
answered with **resource bounds rather than a trampoline**, so long derivations fail
rather than run. That resurfaces in Phase 3.

**The gate that decides all of it — S4 must state, in its own spec, whether the
validator runs *as* a Prolog query or is *driven from Lisp*.**

- *Driven from Lisp* — the validator sweeps claims via the index API and calls Prolog
  only to evaluate each constraint. Needs essentially none of Phases 2, 3 or 4.
- *Expressed as Prolog queries over the graph* — pulls in 2b properly, later wants Phase
  4's pushed-down predicates, and **if the formalism compiles to many asserted clauses,
  pulls in 2a as well**, because `functor.lisp` recompiles the whole functor on every
  `<-` and `clauses-with-arity` is a linear scan.

**Recommendation: drive the validator from Lisp.** The sharpening that decides it is
that **a full-corpus validation sweep does not benefit from an index** — checking every
claim against every constraint is a scan by definition, and no index makes a sweep
selective. S5's access pattern, by contrast, *is* selective (place plus window), which
is exactly what a leading-prefix composite range serves. So:

- S4 write-path validation → single-record lookup by identity. **M supplies this.** No
  #45 work.
- S4 batch pass → a sweep. No index, no #102.
- S5 retrieval → selective. **This is where #102 and Phase 4's pushed-down predicates
  land**, and the general-index design already identified the seam: mirror
  `spatial-query.lisp`, which wires the spatial index into Prolog as index-backed
  predicates — "thin wrappers over the v1 API, so build API first; Prolog is a wrapper,
  not a rewrite."

**Why Phase 3 is genuinely needed later, not optional.** Ontology transitivity
(`subClassOf` over a taxonomy) is a closure; supersession chains are a closure, and S6's
"what superseded this, and what superseded that" is a chain walk. And **tabling is the
termination guarantee the claim model needs**: contradictions are deliberately retained
and rival claims are never resolved into one, so the derived graph is cyclic-capable by
design. Today a recursive rule that loops hits a resource bound and *fails*; tabling
makes it *terminate correctly*. That is the difference between a reasoner that refuses
to answer and one that answers. Semi-naïve evaluation plus magic sets is then what makes
derivation over 300k+ claims tractable rather than theoretical.

⚠ **The trap.** Phase 3 is #45's declared flagship and "historically the direction this
engine has wanted to go." That is exactly the condition under which a programme quietly
reorders itself around the most interesting engine work instead of the work that makes
the substrate real. **Phase 3 is unlocked by this programme, not required by it** —
until there is a real inference workload at real claim volume to size tabling and
magic-sets against. Building SLG against estimates is the measurement failure mode this
project has already hit twice (§11).

### 12.2 Approximate nearest neighbour (ANN / HNSW) — considered, not on the path

Raised 2026-08-09. Recorded because "we considered ANN and here is why it is not on the
path" is exactly the kind of conclusion that gets re-litigated in six months.

**Current state.** Every vector-search strategy is a brute-force exact scan —
`segment.lisp:927`: *"segment-scan is a bounded top-k full-cosine sweep."* Measured at
roughly **1.85 ms per 1000 chunks at dimension 1024** while the vector block is
resident, so ~43 ms at the current ~23k-chunk corpus. The segment-store work estimates
~1.9 s/query at 1M chunks, CPU-bound. ⚠ **That 1.9 s figure was derived from a laptop
CPU-bound regime and has never been measured on the deployment host**, so per §11 it
must not drive a decision until someone runs it there.

**Why this design reduces the need rather than increasing it.** S5's mechanic bounds the
search spatially and temporally *before* dense retrieval, so the vector search runs over
a filtered candidate set rather than the corpus. The candidate set therefore scales with
**density per place-time cell, not with total corpus size** — a corpus ten times larger
with the same spatial-temporal spread yields the same bounded candidate set.
`segment-score-subset` (`segment.lisp:1014`) already scores an arbitrary subset exactly,
which is the primitive that path needs.

**Filtered ANN is the weak case, not the strong one.** An HNSW graph is built over the
whole vector set. Pre-filtering fragments it — connectivity assumed nodes that are no
longer present, and recall collapses. Post-filtering can return zero in-scope hits
inside a tight place-time bound, forcing a much larger k and eroding the speed
advantage. On the bounded path, exact subset scoring is both faster and correct.

**Two consequences if it ever does land**, and they are why the rules below are written
now rather than retrofitted:

1. **It weakens the regression surface this design leans on.** S5 (§8) makes the bundle
   the artifact partly because its correctness is deterministically checkable, and §11
   makes capture-and-diff with *ordering as the contract* a standing rule. HNSW
   construction
   depends on insertion order and randomised level assignment, so seed sets can shift
   between rebuilds. Adding ANN means either a deterministic build or an explicit
   admission that the seed set is no longer a stable contract.
2. **An ANN miss is the absence-vs-value defect class reappearing in the retriever.**
   Expansion cannot recover what was never seeded, and an approximate search returning
   nothing is **not** `searched-empty` — it is `indeterminate`. This design is unusual
   in having the vocabulary to say that correctly (§4.1); most retrieval systems do not.

**Two rules the unit specs must carry**, which are what make ANN safe to add later:

- **S1** — an approximate or otherwise lossy search that returns nothing yields
  `indeterminate`, never `searched-empty`.
- **S5** — bounded retrieval uses exact subset scoring via `segment-score-subset`; a
  global ANN query must never silently become the bounded path.

**Where it would help first**, if it ever becomes urgent: **S3, the map-less document
tenant**. A source declaring `space: none` has no spatial bound to narrow it, so its
queries are often corpus-wide and *do* scale with corpus size. Not the place-anchored
path.

**The trigger metric is not corpus size.** It is per-query candidate-set size *after*
bounding — a different number, currently unmeasured, and one the present corpus cannot
reveal. Measure it during S2/S3, when there is finally a bounded query to measure.

## 13. Next step

Each unit gets its own spec → plan → build cycle. The first is **M** (vivace-graph
#107), whose spec must settle the multi-slot declaration surface, the class-level unique
form and the tuple-NULL rule. **S1** (#108) is designed concurrently and built on M.

No unit is planned by this document. This document decides only what the units are,
where they live, what order they go in, and what would make each of them wrong.
