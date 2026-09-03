# The agent tool surface — design (cl-llm #14, S6a unit 2)

**Unit 2 of three under the single-namespace capstone S6a** (`#14`;
programme `#15`). Unit 1, the decision trace, landed as PR #31
(`2026-09-02-decision-trace-design.md`). This unit is the surface a
language model reaches that record through: the memory reads and
writes, the retrieval planner's internals, and a bounded free-text
Prolog query — every write a validated decision, every read bounded,
and the **scope** of what a session can see set by the operator, never
by the model. Unit 3, the dogfood banner round-trip, follows. Approved
in chat 2026-09-03; the scope model was decided the same day (§2).

Engine: vivace-graph `experiment` HEAD, unpinned (decided 2026-09-01 on
`#15`); this design was made against `73ad4e2`.

## 1. What this is

The capstone's own words: *"LLM-directed traversal — the agent tool
surface over the retrieval layer's planner internals. It lands here
and only here, behind the constraint validator."* And its acceptance:
*"Traversal is bounded — resource limits and effect policy — and every
tool call is validated before its side effect."*

Concretely, a set of cl-llm **tools** — Lisp closures the model calls
in-process through the existing tool loop — over a **scope** of
`cl-llm/memory` stores:

- **reads**: recall a subject's beliefs, read a decision's trace, find
  the decisions resting on a claim — across every store in scope;
- **the only writes**: `conclude` and `conclude-absence`, which are
  unit 1's `conclude` and therefore validate the write set before
  commit and record a refusal structurally; and `retract` — all into
  the one store the scope names as writable;
- **the planner**: `retrieve`, which fuses the claim sources of the
  scope with any sources the operator supplies under a derived or
  supplied window, and `plan-bounds`, the derivation on its own;
- **traversal**: `query`, free-text Prolog through the engine's guard
  pipeline with effects off and budgets the operator sets, against one
  named store of the scope.

The model chooses arguments; the operator sets every bound and the
scope at construction. Nothing here needs a map, and nothing names a
tenant.

## 2. One memory, partitioned by trust

Decided 2026-09-03 (discussion on this unit). A user runs one model
across coding, business, research and writing; the memory should be
**one**, reachable from any session, and the question is what a
separate store is *for*. Four needs hide under "separate graphs":
relevance at recall, trust against untrusted input, operations
(backup, retention, sharing), and consistency across a decision's
evidence. Topic-per-store serves only the first and damages the rest;
the record already serves the first.

- **Topic is the subject namespace**, not the container. A belief is
  `(namespace . key)` subject, relation, standing, validity, producer;
  recall is by subject, so a question about one subject pulls its code
  facts and its business facts together, and a question scoped to
  `(:repo . "cl-llm")` never sees `(:client . "acme")`. A taxonomy of
  stores chosen at write time by the model — the party with the least
  context — fails silently: a memory filed in the wrong store reads as
  absent. The precedent is close to home: a memory store keyed on the
  working directory forked silently when a path was symlinked.
- **Trust is the boundary the container carries**, because the tool
  set can enforce it and the model cannot. A session that reads
  untrusted input (a public repo, a scraped page, inbound mail) is a
  lateral-movement path for injected instructions; its tools are
  constructed without the private store in scope, so there is nothing
  to reach. Two stores will do for a long time: **private** (people,
  finances, business) and **working** (code, research, anything that
  touches external input); a third appears only when a real boundary
  does, such as memory shared with another person.
- **Scope is the operator's, at construction**, exactly like every
  bound: a list of readable stores and exactly one writable store.
  Reads span the scope; writes land in one place. The model names
  subjects, never stores.
