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

## Testing

```sh
sbcl --eval '(asdf:test-system :cl-llm)'                    # offline, no key needed
CL_LLM_LIVE=1 sbcl --eval '(asdf:test-system :cl-llm/live)' # real endpoints
```

The offline suite (`cl-llm/tests`) is 387 checks, sub-second, and needs no
network access or API key. It is what CI runs on every push and pull request.

The live suite (`cl-llm/live`) is a separate ASDF system that hits real
endpoints: Anthropic (needs `ANTHROPIC_API_KEY`) and, optionally, a local
OpenAI-compatible server (`CL_LLM_LOCAL_BASE_URL` / `CL_LLM_LOCAL_MODEL`,
defaulting to an Ollama instance at `http://localhost:11434/v1`). With
`CL_LLM_LIVE` unset or `0`, every live test skips via FiveAM's `skip` — no
network call is attempted and no key is required, so contributors without
credentials are never blocked.

## Status and limitations

Under development. Currently **not** implemented:

- Embeddings, RAG, and vector storage
- Hosted fine-tuning jobs
- Local training / LoRA (planned; see the design doc)
- Multimodal input — the content model supports it, the providers do not yet
- Streamed tool calls on OpenAI-compatible endpoints (non-streaming tool use
  works; Anthropic streams tool calls fine)

See `docs/superpowers/specs/2026-07-17-cl-llm-design.md` for the design and the
reasoning behind each non-goal.

## License

MIT
