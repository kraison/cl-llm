# cl-llm

A Common Lisp library for interacting with and tuning LLMs.

Supports Anthropic and local / OpenAI-compatible endpoints. SBCL is the primary
target; ECL and Clozure are supported by construction (the library uses no
threads).

**Status:** under development. See `docs/superpowers/specs/` for the design.

## Quick start

```lisp
(ql:quickload :cl-llm)
(cl-llm:ask "Explain CLOS in one sentence")
```

## Providers

- **Anthropic** (`anthropic-provider`): the Messages API.
- **OpenAI-compatible** (`openai-compatible-provider`): the chat-completions
  shape used by llama.cpp, Ollama, vLLM, and LM Studio. Requires `:base-url`
  and `:model`; an API key is optional (local servers usually accept none).
  Non-streaming tool use is fully supported. Streaming tool calls are not:
  `parse-stream-event` terminates cleanly on a `tool_calls` delta but does not
  assemble it into a tool-use part, so streamed responses that need tool use
  should fall back to `chat-request`.

## Testing

```sh
sbcl --eval '(asdf:test-system :cl-llm)'     # offline, no API key required
```

## License

MIT