- **The engine's promises match that split.** A class is instantiable
  in any store (kraison/vivace-graph#167); one epoch across stores is
  done (kraison/vivace-graph#94), so cross-store *reads* at one instant
  are S6b's job (`#24`) and not far; cross-store *writes* need the
  deferred two-phase commit (kraison/vivace-graph#93), which is why a
  tool set writes to one store only.

**An engine fact that shapes the implementation**, verified in a
subprocess on 2026-09-03: `def-claim-classes` declares a family's
indexes and uniqueness constraint under the graph name it is given, so
a second store needs the families **declared under its own name** —
`(def-claim-classes belief :memory-private :temporal t)` beside the
existing `:cl-llm-memory` declaration — after which recall, `conclude`,
`trace` and the validators all work there and the first store is
untouched. Declaring a class twice with identical slots is the engine's
supported feature (kraison/vivace-graph#196), at the cost of two
`redefining GDB:SAVE :BEFORE` style warnings per declaration.

## 3. The surface used

| Need | Where | Notes |
|---|---|---|
| tool objects, the tool loop, JSON | `cl-llm` core: `tool`, `call-tool`, `run-tool-loop`, `*max-tool-turns*`, `cl-llm.json` | one addition, §4 |
| beliefs and decisions | `cl-llm/memory`: `recall`, `conclude`, `retract-belief`, `trace`, `decisions-citing`, `claim-cite`, `split-cite`, `resolve-cite` | unit 1, amended in §4 |
| the planner | `cl-llm/rag`: `fuse`, `plan-bounds`, `temporal-bound`, `spatial-bound`, `bounds`, `evidence` | `#13` units 1–2 |
| claims as evidence | `cl-llm/rag/claims`: `make-claim-source` | `#13` unit 3, one source per store in scope |
| a scripted model for tests | `cl-llm` core: `make-mock-provider`, `make-tool-use-part`, `response` | no network |
| a node's home store | `graph-db::resolve-node-graph` | **internal**, fenced, §4 |
| guarded Prolog | `graph-db/gui`: the `#279` pipeline (`%make-scratch-package`, `%guard-context`, `%read-guarded-forms`) and `graph-db::run-query-goals` | **internal**, §8, kraison/vivace-graph#322 |

Two facts that shape it. **The guard lives in the web stack.** The
character screen, the throwaway-package reader and the whitelist walk
are in `graph-db/gui`, which depends on ningle, clack and cl-json; the
JSON query DSL is in the full `graph-db` system for one ndjson header
line. `cl-llm` depends on `graph-db/core` and `graph-db/spacetime` only
(`#23`), and the guard is security-critical, so it is neither copied
nor loaded into the main agent system. **Tool results are strings.**
`execute-tool-call` sends `princ-to-string` of a tool's value back to
the model, so every tool here returns a JSON string, and a cite the
model reads in one result is the exact string it passes back in the
next.

## 4. Systems, layering, and three amendments to unit 1

```
cl-llm  (+ make-tool)
  |- cl-llm/memory        graph-db/spacetime   (unit 1, + define-memory-store,
  |                                             evidence store, trace scope)
  |- cl-llm/rag/claims    cl-llm/rag           (#13)
  |- cl-llm/agent         memory + rag/claims + core   NEW  agent/
       |- cl-llm/agent/prolog   + graph-db/gui         NEW  agent/prolog/
```

- **`cl-llm/agent`**, package `cl-llm.agent`, directory `agent/`.
  Depends on `cl-llm`, `cl-llm/memory`, `cl-llm/rag/claims`. No web
  stack.
- **`cl-llm/agent/prolog`**, package `cl-llm.agent.prolog`, directory
  `agent/prolog/`. Depends on `cl-llm/agent` and `graph-db/gui`. One
  function, `%guarded-rows`, holds every internal engine symbol with
  kraison/vivace-graph#322 beside it; it is deleted when the engine
  exports a guarded runner.
- **Core gains `make-tool`**:
  `(make-tool name description parameters function) => tool`, where
  `parameters` is a `deftool` lambda list. `deftool`'s expansion and
  `cl-llm/rag`'s `make-retrieval-tool` are rewritten on it, so a closure
  tool stops reaching into `derive-schema` and `parameter-spec-of`.

Three amendments to `cl-llm/memory`, each small and each needed by the
scope model:

1. **`define-memory-store`.** `(define-memory-store graph-name)` is a
   macro expanding to the three declarations `memory/schema.lisp` makes
   today — the `belief` family (temporal), the `trace` family and the
   `memory-note` source — under `graph-name`. `schema.lisp` becomes
   `(define-memory-store :cl-llm-memory)`; an operator declares
   `(define-memory-store :memory-private)` for each further store. The
   families' class names are shared, which is the engine's model
   (§2). Because DEF-CLAIM-CLASSES interns each family's derived
   class names into `*PACKAGE*`, the macro expands those declarations
   under `cl-llm.memory`'s own package rather than the caller's --
   else a further store declared from another package mints
   duplicate classes (kraison/vivace-graph#323).
2. **Evidence records its store.** An `evidence` trace claim's `method`
   slot — unused by unit 1 — carries the **name of the store the cited
   claim was found in**, as a string. `conclude`'s `evidence` accepts a
   cite string (store = the write graph), a `(cite . store-name)` pair,
   or a claim (store resolved through `graph-db::resolve-node-graph`,
   fenced in `%claim-store`). A decision in the working store that
   rests on private evidence says so on every cite.
3. **`trace` and `decisions-citing` take a scope.**
   `(trace graph id &key (scope (list graph)))` resolves each cite in
   the store its evidence claim names when that store is in `scope`,
   else reports it `:absent`; a cite whose evidence claim names no
   store (unit 1 data) is resolved in `graph`. `decisions-citing` gains
   the same `scope` and unions the answers, newest first. Unit 1's
   golden is unchanged: the listing carries no store names.

Boundary rules: nothing below `cl-llm` needs a model; `cl-llm/memory`
stays graph-only; the tenant's vocabulary (namespaces, relations) is
the model's to supply, never this system's to know.

## 5. Construction and scope

```lisp
(make-agent-tools stores &key write-store producer sources
                              (k 5) (max-rows 50))
  ;; STORES: the readable graphs, in scope order; WRITE-STORE: one of
  ;; them (default the first).  => a list of TOOLs: recall trace
  ;; decisions-citing conclude conclude-absence retract retrieve
  ;; plan-bounds
(make-query-tool stores &key (max-rows 50) (max-inferences 100000)
                             (timeout 5))
  ;; => the QUERY tool                       (cl-llm/agent/prolog)
```

`stores` are open graphs, each declared with `define-memory-store`;
`write-store` must be one of them. `producer` is required and canonical
(`"<agent>/<host>"`); every decision the model makes is written under
it. `sources` are `collect-evidence` sources the operator adds to the
planner beside the scope's claim sources, such as a dense index over
the same corpus. `k` and `max-rows` cap what a call may ask for; a
larger request is clamped, never refused, and the result says
`truncated`, which for every tool here is true when more items existed
past the cap — never merely that the page filled it. The tools close
over the scope: several scopes in one
image are several tool sets, and a test builds its own over its own
on-disk stores.

Tool and parameter names are hyphenated, as the existing tools are.
Endpoints are **two string parameters**, a namespace and a key, so no
encoding exists for the model to get wrong; `retrieve`'s optional
endpoint list is the one place a `"namespace:key"` string appears,
split at the first colon because namespaces are canonical `[a-z0-9-]`.
Store names cross as the graph name's lowercase string (`"memory-
private"`). Timestamps cross as RFC 3339 strings; standings as their
keyword names without the colon. A field whose value is null is
omitted from every result object rather than rendered as JSON `null`,
the two exceptions being `truncated` and `current`, always-present
booleans; the `query` tool's row cells are the one place an actual
JSON `null` appears, because a row is a fixed-width tuple.

## 6. The memory tools

| tool | parameters | returns |
|---|---|---|
| `recall` | `subject-namespace`, `subject-key`; optional `relation`, `at` | `{"records": [...], "truncated": bool}`; each record: `store`, `cite`, `relation`, `object` `{namespace, key}` or null for an absence, `standing`, `valid-from`, `valid-to` or null, `current`, `superseded-by` cite or null |
| `trace` | `decision-id` | `{id, store, producer, at, rule, rule-version, confidence, outcome, conclusion, evidence, refusals}`; `conclusion` and each `evidence` item: `{store, cite, state, changed-since, standing, valid-from, valid-to}`; `refusals`: `[{family, text}]` |
| `decisions-citing` | `cite` | `{"decisions": [{id, store} ...]}`, newest first |
| `conclude` | `subject-namespace`, `subject-key`, `relation`, `object-namespace`, `object-key`, `rule`; optional `evidence` (list of cites), `standing` ∈ inferred/observed/asserted (default inferred), `confidence`, `rule-version`, `valid-from` | `{id, store, outcome, claim-cite or null, refusals}` |
| `conclude-absence` | `subject-namespace`, `subject-key`, `relation`, `rule`, `standing` ∈ searched-empty/indeterminate/uncovered; optional `evidence`, `rule-version` | same shape |
| `retract` | `cite` | `{cite, store, retracted-at}` |

Reads run over every store in scope, in scope order, and each record
names its `store`. `recall` merges the stores' answers under unit 1's
order rule, ties broken by scope order. `trace` finds the decision in
whichever store holds it — ids are random and unique — and resolves
its cites with the whole scope (§4.3); each evidence item's `store` is
the one it was *resolved against*, the store its own evidence claim
named, so a belief held identically by two stores still reports the
half this decision cited. `decisions-citing` unions the stores.

`conclude` and `conclude-absence` write to `write-store` only, through
unit 1's `conclude`; they inherit its own transaction, its
`validate-writes` pass and its structural refusal. A cite the model
passes as evidence is paired with the store it was found in: the tool
keeps the `cite → store` map from the results it has returned in this
tool set's lifetime, and a cite it has never returned is resolved by
searching the scope, first hit wins. **A refusal is a result, not an
error**: the model must read which family refused and why, so
`outcome` is `"refused"` and `refusals` is populated. A malformed
argument — an unknown decision id, a cite that does not parse, a bad
timestamp, a non-canonical relation — signals, and the existing
`call-tool` turns that into an error result the model also sees. The
tools catch nothing themselves.

`retract` resolves its cite across the scope; a claim found in a store
other than `write-store` is an error result ("not writable in this
scope"), since retraction is a write. A cite that resolves to nothing,
or to an already-retracted claim, is an error result. So is a cite from
any family but `belief`: a `trace` cite names a decision's own record,
which the query tool makes visible, and neither the tool nor
`retract-belief` will close one.

Absence is not a value: an empty `records` array is "nothing recorded";
an absence the agent once wrote is a record with a null `object` and an
absence standing. `recall` excludes retracted beliefs, as unit 1's
`recall` does by default.

## 7. The planner tools

`retrieve` (`query`; optional `endpoints`, `from`, `to`, `k`) runs
`fuse` over one belief claim source per store in scope plus the
operator's `sources`. Each claim source's key-extractor returns exactly
the `endpoints` the model named, so the tenant's vocabulary stays with
the caller (programme §5.1). `from`/`to` become the planner's window
with `:asserted` standing; absent, the window is derived from the seed
evidence through `plan-bounds` and applied, so a second call inside the
derived window is one round trip away. The result:

```
{"query": ..., "modes": [...],
 "bounds": {"window": {"from", "to", "standing"},
            "box": [minlon, minlat, maxlon, maxlat] or null,
            "box-standing"},
 "evidence": [{"method", "source", "store" or null, "text",
               "cite" or null, "standing", "confidence",
               "valid-from", "valid-to"}],
 "truncated": bool}
```

in bundle order, which is the contract. `source` is omitted for an
item from one of the scope's claim sources — `store` and `cite` say
where that one came from — and is the operator source's class name
otherwise. `plan-bounds` (`query`;
optional `endpoints`, `k`) returns the `bounds` object alone, from a
seed retrieval: the derivation as a callable, which `#13` unit 2 built
as separate operations for exactly this.

## 8. The query tool

`query` (`text`; optional `store`, `limit`) runs the `#279` pipeline
verbatim against one store of the scope — `store` names it, default
the first — because a Prolog query runs against one graph. The
pipeline: the character screen, the reader under `*read-eval*` NIL in a
per-call scratch package, the whitelist walk against that store's own
schema, then `run-query-goals` with the guard's package, effects off,
one snapshot, and `max-inferences`/`timeout` bound around the call to
the construction values. Rows return as

```
{"store": ..., "columns": [...], "rows": [[...] ...], "truncated": bool}
```

with `limit` clamped to `max-rows` and one probe row past the cap deciding
`truncated`, the GUI's own rule. Every refusal reaches the model as an error
result carrying the guard's reason text — those reasons were written to be
client-facing — and so do a resource bound and a permission refusal. A
`store` outside the scope is an error result. A store that declares edge
types is refused up front, pending kraison/vivace-graph#322. Because the
whitelist enumerates the store's schema types, the model can walk `belief`
and `trace` vertices with the generic predicates and no tenant code.

All of it lives in `%guarded-rows`, the one function allowed to name
`graph-db.gui::` and `graph-db::` symbols, and its docstring cites
kraison/vivace-graph#322, the ask for an exported
`run-guarded-prolog` in a web-free subsystem. When that lands, the
function body becomes one call and the system's dependency drops to
`graph-db/query`.

## 9. Bounds and errors

- Every bound is the operator's, set at construction: the scope, `k`,
  `max-rows`, the Prolog budgets, and the loop's `*max-tool-turns*`
  from core. A model argument above a cap is clamped and the result
  says so.
- `conclude` and `conclude-absence` are the only writes that create
  claims, each a decision into one store: no bare `record-belief` tool
  exists, and `conclude` validates before it commits. `retract` closes
  a belief's transaction period and only a belief's — a trace claim is
  a decision's own record, refused by the tool and by
  `retract-belief` itself.
- Errors never cross as Lisp conditions: `call-tool` wraps every signal
  into an `is_error` tool result. The one thing that is data rather
  than an error is a refused decision.
- The query tool's effect policy is `()` — reads and pure logic only —
  and a goal naming a cost-unbounded functor is refused up front by the
  engine when a budget is in effect (kraison/vivace-graph#285).

## 10. Testing

`tests-agent/` (`cl-llm/agent/tests`) and `tests-agent-prolog/`
(`cl-llm/agent/prolog/tests`), on real on-disk stores as
`tests-memory` opens them — **two** of them, `:cl-llm-memory` and a
second declared with `define-memory-store` in the test package — the
model scripted with `make-mock-provider` returning `response`s whose
content is `tool-use-part`s, so a whole loop runs deterministically
with no network. Both wired into `test.yml` with the `:in-order-to`
test-op link (`docs/ci.md`). `tests-memory` gains the amendment tests.

- **Unit 1 amendments.** `define-memory-store` on a second name makes
  the families queryable there and the first store untouched; an
  evidence claim records its store; `trace` with a scope resolves a
  cross-store cite and reports `:absent` when the store is out of
  scope.
- **Each tool directly.** Call each tool's function with the arguments
  the model would send and parse the JSON back: shapes, cites, stores,
  order.
- **Scope.** A belief in the private store is recalled when private is
  in scope and invisible when it is not; a conclude in the working
  store citing a private cite records `store` on its evidence and
  `trace` shows it; `retract` on a read-only store is an error result.
- **A scripted loop.** Turn 1 the model calls `recall`; turn 2 it calls
  `conclude` citing what it read; turn 3 it answers. Assert the
  decision exists in the write store and its evidence cites equal the
  recall result's cites byte for byte.
- **Refusal is data.** A conclude the validator refuses returns
  `outcome` refused with the family, and no belief is written.
- **Caps.** A `k` or `limit` above the construction cap is clamped, and
  `truncated` is true when more items existed past the cap — for every
  tool, `recall`, `retrieve` and `query` alike. A page that exactly
  fills the cap with nothing behind it is not truncated; a control
  pins that. A non-positive `k` or `max-rows` at construction is a
  `scope-error`.
- **Errors reach the model.** A malformed timestamp and an unknown
  decision id arrive as `is_error` results in the next request body,
  not as escaped conditions.
- **Query.** A guarded query over beliefs returns rows; `#.` in the
  text is refused with the guard's reason; a write functor is refused
  by the effect policy; a query past the inference budget reports a
  resource error; `limit` past `max-rows` is clamped; a store outside
  the scope is an error result.
- **Order.** `recall` records in unit 1's order across stores;
  `retrieve` evidence in bundle order; both pinned.

No performance figure is claimed.

## 11. Docs

`docs/agent-tools.md` (the user's view: the scope model in a page,
every tool with its parameters and result shape, and a scripted
example); a README section; `docs/agent-memory.md` gains
`define-memory-store` and the evidence-store amendment, and its "What
this is not" paragraph stops naming the tool surface as this issue's.

## 12. Acceptance

From `#14`: LLM-directed traversal lands here, behind the validator —
the planner's internals and a guarded query are callable by a model;
traversal is bounded by resource limits and effect policy; every tool
call with a side effect is validated first, because the only writes
are decisions. From §2: a session's scope is the operator's; a cite
crossing stores is visible as such in the trace.

Not delivered: the banner round-trip (unit 3); cross-store recall at
one consistent instant (`#24`, S6b — reads here are per store, merged);
inference over claims (kraison/vivace-graph#304).

## 13. Engine asks

- kraison/vivace-graph#322 — export `run-guarded-prolog` returning rows
  and home it with the query DSL in a web-free subsystem. Non-blocking:
  `cl-llm/agent/prolog` depends on `graph-db/gui` until then.
- Three things to mention on the engine side when this lands, not worth
  their own issues yet: `resolve-node-graph` is the only way from a
  node to its store and is internal; the `graph-db::graph` class is
  unexported and `graph-p` with it, so "is this an open graph?" is
  fenced in `%graph-p` (`agent/scope.lisp`) for `make-scope`'s check;
  and a second `def-claim-classes` for another store re-emits the
  family's `save :before` method with a redefinition warning.
