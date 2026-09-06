# S6b: one memory over several stores — design

Issue: kraison/cl-llm#24 (S6b of #14). Findings: #46–#51. Engine
dependency: kraison/vivace-graph#347. Predecessors: the memory tenant
(`2026-09-01-agent-memory-tenant-design.md`), the decision trace
(`2026-09-02-decision-trace-design.md`), the agent tools
(`2026-09-03-agent-tools-design.md`). Adversarial pass:
`docs/superpowers/notes/2026-09-05-s6b-adversarial-pass/03-verified.md`.

## 1. Problem

S6a gave the agent two stores (a private one and a working one) and a
scope over them, but every reader in `cl-llm/memory` answers from one
graph. The adversarial pass verified six consequences:

| # | finding |
|---|---|
| #46 | `recall` computes `superseded-by` and `current` inside one store; two runs of one series in two stores both render current |
| #47 | `decisions-citing` unions the scope but returns bare ids; `trace` looks in one store; `trace-listing` and `annotate-banners` signal on a foreign id |
| #48 | `note-cite` last-wins against `cite-store` first-in-scope; after `recall`, `retract` refuses a claim the write store holds |
| #49 | `retrieve` keys claim documents without the store, so two stores' copies fuse into one item |
| #50 | `conclude` validates the write store only; a belief refused by the private store's history is accepted into the working store |
| #51 | `%write-evidence` dedupes on the cite alone, so two stores' copies collapse to one evidence row naming one store (resolved as a documented bound: the family's identity has no room for the store; the row names the first store in scope order) |

The engine facts that bound the fix, verified against `experiment`
3a8ca96: a read-write transaction on store A refuses every read of
store B (`cross-graph-transaction-error`, GH #53); read snapshots
compose per store with deliberately no single instant across them
(`call-with-read-snapshot`); a claim's identity key carries producer,
endpoints, relation and validity start but no store; a system clock
issues one epoch sequence to every store attached to it (GH #168), one
process per clock.

## 2. Rulings

Taken with Kevin during the brainstorm and recorded on #24.

- **One memory, trust-ordered supersession.** A scope is a list of
  stores in trust order, most trusted first. Supersession is computed
  over the whole scope, and a belief supersedes across stores only from
  a store of equal or higher trust. A lower-trust belief is listed
  beside a higher one and never marks it superseded.
- **Cites stay store-free; one resolution rule.** A cite resolves in
  the first store in scope order holding its identity. The agent's cite
  cache never overwrites. Every rendered cite carries the store it
  resolved in. `retract` on a cite whose resolved copy is not in the
  write store is refused by name. The model names subjects, never
  stores.
- **The transaction axis is the shared clock's epoch.** A multi-store
  scope requires one system clock. Decisions record their commit epoch
  from this unit on. Readers that compare instants across stores move
  from wall clock to epoch when vivace-graph#347 lands; until then they
  stay on wall clock, which is sound in one image.
- **Approach A, a scope-aware memory layer.** Every reader and
  `conclude` take `:scope`. Rejected: B, merging in the agent layer
  (the memory API would keep lying to any other caller); C, deriving
  working claims from private ones through rules S3 (a derived copy
  leaks the existence of a private belief into the working store).

## 3. Scope

A scope is a list of open graphs in trust order, most trusted first.
`cl-llm/memory` gains one validator, shared with `agent:make-scope`:

```lisp
(defun check-scope (scope &key write-store) ...)  ; -> scope
```

It signals `scope-argument-error` (a `belief-argument-error` subtype,
`:argument :scope`) when the list is empty, holds a non-graph or a
closed graph, holds one graph twice, holds two graphs with one
`store-name`, or when `write-store` is given and is not in the list.
When the scope holds more than one store, every store must answer the
same non-NIL `graph-system-clock`; a mixed or clockless multi-store
scope is refused with the offending store names in the message. A
single-store scope needs no clock.

Every reader and `conclude` take `&key (scope (list graph))`, so a
single-store caller is unchanged. `graph` stays the first positional
argument and means what it meant: the store answered from by default,
and for `conclude` the write store. `graph` must be in `scope`.

**Resolution rule.** Where an identity may be held by several stores,
the answer comes from the first store in scope order holding it, and
the answer names that store.

**Snapshot discipline.** Every scope read runs under one read snapshot
per store, nested own-store-first:

```lisp
(defun call-with-scope-snapshots (thunk scope) ...)  ; engine order
(defmacro with-scope-snapshots ((scope) &body body) ...)
```

The helper refuses, before any engine call, when `gdb:*transaction*`
is bound: a scope read inside an open write transaction would either
see the writer's own uncommitted state (the own-store half, which the
engine allows) or hit the engine's cross-graph refusal (the foreign
half). The error is `scope-argument-error` naming the mechanism. The
check applies to a single-store scope too, since the engine refuses
only the foreign half (recon C9); a scope of one store still takes its
snapshot, so the single-store path exercises the same code.

