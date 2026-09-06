# The memory as its own MCP server (#57): rulings taken while executing

Spec `docs/superpowers/specs/2026-09-06-memory-mcp-server-design.md`
(amended 0d890f9 for the recon's thirteen corrections); plan
`docs/superpowers/plans/2026-09-06-memory-mcp-server.md`; recon
`docs/superpowers/notes/2026-09-06-memory-mcp-engine-api-facts.md`.
Suites at the end: `cl-llm/agent/mcp` 108 checks (new), memory 453,
agent 269, 0 failures. Each ruling names what it costs if wrong.

## Taken while planning

1. The solo child finds its systems through `CL_LLM_ASDF_REGISTRY`; the
   process tests build it from `asdf:system-source-directory`, so the
   child builds against the same trees as the test, locally and in CI.
   Cost: one environment variable.
2. The query tool is reached by name (`uiop:symbol-call`), so
   `cl-llm/agent/mcp` does not depend on `cl-llm/agent/prolog`.
3. `close-graph :snapshot-p nil` in the memory image too; a backup is a
   separate operation. Cost: an operator wanting a snapshot on stop runs
   one.
4. The round-trip test sets the environment in the test image (the
   client library passes none).

## Taken while executing

5. **Both recon-unsettled facts held**: a store declared at run time
   with `define-memory-store` opens (no allow-list needed), and
   `close-graph :snapshot-p nil` with `*graph*` bound leaves no `.dirty`.
6. **`open-scope` closes what it opened when the write store is not
   found**, instead of leaking a registered store (Task 1). Cost: none.
7. **An empty schema object stays an object**: `%schema-alist` returns
   an empty hash table, since cl-mcp encodes NIL as `[]` (Task 2, latent).
8. **The connection thread is guarded**, the hello parse tolerates any
   JSON, the socket close is established before the first read, IPv6
   loopback is recognised (Task 3 review). Cost: none.
9. **The exit hook is pushed before the image's `start`**: the
   debugger-disabled quit runs `*exit-hooks*` while `exit :abort t` does
   not, so a listener failure can no longer leave the store dirty (Task 4
   review, measured). The solo `%die` stops first; the relay's pump is
   guarded; refused children get a 60 s grace; `start` runs with stdout
   bound to stderr.
10. **The workflow's `env: CL_LLM_ASDF_REGISTRY` is removed**: Actions
    does not shell-expand it, and the tests set the child's registry
    themselves (Task 5).
11. **Final wave**: the accept loop is guarded (an escape ended the
    image); SWANK starts before the listener and a listener failure
    disables the listener instead of the image (a busy 4009 would have
    stopped a default image from coming up at all); a malformed
    principals entry never prints the secret; the docs name the clock
    refusal as the usual one; the relay smoked by hand. Parked as fine
    to defer: IPv4-mapped IPv6 loopback; `k`/`max-rows` for listener
    connections; shell line widths; the concurrent test with distinct
    producers; a constant-time secret compare; `check-bind` ignoring the
    provider; an accepted socket left unclosed when `make-thread` fails
    inside the guarded accept loop (one fd per exhaustion event); the
    round-trip process test without the `unwind-protect` its siblings
    have; the JSON-null refusal documented from the code, not a test.

## What an operator sees differently

- The memory image listens on loopback 4009 by default; set
  `CL_LLM_MEMORY_MCP_PORT=` to keep the old behaviour. Its stop no
  longer takes a snapshot.
- `scripts/run-memory-mcp.sh` is a stdio MCP server for one session;
  `scripts/memory-mcp-client.lisp` relays a session to the image.
- Identity: the image's producer on loopback; named principals with
  shared secrets in `~/.cl-llm-memory/principals.sexp`; tailnet whois
  opt-in.
