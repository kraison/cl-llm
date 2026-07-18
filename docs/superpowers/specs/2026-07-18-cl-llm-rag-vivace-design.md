# cl-llm/rag/vivace Design

**Date:** 2026-07-18
**Status:** Approved
**Relationship:** The vivace-graph store adapter named in the RAG design
(`2026-07-18-cl-llm-rag-design.md`, §2/§3/§7: "the `vector-store` protocol lets
`graph-db` back the store — embeddings as node properties — unifying literature
with field data … a later `cl-llm/rag/vivace` add-on, never a dependency of
`cl-llm/rag`"). Designed against the EOD mine-action vision in
`docs/notes/2026-07-17-eod-expert-architecture.md`.

## 1. Purpose

`cl-llm/rag/vivace` lets a **vivace-graph (`graph-db`) graph back a RAG vector
store**: RAG chunks become graph vertices carrying their embedding and provenance,
so the retrieval corpus lives *inside the same graph* as the mine-action field
data. It satisfies the existing `cl-llm.rag` `vector-store` protocol, so
`(rag:make-index :store (make-graph-store graph …))` just works — nothing else in
the RAG pipeline changes.

This is **slice A** of the integration: the store adapter. **Slice C** — retrieval
hits that carry their graph neighbourhood (related vertices, geolocation), joining
literature to field data — is the natural follow-on and gets its own spec. A is
the substrate that makes C possible; the vertex representation here is chosen so C
can add join edges without reshaping it.

## 2. Scope

### In scope (v1)

- A **`graph-store`** satisfying the four `vector-store` **generic** operations
  (`store-add`, `store-search`, `store-count`, `save-store`) backed by a
  caller-owned `graph-db` graph. (Note: `rag:load-store` is a plain function in
  RAG core — not a generic — that always builds a `memory-store`, so the graph
  store cannot specialize it; standalone reopen is `open-graph-store` instead, §7.)
- **Two selectable search strategies**, identical through the contract:
  - **`scan-graph-store`** — `store-search` maps over the chunk vertices and
    computes exact cosine. Lowest RAM; vectors stay in the graph.
  - **`cached-graph-store`** — composes an in-memory `rag:memory-store` as a RAM
    index for search; the graph is the durable store and future join target.
- The **`rag-chunk` vertex type** (configurable name), self-declared into the
  caller's live graph schema on attach.
- **Hydrate-on-attach**: attaching to a graph that already holds chunk vertices
  initialises the store's dimension (and, for the cached variant, its RAM index)
  from the existing chunks.
- **Offline-ish, deterministic tests** via an in-memory graph + `mock-embedder`.

### Explicit non-goals (v1)

- **Slice C** (hit → graph-neighbourhood joins, geospatial joins). Designed *for*,
  not built.
- **Graph-query `deftool`s** ("ordnance within N km", "prior tasks here") — these
  depend on the consumer's field-data schema and belong to the EOD app.
- **ANN / approximate search.** Exact cosine only, exactly like `memory-store`
  (ANN remains a RAG-level seam, not a graph-store concern).
- **Owning field-data schema.** The store declares only its own `rag-chunk` type;
  the caller owns their graph and every other vertex/edge type in it.

## 3. Boundary, packaging, dependencies

- **New ASDF system `cl-llm/rag/vivace`**, package **`cl-llm.rag.vivace`** (local
  nicknames `rag:` → `cl-llm.rag`, `c:` → `cl-llm.conditions`, `gdb:` →
  `graph-db`). Depends on **`cl-llm/rag`** and **`graph-db`**.
- **`cl-llm/rag` never depends on this system.** The RAG spec's hard boundary
  holds: vivace integration is a consumer add-on satisfying the store protocol.
- **`graph-db` is not in Quicklisp** and pulls in `bordeaux-threads`. Therefore
  `cl-llm/rag/vivace` and its test system **are excluded from the default offline
  CI** (the same gating idea as the live suites) and load only where `graph-db` is
  on the ASDF path. The plan documents making `graph-db` findable (e.g. pushing its
  location onto `asdf:*central-registry*` in the test harness).
- **Thread exception.** `graph-db` uses threads and `with-transaction`. This
  add-on is the project's **one documented, opt-in exception** to the no-threads
  rule; every other system remains thread-free. The store itself spawns nothing —
  it only calls into `graph-db`.

## 4. The chunk vertex and the schema

A chunk becomes a vertex of a configurable type (default `rag-chunk`) with slots:

| slot          | holds                                             |
|---------------|---------------------------------------------------|
| `text`        | the chunk text (string)                           |
| `document-id` | provenance: the parent document id                |
| `metadata`    | the chunk's metadata plist (`:title`, `:position`, `:language`, …) |
| `embedding`   | the embedding vector                              |

Provenance is a **property** now; slice C later turns `document-id` into a real
`chunk → document` edge and adds `chunk → field-data` edges without changing this
shape.

**Runtime schema.** Runtime schema extension of a live graph is supported, so on
construction the store self-declares its type — `def-vertex` the chunk type into
the graph's schema and `update-schema` — with **no action required from the
caller**. (Verified: `def-vertex` after `make-graph`, then `update-schema`,
registers the type on the open graph.) The default type name `rag-chunk` is
configurable so it can't collide with a caller's field-data types.

**The verified serializer behaviour (load-bearing).** A round-trip test
(create → commit → `close-graph` → `open-graph` → read) established:

- A `(simple-array double-float (*))` slot is accepted by `def-vertex`, and its
  **values round-trip intact** (`equalp` holds across close/reopen).
- **But VG's serializer returns the value as a general `T`-element vector**, not
  the specialised type. This is harmless for `rag:cosine` (iterates any vector) and
  `check-dimension` (needs only `length`), but for type parity with `memory-store`
  the store **coerces every embedding read from the graph back through
  `rag:as-embedding`** (which restores `(simple-array double-float (*))` and
  double-float elements).
- Consequently **`as-embedding` must be exported from `cl-llm.rag`** (it is
  currently internal). This is a small, justified addition to the RAG public
  surface: any external store implementer needs to produce well-typed embeddings.
  The store stores the double-float vector directly (values survive) and coerces on
  read.

`def-vertex` generates `make-rag-chunk` / `lookup-rag-chunk` / `rag-chunk-p` and
slot accessors; vertices are created inside `gdb:with-transaction`; the store binds
`gdb:*graph*` to its borrowed graph around every operation.

## 5. Store classes and the borrow model

```
graph-store            abstract: a borrowed graph, a vertex-type, a dimension
  ├─ scan-graph-store    store-search scans vertices, exact cosine
  └─ cached-graph-store  composes a rag:memory-store as an in-RAM search index
```

```lisp
(make-graph-store graph &key (type 'rag-chunk) (strategy :cache) dimension)
;; => a graph-store of the class selected by :strategy (:cache | :scan)
```

- **Borrow.** The store takes an already-open, caller-owned `graph` and **never
  opens or closes it** — lifecycle stays the caller's. This is what lets the store
  write chunk vertices into the same graph that holds field data.
- On construction the store self-declares its type (§4) and **hydrates**: if the
  graph already holds vertices of `type`, the scan variant records the embedding
  `dimension` from the first, and the cached variant loads all existing chunks into
  its `memory-store`. `:dimension` may be supplied to pre-declare it.
- A convenience `open-graph-store (path &key strategy type dimension)` opens a
  standalone graph via `gdb:open-graph` and returns a store over it — for the
  RAG-only case with no field-data graph to share.

## 6. store-add / store-search / store-count

- **`store-add`** (shared across strategies): inside one `gdb:with-transaction`,
  writes one chunk vertex per chunk (`text`, `document-id`, `metadata`,
  `embedding`). Dimension safety mirrors `memory-store`: the first chunk sets the
  dimension; a differently-dimensioned chunk or a nil embedding signals
  `rag:llm-rag-error`, **before any vertex is written** (validate-then-write, so a
  bad batch leaves the graph unchanged — the atomicity `memory-store` guarantees).
  The cached variant also write-throughs into its `memory-store`.
- **`store-search`**:
  - `scan-graph-store`: `gdb:map-vertices` over `type`, compute `rag:cosine`
    against each (coerced) embedding, return the top *k* as `rag:hit`s.
  - `cached-graph-store`: delegate to the composed `memory-store`.
  - **Parity is a hard requirement**: both strategies return identical rankings for
    the same corpus and query. This is the load-bearing test. To make parity *total*
    (not tie-order-dependent), both `store-search` sites `stable-sort` by score with
    a deterministic `document-id` tie-break — so exact score ties resolve identically
    across strategies.
- **`store-count`**: scan counts vertices of `type`; cache reads the
  `memory-store`'s count.
- Every `rag:hit`'s chunk carries its provenance (`document-id`, `metadata`),
  reconstructed from the vertex slots (embedding coerced via `as-embedding`).

## 7. save-store / load-store (standalone-only convenience)

A VG graph is self-durable (transaction log + snapshots), so these matter only for
the standalone case; in the shared/field-data case the caller never calls them.

- **`save-store (store path)`** — implemented as a no-op that returns the store
  (the graph is self-durable via its own transaction log; an explicit checkpoint is
  the caller's `graph-db close-graph`/`snapshot`). It **does not close** the
  borrowed graph.
- **Standalone reopen is `open-graph-store (path …)`**, NOT `load-store`. As built,
  `rag:load-store` is a plain function in RAG core (not a generic) that always
  returns a `memory-store`, so a graph store cannot hook it; `open-graph-store`
  opens the graph via `gdb:open-graph` and returns a store over it. Primary
  construction is always `make-graph-store` over a graph you already hold.

## 8. Error model

- **`rag:llm-rag-error`** for parity with `memory-store`: embedding-dimension
  mismatch, and a chunk with no embedding, signal it (before mutating the graph).
- **`graph-db`'s own** transaction/graph errors propagate unwrapped. The caller
  owns the graph and its error semantics; the adapter does not paper over them.

## 9. Testing

Gated `cl-llm/rag/vivace/tests` (FiveAM, MIT) — **not in default CI** (needs
`graph-db`). Fast in-memory graph (`gdb:make-memory-graph`) + `mock-embedder` +
`mock-provider`:

- **Strategy parity** (load-bearing): `scan` and `cache` return identical rankings
  on the same corpus/query — strategy is invisible through the contract.
- **Dimension safety**: mismatch and nil-embedding signal `llm-rag-error`; a
  failed batch leaves `store-count` and dimension unchanged (atomic add).
- **Provenance survival**: hits carry `document-id`/`metadata`; embeddings come
  back as `(simple-array double-float (*))` after coercion.
- **One persistent close/reopen test** (real `make-graph` + `close-graph` +
  `open-graph`) pinning the serializer behaviour from §4 (values survive; coerce on
  read) and hydrate-on-attach (a reopened store finds its existing chunks).
- **End-to-end**: `make-index :store (make-graph-store g)` → `add-documents` →
  `rag-ask` answers from graph-stored chunks (mock provider), proving the adapter
  drops into the RAG pipeline unchanged.

Tests create graphs under a temp directory and clean up.

## 10. Architecture

```
  vivace/packages.lisp   package cl-llm.rag.vivace
  vivace/schema.lisp      rag-chunk vertex type; self-declare (def-vertex +
                          update-schema) on attach; embedding coerce-on-read
  vivace/store.lisp       graph-store / scan-graph-store / cached-graph-store;
                          make-graph-store, open-graph-store; the five generics;
                          store-add atomicity; hydrate-on-attach
```

Plus `tests-vivace/` and the ASDF systems `cl-llm/rag/vivace` and
`cl-llm/rag/vivace/tests` appended to `cl-llm.asd`. One small change to
`cl-llm/rag` itself: **export `as-embedding`** (§4).

## 11. The C seam (not built)

Nothing here precludes slice C: `document-id` is a property today and an edge
tomorrow; chunk vertices already live in the shared graph beside field data; and
VG's geohash spatial index (a geometry slot marked `:index t` auto-indexes by
location) is available for C's "ordnance within N km of this grid" joins. A builds
the substrate; C builds the joins.

## 12. Deferred: subclassing RAG objects

Carrying extra data by **subclassing** `document`/`chunk`/`hit` was considered and
**deferred** — v1 uses the objects as-is (the `metadata` plist is the extension
point). If a real need emerges, the change splits in two: (a) a `cl-llm/rag` core
change to make the objects subclassable and the pipeline construct them (cleanest
as a generic `chunk-document` specialised on a document subclass, so dispatch emits
the right chunk subclass); and (b) a graph-store serialization story — either a
**blob** slot holding the whole chunk object (arbitrary subclasses, works with the
current structs, extra slots not individually queryable) or **MOP slot-mirroring**
(every slot queryable, best for C's joins/spatial, but needs CLOS + MOP + dynamic
schema). Revisit alongside slice C, when the set of graph-queryable fields is
concrete — guessing them now is where the MOP machinery would be over-built.

## 13. Constraints

Lisp sources use spaces only, never tabs. MIT. SBCL-first. **This is the one system
that is not thread-free** — it depends on `graph-db`, which uses threads and
transactions; documented as the opt-in exception (§3). No *new* external
dependencies beyond `graph-db` itself (which transitively brings its own).
`cl-llm/rag`'s zero-new-dependency budget is unchanged — this add-on is separate
and optional.
