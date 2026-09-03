# Agent tools (`cl-llm/agent`, `cl-llm/agent/prolog`)

The tool surface over `cl-llm/memory` and the retrieval planner: what
a language model reaches the agent's memory through (kraison/cl-llm#14
unit 2, S6a). Design:
`docs/superpowers/specs/2026-09-03-agent-tools-design.md`; this page
is the user's view of it. `cl-llm/memory` itself — beliefs, decisions,
`conclude`, `trace` — is `docs/agent-memory.md`; read that first if the
vocabulary below (belief, standing, cite, decision) is unfamiliar.

`cl-llm/agent` depends on `cl-llm`, `cl-llm/memory` and
`cl-llm/rag/claims` only — no web stack. `cl-llm/agent/prolog` adds
one more tool, `query`, and with it a dependency on `graph-db/gui`
(§"What this is not").

## One memory, partitioned by trust

A user runs one model across many concerns — coding, business,
research, writing — and the memory should be **one**, reachable from
any session. What a separate *store* is for is not topic: **topic is
the subject namespace**, part of a belief's identity
(`docs/agent-memory.md`), not a container an agent chooses at write
time. **Trust is the boundary a store carries**, because the tool set
can enforce it and the model cannot — a session that reads untrusted
input (a public repo, a scraped page, inbound mail) is constructed
with no private store in scope, so there is nothing for an injected
instruction to reach. **Scope is the operator's, at construction**: a
list of readable stores and exactly one writable store, exactly like
every other bound below. The model names subjects — namespace and
key, as two plain strings — never stores.

## Declaring a store

Each store a scope can name is first declared with
`mem:define-memory-store`, which sets up the `belief` and `trace`
claim families and the `memory-note` source under that graph's name:

```lisp
(mem:define-memory-store :cl-llm-memory)   ; cl-llm/memory does this
(mem:define-memory-store :memory-private)  ; a second store, yours
```