**Clock ownership.** The clock is a property of the image, not of the
store on disk: an attachment lives in memory and in the clock's
journal, and a store reopened without the clock silently resumes its
own counter from its persisted highest id, continuing the same
integers (recon C1). So `scripts/memory-image.lisp` opens one system
clock at `CL_LLM_MEMORY_CLOCK` (default `~/.cl-llm-memory/clock/`)
before its stores, holds it for the image's life, passes it on every
`make-graph`/`open-graph` (`open-graph :system-clock` attaches; no
separate `attach-to-system-clock` call), and `stop` closes the clock
after the stores. The two test fixtures do the same (section 9). A
store opened elsewhere without a clock can still be read alone; it
cannot join a multi-store scope, and `check-scope` is the only
detector, so `docs/agent-memory.md` states the rule.

## 4. `recall` over a scope

```lisp
(defun recall (graph subject &key relation producer at include-retracted
                                  (scope (list graph))) ...)
```

Under scope snapshots, `recall` collects the subject's claims from
every store, applies `relation`, `producer`, `at` and the retraction
filter per store exactly as today, then builds one series table over
the union keyed on `(producer subject-namespace subject-key relation)`.
Each record remembers its store.

- `belief-record` gains a `store` slot holding the graph.
- `superseded-by` is the earliest-starting current claim in the same
  series that starts strictly later and lives in a store no later in
  scope order than the record's own. Ties on validity start fall to the
  existing order (recorded-at, then object key).
- `current-p` is true when the claim is open in its own store and has
  no `superseded-by` under that rule.
- Ordering is the existing contract: validity start descending,
  recorded-at descending, object key ascending. `claim-before-p` is
  unchanged, and the agent's cross-store merge in `%recall-tool` goes
  away, since `recall` now returns the merged list.
- Nothing is written. A lower-trust successor never closes a
  higher-trust run, and no writer closes a run in another store.
- No "contested" standing: two current beliefs from two stores are two
  rows, each naming its store.

JSON, in `%record-json`: `"store"` is the record's own store;
`"superseded-by"` becomes an object `{"cite": ..., "store": ...}` when
present. `docs/agent-tools.md` documents both.

## 5. `conclude` with a scope

```lisp
(defun conclude (graph proposal &key producer evidence rule rule-version
                                     confidence (scope (list graph))) ...)
```

Before its transaction opens, `conclude` of a `(:belief ...)`
proposal reads the proposal's series (producer, subject, relation)
over the scope under snapshots and applies the trust rule to the
proposal as if it were recorded. An `(:absence ...)` proposal has no
series and no predecessor (`record-absence` has none), so the pre-read
does not apply and `conclude-absence` reaches `conclude` unchanged
(recon C3). For a belief:

- no prior anywhere: unchanged, the transaction opens as today;
- the prior that would govern is in the write store: unchanged, the
  write store's validator decides as today;
- the governing prior is only in a store earlier in scope order than
  the write store (higher trust): **refused**. A refusal transaction on
  the write store records the `attempted` claim and one `refused` claim
  of family `scope-conflict` whose text names the conflicting cite and
  its store, plus the evidence rows. The returned `decision` has
  `:outcome :refused` and a `report` of `(:scope-conflict cite
  store-name)`; `%violation-families` gains a third branch keyed on
  that list's head and renders exactly one `scope-conflict` row whose
  text names the cite and its store in prose, never a Lisp form
  (recon C2). Nothing is written to any other store;
- the governing prior is only in a store later in scope order (lower
  trust): the write proceeds. It supersedes the lower-trust prior at
  read time under section 4. The trace records the overridden cite as
  an evidence row with `method` = its store name, so the decision says
  what it overrode.

"The governing prior" is the current claim in the series whose
validity start is latest but not later than the proposal's start,
computed by the pre-read itself over the union of the scope's stores
and then filtered by the section 4 rule. It is not
`%current-predecessor`, which is a first-found search that is
unambiguous only inside the write store (recon C3). A proposal whose
start precedes every prior is governed by nothing and proceeds; the
write store's `belief-successor-before-predecessor` check still
applies within that store.

The scope read is advisory, like the validation report. The commit is
the enforcement, and the composed snapshots mean a concurrent writer in
another store can slip a prior in between the read and the commit; the
next `recall` shows it under the same rule. `conclude-absence` (the
tool) reaches this through `conclude` and needs no separate path.
`retract-belief` is unchanged at the memory layer.

