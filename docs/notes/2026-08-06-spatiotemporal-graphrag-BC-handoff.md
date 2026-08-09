# SpatioTemporalGraphRAG — B + C handoff

Paste the block below into a fresh session started in `/Users/kraison/work/cl-llm`.
Written 2026-08-06, at the end of the mine-action hromada-prospect session.

---

## The prompt

> I want to work on **SpatioTemporalGraphRAG as a generic system** — specifically
> directions **B** and **C** from our earlier decomposition, not the mine-action
> domain agent (A).
>
> **B — a general agent-memory substrate.** VivaceGraph + cl-llm become the thing an
> arbitrary AI agent reasons and remembers over, with spatiotemporality as a
> first-class dimension. mine-action is the proving ground and first tenant, but the
> deliverable is the substrate, and it must work for agents with no map at all.
>
> **C — a reasoning engine for a knowledge base.** Closest to the original
> vivace-graph mission: ontologies, inference, constraints, and the LLM as an
> interface to *that*, rather than the graph as an accessory to the LLM. The
> differentiator is that answers are **derived and checkable**, not retrieved.
>
> Start with `superpowers:brainstorming`. Do not write code or a plan until we have
> agreed a decomposition and I have approved a design.
>
> **Read first, in this order:**
> 1. `~/quicklisp/local-projects/mine-action/docs/superpowers/specs/2026-07-29-spatiotemporal-graphrag-stage-a-design.md`
>    — the Stage A design. §3.2 (claims as reified relations), §3.3 (time with
>    provenance) and §3.4 (the source onboarding contract) are the parts that
>    generalise. §10 stages the increments.
> 2. `~/quicklisp/local-projects/mine-action/docs/spine-open-items.md`
>    — the live open-items register. ⚠ §2 says "prose rendering — STILL OPEN"; that
>    is **stale**, `src/site-report-prose.lisp` shipped. Verify each item before
>    believing it.
> 3. `~/work/cl-llm/docs/superpowers/plans/2026-07-18-cl-llm-rag-vivace.md`
>    — the graph-backed RAG store, and `2026-07-19-hybrid-retrieval.md` beside it.
> 4. The memories: `knowledge-substrate`, `graph-db-mvcc-contract`,
>    `vg-namespace-design` (PARKED — read before any cross-graph engine work),
>    `multi-graph-node-escape-bug`, `spatial-index-facts`.
>
> **Three findings that frame the work** (measured, from the earlier session):
>
> - **The reasoning engine is already in the box, unused.** VG v3 ships
>   `~/work/vivace-graph-v3/prologc.lisp` and `prolog-functors.lisp`, and exports
>   `select`, `?-`, `select-flat`, `*prolog-graph*`. Across all of mine-action's
>   `src/`, essentially nothing uses it — the app hand-writes traversals in Lisp
>   while the v1/v2 triple-store/Prolog/RDF lineage sits idle. **C is less
>   greenfield than it sounds; it is mostly a revival plus a formalism.**
> - **The engine has no notion of time.** No valid-time, no transaction-time, no
>   interval index. `observed-start`/`observed-end` are app-level integers on a
>   mixin, and Allen relations are computed in mine-action's `src/spine-time.lisp`,
>   not in the engine. **B's first brick is probably a temporal facility in VG.**
> - **Stage A already built a domain-specific prototype of exactly this**, and it
>   works: a place/time spine, claims reified with method/confidence/precision/
>   rule-version/provenance, temporal extents carrying observed-vs-inferred
>   standing, and 300k+ claims registered across five graphs. **The question for B
>   and C is what of that belongs in the engine, what belongs in cl-llm, and what
>   was mine-action-specific all along.**
>
> **The decomposition we reached before** — at least four independent subsystems,
> each its own spec → plan → build cycle:
> 1. a temporal / interval facility in VG;
> 2. an ontology + reasoning layer (revive Prolog, or add a constraint checker);
> 3. a retrieval layer fusing vector + spatial + temporal + graph traversal, in
>    cl-llm;
> 4. an agent-memory / decision-trace store.
>
> B makes (1) the first brick and forces every mine-action concept out of the
> engine. C makes (2) first, and spatiotemporality becomes one axiom set among
> many. **Wanting both B and C means deciding whether they share a first brick or
> genuinely fork — that is the first thing I want to work out.**
>
> **Where things live:** engine `~/work/vivace-graph-v3` (branch `experiment`,
> `4a2749d`); `~/work/cl-llm` (`rag/`, `vivace/`, `tests-rag/`, `tests-vivace/`);
> the reference application `~/quicklisp/local-projects/mine-action`.
>
> ⚠ **Do not treat mine-action as the requirement.** It is the existence proof and
> the first tenant. Every time a design decision is justified only by what
> mine-action needs, that is a signal it belongs in the app, not the substrate.

---

## Context the prompt does not carry

**Engine version floor.** mine-action now requires vivace-graph ≥ `7ac1458`
(runbook §B4). The production host runs an older engine and is not yet bumped, so
engine changes must not assume production is current.

**Two upstream issues** fixed but still open on the tracker: vivace-graph #104
(shared-index floor) and #105 (WKT EMPTY parse). The VG team closes them at their
next release.

**The absence-vs-value defect class** is the single most valuable thing Stage A
and the prospect work produced, and it generalises directly to B: any memory
substrate must distinguish *"the source looked and found nothing"* from *"no
source covers this"* from *"we could not find out"*. Collapsing those is the
defect that recurred eight times in mine-action. See
`~/quicklisp/local-projects/mine-action/src/prospect-cell.lisp` for the smallest
complete statement of it, and the memory `absence-vs-value-defect-class`.

**Measurement discipline.** Every performance figure in this project that was
assumed rather than measured has been wrong, twice by quoting a cold reading as
steady state. Take the third run.
