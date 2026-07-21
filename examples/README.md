# cl-llm examples

A catalog of runnable howtos. Each file is self-contained: definitions live at
the top level (so the file loads with no side effects), and the live,
model-calling demos are wrapped in a `run` function you invoke when you want to
see them. Inline `;; =>` comments show real output from an actual run.

## Running an example

Make the system loadable, then load a file and call its `run`:

```lisp
;; If the repo isn't in ~/quicklisp/local-projects, point ASDF at it:
(push #p"/path/to/cl-llm/" asdf:*central-registry*)

(load "examples/streaming.lisp")
(examples/streaming:run)
```

Each example is its own package (`examples/<name>`) so they don't clash.

## The catalog

| File | What it shows | Needs a network call? |
|------|---------------|------------------------|
| [quickstart.lisp](quickstart.lisp) | `ask`; Anthropic and local providers; specials vs. keywords | yes (a provider) |
| [ollama-cloud.lisp](ollama-cloud.lisp) | Remote cloud models via the local Ollama proxy — big models, zero local RAM | yes (Ollama + cloud) |
| [streaming.lisp](streaming.lisp) | Pull-based, thread-free streaming | yes |
| [conversations.lisp](conversations.lisp) | Multi-turn chat with a system prompt | yes |
| [tools.lisp](tools.lisp) | `deftool` + the automatic tool loop; tools run in-process | yes |
| [rag-quickstart.lisp](rag-quickstart.lisp) | `cl-llm/rag`: index → retrieve → grounded, cited, abstaining answers | **no** — offline via mocks |
| [rag-local.lisp](rag-local.lisp) | The same RAG pipeline with a real local Ollama embedder + persistence | yes (Ollama + an embed model) |
| [rag-crosslingual.lisp](rag-crosslingual.lisp) | Index Russian & Ukrainian sources, ask in English — cross-lingual retrieval via `bge-m3` | yes (Ollama + `bge-m3`) |
| [rag-eval.lisp](rag-eval.lisp) | Measure a RAG system: retrieval recall@k / MRR (standalone) + groundedness & abstention (`cl-llm/eval`) | yes (Ollama + `bge-m3`) |
| [rag-vivace.lisp](rag-vivace.lisp) | Back the RAG store with a vivace-graph (`graph-db`) graph: drop-in `make-graph-store`, the `:segment`/`:cache`/`:scan` strategies, persistence + hydrate | **no** — offline via mocks (needs `graph-db` on the ASDF path) |
| [errors-and-retries.lisp](errors-and-retries.lisp) | The condition hierarchy, timeouts, the `retry-request` restart | some (parts are offline) |
| [evaluation.lisp](evaluation.lisp) | `defsuite` / scorers / judge / `report` | **no** — runs offline via the mock |
| [testing-with-mock.lisp](testing-with-mock.lisp) | `mock-provider`: test your own cl-llm code with no network | **no** — offline |

Start with **rag-quickstart**, **evaluation**, and **testing-with-mock** if you
want to run something immediately without an API key or a running model — they use
the built-in `mock-provider` (and, for RAG, `mock-embedder`).

**rag-vivace** needs no key or model either (it uses the mocks), but it does need
the optional `cl-llm/rag/vivace` add-on's dependency, **`graph-db`**
(vivace-graph-v3), which isn't in Quicklisp — put it on the ASDF path before
loading, e.g. `(push #p"/path/to/vivace-graph-v3/" asdf:*central-registry*)`.

## Providers used

- **Anthropic** — `(make-instance 'cl-llm:anthropic-provider)`, reads
  `ANTHROPIC_API_KEY` from the environment.
- **Local / OpenAI-compatible** (Ollama, llama.cpp, vLLM, LM Studio) —
  `(make-instance 'cl-llm:openai-compatible-provider :base-url "..." :model "...")`.
- **Ollama Cloud** — the same OpenAI-compatible provider pointed at your local
  Ollama, with a `:cloud` model name; the local `ollama` forwards it to Ollama's
  servers. See `ollama-cloud.lisp`.