## 6. Cites

```lisp
(defun resolve-cite (graph cite at &key (scope (list graph))) ...)
```

Under scope snapshots, the cite resolves in the first store in scope
order holding its identity, and the returned `cite-record` names that
store in `store`; `:absent` when no store holds it. `changed-since`
is computed within the resolving store, as today; a supersession that
exists only across stores shows in `recall`, not here (section 10).
The internal callers that already resolve in a named store
(`%resolve-in`, for evidence rows) keep doing so: a decision's evidence
resolves where the decision said it was.

Agent side, `note-cite` becomes first-wins: an existing entry is never
overwritten, so the cache agrees with `cite-store`'s first-in-scope
scan whatever order the tools ran in (#48). `retract` resolves the cite
through `cite-store`; when the answer is not the write store the tool
returns the existing error result naming the store and does nothing.
Every rendered cite carries its store: `recall` rows and `trace`
records already do; `retrieve` items, `decisions-citing` entries and
the evidence in `%decision-json` gain `"store"`.

The cite format is unchanged. Existing transcripts and evidence rows
stay valid.

## 7. Decisions across the scope

```lisp
(defun decisions-citing (graph claim-or-cite &key (scope (list graph)))
  ...)  ; -> list of (id . store-name), newest first
(defun trace (graph decision-id &key (scope (list graph))) ...)
(defun trace-listing (graph decision-ids &key (scope (list graph))) ...)
```

- `decisions-citing` returns `(id . store-name)` pairs in the existing
  order. The tool's JSON entries gain `"store"`.
- `trace` finds the decision's claims in the first store in scope order
  holding the id, then reconstructs as today. Evidence cites resolve in
  the store their row named, as today. A replica holding the same id is
  a documented Latent case, not handled here.
- `trace-listing` passes `scope` to `trace` and survives a NIL result
  by emitting a row with `:missing` as the outcome, so capture-and-diff
  stays deterministic. `annotate-banners` traces with the scope and
  skips an id `trace` cannot find (#47).
- One evidence row per cite per decision (#51, documented bound): the
  trace family's identity is producer, decision, relation and the cited
  cite, and excludes the `method` slot that names the store, so two
  rows for one cite differing only in store collide on the unique
  constraint (found in execution; changing the family's identity is a
  schema migration outside this unit). When a cite is cited from two
  stores, the row names the first store in the pairs list, which the
  tools build in scope order. `trace` orders evidence by cite.
- `%claim-doc-id` includes the store name as its first segment after
  `claim:`, matching `%absence-evidence` (#49). Two stores' copies are
  two retrieval items, each with its store.
- Every decision carries its commit epoch. The engine stamps every
  claim version with the id of the transaction that committed it
  (`commit-epoch`, a node-head slot; #347's recon note E1), so nothing
  new is persisted: `conclude` reads it from the outcome claim after
  the commit, and `trace` reads it from the outcome claim it finds.
  `decision` and `decision-record` gain an `epoch` slot. The number is
  comparable across stores only for decisions recorded under the
  shared clock; an older decision's epoch is the store's own counter,
  and `docs/decision-trace.md` says so. This unit needs only the
  export of `commit-epoch` from `graph-db`, which #347 delivers first.

## 8. Errors

- `scope-argument-error`: a `belief-argument-error` with `:argument
  :scope`, for every `check-scope` refusal and for a scope read inside
  an open transaction. The message names the store or mechanism.
- `scope-conflict`: a new refusal family recorded in the trace, never
  signalled. `%violation-families` renders it like a validator family.
- `agent:scope-error` keeps its role for the agent-layer shape checks
  and wraps `scope-argument-error` when `make-scope` delegates to
  `check-scope`.

## 9. Testing

Every test is red first against the single-store code and named for the
mechanism it proves.

- **Fixtures.** `tests-memory`'s existing `with-two-stores` is
  extended, not duplicated (recon C5): a third scratch directory holds
  one system clock opened before the stores and closed in an outer
  `unwind-protect` after them (a leaked clock makes every later
  `open-system-clock` in the run signal `system-clock-in-use`); both
  stores are made with `:system-clock`; the fixture asserts inside
  itself that both graphs answer one `eq` clock. `tests-agent`'s
  `with-stores` gets the same three changes. The single-store
  `with-memory-graph` is untouched.
- **Scope validation.** One test per refusal: duplicate graph, two
  graphs with one store-name, a closed graph, a write store not in the
  list, two stores on different clocks, two stores with no clock. One
  positive test for a clockless single-store scope.
- **Snapshot discipline.** A scope read inside `with-transaction` is
  refused as `scope-argument-error` before any engine call, for a
  two-store scope (the engine's cross-graph error never surfaces) and
  for a single-store scope (which the engine would have allowed, showing
  uncommitted state).
- **Trust rule, both directions (#46).** One series split across
  stores. Newer belief in the higher-trust store: the older row has
  `superseded-by` naming the successor and its store and is not current.
  Newer belief in the lower-trust store: both rows current, nothing
  superseded. The reversed scope order is the control.
- **Conclude (#50).** Higher-trust prior: refused with `scope-conflict`
  naming cite and store, nothing new in either store. Lower-trust prior:
  concluded, the trace's evidence carries the overridden cite and its
  store. Write-store prior: the validator path, unchanged.
- **Cites (#48).** `resolve-cite` first-in-scope; after `recall` over
  both stores the cache still names the first store; `retract` refused
  by name when the copy is not writable and succeeds when it is.
- **Decisions (#47, #51, #49).** `decisions-citing` returns the pair
  and the tool's JSON carries `"store"`; `trace-listing` and
  `annotate-banners` handle a decision in the private store; one cite
  in two stores gives two evidence rows; two copies give two `retrieve`
  items with distinct ids.
- **Epoch.** Two concludes on two stores under one clock record integer
  epochs in increasing order. As-of-epoch reads are tested by the unit
  that consumes #347, not here.
- **Runs.** The memory and agent suites in this worktree, foreground,
  one at a time, check counts recorded in the SDD ledger; CI's `test`
  workflow on the PR.

## 10. Out of scope

- **Epoch-bounded reads.** As-of and changed-since stay on wall clock
  until #347 lands; this unit only records the epoch. Two axes never
  coexist in one reader.
- **Cross-store `changed-since`.** A cite's `changed-since` compares
  two versions in one store. Reporting a supersession from another
  store is an as-of question, and as-of moves to the epoch axis with
  #347; it is redefined once, there, not twice.
- **Cross-process scope.** A scope is open graphs in one image on one
  clock. Stores held by two images are the blackboard's question.
- **Derivation between stores.** No rules-S3 derivation from private
  to working; it would leak private existence.
- **A "contested" standing.** Two current rows from two stores are
  shown with their stores; the reader decides.
- **Writes to any store but the write store.** Promotion from working
  to private is an operator action.
- **A cite format change.** The store sits beside the cite in output,
  never inside it.
- **Mixed-clock tolerance.** Refused, not degraded to wall clock.
- **Replica de-duplication in `trace`.** First-in-scope, documented as
  Latent.
- **Migration of old records.** Old decisions keep a NIL epoch; nothing
  rewrites the real store.

## 11. Files

| file | change |
|---|---|
| `memory/scope.lisp` (new) | `check-scope`, `scope-argument-error`, `call-with-scope-snapshots`, `with-scope-snapshots` |
| `memory/recall.lisp` | `:scope`, union series table, trust rule, `store` slot |
| `memory/trace.lisp` | `:scope` on `conclude`, pre-read and `scope-conflict`; `decisions-citing` pairs; `trace` first-in-scope; `trace-listing` NIL-safe; `%write-evidence` key; `epoch` slots |
| `memory/cite.lisp` | `resolve-cite &key scope`; `%changed-since` is already per resolving store |
| `memory/packages.lisp` | exports |
| `agent/scope.lisp` | `make-scope` delegates to `check-scope`; `note-cite` first-wins |
| `agent/memory-tools.lisp` | drop the local merge; pass scope; `"store"` on decisions and evidence |
| `agent/annotate.lisp` | scope-aware trace, skip missing |
| `agent/render.lisp` | `"superseded-by"` object |
| `claims/source.lisp` | `%claim-doc-id claim source` with the source graph's downcased name, as `%absence-evidence` already does (`cl-llm/claims` cannot see `mem:store-name`) |
| `scripts/memory-image.lisp` | open the clock first, pass it on every open, close it last |
| `tests-memory/harness.lisp`, `tests-agent/harness.lisp` | clocked fixtures |
| `docs/agent-memory.md`, `docs/agent-tools.md` | scope, trust rule, JSON fields, refusal family, clock as a property of the image, the epoch field (the trace surface is documented in agent-tools.md; there is no decision-trace doc) |

## 12. Sequencing

1. vivace-graph#347 recon note, then its bounded design and PR against
   `experiment`.
2. This unit's plan (writing-plans), executed on
   `feat/s6b-adversarial-pass` or a branch from it, against an
   `experiment` that exports `commit-epoch`.
3. `docs/agent-memory.md` documents which readers still compare wall
   clock across stores and cites #347 as the follow-up.
