# The agent tool surface — design (cl-llm #14, S6a unit 2)

**Unit 2 of three under the single-namespace capstone S6a** (`#14`;
programme `#15`). Unit 1, the decision trace, landed as PR #31
(`2026-09-02-decision-trace-design.md`). This unit is the surface a
language model reaches that record through: the memory reads and
writes, the retrieval planner's internals, and a bounded free-text
Prolog query — every write a validated decision, every read bounded.
Unit 3, the dogfood banner round-trip, follows. Approved in chat
2026-09-03.

Engine: vivace-graph `experiment` HEAD, unpinned (decided 2026-09-01 on
`#15`); this design was made against `73ad4e2`.

## 1. What this is

The capstone's own words: *"LLM-directed traversal — the agent tool
surface over the retrieval layer's planner internals. It lands here
and only here, behind the constraint validator."* And its acceptance:
*"Traversal is bounded — resource limits and effect policy — and every
tool call is validated before its side effect."*

Concretely, a set of cl-llm **tools** — Lisp closures the model calls
in-process through the existing tool loop — over one `cl-llm/memory`
graph:

- **reads**: recall a subject's beliefs, read a decision's trace,
  find the decisions resting on a claim;
- **the only writes**: `conclude` and `conclude-absence`, which are
  unit 1's `conclude` and therefore validate the write set before
  commit and record a refusal structurally; and `retract`;
- **the planner**: `retrieve`, which fuses the claim source with any
  sources the operator supplies under a derived or supplied window,
  and `plan-bounds`, the derivation on its own;
- **traversal**: `query`, free-text Prolog through the engine's guard
  pipeline with effects off and budgets the operator sets.

The model chooses arguments; the operator sets every bound at
construction. Nothing here needs a map, and nothing names a tenant.

## 2. The surface used

| Need | Where | Notes |
|---|---|---|
| tool objects, the tool loop, JSON | `cl-llm` core: `tool`, `call-tool`, `run-tool-loop`, `*max-tool-turns*`, `cl-llm.json` | one addition, §3 |
| beliefs and decisions | `cl-llm/memory`: `recall`, `conclude`, `retract-belief`, `trace`, `decisions-citing`, `claim-cite`, `split-cite`, `resolve-cite` | unit 1 |
| the planner | `cl-llm/rag`: `fuse`, `plan-bounds`, `temporal-bound`, `spatial-bound`, `bounds`, `evidence` | `#13` units 1–2 |
| claims as evidence | `cl-llm/rag/claims`: `make-claim-source` | `#13` unit 3 |
| a scripted model for tests | `cl-llm` core: `make-mock-provider`, `make-tool-use-part`, `response` | no network |
| guarded Prolog | `graph-db/gui`: the `#279` pipeline (`%make-scratch-package`, `%guard-context`, `%read-guarded-forms`) and `graph-db::run-query-goals` | **internal**, §7, kraison/vivace-graph#322 |

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

## 3. Systems and layering

```
cl-llm  (+ make-tool)
  |- cl-llm/memory        graph-db/spacetime          (unit 1)
  |- cl-llm/rag/claims    cl-llm/rag                  (#13)
  |- cl-llm/agent         memory + rag/claims + core  NEW  agent/
       |- cl-llm/agent/prolog   + graph-db/gui        NEW  agent/prolog/
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

Boundary rules: nothing below `cl-llm` needs a model; `cl-llm/memory`
stays graph-only; the tenant's vocabulary (namespaces, relations) is
the model's to supply, never this system's to know.

## 4. Construction

```lisp
(make-agent-tools graph &key producer sources (k 5) (max-rows 50))
  ;; => a list of TOOLs: recall trace decisions-citing conclude
  ;;    conclude-absence retract retrieve plan-bounds
(make-query-tool graph &key (max-rows 50) (max-inferences 100000)
                            (timeout 5))
  ;; => the QUERY tool                       (cl-llm/agent/prolog)
