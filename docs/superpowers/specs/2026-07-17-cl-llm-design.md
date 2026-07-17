# cl-llm Design

**Date:** 2026-07-17
**Status:** Approved

## 1. Purpose

`cl-llm` is an open source Common Lisp library for interacting with and tuning
large language models. It targets SBCL first, with ECL and Clozure kept viable
by construction rather than by later porting effort.

The library is REPL-first: a one-line call must work with no ceremony, and the
same API must scale to full control without switching idioms.

## 2. Relationship to the Allegro LLM API

Franz's Allegro CL LLM API (package `llm.gpt`, nickname `gpt`) is the
inspiration for this library's ergonomics, not a compatibility target.

**What we take:** REPL-first design, short verbs, special variables for
defaults, docstring-driven definitions.

**What we reject, and why:** Allegro's surface is OpenAI-only and reflects a
GPT-3-era API. It centers on `ask-chat`, `chat` (for the retired ada/babbage/
davinci completion models), and a generic `call-openai` escape hatch; it exposes
roughly twenty `*openai-default-*` special variables; it uses OpenAI's
deprecated `functions`/`function_call` tool shape; and it documents no
streaming, no conversation object, and no error conditions. Cloning that surface
would import its limitations as our primary design.

Consequently there is **no `llm.gpt` package, no `*openai-default-*` variables,
no `call-openai`, and no `ask-my-documents`**. Allegro code does not port to
cl-llm; this is intentional and accepted.

## 3. Scope

### In scope for v1

- Chat completion (single-shot and multi-turn conversations)
- Streaming responses
- Tool use, including an automatic bounded tool loop
- Inference-time tuning parameters (temperature, top-p, max-tokens, system
  prompt, stop sequences)
- An evaluation harness for the "tune by measuring" loop
- Providers: **Anthropic** and **local / OpenAI-compatible** endpoints
  (llama.cpp, Ollama, vLLM, LM Studio)

### Explicit non-goals for v1

These are recorded so they are not lost, and so their absence is understood as a
decision rather than an oversight.

- **Hosted fine-tuning jobs.** Deferred because neither chosen v1 provider
  offers one: Anthropic has no public fine-tuning API, and OpenAI-compatible
  local servers do not either. Fine-tuning is an OpenAI-family feature, and
  designing the abstraction with zero backends to validate it against would be
  guesswork. It returns when there is a real provider for it.
- **Embeddings, RAG, and the vector database.** No `embed`, `nn`,
  `ask-my-documents`, or `vector-database`. Anthropic has no embeddings
  endpoint, so v1 support would be local-only. Likely a separate `cl-llm-rag`
  system later.
- **Local training / LoRA. (TODO, post-v1 — explicitly desired.)** Actually
  training weights from Lisp, including the ability to spin up a remote
  JarvisLabs host to perform training. This is a stated eventual goal for the
  project. It is out of scope for v1 because it likely requires FFI to a
  Python/C stack and is a substantially larger project than the client library.
  Hosted fine-tuning is expected to return alongside this work.
- **Multimodal input (images, audio).** Not implemented in v1, but the message
  content model (§6) is designed so this is an addition, not a rewrite.
- **Providers beyond Anthropic and OpenAI-compatible.** The provider protocol is
  extensible; Google Gemini and a first-party OpenAI backend are plausible
  additions.

## 4. Portability strategy

SBCL is the first target. ECL and Clozure are supported by construction:

1. **No threads anywhere in the library.** This is why streaming is pull-based
   (§7). It means the library works on ECL built without thread support.
2. **Implementation-sensitive code is confined to two wrapper packages**,
   `cl-llm/http` (over Dexador) and `cl-llm/json` (over com.inuoe.jzon). Both
   dependencies already build on all three implementations. A swap of either is
   one file, not a refactor. These wrappers are internal protocols, not a
   user-facing pluggable driver system — that flexibility is not worth the
   combinatorial test burden.

## 5. Architecture

Layers, each independently testable:

```
  facade      ask / send / with-streamed-response / deftool / defsuite
  core        conversation, message, response, tool, provider  (CLOS)
  protocol    chat-request, stream-request, encode-request,
              decode-response, parse-stream-event   (generic functions)
  providers   anthropic | openai-compatible
  portability cl-llm/http (dexador)   cl-llm/json (jzon)   cl-llm/sse
```

The portability row is the only implementation-sensitive code, and it is the
seam where the fake HTTP driver plugs in for tests (§9).

### ASDF systems

| System         | Contents                                            |
|----------------|-----------------------------------------------------|
| `cl-llm`       | Core library, facade, both providers                |
| `cl-llm/eval`  | Evaluation harness                                  |
| `cl-llm/tests` | Offline fixture-replay suite (the default)          |
| `cl-llm/live`  | Live-endpoint suite, gated on `CL_LLM_LIVE`         |

## 6. Core objects

- **`message`** — a role plus content. **Content is a list of parts** (text,
  tool-use, tool-result), never a bare string. This costs a small amount of
  complexity now and is what makes multimodal a v2 addition rather than a v2
  rewrite.
