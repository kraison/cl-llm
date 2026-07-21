# cl-llm

A Common Lisp library for interacting with and tuning LLMs.

Supports **Anthropic** and **local / OpenAI-compatible** endpoints (llama.cpp,
Ollama, vLLM, LM Studio). SBCL is the primary target; ECL and Clozure are
supported by construction — the library uses no threads.

## Install

```lisp
(ql:quickload :cl-llm)
```

Set `ANTHROPIC_API_KEY` in your environment for the default provider.

## Examples

Runnable howtos live in [`examples/`](examples/) — quickstart, streaming,
conversations, tools, error handling, Ollama Cloud (remote models), the
evaluation harness, and testing your own code with the mock provider. The
`evaluation` and `testing-with-mock` examples run offline with no API key. See
[`examples/README.md`](examples/README.md) for the catalog.

## Use

```lisp
(cl-llm:ask "Explain CLOS in one sentence")
;; => "CLOS is Common Lisp's object system, built on generic functions..."
```

Every keyword has a matching special variable, so a one-liner and a fully
specified call are the same API:

```lisp
(let ((cl-llm:*model* "claude-opus-4-8"))
  (cl-llm:ask "..." :temperature 0.2 :system "Be terse."))
```

### Conversations

```lisp
(let ((c (cl-llm:make-conversation :system "You are terse.")))
  (cl-llm:send c "hi")
  (cl-llm:send c "and again"))
```

### Streaming

Streaming is pull-based and thread-free — `next-delta` reads one event in your
own thread. The stream is a live resource, so scope it:

```lisp
(cl-llm:with-streamed-response (r "Write a haiku")
  (cl-llm:do-deltas (d r)
    (write-string d)
    (force-output)))
```

A streamed response is single-consumer and not restartable.

### Tools

`deftool` defines the whole tool surface in Lisp. It expands to a plain `defun`
plus a registration form, and the tool loop calls your function **in-process** —
so a tool body closes over live database handles, open transactions, and
whatever else an ordinary function would:

```lisp
(cl-llm:deftool find-related (node-id (depth :type integer :default 1))
  "Find nodes related to the given node in the knowledge graph."
  (vivace-graph:with-graph (*graph*)
    (vivace-graph:lookup-related node-id :depth depth)))

(cl-llm:ask "What connects to node n42?" :tools '(find-related))
```

The JSON schema is derived from the lambda list:

| Form                                | Schema                       |
|-------------------------------------|------------------------------|
| `city`                              | required string              |
| `(units :celsius :fahrenheit)`      | required enum                |
| `(depth :type integer)`             | required integer             |
| `(limit :type integer :default 10)` | optional integer, default 10 |
| `(ids :type (list string))`         | required array of strings    |
| `(note :type string :optional t)`   | optional string              |

Types: `string`, `integer`, `number`, `boolean`, `(list <type>)`.

The tool loop runs automatically and is bounded by `*max-tool-turns*` (default
8), so a runaway loop is impossible rather than merely unlikely.

> **Security.** The *model* chooses the arguments. A narrow tool is bounded by
> its schema; a general escape hatch such as `(deftool run-query (sql) ...)`
> grants the model arbitrary execution against your store. Prefer narrow,
> purpose-specific tools, and treat every tool argument as untrusted input.

## Evaluation

`cl-llm/eval` is a separate ASDF system for evaluating prompts and models: a
dataset of cases run across a grid of variants and scored, with a text report
at the end. It has its own package, `cl-llm.eval` (conventionally
local-nicknamed `eval:`, as below), and its own offline test suite
(`cl-llm/eval/tests`), which — like the core suite — runs entirely against
`cl-llm:make-mock-provider` and needs no API key or network access.

```lisp
(eval:defsuite greeting-suite
  :dataset (list (eval:make-case "hi" :expected "hi")
                 (eval:make-case "yo" :expected "yo"))
  :variants ((:model "claude-haiku-4-5" :temperature 0.0 :label "cold")
             (:model "claude-haiku-4-5" :temperature 1.0 :label "warm"))
  :scorers (eval:exact-match))

(eval:report (eval:run-suite 'greeting-suite) :detail t)
```