```

`producer` is required and canonical (`"<agent>/<host>"`); every
decision the model makes is written under it. `sources` are
`collect-evidence` sources the operator adds to the planner beside the
belief claim source, such as a dense index over the same corpus; the
claim source is always present. `k` and `max-rows` cap what a call may
ask for; a larger request is clamped, never refused, and the result
says `truncated`. The tools close over the graph: several graphs in one
image are several tool sets, and a test builds its own over its own
on-disk graph.

Tool and parameter names are hyphenated, as the existing tools are.
Endpoints are **two string parameters**, a namespace and a key, so no
encoding exists for the model to get wrong; `retrieve`'s optional
endpoint list is the one place a `"namespace:key"` string appears,
split at the first colon because namespaces are canonical `[a-z0-9-]`.
Timestamps cross as RFC 3339 strings; standings as their keyword names
without the colon.

## 5. The memory tools

| tool | parameters | returns |
|---|---|---|
| `recall` | `subject-namespace`, `subject-key`; optional `relation`, `at` | `{"records": [...], "truncated": bool}`; each record: `cite`, `relation`, `object` `{namespace, key}` or null for an absence, `standing`, `valid-from`, `valid-to` or null, `current`, `superseded-by` cite or null |
| `trace` | `decision-id` | `{id, producer, at, rule, rule-version, confidence, outcome, conclusion, evidence, refusals}`; `conclusion` and each `evidence` item: `{cite, state, changed-since, standing, valid-from, valid-to}`; `refusals`: `[{family, text}]` |
| `decisions-citing` | `cite` | `{"decisions": [id ...]}`, newest first |
| `conclude` | `subject-namespace`, `subject-key`, `relation`, `object-namespace`, `object-key`, `rule`; optional `evidence` (list of cites), `standing` ∈ inferred/observed/asserted (default inferred), `confidence`, `rule-version`, `valid-from` | `{id, outcome, claim-cite or null, refusals}` |
| `conclude-absence` | `subject-namespace`, `subject-key`, `relation`, `rule`, `standing` ∈ searched-empty/indeterminate/uncovered; optional `evidence`, `rule-version` | same shape |
| `retract` | `cite` | `{cite, retracted-at}` |

`conclude` and `conclude-absence` are unit 1's `conclude` with a
`:belief` or `:absence` proposal; they inherit its own transaction, its
`validate-writes` pass and its structural refusal. **A refusal is a
result, not an error**: the model must read which family refused and
why, so `outcome` is `"refused"` and `refusals` is populated. A
malformed argument — an unknown decision id, a cite that does not
parse, a bad timestamp, a non-canonical relation — signals, and the
existing `call-tool` turns that into an error result the model also
sees. The tools catch nothing themselves.

`retract` resolves its cite through `split-cite` and the subject's
claims, then `retract-belief` inside a transaction the tool opens. A
cite that resolves to nothing, or to an already-retracted claim, is an
error result.

Absence is not a value: an empty `records` array is "nothing recorded";
an absence the agent once wrote is a record with a null `object` and an
absence standing. `recall` excludes retracted beliefs, as unit 1's
`recall` does by default.

## 6. The planner tools

`retrieve` (`query`; optional `endpoints`, `from`, `to`, `k`) runs
`fuse` over the belief claim source plus the operator's `sources`. The
claim source's key-extractor returns exactly the `endpoints` the model
named, so the tenant's vocabulary stays with the caller (programme
§5.1). `from`/`to` become the planner's window with `:asserted`
standing; absent, the window is derived from the seed evidence through
`plan-bounds` and applied, so a second call inside the derived window
is one round trip away. The result:

```
{"query": ..., "modes": [...],
 "bounds": {"window": {"from", "to", "standing"},
            "box": [minlon, minlat, maxlon, maxlat] or null,
            "box-standing"},
 "evidence": [{"method", "source", "text", "cite" or null,
               "standing", "confidence", "valid-from", "valid-to"}],
 "truncated": bool}
```

in bundle order, which is the contract. `plan-bounds` (`query`;
optional `k`) returns the `bounds` object alone, from a seed retrieval:
the derivation as a callable, which `#13` unit 2 built as separate
operations for exactly this.

## 7. The query tool

