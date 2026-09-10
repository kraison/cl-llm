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

One vertex per endpoint per store, keyed by `(ev-namespace, ev-key)`
through two named declarations: a `def-index` on the pair for lookup
and a `def-unique` on it for enforcement (facts E5). "No vector" means
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
(defun make-hybrid-key-extractor (graph vocabulary embedder
                                  &key (cap 10) floor)
  "A function of a query string returning up to CAP endpoints of
GRAPH as (namespace-keyword . key): the lexical matches of VOCABULARY
first, in MAKE-KEY-EXTRACTOR's order, then the endpoints whose
profile embeds nearest the query at cosine >= FLOOR (default the
embedder's floor), best first.  EMBEDDER NIL is MAKE-KEY-EXTRACTOR.
Trap: an endpoint without a vector -- touched by a write and not yet
re-embedded -- is reachable lexically only.")
```

`%claim-sources` (`agent/planner-tools.lisp`) builds one per store in
scope, as it builds the lexical extractor today, passing the scope's
embedder.

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
2. **Drain**: for each enqueued endpoint, render the profile under a
   fresh read snapshot, embed it, and in one small transaction set
   `embedding` and `ev-model`; an endpoint that turns out to have no
   current belief gets no vector. A write that lands between the render
   and the store clears the vector again in its own transaction, and
   the notification re-enqueues the endpoint; the last writer wins and
   the invariant holds throughout.
3. **Failure**: an embedder error is logged once per outage on stderr,
   the endpoint stays dirty, and the worker backs off (1 s doubling to
   60 s) before retrying the queue. Nothing is dropped.
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

### 4.4 Synchronous drain

`drain-endpoint-vectors (stores embedder)` runs the sweep and the drain
in the calling thread and returns the number of endpoints embedded. It
serves the tests (no sleeping on a worker) and an operator who wants a
rebuild finished before a scripted session; `rebuild-endpoint-vectors`
is the same call with every vector first treated as absent.

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

The floor is documented with a calibration recipe: run a few paraphrase
queries and a few out-of-domain queries through
`nearest-endpoints (graph embedder query &key k)`, which returns
`(endpoint . cosine)` pairs unfiltered, and set the floor between the
two bands.

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

## 9. Relation to the blackboard

The blackboard's stores are memory stores, so one `endpoint-vector` set
per store and the same lexical-first route apply unchanged; profiles
carry the producer, so a routed endpoint's provenance across principals
is visible before any traversal. The worker is a per-process thread the
blackboard service hosts the way the image does.
