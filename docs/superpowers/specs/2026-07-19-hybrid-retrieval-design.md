# Hybrid Dense+Sparse Retrieval (BM25 + embeddings) — Design

**Date:** 2026-07-19
**Status:** Approved (design). Branch of record (cl-llm): `feat/hybrid-retrieval`.
**Consumer:** mine-action's knowledge substrate — fixes exact-designation / general-concept recall
that pure dense retrieval misses.

---

## 1. Purpose & motivation

The mine-action KB eval (now a trustworthy, deterministic recall metric over a vetted gold set)
measured **dense-only retrieval at recall@5 = 0.875**, rising to **0.917 at k=8 and then
plateauing** — ~2 of 24 gold documents **never surface at any k up to 20**. Those are exactly the
queries this project cares about most: **exact ordnance designations** (TM-62M vs TM-62P) and
**general-concept lookups** ("what is det-cord", "what is a shaped charge") where the authoritative
source (e.g. the Cooper textbook) is out-ranked on cosine by shorter or translated decks. An
app-level re-ranker cannot fix this — it only reorders what dense already found; a document dense
never surfaces stays invisible. The fix is **true hybrid retrieval**: a lexical (BM25) index that
can *recall* a document on exact term overlap, fused with the dense results.

cl-llm's own examples already name this gap: *"precise retrieval of one designation is the job of
the (future) hybrid sparse+dense retriever."* This builds it.

## 2. Decisions (from the design discussion)