`run-suite` runs every (case, variant) pair through `cl-llm:ask`, scores each
response with the suite's scorers, and returns a `suite-result`; a failed
`ask` call becomes an error cell rather than aborting the run. `report`
prints a summary table (one row per variant, one column per scorer, each cell
the mean score — `—` when a variant has no scoreable cells) and, with
`:detail t`, a per-case breakdown showing each scorer's value and
explanation. `suite-result` also has its own `print-object`, so evaluating a
result at the REPL shows the same summary table.

Beyond `exact-match`, `defscorer` defines custom scoring functions and
`defjudge` builds an LLM-as-judge scorer that prompts a model to grade a
response and parses back a numeric score.

### Local models

```lisp
(let ((cl-llm:*provider* (make-instance 'cl-llm:openai-compatible-provider
                                        :base-url "http://localhost:11434/v1"
                                        :model "llama3.1")))
  (cl-llm:ask "hi"))
```

Non-streaming tool use is fully supported against OpenAI-compatible endpoints.
Streaming tool calls are not: `parse-stream-event` terminates the stream
cleanly on a `tool_calls` delta but does not assemble it into a tool-use part,
so a streamed response that needs tool use should fall back to `chat-request`.

### Errors

Everything signals under `cl-llm:llm-error`: `llm-http-error`, `llm-api-error`,
`llm-rate-limit-error`, `llm-auth-error`, `llm-timeout-error`, `llm-parse-error`,
`llm-tool-error`. 429 and 5xx are retried with exponential backoff honoring
`Retry-After`, bounded by `*retries*`. A `retry-request` restart is established
around every request.

## Retrieval (RAG)

`cl-llm/rag` is a separate ASDF system: chunking, embedding, a vector store,
and grounded answering on top of `cl-llm`. It has its own package,
`cl-llm.rag` (conventionally local-nicknamed `rag:`, as below), and its own
offline test suite (`cl-llm/rag/tests`), which runs entirely against
`rag:make-mock-embedder` and `cl-llm:make-mock-provider` — no API key or
network access needed.

```lisp
(let ((index (rag:make-index
              :embedder (rag:make-openai-compatible-embedder
                         :base-url "http://localhost:11434/v1"
                         :model "nomic-embed-text"))))
  (rag:add-documents index
                     (list (rag:make-document
                            "The TM-62 is a Soviet anti-tank blast mine with a pressure fuze."
                            :id "tm62" :metadata (list :title "TM-62"))))
  (multiple-value-bind (answer hits) (rag:rag-ask index "What fuze does the TM-62 use?")
    (values answer hits)))
```

`make-index` combines an embedder, a chunker, and a vector store;
`add-documents` chunks, embeds (in a single batch call), and stores.
`rag-ask` retrieves the top `:k` chunks, assembles them into a numbered,
cited context block (`assemble-context`), and asks the model to answer using
ONLY that context — citing sources by number and saying "not in the provided
sources" instead of guessing when the retrieved passages don't support an
answer. That grounding instruction (`*grounding-instructions*`) is always
included, even when a caller supplies its own `:system` prompt; the two are
composed, never one replacing the other. `rag-ask` returns
`(values answer hits)`, so callers can show citations alongside the retrieved
sources. For agentic use, `make-retrieval-tool` wraps an index as a
`cl-llm:tool` the model can call to fetch its own cited context.

### Graph-backed stores (`cl-llm/rag/vivace`)