- **`conversation`** — messages, system prompt, provider, model, parameters.
- **`response`** — content parts, convenience `text`, tool calls, stop reason,
  token usage, and the raw decoded payload.
- **`tool`** — name, description, JSON schema, and the implementing function.
- **`provider`** — abstract; `anthropic-provider` and
  `openai-compatible-provider` specialize it.

### Protocol generic functions

`chat-request`, `stream-request`, `encode-request`, `decode-response`,
`parse-stream-event`, `provider-default-model`.

## 7. Public API

```lisp
(ask "Explain CLOS in one sentence")   ; => string; response object as 2nd value

(let ((*model* "claude-opus-4-8"))
  (ask "..." :temperature 0.2 :system "Be terse."))

(let ((c (make-conversation :system "You are terse.")))
  (send c "hi")
  (send c "and again"))

(with-streamed-response (r "Write a haiku")
  (do-deltas (d r) (write-string d)))

(deftool get-weather (city (units :celsius :fahrenheit))
  "Look up current weather for a city."
  (weather-lookup city units))
(ask "Weather in Oakland?" :tools '(get-weather))
```

### Special variables

`*provider*`, `*model*`, `*temperature*`, `*max-tokens*`, `*system*`, `*tools*`,
`*retries*`, `*timeout*`.

Every special mirrors a keyword argument of the same name, so the one-liner and
the fully-specified call are the same API rather than two parallel ones.

### Tools

`deftool` derives the JSON schema from a typed lambda list and the docstring,
and expands to a plain `defun` plus a registration form — nothing is hidden.
Parameters are either a bare symbol (a required string parameter) or a list of
`(name . allowed-values)` which becomes a schema enum.

`ask` with `:tools` runs the **tool loop automatically**: the model requests a
tool, cl-llm executes it, feeds the result back, and repeats. The loop is
bounded by `:max-tool-turns` (default 8), making runaway loops impossible rather
than merely unlikely. `send` exposes the single-turn version for callers who
want to drive the loop themselves.

### Streaming

Streaming is **pull-based and thread-free**. The response object owns the live
HTTP stream; `next-delta` reads and parses exactly one SSE event per call, in
the caller's own thread. `next-event` exposes typed raw events.
`with-streamed-response` guarantees the stream is closed via `unwind-protect`;
`do-deltas` is the iteration convenience.

Documented tradeoff: the stream is a real resource, so a streamed response is
**single-consumer and not restartable**.

## 8. Error handling

Condition hierarchy rooted at `llm-error`:

| Condition              | Meaning                                  |
|------------------------|------------------------------------------|
| `llm-http-error`       | Transport/status failure (carries status)|
| `llm-api-error`        | Provider-level error (code, type)        |
| `llm-rate-limit-error` | 429 (carries retry-after)                |
| `llm-auth-error`       | Missing/invalid credentials              |
| `llm-timeout-error`    | Request exceeded `*timeout*`             |
| `llm-parse-error`      | Malformed response or SSE payload        |
| `llm-tool-error`       | A tool function signaled during the loop |

A `retry-request` restart is established around every request, so the debugger
is a useful place to land rather than a dead end. Automatic exponential backoff
applies to 429 and 5xx responses, honoring `Retry-After` when present, bounded
by `*retries*`.

API keys are read from the environment (`ANTHROPIC_API_KEY`) by default and are
never written to logs, condition reports, or fixtures.

## 9. Evaluation harness

`cl-llm/eval` implements a dataset × variants × scorers grid:

```lisp
(defsuite haiku-quality
  :dataset *cases*
  :variants ((:model "claude-opus-4-8" :temperature 0.0)
             (:model "claude-opus-4-8" :temperature 1.0))
  :scorers (exact-match judge-fluency))

(run-suite 'haiku-quality)   ; => result table
```

- **Dataset** — cases of input plus optional expected output.
- **Variants** — model/prompt/parameter combinations to compare.
- **Scorers** — `exact-match`, arbitrary predicates, and LLM-as-judge.
- **Result** — a comparable table across the cross product.

Deliberately excluded from v1: persisted run history, baseline regression
detection, and report export. Those constitute their own project.

## 10. Testing

Test-driven throughout.

- **`cl-llm/tests` (default)** — offline, deterministic, requires no API key.
  A fake HTTP driver replays recorded JSON and SSE fixtures through the
  `cl-llm/http` seam, so request-building and SSE parsing — where the bugs
  actually are — are covered rather than mocked past.
- **`cl-llm/live`** — hits real Anthropic and a real local server. Gated on the
  `CL_LLM_LIVE` environment variable so contributors without keys are never
  blocked.

```sh
sbcl --eval '(asdf:test-system :cl-llm)'                  # offline
CL_LLM_LIVE=1 sbcl --eval '(asdf:test-system :cl-llm/live)'
```

Framework: **FiveAM**. License: **MIT**.

CI runs the offline suite on SBCL for v1; ECL and Clozure jobs are added as
those targets are validated.

## 11. Code style

Lisp sources are indented with **spaces only, never tabs**, at a tab-width-8
assumption for any converted material.
