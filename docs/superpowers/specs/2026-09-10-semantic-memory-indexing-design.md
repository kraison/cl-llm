# Semantic Endpoint Routing for `retrieve`: Design

**Issue:** kraison/cl-llm#78 (follow-up to #64, its option 2b).
**Prerequisites:** the engine's vector segments (`:vector-index t` on a
vertex slot, `graph-db:vector-search`), already used by
`cl-llm/rag/vivace`; the memory's recall rules (`memory/recall.lisp`)
and the vocabulary (`memory/vocabulary.lisp`, #64, #68, #70).
**Date:** 2026-09-10.
**Status:** Approved 2026-09-10 (rulings R1–R7 in discussion); amended
the same day after the engine-facts pass
(`docs/superpowers/notes/2026-09-10-semantic-index-engine-facts.md`):
profiles carry beliefs only, absences never touch, the segment reset
happens at start before the listener, the memory layer takes an
embedding *function* rather than a `cl-llm/rag` embedder.

---

## 0. Problem and context

#64 gave `retrieve` a lexical key extractor (`agent/extract.lisp`): the
query's tokens are matched against the store's vocabulary of endpoint
keys, and the matching endpoints become the claim sources consulted.
It matches strictly on tokens of three or more characters, split on
hyphens. That has a sharp failure mode:

1. **Paraphrase misses.** A query that describes a thing without its
   key's tokens finds nothing: "why was the deployment reverted" against
   `incident:<name>-rollback-<date>`, or "do we still reindex nightly"
   against `decision:drop-nightly-reindex`.
2. **The refusal blocks the agent.** `retrieve` refuses with
   `no endpoint recognised` when nothing is found, on purpose: an empty
   bundle would read as "nothing recorded". A paraphrase therefore
   leaves the agent with `list-taxonomy` scans or exhaustive Prolog.
3. **Prolog fallback cost.** Both fallbacks walk the store and spend
   the inference budget on what one routed lookup would answer.

#64 deferred embedding-backed routing until it had a write-path
invalidation model and a clean relation to bitemporality. This document
is that design.

---

## 1. Rulings

| # | Ruling | Why |
|---|--------|-----|
| **R1** | **Vectors route to endpoints, never to beliefs.** Dense search yields candidate endpoints `(namespace-keyword . key-string)`; the graph is then traversed exactly as today. No chunk, no belief text, is served from the vector side. | The graph stays authoritative for validity intervals, transaction time, citations and provenance. Every downstream tool keeps its contract. |
| **R2** | **Lexical first, then dense fill.** Lexical hits keep today's order and come first; dense candidates above the floor fill the remaining cap in similarity order; duplicates collapse. | An exact identifier in the query (`sigil-…`, a commit SHA, a date) is a lexical hit and is never displaced by embedding drift. With no embedder the route is exactly today's, so the change is additive. |
| **R3** | **The refusal stays, with a per-embedder floor.** No lexical hit and no dense candidate at or above the floor is still `no endpoint recognised`. The floor is a field of the embedder configuration, not a constant. | Keeps `searched-empty` distinct from `uncovered`. A fixed cosine such as 0.65 would gate out most paraphrases on common models, silently. |
| **R4** | **The unit indexed is an endpoint's active profile**, rendered from the beliefs that are current in recall's sense (not retracted, validity open), capped. Decisions are not in the profile (amended: a concluded decision carries only its rule name and cites, and it is written by `conclude`'s own transaction, possibly citing beliefs in other stores, so it would need a cross-store touch for one word of text). | A single triple lacks the context an embedding needs; a superseded predecessor must leave the profile the moment its successor lands. |
| **R5** | **Invalidation is a derived dirty set.** A write clears the touched endpoints' vectors inside its transaction. An endpoint with current beliefs and no vector *is* dirty; the state is on disk, nothing is queued durably. One worker thread per process re-embeds; the write path never waits on the embedder. | Nothing stale is ever searchable, in any mode. The memory host has no GPU: a local model's cold load, timeouts and outages must not land in an agent's tool call. A lost queue costs nothing because the sweep re-derives it. |
| **R6** | **The engine's vector segment is the store.** The `endpoint-vector` vertex declares its `embedding` slot `:vector-index t`; the apply path maintains the mmap segment, `graph-db:vector-search` scans it. | No new storage, no daemon; `cl-llm/rag/vivace` already proves the path. |
| **R7** | **The embedder rides on the scope; each vector records its model.** Configured by environment on the image and the solo server, empty meaning inert. A vector from a different model reads as absent, so a model change re-embeds in the background; the floor travels with the model. | One configuration path for the in-process agent and both MCP entry points. Vectors from two models are not comparable, at any dimension. |

---

## 2. The indexed unit: endpoint active profiles

### 2.1 Membership

For an endpoint `E = (namespace . key)` in a store, the profile is built
under the caller's read snapshot from every belief where `E` is the
subject or the object and the belief is **current in recall's sense**:
`claim-current-p` (its transaction period is open, so not retracted)
**and** its validity extent is still open (`%open-p` in
`memory/recall.lisp`). That is stricter than the retraction flag alone:
a superseded predecessor has its validity closed by `record-belief`, so
it leaves the profile at the same commit its successor enters it.

An endpoint with no current belief has no profile and therefore no
vector: a paraphrase for a fully retracted topic refuses rather than
routes, which is what the lexical extractor does today (the vocabulary
it reads is current-only by default, #350).

### 2.2 Text

Rendered in this order, one line each:

1. the namespace and the key written as words, hyphens as spaces, so
   the key's tokens embed as vocabulary rather than as one opaque token;
2. one line per current belief, rendered by `claims:render-claim`
   (endpoints, relation, producer, standing, validity), the endpoint's
   own beliefs first as subject then as object, newest validity first;
Decisions contribute no line (R4 as amended; facts E6). The "why" a
paraphrase finds is the relation and the object of the belief itself
(`decided-because`, `root-cause`), which is what the memory records.

The rendering is the memory layer's own, in `render-claim`'s shape
(`ns:key relation ns:key (producer, standing, validity)`): the memory
system does not depend on `cl-llm/rag`, where `render-claim` lives.

The profile is **capped** at a documented number of belief lines
(default 32), newest validity first, so an endpoint with hundreds of
beliefs embeds a representative head. Absences (`record-absence`) are
instants, never open, so they are never profile lines.

### 2.3 Supersession chains

No pointer to a successor is written into a profile. A superseding
belief is on the same subject with a different object, so the successor
is already a distinct endpoint with its own profile. Routing to either
endpoint hands the query to the graph traversal, which returns the
supersession link as it does today.

### 2.4 What counts as a touch

Only a claim actually created or closed touches its endpoints. An
idempotent `record-belief` (the same object already held) returns the
existing belief and writes nothing, so it touches nothing and costs no
embedding. There is no profile hash: every write that changes a profile
clears the vector, so a vector that exists was embedded from the
current text by construction.

### 2.5 Storage

Declared inside `define-memory-store` (`memory/schema.lisp`), so every
memory store has the class:

```lisp
(gdb:def-vertex endpoint-vector ()
  ((ev-namespace :type keyword)
   (ev-key       :type string)
   (ev-model     :type string)     ; the embedder model that produced EMBEDDING
   (embedding    :type (simple-array single-float (*))
                 :vector-index t))
  <graph-name>)
```

One vertex per endpoint per store, found by a named `def-index` on
`(ev-namespace, ev-key)`. There is deliberately NO unique constraint
(amended in SDD Task 1): a commit-time unique violation is not retried
by the engine, so two connections first-touching one endpoint would
fail one agent's write for a race the index caused. Duplicates are
benign instead: the touch clears every live vertex of the endpoint,
lookups take the first live one, search dedups by endpoint. Within one
transaction the touch dedups through a synchronized per-transaction
set, since `index-lookup` reads committed state only. "No vector" means
`embedding` holds anything but a conforming `(simple-array single-float
(*))` (unbound and NIL both drop the segment entry, E2): the endpoint
is then lexical-only. The segment is created lazily by the first
conforming write and fixes its dimension then (engine behaviour).

---

## 3. Routing

### 3.1 Shape

```
query
  ├─ lexical: today's %endpoint-match over the vocabulary  → L (ordered)
  └─ dense:   embed(query); vector-search over endpoint-vector,
              k = cap, score ≥ floor                        → D (ordered)
result = L ++ (D \ L), truncated to cap
empty result and no operator source → "no endpoint recognised"
```

`L` is exactly `make-key-extractor`'s output. `D` is consulted only when
`L` leaves room under the cap. The refusal (R3) is unchanged in
`%check-consulted`.

### 3.2 Constructor

```lisp
(defun make-hybrid-key-extractor (graph vocabulary endpoint-embedder
                                  &key (cap 10) query-vector)
  "A function of a query string returning up to CAP endpoints of GRAPH
as (namespace-keyword . key): VOCABULARY's lexical matches first, in
MAKE-KEY-EXTRACTOR's order, then the endpoints whose profile embeds
nearest the query at cosine >= the embedder's floor, best first.
QUERY-VECTOR is a function of the query returning its embedding, so a
caller can memoise it across the stores in scope; the default embeds
on every call.  ENDPOINT-EMBEDDER NIL is MAKE-KEY-EXTRACTOR itself.
Traps: an endpoint a write touched and the indexer has not re-embedded
is reachable lexically only (§4.1); and the vector search runs when
the returned function is called, not under whatever snapshot
VOCABULARY was read in.")
```

There is no `floor` key: the floor is the endpoint embedder's, so one
scope cannot answer two queries at two floors. `%claim-sources`
(`agent/planner-tools.lisp`) builds one extractor per store in scope,
as it builds the lexical extractor today, passing the scope's embedder
and one memoised `query-vector` closure so a query is embedded once
per `retrieve`, not once per store.

### 3.3 Cost

One embedding of the query per `retrieve` call (not per store), one
segment scan per store. A store without a segment yet answers
`:no-segment-yet` and contributes nothing dense.

---

## 4. Invalidation: the derived dirty set

### 4.1 Definition

An endpoint is **dirty** when it has at least one current belief and its
`endpoint-vector` either does not exist, holds no conforming vector, or
carries an `ev-model` other than the configured model. Nothing else
records dirtiness: the set is derived from the store, so it survives a
crash, an exit, or a lost worker unchanged.

### 4.2 The write path

Inside the transaction that `record-belief`, the supersession it
performs, or `retract-belief` runs in, the touched endpoints are the
subject and, when binary, the object of the written or retracted belief.
For each, the `endpoint-vector` (created if absent) has its `embedding`
cleared. The apply path removes the segment entry with the commit. From
that commit on the endpoint is lexical-only until re-embedded. A
superseded predecessor shares its subject with the successor and
contributes no endpoint of its own; its object endpoint is touched as
well, since its profile loses a line. `record-absence` touches nothing:
an absence is never a profile line (§2.2). `conclude` touches nothing
beyond the belief it records through `record-belief`.

`conclude` and `retract` (the tools) do nothing more: they own the
transaction, and the clearing rides inside it. After the commit they
**notify** the worker (a condition variable; a no-op when no worker
runs) and return at once.

### 4.3 The worker

One thread per process that has an embedder, started by
`start-endpoint-indexer` and stopped by `stop-endpoint-indexer`:

1. **Sweep** at start: walk every store's vocabulary endpoints (the
   count indexes make this a lookup, #361), and for each dirty one
   (4.1) enqueue it. This is also the bulk rebuild: a store copied in,
   or opened with a new model, fills in behind while the image serves.
2. **Materialise, then drain** (amended in SDD Task 1, re-amended in
   its fix round): the sweep first creates a vertex, with no vector,
   for every vocabulary endpoint that lacks one, so the drain and the
   touch only ever UPDATE an existing node. A touch then rewrites
   every live vertex of its endpoints unconditionally -- clearing an
   already-clear vector is still a `save`, and that write-set entry is
   the only thing a create-only writer (a first belief, nothing
   superseded, whose claim writes are all creates) offers a concurrent
   drain to validate against. The drain itself embeds OUTSIDE every
   transaction -- an embedder is a network round trip and the engine's
   ninth attempt at a transaction runs the body under the global
   transaction-manager lock -- and per endpoint makes up to four
   passes of: render under a read snapshot, embed, then in ONE
   transaction re-render and store the vector only when the text is
   unchanged. A racing touch that commits before the re-render changes
   the text, so nothing is stored and the pass repeats; one that
   commits after it fails the store's validation, and the engine's
   retry re-renders to the same effect. An endpoint with no current
   belief gets no vector; one still changing after four passes stays
   dirty for the next drain.
3. **Failure**: a failed drain is logged once per outage on stderr
   (`drain failed: ...` -- the guard covers the dirty sweep as well as
   the embedder, and an engine error is not an outage), the endpoint
   stays dirty, and the worker backs off (1 s doubling to 60 s) before
   retrying the queue. The guard is `serious-condition`, not `error`:
   a `storage-condition` escaping the thread body would take the whole
   process under `--script`, not just the worker. Nothing is dropped.
   The backoff is a deadline (SDD Task 3 fix round 1): a notify does
   not shorten it, only a stop does, since the write path notifies per
   write and an import against a down embedder would otherwise make
   one failing round trip per write. Any error-free drain ends the outage state
   (so a later failure logs as its own outage), but only one that
   embedded at least one endpoint announces the recovery: an empty
   drain proves nothing about the embedder and clears the state
   silently. **The stop is bounded** (final review, I2):
   `stop-endpoint-indexer (indexer &key (timeout 35))` sets the flag,
   wakes the thread, then polls `bt:thread-alive-p` against a deadline
   (bordeaux-threads 0.9.4's `join-thread` takes no `:timeout`) and
   joins when it is dead; past the deadline it logs `stop timed out
   after N s; abandoning the worker` and answers NIL. The drain itself
   observes the flag between endpoints, so one stop waits for at most
   one embedding. Both entry points pass 35 = the 30 s embedder bound
   plus a margin. An abandoned worker still writes, which is bad; a
   join that never returns holds SIGTERM until the supervisor's
   SIGKILL and parks the store's `.dirty` marker, which is worse.
4. **Model change**: a vector whose `ev-model` differs from the
   configured model is dirty and re-embedded by the ordinary drain. A
   *dimension* change cannot be handled by the worker: an empty segment
   keeps its dimension and the engine's only drop is unsafe against a
   concurrent search (facts E3). So each entry point, after opening the
   stores and before starting the listener or the worker, embeds one
   probe string, and when the segment's dimension differs it clears
   every vector in one transaction and rebuilds the segment
   (`graph-db::rebuild-vector-segment`, internal; an export is asked of
   the engine) while nothing can search. A dimension change therefore
   costs one restart, which a configuration change already requires.
5. **Idle** (added in SDD Task 3): the worker reports itself idle only
   when a drain finished with no notify outstanding *and* no store has
   a dirty endpoint left, so `wait-endpoint-indexer` cannot read
   "drained" over an endpoint the four passes of step 2 could not
   settle. Such an endpoint is not an error: the worker waits the
   initial backoff (a never-settling endpoint is an embedder-speed
   problem, not an outage) and drains again, naming it on stderr once
   per worker so an operator can see it. The notify flag is cleared before the
   drain runs, so a write landing mid-drain is kept for the next pass
   rather than lost -- one drain takes each store's dirty set once and
   is not promised to empty it.

### 4.4 Synchronous drain

`drain-endpoint-vectors (stores &key embed model stop-p)` runs the
sweep and the drain in the calling thread and returns **two values**:
the number of endpoints embedded, and the endpoints whose profile
outran `*embed-passes*` and are still dirty. It serves the tests (no
sleeping on a worker) and an operator who wants a rebuild finished
before a scripted session; `rebuild-endpoint-vectors` is the same call
with every vector first treated as absent, and passes both values
through. `stop-p`, when given, is called between endpoints and ends
the drain there — it is how the worker's stop stays bounded (§4.3
step 3).

### 4.5 The solo server and the image

The image starts the worker after the listener when an embedder is
configured; the solo server (`memory-mcp.lisp`) starts one per process.
A solo process that exits with dirty endpoints leaves absent vectors
behind; the next process's sweep finds them. Two processes never hold
one store (engine rule), so two workers never race on one segment.

---

## 5. Configuration

The memory layer (`cl-llm/memory`) depends on the engine only and must
not depend on `cl-llm/rag` (its system definition says so). It therefore
takes an **embedding function** `(lambda (text) vector)` and a model
name, never an embedder object. The agent layer wraps a `rag:embedder`
into that pair together with the floor: `endpoint-embedder (embedder
model floor)`, made by `make-endpoint-embedder`, which requires a
non-empty model name (a `rag:mock-embedder` has none, E9). It is a
field of the agent scope (`agent/scope.lisp`), set by
`make-agent-tools :embedder`. The image and the solo server read it
from the environment, in the house style of the existing variables:

| variable | meaning |
|---|---|
| `CL_LLM_MEMORY_EMBED_URL` | OpenAI-compatible embeddings endpoint; empty (the default) means no embedder |
| `CL_LLM_MEMORY_EMBED_MODEL` | model name, recorded per vector |
| `CL_LLM_MEMORY_EMBED_KEY` | optional bearer key |
| `CL_LLM_MEMORY_EMBED_FLOOR` | cosine floor for dense candidates; required when the URL is set |

Empty URL means the feature is inert: no worker, no embedding at
retrieve, `retrieve` is today's lexical route, the class sits unused.
That is the state every existing suite runs in.

The floor is documented with a calibration recipe. The memory layer's
search takes a vector, not an embedder — `nearest-endpoints (graph
query-vector &key k model)`, returning `((namespace . key) . cosine)`
pairs unfiltered — so embed each query first with `rag:embed` on the
endpoint embedder's own embedder (`endpoint-embedder-embedder`), run a
few paraphrase queries and a few out-of-domain ones through it, and set
the floor between the two bands.

The endpoint need not be on the memory host: a GPU box on the tailnet
serving an OpenAI-compatible route makes the round trip small, and the
worker makes a slow local model tolerable.

---

## 6. Downstream tools

No contract changes. `recall`, `trace`, `decisions-citing`, `query`
and `list-taxonomy` are untouched. `retrieve` gains paraphrase routing,
keeps its `endpoints` field (now listing dense-routed endpoints too),
keeps its refusal, and keeps fusing claim and operator sources under its
temporal bounds. A query with `at` or a validity window still routes by
the *current* profile (the vectors are timeless, R4) and then answers
from the graph at the requested time.

---

## 7. Testing

A **synonym-table test embedder** lives in the test package: a
hand-written table maps tokens to a few dozen dimensions, so "reverted"
and "rollback" land near each other and an unrelated word lands
nowhere; it is deterministic and needs no service. Every assertion
below is exact under it. One test tagged for a live model runs only when
`CL_LLM_MEMORY_EMBED_URL` is set in the test environment, as the mcp
suite gates its child-process tests.

1. **Paraphrase recovery.** A belief under an incident endpoint whose
   key shares no token with the query; the query's paraphrase routes to
   the endpoint through the dense fill and `retrieve` cites the belief.
   Control: the same store with `:embedder nil` refuses.
2. **The refusal stays.** An out-of-domain query yields no lexical hit
   and no dense candidate above the floor; `retrieve` signals
   `no endpoint recognised`.
3. **Identifier invariance.** A query naming a key exactly ranks that
   endpoint first regardless of what the dense side returns (a decoy
   endpoint whose profile embeds nearer the query).
4. **Supersession.** A belief superseded by another on the same subject:
   after the commit the old object endpoint is dirty and unsearchable;
   after a drain, its profile no longer contains the old line (the
   endpoint has no vector at all when nothing current remains), and a
   paraphrase for the new object routes to the new endpoint.
5. **Retraction.** A retracted belief leaves its endpoints dirty; an
   endpoint with no remaining current belief has no vector after the
   drain and its paraphrase refuses.
6. **An idempotent write touches nothing.** A `conclude` of a belief
   already held leaves the vector in place and the counting embedder
   reports no embedding.
7. **Model change.** Vectors written under model A read as dirty under
   model B; a drain re-embeds every endpoint. A different dimension:
   the start-time reset clears the vectors and rebuilds the segment,
   and a vector of the new length is then accepted.
8. **The write path never embeds.** A probe on the embedder proves
   `conclude` and `retract` return with zero embedder calls, and that
   the calls happen in the drain.
9. **Inert without an embedder.** Every existing suite runs unchanged
   with no embedder configured (the suites' own counts are the check).

---

## 8. Implementation phases

1. **Profile and schema (`cl-llm/memory`).** `endpoint-vector` and its
   two declarations in `define-memory-store`; `memory/profile.lisp`
   with the renderer, the current-belief walk, the dirty predicate and
   `touch-endpoints`; the write-path clearing in `memory/write.lisp`.
2. **The indexer (`cl-llm/memory`).** `memory/index.lisp`:
   `nearest-endpoints`, `drain-endpoint-vectors`,
   `rebuild-endpoint-vectors`, `reset-endpoint-segment`,
   `start-/notify-/stop-endpoint-indexer` over an embedding function
   and a model name; `bordeaux-threads` joins the system's dependencies
   (the engine already loads it).
3. **Routing (`cl-llm/agent`).** `endpoint-embedder`,
   `make-hybrid-key-extractor` in `agent/extract.lisp`; the scope's
   embedder; `%claim-sources` passes it and embeds the query once per
   call; the synonym-table test embedder; `conclude`/`retract` notify.
4. **Entry points and docs (`cl-llm/agent/mcp`, `scripts/`).** The
   environment variables on the image and the solo server, the
   dimension reset before the listener, the worker's start and stop in
   their lifecycles, `docs/agent-memory.md` and `docs/agent-tools.md`.

The engine-facts pass (`docs/superpowers/notes/2026-09-10-semantic-index-engine-facts.md`)
pinned the facts this design relies on; its seven disagreements are
resolved in the amendments above.

---

## 9. Relation to a multi-agent successor

A multi-agent successor built on these stores inherits this unchanged:
its stores are memory stores, so one `endpoint-vector` set per store
and the same lexical-first route apply as they stand; profiles carry
the producer, so a routed endpoint's provenance across principals is
visible before any traversal. The worker is a per-process thread such a
service hosts the way the image does.