Two things worth knowing before you declare a second store. First,
the macro is callable from any package: `def-claim-classes` derives
each family's class names from the parent symbol's package
(kraison/vivace-graph#323, fixed 2026-09-03), so `belief-binary` and
friends always live in `cl-llm.memory`. Second, declaring the same store name twice
— your test suite opening a store another suite already declared, for
instance — is the engine's supported idempotent case
(kraison/vivace-graph#196), at the cost of a `redefining GDB:SAVE
:BEFORE`-style warning per declaration. That warning is expected, not
a bug to chase.

## Building the tools

```lisp
(agent:make-agent-tools stores &key write-store producer sources
                                     (k 5) (max-rows 50))
;; => 8 tools: recall trace decisions-citing conclude
;;    conclude-absence retract retrieve plan-bounds

(prolog:make-query-tool stores &key (max-rows 50)
                                     (max-inferences 100000)
                                     (timeout 5))
;; => the query tool (cl-llm/agent/prolog)
```

- `stores` — the readable graphs, each already declared with
  `define-memory-store`, in scope order. Reads run over all of them;
  each result names the `store` it came from.
- `write-store` — one of `stores` (default the first). The only
  target of `conclude`, `conclude-absence` and `retract`.
- `producer` — required, a canonical `"<agent>/<host>"` string; every
  decision the model makes is written under it.
- `sources` — extra `collect-evidence` sources `retrieve` fuses in
  beside one claim source per store in scope, such as a dense index
  over the same corpus.
- `k`, `max-rows` — caps on what a call may ask for. A larger request
  is clamped, never refused, and the result says `truncated`.
- `max-inferences`, `timeout` — the Prolog budgets `query` runs under
  (inferences and wall-clock seconds), the operator's alone.

Every bound above is fixed at construction; the model only chooses
its call's arguments. `make-agent-tools` and `make-query-tool` each
close over their own scope, so several scopes in one image are simply
several tool sets — a test builds its own over its own on-disk
stores, and nothing here is process-global.

One further thing the tools do on the model's behalf: every
namespace the model sends, on a write, in an endpoint, or inside a
cite, is validated as canonical (`[a-z0-9-]+`) and then interned as a
keyword. The alphabet is bounded but the count is not: any canonical
string the model invents becomes a namespace, there and then, with
no registry to consult first. An uncanonical one is refused, never
interned — minting it would be unrecoverable. `recall`'s own
`subject-namespace` never mints at all: an unrecognised namespace
just reads back as nothing recorded, never an error. A cite whose
namespace is canonical but unknown likewise parses and resolves to
nothing, since a fresh image must be able to trace a decision before
it has read a claim under that namespace.

## The tools

Every JSON key below is hyphenated, matching the parameter names.
**A field whose value is absent is omitted from the object entirely
— never rendered as JSON `null`** — with two exceptions: `truncated`
and `current`, which are always present booleans. The `query` tool's
row cells are the one place an actual JSON `null` appears (for an
unbound Prolog variable or an empty slot).

### `recall`

Parameters: `subject-namespace`, `subject-key`; optional `relation`,
`at` (RFC 3339 — only beliefs valid then).

```json
{
  "records": [
    {
      "store": "cl-llm-memory",
      "cite": "cl-llm.memory::belief|1a2b3c...",
      "relation": "ci-status",
      "object": {"namespace": "verdict", "key": "green"},
      "standing": "observed",
      "valid-from": "2026-09-01T08:00:00.000000Z",
      "current": true
    }
  ],
  "truncated": false
}
```

Reads run over every store in scope and merge under
`docs/agent-memory.md`'s order — validity start descending, then
recorded-at, then object key — ties broken by scope order. An
absence record has no `object` key at all (omitted, per the rule
above) and its `standing` is one of `searched-empty`,
`indeterminate`, `uncovered`. `valid-to` and `superseded-by` are
likewise omitted when there is none. An empty `records` array means
"nothing recorded" — it is not an absence; an absence is a record.

### `trace`

Parameters: `decision-id`.

```json
{
  "id": "9f8e...",
  "store": "cl-llm-memory",
  "producer": "claude-code/agent",
  "at": "2026-09-03T10:00:00.000000Z",
  "rule": "owner-says",
  "rule-version": "1",
  "confidence": 0.8,
  "outcome": "concluded",
  "conclusion": {
    "store": "cl-llm-memory",
    "cite": "cl-llm.memory::belief|9f8e...",
    "state": "resolved",
    "standing": "inferred",
    "valid-from": "2026-09-03T10:00:00.000000Z"
  },
  "evidence": [
    {
      "store": "memory-private",
      "cite": "cl-llm.memory::belief|1a2b...",
      "state": "resolved",
      "standing": "observed",
      "valid-from": "2026-09-01T08:00:00.000000Z"
    }
  ],
  "refusals": []
}
```

Found in whichever store of the scope holds it — decision ids are
random and unique. `confidence` is present when the decision that
made the claim gave one (omitted otherwise). Each evidence cite
resolves in the store its evidence claim names, when that store is
in scope, and the item's `store` is **the store it was resolved
against** — so a belief held identically by two stores still reports
the half this decision cited. A cite naming a store the tool set was
not built with reports `state: "absent"` and carries **no `store` key
at all** — never falling back to the decision's own store, which
would falsely suggest it was found. A refused decision has no
`conclusion` and no
`rule`/`rule-version`/`confidence` (omitted); `refusals` is
`[{"family": ..., "text": ...}]`, one per constraint family that
objected.

### `decisions-citing`

Parameters: `cite`.

```json
{"decisions": [{"id": "9f8e...", "store": "cl-llm-memory"}]}
```

Every decision anywhere in scope whose evidence cites the claim,
newest first (recorded-at descending, then id).

### `conclude`

Parameters: `subject-namespace`, `subject-key`, `relation`,
`object-namespace`, `object-key`, `rule`; optional `evidence` (a list
of cites), `standing` — `inferred` (default), `observed` or
`asserted` — `confidence`, `rule-version`, `valid-from` (RFC 3339).

```json
{
  "id": "9f8e...",
  "store": "cl-llm-memory",
  "outcome": "concluded",
  "claim-cite": "cl-llm.memory::belief|9f8e...",
  "refusals": []
}
```

A refusal is a result, not an error: the write validator caught
something before commit, nothing was written, and the model reads
why:

```json
{
  "id": "...",
  "store": "cl-llm-memory",
  "outcome": "refused",
  "refusals": [{"family": "subsystem", "text": "..."}]
}
```

(`claim-cite` is omitted on a refusal.) Every `evidence` cite the
model passes must be one this tool set has already returned in a
result, or one `recall`/`retrieve`/`trace` could still find by
searching the scope; a cite that resolves nowhere in scope is an
*error* result, never silently charged to the write store. Every
namespace argument — subject and object — is validated canonical
(`[a-z0-9-]+`) before anything is staged; a bad one is an error
result and writes nothing, on either side of the proposal.

### `conclude-absence`

Parameters: `subject-namespace`, `subject-key`, `relation`, `rule`,
`standing` — `searched-empty` (looked in a nameable place, nothing
there), `indeterminate` (could not find out) or `uncovered` (nothing
has looked); optional `evidence`, `rule-version`. Same result shape
as `conclude`, writing a unary claim instead of a binary one.

### `retract`

Parameters: `cite`.

```json
{
  "cite": "cl-llm.memory::belief|...",
  "store": "cl-llm-memory",
  "retracted-at": "2026-09-03T10:05:00.000000Z"
}
```

Only a **belief** is retractable, and only one in `write-store`. A
cite from any other family — a `trace` cite, say, naming a decision's
own record, which `query` makes visible — is an error result ("only
beliefs are retractable"); `mem:retract-belief` refuses one too, so
the rule holds below the tool as well. A cite that resolves to a store
elsewhere in scope is an error result ("not writable in this scope"),
since retraction is a write. Among claims sharing a cite, the
still-current one is preferred; a cite that resolves to nothing, or
only to an already-retracted claim, is an error result.

### `retrieve`

Parameters: `query`; optional `endpoints` (a list of
`"namespace:key"` strings, split at the first colon — the one place
that encoding appears, because namespaces are canonical
`[a-z0-9-]`), `from`, `to` (RFC 3339), `k`.

```json
{
  "query": "is it releasable?",
  "modes": ["claim"],
  "bounds": {
    "window": {
      "from": "2026-09-01T08:00:00.000000Z",
      "standing": "inferred"
    },
    "box-standing": "searched-empty"
  },
  "evidence": [
    {
      "method": "claim",
      "store": "cl-llm-memory",
      "text": "cl-llm ci-status verdict green",
      "cite": "cl-llm.memory::belief|...",
      "standing": "observed",
      "valid-from": "2026-09-01T08:00:00.000000Z"
    }
  ],
  "truncated": false
}
```

Runs `fuse` over one belief claim source per store in scope plus any
`sources` the operator supplied, so each evidence item names its
`store` when it came from one (omitted for an operator source).
`from`/`to` set the window explicitly (reported `standing:
"asserted"`); left out, the window is derived from a first,
unbounded fusion through `plan-bounds` and then applied — so a
second call inside that derived window is one round trip away.
`bounds.box` is present only when a spatial bound applies; here it is
absent because nothing has one. `truncated` means **more evidence
existed past `k`**, the same as in `recall`: the fusion runs at
`k + 1` and the extra item is cut, so a page that exactly fills `k`
with nothing behind it is not truncated. A recognised endpoint with
nothing recorded comes back as its own evidence item, `standing:
"searched-empty"`, with no `cite` — "looked and found nothing"
survives into the bundle rather than reading as an omission.

### `plan-bounds`

Parameters: `query`; optional `endpoints`, `k`. Returns the `bounds`
object alone (see `retrieve`, above), from a seed retrieval — the
derivation as a callable on its own, for a caller that wants the
window or region without paying for a full fetch.

### `query` (`cl-llm/agent/prolog`)

Parameters: `text`; optional `store` (default the first in scope),
`limit`.

```json
{
  "store": "cl-llm-memory",
  "columns": ["c", "r"],
  "rows": [
    ["9f8e7d6c5b4a39281706f5e4d3c2b1a0", "ci-status"],
    ["1a2b3c4d5e6f70819293a4b5c6d7e8f9", "last-push"]
  ],
  "truncated": false
}
```

Runs vivace-graph's guarded free-text Prolog pipeline verbatim
against one named store: the character screen, a reader with
`*read-eval*` off in a throwaway package, a whitelist walk against
that store's own schema, then the query with effects **off**, one
snapshot, and the operator's `max-inferences`/`timeout`. `?`-variables
become columns, **camelCased by the engine** (`?valid-from` becomes
`validFrom` in `columns`, not `valid-from`). `limit` is clamped to
`max-rows`, itself further clamped by the engine's own default row
cap (1000); one probe row past the cap decides `truncated`. **Row
cells use an actual JSON `null`** for an unbound variable or an
empty slot — the one place in this tool set that null appears rather
than an omitted key, because a row is a fixed-width tuple, not an
object with optional fields.

Because the whitelist enumerates the store's own schema types, a
query can walk `belief` and `trace` vertices with generic predicates
— `(is-a ?c belief-binary) (node-slot-value ?c relation ?r)` — and no
tenant-specific code. Note what `?c` holds above: a **node id**, a
32-hex string, not a cite. `query` is for walking the graph, not for
producing evidence — the cites `conclude` and `retract` take come
from `recall` and `retrieve`, never from a query row. A store outside
the scope is an error result. A
store that declares **edge** types is refused up front, pending
kraison/vivace-graph#322 (§"What this is not"). Every refusal the
guard or the engine produces — disallowed reader syntax, an
excluded control word, a write-effect goal, the inference or time
budget tripping — reaches the model as the **exact reason text** the
engine wrote for a client to read; nothing here re-splits or
rewords it.

## A scripted example

Abridged from `tests-agent/loop-tests.lisp`: a model scripted with
`cl-llm:make-mock-provider` reads a belief, then writes a decision
citing exactly the cite it read, with no network involved.

```lisp
(let* ((tools (agent:make-agent-tools (list working private)
                                      :producer "claude-code/agent"))
       (provider
         (make-scripted-provider
          (list
           ;; turn 1: the model reads what is known
           (lambda (c) (declare (ignore c))
             (tool-use "t1" "recall" "subject-namespace" "repo"
                       "subject-key" "cl-llm"))
           ;; turn 2: it concludes, citing the cite it just read
           (lambda (c)
             (let ((cite (cite-of-first-record (last-tool-result c))))
               (tool-use "t2" "conclude"
                         "subject-namespace" "repo"
                         "subject-key" "cl-llm"
                         "relation" "releasable"
                         "object-namespace" "verdict"
                         "object-key" "yes"
                         "rule" "owner-says"
                         "evidence" (vector cite))))
           ;; turn 3: it answers in plain text
           (lambda (c) (declare (ignore c)) "Done.")))))
  (cl-llm:ask "is it releasable?" :provider provider :tools tools))
;; => "Done."
```

After the loop, `mem:decisions-citing` on the cite the model read
returns exactly one decision, and its evidence cite is the same
string byte for byte — a cite the model reads in one tool result is
the exact string it is expected to pass back in the next.

## The first consumer: annotate-banners

`cl-llm/agent`'s `annotate-banners` (`agent/annotate.lisp`, spec
`2026-09-03-banner-round-trip` §5) is the tool surface's first
consumer: a model reads one note's hand-written banner (scanned by
`cl-llm/memory`'s `scan-banners`, `docs/agent-memory.md`) and
concludes what it overturns.

```lisp
(agent:annotate-banners stores dir &key provider producer
                                        (max-tool-turns 4)
                                        (model-name "unknown"))
;; => (((name . position) . decision-id-or-nil) ...), name then
;;    position order
```

`stores` and `producer` are as everywhere else in this doc (`stores`'
first is the writable one); `dir` is a memory directory, the same
shape `capture-memory-dir` reads; `model-name` rides the system
prompt only, for the record. One `ask` per **banner** in `dir` — not
per note — that is `UPDATE`, `CORRECTION` or `STALE`: a note can carry
more than one prose-target banner (the fixture `two.md`), and asking
once per note with every banner bundled into one prompt left
`conclude`'s evidence cite ambiguous between them (finding 1, #14 unit
3 final review). A `SUPERSEDED` banner is not read here at all:
capture already turns it into deterministic claims on its own — an
`annotates` belief always, `superseded-by` too when it links
(`docs/agent-memory.md`) — and there is nothing left in it for a model
to conclude.

The model gets exactly three tools (`annotation-tools`, a fixed
subset of `make-agent-tools`' eight): `recall`, `retrieve`,
`conclude`. `retrieve`, called with the note's name as query and
`endpoints ["memory-note:<name>"]`, returns every claim touching the
note — including **every** banner's `annotates` claim when the note
carries more than one, so the prompt tells the model which is this
ask's own: the banner's identity, `banner:<name>#<n>`, rides the
prompt verbatim (`%banner-block`), and the model matches it against
the evidence item whose rendered **text** begins with that same
string — `retrieve`'s claim renderer always leads with the subject
endpoint (`docs/agent-memory.md`'s claim shape) — and cites that
item's cite. The banner's own text does **not** ride any tool result:
the claim renderer emits a one-line summary, not the banner's words,
so the text rides the **user prompt** instead, verbatim, under the
note line, ahead of `retrieve` ever being called. The system prompt
tells the model this in as many words and gives it the rest of the
contract: call `retrieve` once, find the item by its `banner:<name>#<n>`
prefix, call `conclude` once — subject `(memory-note . name)`,
relation `overturns`, object `(proposition . <one sentence>)`,
standing `inferred`, rule `read-banner`, rule-version `<model-name>`,
evidence `[that cite]` — then reply `done`, or, if the banner
overturns nothing statable, reply `no`.

A banner the model declines — it never calls `conclude`, or concludes
something that is not the newest decision by this producer citing
this banner's own `annotates` claim (`%banner-annotates-cite`, keyed
on `<name>#<position>`) since the call began — comes back as
`((name . position) . NIL)` in the results list. **NIL is a normal
outcome, not an error**: the model may decline, and a declined
annotation still means the pass ran the banner through and got an
answer. `producer` here is always the **agent's own**, distinct from
whatever produced the underlying capture (`capture-memory-dir`'s
`:producer`) — the two are never conflated, so a decision's trace
names who read the banner, not who captured it.

**The live suite** (`cl-llm/agent/live`, `live-agent/`) runs
`annotate-banners` against a real provider — `llm:*provider*`,
Anthropic by default, so `ANTHROPIC_API_KEY` must be set. It is
gated exactly like `cl-llm/live` and `cl-llm/rag/live`: skipped via
FiveAM's `skip` whenever `CL_LLM_LIVE` is unset or `0`, so it loads
and runs offline with nothing skipped that should not be, and is
never run by CI (`docs/ci.md`):

```sh
CL_LLM_LIVE=1 sbcl --eval '(asdf:test-system :cl-llm/agent/live)'
```

It depends on `cl-llm/agent/tests` for the two-store on-disk harness
(`with-stores`, `%banner-dir`) rather than duplicating it.

## What this is not

- **No cross-store consistent instant.** Reads run per store and
  merge; one epoch spanning several stores at once is S6b's job
  (`#24`), not this one's.
- **The `query` tool loads the web stack.** The guard pipeline lives
  in `graph-db/gui`, which depends on ningle, clack and cl-json;
  `cl-llm/agent/prolog` therefore pulls that in, until
  kraison/vivace-graph#322 exports a guarded runner in a web-free
  subsystem. `cl-llm/agent` itself has no such dependency.
