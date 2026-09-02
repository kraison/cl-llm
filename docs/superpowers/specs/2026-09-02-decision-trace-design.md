# The decision trace — design (cl-llm #14, S6a unit 1)

**Unit 1 of three under the single-namespace capstone S6a** (`#14`;
programme `#15`, design
`2026-08-09-spatiotemporal-substrate-programme-design.md` §8). The
capstone was cut on 2026-09-02 into: **unit 1, the decision-trace record**
(this spec); unit 2, the agent tool surface over recall, record and the
retrieval planner, every write validated first; unit 3, the dogfood
round-trip that turns the memory corpus's hand-written supersession
banners into claims. Units 2 and 3 get their own specs once this record
exists to build on. Approved in chat 2026-09-02.

Engine: vivace-graph `experiment` HEAD, unpinned (decided 2026-09-01 on
`#15`). Every engine surface relied on is named in §2; all of it shipped
in the 2026-09-02 capstone batch (kraison/vivace-graph#300–#303) and is
green in CI at `73ad4e2`.

## 1. What this is

A record of a **decision**: at time *t*, producer *p* concluded *X* from
evidence *E* under rule *r* at version *v* — or was refused, and why.
It makes an agent's conclusion **checkable after the fact** rather than
merely plausible: a reader can reconstruct what was believed at *t*, see
which of those beliefs have since been superseded, retracted or updated,
and see which other conclusions rest on the same ground.

Three properties, each the mirror of one the belief tenant already has:

- a decision cites its evidence **by claim identity**, not by node id,
  so the cite survives retraction, re-assertion and regeneration;
- reconstruction reads each cite **as of the decision's instant**, so a
  cited fact comes back as the version believed then, never as the
  current version standing in for it;
- a refusal is recorded **structurally** — which constraint family,
  which write — not as a caught error string.

The first producer of decisions is a Lisp-side `conclude` over claims
already in the store. No LLM, no tool surface, no prose parsing: those
are units 2 and 3.

## 2. The engine surface used

| Need | Engine | Where |
|---|---|---|
| a second claim family, non-temporal | `def-claim-classes` (kraison/vivace-graph#131) | `spacetime/claim.lisp` |
| a claim's identity as a string | `claim-identity-key` (kraison/vivace-graph#303) | `spacetime/claim-query.lisp` |
| read as of a transaction instant | `claims-touching … :as-of`, `reaped-claim` (kraison/vivace-graph#300) | same |
| read by relation, paginated | `claims-touching … :relation :limit :offset` (kraison/vivace-graph#302) | same |
| validate a write set without committing | `validate-writes`, `validation-report` (kraison/vivace-graph#301) | `evaluator.lisp` (core) |
| a transaction of our own, rolled back on refusal | `with-transaction (:graph g)`, `rollback`, `*transaction*` (kraison/vivace-graph#175) | `transactions.lisp` |
| the transaction's own write set | `graph-db::writes` — **internal**, see §9 | same |
| transaction time on every claim | `claim-recorded-at`, `claim-current-p` (kraison/vivace-graph#148) | `spacetime/claim-query.lisp` |

Two engine facts that shape the design. **A claim constructor enrols
its node in the open transaction at once** — the engine's own evaluator
tests fabricate proposed writes inside a rolled-back transaction for
exactly this reason — so a dry run cannot happen inside a caller's
transaction whose other writes must survive. And **`validate-writes` is
advisory**: it runs outside the manager lock, so a clean report does not
bind the commit that follows (kraison/vivace-graph#301).

## 3. The record

```lisp
(st:def-claim-classes trace :cl-llm-memory)   ; beside BELIEF, not temporal
```

A decision is an endpoint `(:decision . id)`; `id` is a 32-hex-digit
random string minted by `conclude` (ironclad, already a dependency).
Everything known about a decision is claims on that endpoint, all by the
same producer, each with an **instant** validity extent at the decision
time (`:semantics :validity :standing :asserted`):

| relation | arity | object | standing | slots carried |
|---|---|---|---|---|
| `concluded` | binary | `(:claim . cite)` — the belief or absence written | `:inferred` | `method` = rule name, `rule-version`, `confidence` |
| `evidence` | binary | `(:claim . cite)`, one per distinct cite | `:observed` | — |
| `refused` | binary | `(:violation . family)`, one per violation in the report | `:observed` | `method` = the violation's report text |

Exactly one of `concluded` / `refused` exists per decision. The family
is not temporal, so identity is `(producer subject object relation)`:
two cites of the same claim collapse to one `evidence` claim, and two
violations of one family collapse to one `refused` claim carrying the
first — the same rule the engine's report applies to its signalling
families.

**A cite** is the string `"<family>|<identity-key>"`: the parent claim
class's name, downcased, then the engine's `claim-identity-key`. The
key's first three fields are producer, subject namespace and subject key
(`|` and `\` escaped inside string fields), so a cite resolves to one
`claims-touching` call on the subject plus a `string=` on the key. The
split is implemented here (§9 asks the engine for it); nothing else
parses the key.

The belief written by a `concluded` decision also carries `method`,
`rule-version` and `confidence` — `record-belief` already accepts them
— so a reader of beliefs sees the rule without visiting the trace.
Duplication is deliberate: both are written in one transaction, and the
identity key ties them.

## 4. Write path

```lisp
(conclude graph proposal
          &key producer evidence rule rule-version confidence)
  ;; PROPOSAL  (:belief subject relation object &key standing extent)
  ;;        or (:absence subject relation &key standing extent)
  ;; EVIDENCE  a list of claims and/or cite strings; may be empty
  ;; => a DECISION
```

`decision` is a struct: `id`, `outcome` (`:concluded` or `:refused`),
`claim` (the belief or absence written, else NIL), `report` (the
`validation-report` or the caught condition, else NIL), `at` (the
outcome claim's `recorded-at`).

**`conclude` owns its transaction**, unlike the tenant-three writers,
which run inside the caller's. A decision is atomic with its outcome,
and the refusal path needs a rollback. A caller already inside a
transaction gets a `belief-argument-error` naming `*transaction*`; there
is no nesting.

1. Open `with-transaction (:graph graph)`. Stage the proposal through
   `record-belief` or `record-absence` — predecessor close included, and
   every argument check those already do. Argument errors propagate
   before anything is written and record no decision: a malformed
   proposal is the caller's defect, not a decision that was refused.
2. Run `validate-writes` over the transaction's own write set. Any
   violation: `rollback`; then, in a fresh transaction, record the
   `refused` claims and the `evidence` claims; outcome `:refused`, the
   report attached.
3. A clean report: write the `concluded` and `evidence` claims in the
   same transaction and commit. If the commit still refuses (the report
   is advisory), catch `constraint-violation`, and record the refusal
   from the condition — one family — in a fresh transaction.

Evidence is recorded on both outcomes: a refused decision still says
what it was looking at. When `record-belief` takes its idempotent path
(the same object already held), `concluded` cites the existing belief
and the trace is still new — a decision happened even if nothing
changed. `conclude` never retracts; an agent that concludes it was wrong
says so through `retract-belief`, and a later `conclude` can cite the
retracted claim as evidence of that.

Cites are rendered at step 1, from the claims the caller passed, before
any write; a claim passed as evidence is not required to be current.

## 5. Read path

```lisp
(trace graph decision-id)               ; => a DECISION-RECORD, or NIL
(decisions-citing graph claim-or-cite)  ; => decision ids, newest first
```

A `decision-record` carries `id`, `producer`, `at`, `rule`,
`rule-version`, `confidence`, `outcome`, `conclusion` (a `cite-record`
or NIL), `evidence` (a list of `cite-record`s) and `refusals` (a list of
`(family . text)`).

The conclusion and every evidence cite are resolved **as of `at`**
through `claims-touching … :as-of`, so each `cite-record` is in one of
three states:

| `state` | meaning |
|---|---|
| `:resolved` | `claim` is the version believed at `at`; `standing` and `extent` are that version's |
| `:reaped` | the claim existed at `at`, but every version of that age is past the family's `:keep-revisions` window (engine `reaped-claim`) |
| `:absent` | no claim with that identity is findable at `at` — swept by `delete-claims-by-producer`, or never there |

A resolved cite also carries `changed-since`: `:retracted` when the
claim's transaction extent has closed since `at`; `:superseded` when its
validity end, open at `at`, is now closed; `:updated` when the current
version otherwise differs from the as-of version; NIL when nothing has
moved. The as-of version is what the record hands the reader; the
current version is consulted only to set this flag.

`decisions-citing` is `claims-touching` on the trace family with the
cite as the **object** endpoint, `:relation "evidence"`. It is the
reverse direction, and it is what turns "this belief was superseded"
into "these conclusions rest on it".

**Order is the contract** (programme §11): evidence in cite-string
order; refusals in family order; `decisions-citing` by `recorded-at`
descending, then id. A reordering is a regression.

Why `at` is the outcome claim's `recorded-at` and not a caller-supplied
time: the evidence was read before the outcome was written, so every
cited version's stamp precedes `at` and the as-of walk finds it; a
caller-supplied time could precede the cites and resolve nothing.

## 6. Layering and boundaries

- Lives in `cl-llm/memory`: `memory/trace.lisp`, the family added to
  `memory/schema.lisp`, exports added to `memory/packages.lisp`. **No new
  dependency**: `validate-writes` is in graph-db core, ironclad is
  already there. Still nothing on `cl-llm` core or `cl-llm/rag`.
- Nothing here names a tenant of another repo. The cite scheme is
  family-neutral by construction: a decision may cite a document claim,
  a spine claim or a belief alike, because every claim family renders
  an identity key.
- `graph-db::writes` is reached through its package until §9's export
  lands. The one use is fenced in one function, `%staged-writes`, with
  the issue number beside it.

## 7. Testing

`tests-memory/trace-tests.lisp`, in the existing `:cl-llm-memory` suite
on the real on-disk graph `with-memory-graph` opens. The load-bearing
tests, each pinned to the acceptance line it proves:

- **Round-trip.** `conclude` a belief from two evidence beliefs; `trace`
  returns `:concluded`, the conclusion resolved, both cites `:resolved`
  with `changed-since` NIL, rule and version as given.
- **Refusal, non-vacuous.** A belief held over `[t1, t5]` and closed;
  no current predecessor, so `record-belief` stages a fresh claim.
  Proposing the same object with validity starting at `t3` overlaps the
  lapsed claim on one base tuple, which the extent-disjointness
  validator refuses (`:subsystem`); starting at `t1` repeats the
  identity tuple, which the unique constraint refuses (`:unique`). Both
  are tested. `trace` shows `:refused` with the family, **and** `recall`
  on the subject shows no new belief. The second assertion is what makes
  the first mean something (the ablation rule in
  `weak-assertions-pass-vacuously`).
- **As-of.** `conclude` from a belief; then supersede that belief with
  `record-belief`; `trace` still resolves the cite to the version with
  the open validity end, flagged `:superseded`. A retraction after the
  decision flags `:retracted`.
- **Reverse.** `decisions-citing` from the superseded belief returns the
  decision; from an uncited belief returns NIL — which is "no decisions",
  not an absence standing.
- **Idempotent conclusion.** Concluding the object already held yields a
  new decision citing the existing belief.
- **Capture-and-diff.** A fixture sequence of concludes and supersessions
  rendered by `trace-listing` and diffed against
  `tests-memory/golden/trace.sexp`, ordering as the contract.
- **Nested call refused.** `conclude` inside a caller's transaction
  signals before writing.

No performance figure is claimed. A trace read is one `claims-touching`
plus one resolution per cite; if that ever needs a number it is measured
on a named host, third run (programme §11).

## 8. Acceptance

From `#14`'s list, unit 1 delivers:

- **A decision trace reconstructs what was believed and why, at a past
  instant** — `trace` resolves every cite as of the decision, reports
  reaped and absent cites as such, and flags what has moved since.
- **Every write is validated before its side effect** — for `conclude`;
  a refusal is recorded structurally and leaves no belief behind.
- **A superseded fact is never returned as current** — a cite whose
  ground has moved says so, and the as-of version is what is returned.

Not delivered here, by the cut: the tool surface and bounded traversal
(unit 2), and the dogfood banners becoming supersession claims (unit 3).

## 9. Findings filed on vivace-graph (2026-09-02)

- **Export the transaction's write-set reader** —
  kraison/vivace-graph#320. `writes` on a transaction is what
  `validate-writes` wants handed the open transaction's delta, and it
  is internal.
- **An identity-key splitter** — kraison/vivace-graph#321.
  `claim-identity-key` renders; nothing parses. A tenant that stores
  keys and resolves them re-implements the escape rule. Small, and its
  absence means the rule lives in two places.

Neither blocks this unit; both are worked around in one fenced function
each, and the workaround is deleted when the engine lands the ask.