| Decision | Choice |
|---|---|
| **Sparse scoring** | **Roll our own BM25** (in-process inverted index, `cl-ppcre` tokenizer). No new dependency, sovereignty-clean, exact control over tokenizing military designations + Cyrillic. (Montezuma rejected: its value is an on-disk index format we don't need — we rebuild from the graph — and its analyzer needs Cyrillic tuning anyway.) |
| **Fusion** | **Reciprocal Rank Fusion (RRF)** — parameterless, robust, rank-based (no score calibration between cosine and BM25). |
| **Where it lives** | **cl-llm.rag core** — a new `sparse-store` (implements the shared store protocol for indexing) + a `hybrid-retriever` (peer of `dense-retriever`). Nothing in graph-db/vivace changes. |
| **Persistence** | **Rebuild the sparse index from the chunks at open** (hydrate), like `cached-graph-store`. No separate on-disk sparse index to keep in sync. |
| **Sovereignty** | All local — the corpus never leaves the host. |

## 3. Architecture

### 3.1 `sparse-store` (`cl-llm.rag`, new)

An in-RAM BM25 inverted index over chunk **text**. It implements the *indexing* half of the store
protocol so it stays in lock-step with the dense store, but its search is **text-based**, not
vector-based (BM25 needs the query string, not an embedding):

- `store-add (store chunks)` — tokenize each chunk's text; update postings (`token → list of
  (chunk . term-freq)`), per-chunk length, doc count, running average doc length.
- `store-count (store)` — number of indexed chunks.
- `store-delete-document (store document-id)` — drop the doc's chunks from the postings + stats
  (mirrors the dense `store-delete-document` so a refresh stays consistent across both indexes).
- `sparse-search (store query-string k) → list of hit` — **new generic**; tokenize the query,
  BM25-score candidate chunks, return the top-k as `hit`s (score = BM25 sum). It does **not**
  implement `store-search (store query-vector k)` — that generic is dense-only by contract.

### 3.2 `hybrid-retriever` (`cl-llm.rag`, new — peer of `dense-retriever`)

Holds an `embedder`, a `dense-store`, and a `sparse-store`. Implements the existing generic:

```lisp
(defmethod retrieve ((r hybrid-retriever) query &key (k 5))
  ;; 1. dense: embed the query text, cosine-search the dense store
  ;; 2. sparse: BM25-search the sparse store on the query text
  ;; 3. fuse the two ranked lists by RRF; return the top-k fused hits
  ...)
```

Each sub-search fetches a **candidate depth** `kc` (default `max(k, 20)` — deep enough that a
sparse-only hit can enter the fused top-k) and RRF combines them.

### 3.3 mine-action integration

`open-knowledge-graph` already builds a dense `cached-graph-store` over the chunk vertices. It
additionally builds a `sparse-store`, hydrating it from the same `map-chunk-vertices` scan, and
`knowledge-index` returns a `hybrid-retriever` over both. `*kb-default-k*` rises **5 → 8** (rides
along; recovers the one k-recoverable case). No graph schema change — the sparse index is derived
from text already in the graph. `store-delete-document` (the refresh path) fans out to both stores.

## 4. BM25 details

Standard Okapi BM25 per query token `t` over chunk (document) `d`:

```
score(d, q) = Σ_{t∈q}  IDF(t) · ( f(t,d)·(k1+1) ) / ( f(t,d) + k1·(1 - b + b·|d|/avgdl) )
IDF(t) = ln( 1 + (N - n(t) + 0.5) / (n(t) + 0.5) )
```
- `f(t,d)` term frequency; `|d|` chunk token count; `avgdl` mean over the corpus; `N` chunk count;
  `n(t)` chunks containing `t`. Defaults **k1 = 1.2, b = 0.75** (defparameters, tunable).
- **Tokenization (the load-bearing part for this domain):** lowercase, then extract maximal runs of
  Unicode letters/digits **with internal hyphens/slashes preserved**, so a designation like
  `TM-62M` stays a **single token** `tm-62m` (splitting it into `tm`/`62m` would destroy the exact
  match this feature exists for), and Cyrillic terms (`ТМ-62`) stay whole. No stemming, no
  stop-word removal in v1 (IDF already down-weights common tokens; stemming across EN/UK/RU is a
  future refinement). The tokenizer is a shared pure function, reused by `store-add` and
  `sparse-search`.

## 5. Reciprocal Rank Fusion

```
RRF(d) = Σ_{r∈{dense,sparse}}  1 / (c + rank_r(d))        c = 60 (standard), tunable
```
Rank is 1-based within each list; a document missing from a list contributes 0 from that list. RRF
is rank-based, so it needs no score normalization between cosine (0..1) and BM25 (unbounded) — the
reason it's the default hybrid fusion. Return the top-k documents by RRF, carrying each hit's chunk
(dense hit preferred when a chunk appears in both, so downstream metadata/score fields are populated).

## 6. Embedding-models rundown (the related recall lever)

Hybrid is the **first** retrieval lever because it targets the measured gap directly and needs **no
re-embedding**. A stronger *embedder* is the complementary lever, but heavier (a full corpus
re-embed + re-ingest, and the store dimension changes). Notes for when we take it up:

- **Current:** `bge-m3` (BAAI), 1024-dim, one of the strongest **open multilingual** retrievers
  (EN/UK/RU), local via Ollama. It is *not* the bottleneck for exact designations — that's a lexical
  problem hybrid fixes — but it may leave dense recall on the table for paraphrastic queries.
- **Sovereignty gate:** the corpus never leaves the host, so the embedder must be **local
  (Ollama-hostable)**. This rules out hosted embedders (OpenAI `text-embedding-3`, Voyage, Cohere)
  unless self-hosted — and note this constraint is *independent* of moving the **chat** model to a
  hosted Claude API: the embedder should stay local (or its chunk-text egress is an explicit
  sovereignty decision).
- **Candidates to A/B (local), roughly by interest:**
  - **Qwen3-Embedding** (0.6B / 4B / 8B) — top recent MTEB multilingual, Ollama-able; the 4B is a
    strong size/quality sweet spot.
  - **snowflake-arctic-embed-l-v2.0** — strong multilingual, Ollama-able.
  - **multilingual-e5-large** / **e5-mistral-7b-instruct** — e5-mistral is top-tier but heavy (7B,
    4096-dim → 4× the storage/compute of bge-m3).
  - **jina-embeddings-v3** — strong multilingual, long-context.
  - **nomic-embed-text** (already local) — English-leaning; unlikely an upgrade for UK/RU.
- **The eval is the yardstick:** recall@k over the vetted gold set is now the objective way to
  compare embedders — swap embedder → re-ingest → measure recall. The eval-maturation work directly
  enables principled embedder selection, so an embedder bake-off is a clean, measurable follow-up
  *after* hybrid lands (compare dense-only-bge-m3 vs dense-only-candidate vs hybrid on the same set).

## 7. Testing

Roll-our-own BM25 is fully deterministic → unit-testable offline (no model, no graph):
- **Tokenizer:** designations stay whole (`TM-62M → "tm-62m"`, not `tm`/`62m`); Cyrillic runs whole;
  hyphen/slash internal preserved; punctuation/whitespace split; lowercased.
- **BM25 scoring:** a chunk containing a rare query term outranks one with only common terms; IDF
  down-weights a token present in every chunk; longer chunks are length-normalized; `f=0 → 0`
  contribution.
- **`sparse-store` protocol:** add → count; `sparse-search` returns the exact-term chunk first;
  `store-delete-document` removes a doc from postings + stats and it no longer appears.
- **RRF fusion:** a doc ranked highly by *sparse only* (dense missed it entirely) enters the fused
  top-k — the core recall win; a doc top of both lists ranks first; empty sparse (no term overlap)
  degrades to dense order.
- **`hybrid-retriever` end-to-end** with mock embedder + a tiny corpus: an exact-designation query
  surfaces the sparse-only document that dense alone misses.
- **mine-action acceptance (the real proof):** re-run `run-kb-eval` and confirm **recall rises above
  the dense-only 0.875/0.917 plateau** — specifically that the ~2 persistent dense misses
  (det-cord / shaped-charge / SpotlightAI class) now surface. Correctness/groundedness (LLM-judge,
  noisy) are not the measure here; recall (deterministic) is.

## 8. Non-goals (YAGNI)

- **No Montezuma / external search engine** — roll-our-own BM25 is enough and dependency-free.
- **No hosted embedders** — sovereignty.
- **No stemming / lemmatization / stop-word lists** in v1 (cross-lingual stemming is its own project;
  IDF handles common terms).
- **No learned re-ranker / cross-encoder** — RRF is the fusion; a cross-encoder re-rank is a later,
  heavier lever.
- **No query expansion / synonyms** in v1.
- **No on-disk sparse index** — rebuilt from the graph at open.
- **The embedder swap itself is out of scope here** — this spec only *documents* the candidates;
  a bake-off is a separate, measured follow-up using this eval.

## 9. Process / deployment

- Develop in `/Users/kraison/work/cl-llm` on `feat/hybrid-retrieval`; FiveAM offline tests. Same
  flow as `store-delete-document`. mine-action consumes the local checkout.
- mine-action change (build the sparse-store at open, hybrid `knowledge-index`, `*kb-default-k*`→8)
  needs a server restart; the sparse index is built at open from existing chunks (no re-ingest).
- Acceptance = the eval's recall dimension improves on the dev hub.

## Related documents

- [`2026-07-18-cl-llm-rag-design.md`](2026-07-18-cl-llm-rag-design.md) — the retrieve/store protocol
  this extends (`retrieve`, `dense-retriever`, `store-search`).
- [`2026-07-19-store-delete-document-design.md`](2026-07-19-store-delete-document-design.md) — the
  store protocol + the refresh path the sparse store also participates in.
- mine-action `docs/superpowers/specs/2026-07-19-kb-eval-maturation-design.md` — the eval whose
  deterministic recall metric motivates and measures this.
