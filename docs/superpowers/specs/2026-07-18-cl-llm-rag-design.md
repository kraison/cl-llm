# cl-llm/rag Design

**Date:** 2026-07-18
**Status:** Approved
**Relationship:** The embeddings/RAG addition deferred in the core spec
(`2026-07-17-cl-llm-design.md`, §3, as "likely a separate cl-llm-rag system
later"). Designed against the EOD mine-action requirements in
`docs/notes/2026-07-17-eod-expert-architecture.md`.

## 1. Purpose

`cl-llm/rag` adds retrieval-augmented generation to cl-llm: embed a corpus,
retrieve the passages relevant to a question, and answer *grounded in and citing
those passages*. Its first driving use case is a domain-expert assistant over
specialist demining literature, so grounding, citation, and the ability to
abstain are first-class, not afterthoughts.

It is a **separate ASDF system** (`cl-llm/rag`) depending only on `cl-llm`. A
user who never does retrieval never loads it.

## 2. Scope

### In scope for v1

- An **embedder** abstraction with a local/OpenAI-compatible default and a mock.
- A **document / chunk** data model in which provenance is structural.
- A default **chunker** (size-with-overlap, provenance-preserving), swappable.
- A **vector-store** protocol with a built-in brute-force exact-cosine
  `memory-store`, file persistence, and embedding-dimension safety.
- **Dense retrieval** end-to-end: `retrieve` → ranked, cited hits.
- **`rag-ask`** — a deterministic retrieve-then-answer flow that instructs the
  model to answer only from the retrieved context, cite sources, and abstain
  when unsupported. Returns the answer *and* the sources.
- A **retrieval `deftool`** for the agentic/multi-source path.
- Offline, deterministic tests via `mock-embedder` + `mock-provider`.

### Designed-in seams, built next (not v1)

- **Hybrid retrieval** — a `retriever` protocol so a future sparse/BM25 retriever
  fuses with the dense one (reciprocal-rank fusion) for exact ordnance-designation
  matching. v1 ships the dense retriever behind this protocol.
- **Cross-lingual retrieval** — architecturally almost free: choose a multilingual
  embed model in the embedder; the only code touch is per-chunk `language`
  metadata for filtering/display.
- **vivace-graph store adapter** — the `vector-store` protocol lets `graph-db`
  back the store (embeddings as node properties, nearest-neighbor there),
  unifying literature with field data. Lives in the EOD app or a later
  `cl-llm/rag/vivace` add-on, **never** as a dependency of `cl-llm/rag`.

### Explicit non-goals for v1

- Approximate nearest-neighbor / ANN indexing (brute-force exact is the v1
  default; ANN is a scale-out seam).
- OSINT / temporal-geospatial retrieval (a different retrieval problem; the
  agent joins it later).
- A full agent orchestrator (the EOD assistant is a downstream project; this is
  a tool it uses).

## 3. Boundary and dependencies

`cl-llm/rag` depends only on `cl-llm` and adds **no new external dependencies** —
brute-force cosine and file persistence are pure Common Lisp, and the embedder
reuses cl-llm's existing `cl-llm.http` / `cl-llm.json` wrappers. The core's
four-dependency budget (`dexador`, `com.inuoe.jzon`, `uiop`, `fiveam` test-only)
is unchanged.

The one hard boundary: **`cl-llm/rag` never depends on vivace-graph.** vivace
integration is an adapter satisfying the `vector-store` protocol, provided by the
consumer, exactly as the provider protocol keeps HTTP backends swappable.

Package: `cl-llm.rag`, with local nicknames `llm` → `cl-llm`,
`c` → `cl-llm.conditions`.

## 4. Embeddings

```lisp
(embed embedder "some text")           ; => a vector of floats
(embed embedder (list "a" "b" "c"))    ; => a list of vectors, one HTTP call
```

- **`embedder`** — abstract class; reader `embedder-model`. (Embedding
  dimension is owned by the *store*, §7, which records it from the first indexed
  chunk and enforces consistency — the embedder need not declare it.)
- **`openai-compatible-embedder`** (`:base-url :model :api-key`) — posts to
  `<base-url>/embeddings` using the same HTTP driver and bearer-auth path as
  `openai-compatible-provider`. Its `:model` is an *embedding* model
  (`nomic-embed-text`, `bge-m3`, `multilingual-e5`, …), independent of any chat
  model. Local-first: points at Ollama / llama.cpp / vLLM by default, keeping
  data in-country.
- **`mock-embedder`** — returns a deterministic vector derived from the text
  (a stable hash into a fixed-dimension float vector), so the offline suite gets
  real, distinguishable, reproducible embeddings with no network.

`(embed embedder texts)` returns vectors in input order; a text that fails to
embed aborts the batch with `llm-api-error` (the existing HTTP error path).

## 5. Data model — provenance is structural

- **`document`** — a source unit: `document-id`, `document-text`,
  `document-metadata` (a plist; conventionally holds `:title`, `:source`,
  `:language`, and anything else). `(make-document text &key id metadata)`.
- **`chunk`** — a retrievable slice: `chunk-text`, `chunk-document-id`,
  `chunk-metadata` (inherited from its document plus `:position`), and
  `chunk-embedding`. A chunk always carries enough to cite its origin.
- **`hit`** — a retrieval result: `hit-chunk` and `hit-score` (cosine
  similarity). `retrieve` returns a ranked list of these.

Accessors use the `document-*` / `chunk-*` / `hit-*` convention. Note the chunk's
text accessor is `chunk-text`; the *chunker* function (§6) is `split-text`, a
distinct symbol, so the accessor and the function do not collide.

## 6. Chunking

```lisp
(split-text text &key (size 1000) (overlap 200)) ; => list of (substring . position)
```

The default chunker `split-text` splits `text` into overlapping windows of
approximately `size` characters with `overlap` characters shared between
neighbors, recording each chunk's start position. It is deliberately simple and
deterministic in v1.
`add-documents` accepts a `:chunker` function to swap in a smarter one (sentence-
or token-aware, language-aware) without touching the rest of the pipeline.

## 7. Vector store

```lisp
(defgeneric store-add (store chunks))            ; index chunks (with embeddings)
(defgeneric store-search (store query-vector k)) ; => k highest-cosine hits
(defgeneric store-count (store))
(defgeneric save-store (store path))
(defgeneric load-store (path))                   ; => a store
```

- **`memory-store`** (the built-in default) — holds chunks in a flat vector.
  `store-search` computes exact cosine similarity of `query-vector` against every
  chunk embedding and returns the top `k` as `hit`s. Exact, portable, zero-dep,
  and appropriate for a specialist corpus of thousands to low-hundred-thousands
  of chunks. No threads.
- **Persistence** — `save-store`/`load-store` serialize chunks and their vectors
  to a defined on-disk format (pure CL; no new dependency). A round-trip
  reproduces an identical store.
- **Dimension safety** — a store records the embedding dimension of its first
  chunk. `store-add` of a differently-dimensioned chunk, or `store-search` with a
  mismatched query vector, signals `llm-rag-error` — indexing with one embed
  model and querying with another otherwise silently corrupts similarity.

vivace-graph (or any other backend) becomes a store by implementing these five
generic functions; nothing else in the pipeline changes.

## 8. Retrieval and the hybrid seam

```lisp
(retrieve retriever query &key (k 5)) ; => ranked list of hits
```

- A **`retriever`** protocol (`retrieve`) sits over the store so retrieval
  strategy is swappable.
- **`dense-retriever`** (v1) wraps an `embedder` + a `vector-store`: it embeds the
  query and calls `store-search`.
- The seam for **hybrid**: a future `sparse-retriever` (keyword/BM25) and a
  `fusion-retriever` that merges two retrievers' rankings via reciprocal-rank
  fusion. v1 defines the protocol and ships only the dense retriever.

## 9. Index — the convenience that ties it together

```lisp
(make-index &key embedder store chunker) ; defaults: openai-compatible-embedder,
                                         ; memory-store, the default chunker
(add-documents index documents)          ; chunk -> embed -> store
(retrieve index query :k 5)              ; index is itself a retriever
(save-index index path) / (load-index path embedder)
```

An `index` bundles an `embedder`, a `vector-store`, and a `chunker`, and is
itself a `retriever` (delegating to an internal `dense-retriever`).
`add-documents` runs the pipeline: chunk each document (carrying provenance),
embed the chunks (batched), and `store-add` them.

## 10. Grounded answering

```lisp
(rag-ask index question &key (k 5) (provider *provider*) system)
;; => (values answer-text hits)
```

`rag-ask`:

1. `retrieve`s the top `k` hits for `question`.
2. `assemble-context`s them into a numbered, cited context block.
3. Builds a prompt instructing the model to **answer only from the provided
   context, cite the sources it uses by number, and state "not in the provided
   sources" when the answer is not supported** — the abstention discipline.
4. Calls `ask` and returns `(values answer hits)`, so the caller always has both
   the answer and the exact passages it was grounded in.

A caller-supplied `system` prompt (a domain persona, tone, extra rules) is
composed *with* — not in place of — `rag-ask`'s grounding/citation/abstention
instructions, so the safety discipline can't be silently dropped by passing a
`system`.

The grounding/abstention behavior is **prompt-driven in v1** — which is exactly
what the `cl-llm/eval` harness exists to measure (groundedness/faithfulness
scorers, abstention on out-of-corpus questions) before any operational trust.

`assemble-context` is exposed separately, and `make-retrieval-tool`:

```lisp
(make-retrieval-tool index &key (k 5)) ; => a tool for (ask ... :tools (list it))
```

returns a `deftool`-style tool that retrieves and returns a cited context block,
for the composable/agentic path where the model decides whether to retrieve
(e.g. the eventual graph + literature + OSINT agent).

## 11. Errors

- **`llm-rag-error`** (subtype of `cl-llm:llm-error`) — RAG misuse: an empty
  corpus, an embedding-dimension mismatch, an unknown store/retriever, a
  malformed document. Surfaced immediately, like `llm-eval-error`.
- Embedding **transport** failures reuse the existing `llm-api-error` /
  `llm-timeout-error` path (they go through `cl-llm.http`).

## 12. Architecture

```
  rag/packages.lisp    package cl-llm.rag; llm-rag-error
  rag/embed.lisp       embedder, openai-compatible-embedder, mock-embedder, embed
  rag/document.lisp    document, chunk, hit, make-document
  rag/chunk.lisp       split-text (default chunker)
  rag/store.lisp       vector-store protocol, memory-store, cosine, persistence,
                       dimension safety
  rag/retrieve.lisp    retriever protocol, dense-retriever, retrieve
  rag/index.lisp       index, make-index, add-documents, save/load-index
  rag/answer.lisp      assemble-context, rag-ask, make-retrieval-tool
```

The `mock-embedder` lives here (not core), paired with the core `mock-provider`
for offline tests — the two together make the whole RAG path testable with no
network.

## 13. Testing

`cl-llm/rag/tests` (FiveAM, MIT) runs **fully offline** via `mock-embedder`
(deterministic vectors) and `mock-provider` (scripted answers):

- `embed` returns stable vectors; batching preserves order.
- Chunking splits with correct overlap and positions; provenance is carried onto
  each chunk.
- `add-documents` chunks + embeds + stores; `store-count` is right.
- `retrieve` ranks the genuinely-nearest chunk first (constructed so the mock
  vectors make the expected chunk closest), and hits carry provenance.
- A dimension mismatch signals `llm-rag-error`; an empty corpus is handled.
- `save`/`load` round-trips a store to an identical state.
- `rag-ask` assembles a cited context, instructs abstention, and returns
  `(values answer hits)` with the mock answer and the grounding hits.
- `make-retrieval-tool` returns a working tool that yields a cited context.

A gated `cl-llm/rag/live` suite (on `CL_LLM_LIVE`) hits a real Ollama embeddings
endpoint (e.g. `nomic-embed-text`) to confirm the OpenAI-compatible embed path.

## 14. Constraints (inherited)

Lisp sources use spaces only, never tabs. No threads anywhere (brute-force search
is a serial loop; the `*eval-map*`-style seam is not needed here, but nothing
precludes a consumer parallelizing). SBCL first; nothing implementation-specific,
so ECL/Clozure remain viable. No new external dependencies. License MIT.
