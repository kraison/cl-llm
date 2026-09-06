# Memory taxonomy and a live retrieve query: design

**Issue:** kraison/cl-llm#64. **Engine prerequisites:** kraison/vivace-graph#351
(guarded query gaps, this unit) and kraison/vivace-graph#350 (vocabulary
index, the successor to §1's walk, not a blocker).
**Date:** 2026-09-06. **Status:** approved in review, sections 1–5.

## 0. Problem

Every read tool needs the exact namespace and key. `recall` is exact on
`(namespace, key)`; `retrieve` only consults the endpoints the caller
names, because the belief claim source's key extractor ignores the query
string; `query` can scan, but cannot filter on a namespace, and its
`node-slot-value` goal silently matches nothing when the node or slot is
unbound. An agent that does not already know a subject's address gets a
well-formed empty result, indistinguishable from "nothing recorded" —
the one conclusion it must not draw without having looked. Six headless
Claude Code runs against a synthetic store answered every question
correctly but took 12 to 36 turns each, nearly all of it discovering
keys through full Prolog scans (#64, comments).

Three findings on the query language were recorded on #64 and are
engine work: no keyword literal can be written, so a namespace cannot
be filtered; an unbound node in `node-slot-value` is a silent empty; an
unbound slot is a silent empty.

## 1. Rulings

| # | Ruling | Why |
|---|--------|-----|
| R1 | Scope: `list-taxonomy` + lexical key extractor + nothing-consulted error. Embedding-backed retrieval is deferred to a new issue. | Three units testable alone, sharing one mechanism; embeddings need an index and a write-path hook, a different risk class. |
| R2 | Vocabulary is a per-call walk of the belief vertices in cl-llm, under the scope snapshot. No cache. | Linear in beliefs; milliseconds at today's scale. The engine index (vivace-graph#350) replaces the walk behind the same function later. |
| R3 | `retrieve`/`plan-bounds` raise a tool error when nothing would be consulted. | A field is skimmed past; `isError` is not. Same choice #63 made for an uncanonical namespace. |
| R4 | The three query-language gaps are fixed in the engine, first (vivace-graph#351). | They are the runner's behaviours, and the cl-llm docs and tests for `query` depend on them. |
| R5 | A string unifies with a keyword via a `prolog-equal` method, not via the guard admitting bare symbols. | Only turns non-matches into matches on keyword slots; the guard alternative interns from untrusted text and needs position-awareness. |

## 2. The vocabulary walk (`memory/vocabulary.lisp`)

```lisp
(defstruct vocabulary
  store        ; the graph
  namespaces   ; name-string -> namespace-entry
  relations    ; name-string -> count
  endpoints)   ; list of (namespace-keyword . key-string), distinct

(defstruct namespace-entry
  name subjects objects keys)   ; keys: key-string -> count

(defun vocabulary (graph &key include-retracted)
  "One walk of GRAPH's belief vertices, both arities, under the
current read snapshot.  Retracted claims are skipped unless
INCLUDE-RETRACTED (RECALL's default).  Returns a VOCABULARY.")
```

- Walks `belief-binary` and `belief-unary` through the engine's vertex
  traversal restricted to those classes, inside the scope snapshot the
  other reads use (`with-scope-snapshots` at the caller).
- For each current claim: subject namespace and key count once under
  `subjects`; a binary claim's object namespace and key once under
  `objects`; the relation once; both endpoints go into `endpoints`.
- Names in the struct are the keyword's canonical lowercase spelling for
  namespaces and relations; keys are the stored strings.
- Cost is linear in the store's beliefs per call. Nothing is cached or
  stored. The signature is the contract vivace-graph#350 implements
  behind later.

## 3. `list-taxonomy` (`agent/taxonomy-tool.lisp`)

Parameters: optional `namespace`, `store`, `limit`. Read-only; no cite
cache interaction. Added to `make-agent-tools`, so both MCP modes serve
it with no configuration change.

**Without `namespace`** — every store in scope, in scope order:

```json
{"stores": [
  {"store": "cl-llm-memory",
   "namespaces": [
     {"name": "incident", "subjects": 5, "objects": 0, "keys": 5,
      "sample": ["drift-b8dc70-2026", "ledger-freeze-2026-05-22"]}],
   "relations": [{"name": "outage-root-cause", "claims": 5}]}]}
```

Namespaces sort by `subjects + objects` descending, then name;
`relations` by claims descending, then name. `sample` is the first
keys alphabetically, at most the operator's `max-rows`; `keys` is the
full distinct count. `store` (a scope store name) restricts to one
store; an out-of-scope name is the error `query` already raises.

**With `namespace`** — the keys under it:

```json
{"namespace": "incident",
 "keys": [{"key": "ledger-freeze-2026-05-22", "store": "cl-llm-memory",
           "claims": 1}],
 "truncated": false}
```

One list across the scope, each key naming its store, as `recall`'s
records do; the same key held by two stores is two entries. Keys sort
by claims descending, then key, then scope order. `store` restricts to
one store in both shapes. `limit` clamps to `max-rows`; `truncated` is
the one-past-the-cap rule `recall` uses. An uncanonical `namespace` is
the #63 error; a canonical one no store holds returns an empty `keys`
array (the store's answer, not a misspelling).

Tool description (verbatim intent): discover the spelling of what this
memory holds before an exact read; never conclude absence from a
guessed key.

## 4. The query string participates in `retrieve`

### 4.1 Extractor (`agent/extract.lisp`)

```lisp
(defun make-key-extractor (vocabulary &key (cap 10))
  "A function of a query string returning up to CAP endpoints from
VOCABULARY, best match first.")
```

- Tokenise: lowercase, split on any character outside `[a-z0-9]`,
  drop tokens shorter than 3 characters.
- Each endpoint's key is split on `-`. An endpoint matches when at
  least one query token equals one of its key tokens or the whole key.
- Score: number of distinct matching query tokens. Ties: a key under
  a namespace whose name equals a query token first, then shorter key,
  then alphabetical on `namespace:key`.
- A token equal to a namespace name selects nothing by itself.
- Result: distinct endpoints, best first, at most CAP.

### 4.2 `retrieve` and `plan-bounds` (`agent/planner-tools.lisp`)

- `%claim-sources` builds one claim source per store whose extractor is
  `make-key-extractor` over that store's `vocabulary`, computed once per
  call under the scope snapshot.
- The endpoint set per store: explicit `endpoints` first, never
  displaced, then extracted ones in score order; the union capped at
  `2k`. Explicit endpoints keep the #63 canonical check.
- If the union is empty for every store **and** `scope-sources` is
  empty, both tools signal `llm-tool-error` with the text
  `no endpoint recognised in "<query>": name endpoints, or call
  list-taxonomy to see what this memory holds`. With operator sources
  present, fusion runs over them alone.
- The result gains an always-present `"endpoints"` array of
  `"namespace:key"` strings actually consulted, in consultation order,
  across stores, deduplicated. `plan-bounds` gains the same array.
- Fusion, ranking, bounds derivation, `searched-empty` items, cite
  cache seeding in scope order, and `truncated` are unchanged.

## 5. Engine unit (vivace-graph#351, `experiment`)

- `node-slot-value/3` with an unbound node enumerates vertices in the
  pattern `is-a/2` uses with both arguments unbound: per-type scans via
  `map-vertices`, snapshot-safe. A vertex whose type does not declare
  the slot is skipped (no null row).
- With the node bound and the slot unbound, one solution per declared
  slot of the vertex's type: `?slot` bound to the slot keyword, `?v` to
  the value (NIL when unset). Both unbound: vertices, then slots.
- `prolog-equal` gains `(string keyword)` and `(keyword string)`
  methods, `string-equal` on the symbol name.
- One test per behaviour in the prolog suite; `docs/guarded-query.md`
  "What the guard admits" documents keyword-valued slots.
- cl-llm side, after CI's engine pin passes the merge: query-tool tests
  for a namespace filter by string and an `is-a`-free lookup;
  `docs/agent-tools.md` `query` section documents all three.

## 6. Surfaces and docs

- MCP: no configuration change. `retrieve`/`plan-bounds` descriptions
  say the query finds endpoints by key tokens and name the error and
  `list-taxonomy` as the recovery.
- `docs/agent-tools.md`: `list-taxonomy` section (both shapes);
  `retrieve` documents the matching rule, cap, `endpoints`, the error.
- `docs/agent-memory.md`: the vocabulary walk, its linear cost,
  vivace-graph#350 as successor.
- `examples/skills/graph-memory/SKILL.md` is in flight on main and is
  not touched here; the #64 closing comment lists the three edits it
  needs (taxonomy as the first move for an unfamiliar name; the
  recall-miss paragraph points at `list-taxonomy`; the "retrieve needs
  endpoints" note goes).

## 7. Testing

- **memory**: `vocabulary` counts subjects/objects/relations/keys on a
  mixed store; skips retracted by default; sees a namespace the image
  never interned (the #61 cold-store fixture).
- **agent**: taxonomy both shapes, sort orders, `sample` cap,
  `truncated`, uncanonical namespace error, unknown-canonical empty;
  extractor tokenisation, scoring, ties, cap; `retrieve` finds
  `incident:ledger-freeze-2026-05-22` from "why did the ledger freeze in
  May" with no endpoints; explicit endpoints never displaced; the
  nothing-consulted error; fusion still runs with an operator source;
  `endpoints` array present and ordered; `plan-bounds` parity.
- **agent/mcp**: `list-taxonomy` listed by `tools/list` and callable
  over the adapter.
- **engine** (vivace-graph): the three §5 behaviours.
- Suites run CI-style in a subprocess; check counts recorded in the PR.

## 8. Out of scope

Embedding-backed retrieval (new issue when the lexical extractor shows
where it falls short); `member/2`; the engine vocabulary index
(vivace-graph#350); the skill edits (post-merge, listed on #64).
