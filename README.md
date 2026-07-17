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

## Testing

```sh
sbcl --eval '(asdf:test-system :cl-llm)'     # offline, no API key required
```

## License

MIT