`cl-llm/rag/vivace` lets a persistent [vivace-graph](https://github.com/kraison/vivace-graph)
(`graph-db`) graph *be* the vector store, so the retrieval corpus lives in the
same graph as your other data. Chunks become vertices of a self-declared
`rag-chunk` vertex type; the store satisfies the same protocol a `memory-store`
does, so nothing else in the pipeline changes:

```lisp
;; v = cl-llm.rag.vivace, rag = cl-llm.rag, gdb = graph-db
(let* ((embedder (rag:make-openai-compatible-embedder
                  :base-url "http://localhost:11434/v1" :model "nomic-embed-text"))
       ;; open-graph-store opens (and hands you) its own graph.  :name defaults
       ;; to the last directory component upcased -- :KB here.
       (store (v:open-graph-store #p"/var/tmp/kb/" :name :kb))
       (index (rag:make-index :embedder embedder :store store)))
  (rag:add-documents index documents)
  (multiple-value-prog1 (rag:rag-ask index "What fuze does the TM-62 use?")
    ;; the caller owns the graph: close it to release the mmaps and clear .dirty
    (gdb:close-graph (v:graph-store-graph store))))
```

`open-graph-store` is for the RAG-only case. When you already have a graph open
— field data and retrieval corpus in one place — use `make-graph-store` over it
instead; it borrows the graph and never opens or closes it:

```lisp
(rag:make-index :embedder embedder
                :store (v:make-graph-store graph :type 'my-chunk :dimension 1024))
```

`:type` names the chunk vertex type (default `rag-chunk`) — give it your own
name if the graph holds more than one corpus. `:dimension` is optional; a store
otherwise learns its dimension from the first chunk written or hydrated, and
rejects a later mismatch either way.

`examples/rag-vivace.lisp` is a runnable end-to-end walkthrough (mock embedder,
real on-disk graph, index → ask → close → reopen).

#### Choosing a strategy

Both constructors take `:strategy`. The three are **trades, not a progression** —
all of them are supported:

| strategy | dense search @20k | corpus in the Lisp heap | what it is |
| --- | --- | --- | --- |
| `:segment` (**default**) | ~35 ms | no | embeddings live in graph-db's mmap vector segment; search never materialises a chunk vertex it will not return |
| `:cache` | **~15 ms** | **yes** | an in-RAM index over the same graph. The **fastest** option and **not deprecated** |
| `:scan` | ~2.3 s | no | no index; rescans every chunk vertex per query. Fallback and correctness reference |

`:cache` is faster than `:segment`, and that is not a defect: the corpus is
already in the heap, so there is nothing to decode. `:segment`'s advantage is
that the corpus **does not have to be** in the heap, and that the embeddings are
queryable alongside ordinary graph queries. If your corpus fits comfortably in
the heap and latency matters, `:cache` is still the right answer — pass it
explicitly.

**The default changed from `:cache` to `:segment`.** A caller that never passed
`:strategy` now gets a segment-backed store. Pass `:strategy :cache` to keep the
previous behaviour. Passing `:strategy` explicitly is worth doing either way: it
is self-documenting and immune to future default changes.

#### Declare the chunk class before you open the graph

If you open your own graph with `gdb:open-graph`, call `ensure-chunk-class`
**first**:

```lisp
(v:ensure-chunk-class 'my-chunk :my-graph)          ; type, then graph name
(let ((graph (gdb:open-graph :my-graph #p"/var/tmp/kb/")))
  (v:make-graph-store graph :type 'my-chunk :dimension 1024))
```

`open-graph` instantiates the persisted chunk vertices, which requires the class
to already exist — in a fresh image (any process restart) it does not. Letting
`make-graph-store` declare it is too late, because that runs *after* the open.
Under `:segment` the ordering is load-bearing for a second reason: re-registering
an existing vector segment at open needs the owning class defined *and*
finalized. `ensure-chunk-class` is idempotent, so it is a no-op in a warm image.
`open-graph-store` does this for you.

#### First open of an existing store

Under `:segment`, `hydrate` fills the vector segment with any chunk not already
in it. The sweep is batched and resumable — the segment itself records which ids
it holds, so an interrupted migration is finished by the next open — and it
reports progress on `*error-output*`, because a multi-minute silent migration
looks hung. Legacy embeddings that are not already normalised
`(simple-array single-float (*))` vectors are rewritten in place first, honouring
`cl-llm.rag.vivace:*embedding-migration-policy*` (`:migrate` by default;
`:error` refuses to open). That step is not optional: the segment silently skips
non-conforming vectors, so without it those chunks would be missing from every
search result with no error at all.

**Expect the first open of an existing corpus to be slow, once.** Later opens
still walk the chunk vertices to find anything unindexed, but skip what is
already there.

Sizing: the vector block is `chunks × dimension × 4` bytes — **4 KB per chunk at
dimension 1024**, so 20k chunks ≈ 80 MB and 1M ≈ 4 GB, on disk inside the graph
directory.

For an existing deployment moving to `:segment` — rollout, rollback, and the
gotchas that come with a real corpus — see
[`docs/2026-07-21-segment-store-transition-guide.md`](docs/2026-07-21-segment-store-transition-guide.md).

#### Results are the same across strategies

`store-search` returns a list of `rag:hit` (`rag:hit-chunk` / `rag:hit-score`)
whichever strategy you use, and the **ranking is identical, ties included** —
`:segment` over-fetches from the engine and re-ranks through cl-llm's own
collector, because the engine's tiebreak is by node id and cl-llm's is by
document id. Deleted chunks are filtered out on every strategy.

Scores match too for the unit-norm query vectors `rag:embed` produces. On a query
vector that is *not* unit-norm, `:segment` returns `:cache`'s score divided by the
query norm — the engine computes a full cosine, `:cache` a bare dot product.
Ordering is unaffected, so this is only visible to a caller that hand-builds an
unnormalised query and compares absolute scores across strategies.

A separate live suite (`cl-llm/rag/live`) exercises a real embeddings
endpoint (e.g. Ollama with `nomic-embed-text`) and skips cleanly with
`CL_LLM_LIVE` unset — the same gating convention as `cl-llm/live`.

## Testing

```sh
sbcl --eval '(asdf:test-system :cl-llm)'                    # offline, no key needed
CL_LLM_LIVE=1 sbcl --eval '(asdf:test-system :cl-llm/live)' # real endpoints
```

The offline suite (`cl-llm/tests`) is several hundred checks, sub-second, and
needs no network access or API key. It is what CI runs on every push and pull
request. The separate `cl-llm/eval` system has its own offline suite
(`sbcl --eval '(asdf:test-system :cl-llm/eval)'`).

`cl-llm/rag/vivace`'s offline suite needs a **larger heap than SBCL's 1GB
default** — run it with `--dynamic-space-size 4096`, or it exhausts the heap
on roughly two runs in three (a pre-existing ~870MB retention in the vivace
suite fixtures, tracked as cl-llm#11; not caused by, and not specific to, the
`:segment` strategy tests):

```sh
sbcl --dynamic-space-size 4096 --non-interactive \
     --eval '(asdf:test-system :cl-llm/rag/vivace/tests)'
```

The live suite (`cl-llm/live`) is a separate ASDF system that hits real
endpoints: Anthropic (needs `ANTHROPIC_API_KEY`) and, optionally, a local
OpenAI-compatible server (`CL_LLM_LOCAL_BASE_URL` / `CL_LLM_LOCAL_MODEL`,
defaulting to an Ollama instance at `http://localhost:11434/v1`). With
`CL_LLM_LIVE` unset or `0`, every live test skips via FiveAM's `skip` — no
network call is attempted and no key is required, so contributors without
credentials are never blocked.

## Status and limitations

Under development. Currently **not** implemented:

- Hosted fine-tuning jobs
- Local training / LoRA (planned; see the design doc)
- Multimodal input — the content model supports it, the providers do not yet
- Streamed tool calls on OpenAI-compatible endpoints (non-streaming tool use
  works; Anthropic streams tool calls fine)
- Approximate nearest-neighbour search. **Every strategy — `:segment` included —
  is a brute-force exact scan**, so dense-search latency is linear in corpus
  size: roughly 1.85 ms per 1000 chunks at dimension 1024 while the vector block
  fits in page cache, and considerably worse once it does not. At a scale where
  that hurts, the answer is an ANN index, and there isn't one yet.

Two things worth knowing about the graph-backed store:

- **`:segment` has been developed and tested on SBCL only.** The vivace suite has
  never been run on ECL, and `:segment` is now the default — so an ECL user gets
  an untested path unless they pass `:strategy :cache` or `:scan`. There is an
  existing related report of ECL/SBCL store disagreement
  ([cl-llm#9](https://github.com/kraison/cl-llm/issues/9)).
- Do not construct two `:segment` stores over the same graph from two threads at
  once — the engine requires that two migrations of one segment never overlap.
  Concurrent *readers* are safe.

See `docs/superpowers/specs/2026-07-17-cl-llm-design.md` for the design and the
reasoning behind each non-goal.

## License

MIT