`query` (`text`; optional `limit`) runs the `#279` pipeline verbatim —
the character screen, the reader under `*read-eval*` NIL in a
per-call scratch package, the whitelist walk against the graph's own
schema — and then `run-query-goals` with the guard's package, effects
off, one snapshot, and `max-inferences`/`timeout` bound around the call
to the construction values. Rows return as

```
{"columns": [...], "rows": [[...] ...], "truncated": bool}
```

with `limit` clamped to `max-rows` and one probe row past the cap
deciding `truncated`, the GUI's own rule. Every refusal reaches the
model as an error result carrying the guard's reason text — those
reasons were written to be client-facing — and so do a resource bound
and a permission refusal. Because the whitelist enumerates the graph's
schema types, the model can walk `belief` and `trace` vertices with the
generic predicates and no tenant code.

All of it lives in `%guarded-rows`, the one function allowed to name
`graph-db.gui::` and `graph-db::` symbols, and its docstring cites
kraison/vivace-graph#322, the ask for an exported
`run-guarded-prolog` in a web-free subsystem. When that lands, the
function body becomes one call and the system's dependency drops to
`graph-db/query`.

## 8. Bounds and errors

- Every bound is the operator's, set at construction: `k`,
  `max-rows`, the Prolog budgets, and the loop's `*max-tool-turns*`
  from core. A model argument above a cap is clamped and the result
  says so.
- Every write is a decision: no bare `record-belief` tool exists, and
  `conclude` validates before it commits.
- Errors never cross as Lisp conditions: `call-tool` wraps every signal
  into an `is_error` tool result. The one thing that is data rather
  than an error is a refused decision.
- The query tool's effect policy is `()` — reads and pure logic only —
  and a goal naming a cost-unbounded functor is refused up front by the
  engine when a budget is in effect (kraison/vivace-graph#285).

## 9. Testing

`tests-agent/` (`cl-llm/agent/tests`) and `tests-agent-prolog/`
(`cl-llm/agent/prolog/tests`), both on the real on-disk graph
`tests-memory` opens, the model scripted with `make-mock-provider`
returning `response`s whose content is `tool-use-part`s, so a whole
loop runs deterministically with no network. Both wired into `test.yml`
with the `:in-order-to` test-op link (`docs/ci.md`).

- **Each tool directly.** Call each tool's function with the arguments
  the model would send and parse the JSON back: shapes, cites, order.
- **A scripted loop.** Turn 1 the model calls `recall`; turn 2 it calls
  `conclude` citing what it read; turn 3 it answers. Assert the
  decision exists and its evidence cites equal the recall result's
  cites byte for byte.
- **Refusal is data.** A conclude the validator refuses returns
  `outcome` refused with the family, and no belief is written.
- **Caps.** A `k` or `limit` above the construction cap is clamped and
  `truncated` is set when more existed.
- **Errors reach the model.** A malformed timestamp and an unknown
  decision id arrive as `is_error` results in the next request body,
  not as escaped conditions.
- **Query.** A guarded query over beliefs returns rows; `#.` in the
  text is refused with the guard's reason; a write functor is refused
  by the effect policy; a query past the inference budget reports a
  resource error; `limit` past `max-rows` is clamped.
- **Order.** `recall` records in unit 1's order; `retrieve` evidence in
  bundle order; both pinned.

No performance figure is claimed.

## 10. Docs

`docs/agent-tools.md` (the user's view, every tool with its
parameters and result shape and a scripted example); a README
section; a pointer from `docs/agent-memory.md`'s "What this is not"
paragraph, which currently says the tool surface is this issue's.

## 11. Acceptance

From `#14`: LLM-directed traversal lands here, behind the validator —
the planner's internals and a guarded query are callable by a model;
traversal is bounded by resource limits and effect policy; every tool
call with a side effect is validated first, because the only writes
are decisions.

Not delivered: the banner round-trip (unit 3); cross-namespace
recall (`#24`); inference over claims (kraison/vivace-graph#304).

## 12. Engine ask filed

kraison/vivace-graph#322 — export `run-guarded-prolog` returning rows
and home it with the query DSL in a web-free subsystem. Non-blocking:
`cl-llm/agent/prolog` depends on `graph-db/gui` until then.
