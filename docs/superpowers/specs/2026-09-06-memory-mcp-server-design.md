# The memory as its own MCP server — design

Issue: kraison/cl-llm#57 (re-evaluation of kraison/cl-mcp-server#8,
decided 2026-09-06). Predecessors: the agent tools
(`2026-09-03-agent-tools-design.md`), one memory over several stores
(`2026-09-05-s6b-cross-store-memory-design.md`), the memory image
(`docs/agent-memory.md`, "Running a memory image").

## 1. Problem

`cl-llm/agent`'s tools -- recall, trace, decisions-citing, conclude,
conclude-absence, retract, retrieve, plan-bounds, and the guarded query
tool -- serve only a model driven by cl-llm's own `ask` loop. An external
client such as Claude Code reaches the memory image only through
cl-mcp-server's remote SWANK tools, which evaluate raw Lisp. For the
public memory to stand on its own, it must expose those tools to any MCP
client directly, from this repo, with no dependency on the blackboard's
protocol (kraison/blackboard#3) or on cl-mcp-server.

Two engine facts bound the design. A graph-db store has exactly one
holder: opening a store another process holds signals
`store-not-closed-cleanly-error`, and a store left without `close-graph`
keeps a `.dirty` marker that forces recovery on the next open. And a
multi-store scope must share one system clock (S6b SS3), which the memory
image now opens before its store and closes after it.

Two client facts, from the Claude Code documentation and its gaps: on
exit Claude Code sends a spawned stdio server SIGTERM and then SIGKILL,
with an undocumented grace period; there is no MCP-level shutdown
message; a crashed stdio server is not respawned. Whether concurrent
sessions on one machine share a user-scoped stdio server or each spawn
one is undocumented; this design assumes each spawns one.

## 2. Rulings

Taken with Kevin during the brainstorm and recorded on #57.

- **Approach: the adapter lives in cl-llm** as a new system on
  `cl-mcp`, the protocol library cl-mcp-server already uses. Rejected:
  reopening cl-mcp-server#8 as written (an adapter in the REPL image that
  collides with the single-holder rule and leaves the public memory
  dependent on a second repo); waiting for the blackboard's slice 2 (the
  public memory would depend on a private protocol to be usable).
- **Default identity is portable, not tailnet.** The listener binds to
  loopback by default; principals are names with shared secrets in a
  local file; tailnet whois is an opt-in provider. A non-loopback bind
  without principals is refused.
- **Shutdown protects the store** on EOF, SIGTERM and normal exit, with
  no work that could outlast the unknown grace period.

## 3. The adapter

A new system `cl-llm/agent/mcp` (package `cl-llm.agent.mcp`, files under
`agent/mcp/`), depending on `cl-llm/agent` and `cl-mcp`. `cl-mcp` brings
`yason`, `bordeaux-threads` and `opsis/conditions`; none is in Quicklisp's
distribution, so CI clones `kraison/cl-mcp` and `quasi/opsis` beside
vivace-graph (section 8).

```lisp
(defun make-memory-server (stores &key write-store producer sources
                                       (k 5) (max-rows 50) query-tool
                                       (name "cl-llm-memory")
                                       (version "0.1"))
  ...) ; => a cl-mcp server
```

- **Registration.** `make-memory-server` calls `agent:make-agent-tools`
  with the same arguments, so every bound is fixed here and the model
  chooses arguments only (agent tools SS5). Each cl-llm `tool` registers
  with `cl-mcp:register-tool`: `tool-name` and `tool-description` pass
  through; `tool-schema`, which cl-llm holds as nested `equal` hash tables
  with vectors for arrays, is converted by `%schema-alist` to the
  string-keyed alist `cl-mcp` encodes and validates, with `required`
  coerced to a LIST: `cl-mcp` validates it with `dolist`, so the vector
  cl-llm holds would turn every call into an internal error while
  `tools/list` looked right (recon C1). With `:query-tool t` the adapter
  also calls `make-query-tool` from `cl-llm/agent/prolog` over the store
  list and registers it; `make-agent-tools` has no such keyword, and the
  query tool runs on `graph-db/query`, not `graph-db/gui`, since #44
  (recon C5, C9). The query tool is scope-blind: a cite it returns is
  found by `cite-store`'s fallback scan, today's behaviour.
- **Calls.** `cl-mcp` hands a handler the decoded arguments as an alist.
  `%arguments-table` rebuilds the `equal` hash table `llm:call-tool`
  expects; a value for an array-typed parameter becomes a vector, since
  the tools read arrays with `across`; yason decodes arrays as lists,
  `null` and `false` as NIL, and a JSON float as a double, so an
  integer-typed cap sent as `5.0` falls back to the configured cap
  (recon C12, documented). The tool's JSON string result is the text
  content block. A `c:llm-tool-error` -- a refusal or a bad
  argument, the same thing the in-process loop shows the model -- becomes
  a text block with `cl-mcp`'s second value `t`, so the client sees
  `isError: true` and the message. Any other condition propagates to
  `cl-mcp`'s loop, which answers an internal error and keeps serving.
- **Scope stays in configuration.** No tool takes a store, producer or
  cap. `docs/agent-tools.md`'s contract that the model names subjects,
  never stores, holds over MCP unchanged.
- **Nothing in `cl-llm/agent` changes.** The adapter consumes the
  existing tool objects. A conversion that needs a hook there is a plan
  finding, not a design change.

## 4. Solo mode: a stdio server the client launches

`scripts/memory-mcp.lisp`, run through `scripts/run-memory-mcp.sh`, is
what a client spawns:

```
claude mcp add --scope user memory -- /path/to/cl-llm/scripts/run-memory-mcp.sh
```

- It reads the memory image's environment (`CL_LLM_MEMORY_STORE`,
  `_SYSTEM`, `_GRAPH`, `_PRODUCER`, `_BUFFER_POOL`, `_CLOCK`), opens the
  clock, then the store with `:system-clock`, builds the server with
  `make-memory-server`, and calls `cl-mcp:run-server` on stdin and
  stdout. All loading output goes to stderr: stdout carries JSON-RPC only.
- **A multi-store scope** comes from `CL_LLM_MEMORY_SCOPE`, a
  comma-separated list of `name=dir` in trust order, most trusted first,
  each name a graph name; the config layer declares the schema for each
  name at startup (`define-memory-store` takes an unevaluated name, so
  this is an `eval` per name; if the plan's first red test shows that
  cannot work, the scope is restricted to names declared in the image
  and the rest refused at startup -- recon C11); the write store is
  `CL_LLM_MEMORY_WRITE`, default the last entry. Unset,
  the scope is the single `CL_LLM_MEMORY_STORE` store, and today's
  variables mean what they mean.
- **Refusal to double-hold.** If the store or the clock is already held,
  the script prints the image's "another image may hold the store"
  message to stderr and exits non-zero before any handshake, so a second
  session cannot become a second holder. Claude Code shows the server as
  failed; nothing is written.
- `CL_LLM_MEMORY_QUERY_TOOL=1` adds the guarded query tool.

## 5. Listener mode: the memory image serves connections

The memory image (`scripts/memory-image.lisp`) gains a listener beside
its SWANK port. Configuration:

| variable | default | meaning |
|---|---|---|
| `CL_LLM_MEMORY_MCP_PORT` | `4009` | listener port; empty disables |
| `CL_LLM_MEMORY_MCP_BIND` | `127.0.0.1` | bind address |
| `CL_LLM_MEMORY_PRINCIPALS` | `~/.cl-llm-memory/principals.sexp` | the principals file, optional on loopback |
| `CL_LLM_MEMORY_IDENTITY` | `secret` | identity provider: `secret` or `tailscale` |

- **Connections.** An accept loop runs in its own thread, polling
  `usocket:wait-for-input` with a timeout and checking a `stopping` flag
  between ticks, because closing a listening socket does not wake a
  parked accept (recon C3). Each accepted socket gets its own server
  from `make-memory-server` with the connection's producer -- one server
  and one tool set per connection, since `cl-mcp` keeps the output
  stream in the server and a handler sees only its arguments (recon
  C10) -- run by `cl-mcp:run-server` over the socket's character
  streams in its own thread, and ends when the client disconnects or
  the hello is refused. Concurrent connections are
  concurrent transactions on one image, which the engine handles.
- **The hello.** Before any JSON-RPC, a client may send one line:
  `{"cl-llm-memory": {"principal": "<producer>", "secret": "<secret>"}}`.
  The image reads the first line itself: a hello is consumed and checked
  against the principals; any other line is a JSON-RPC message, so the
  image hands `run-server` a concatenated stream that yields that line
  first and then the socket, and the connection gets the default
  identity. The
  principals file is a list of `("<producer>" . "<secret>")` pairs, each
  producer canonical (`st:canonical-producer-p`); it is read at each
  connection so edits take effect without a restart.
- **Identity, provider `secret`.** A matching hello sets that
  connection's producer. A hello with no match, or a malformed hello,
  closes the connection before the handshake with one line on stderr.
  No hello on a loopback connection: the image's own producer. No hello
  on a non-loopback connection: refused. Binding to any non-loopback
  address with no readable principals file is refused at startup.
- **Identity, provider `tailscale`.** The peer address maps to
  `claude-code/<node>` through `tailscale whois`; a peer whois cannot
  name is refused; the hello is ignored. Off by default; documented as
  one provider among two behind the same hello, so a third can be added
  without touching the protocol.
- **The bridge.** `scripts/memory-mcp-client.lisp` is a stdio relay:
  connect, send the hello if it has a principal, pump stdin to the socket
  and the socket to stdout in two threads, exit on either EOF. It takes
  `--host`, `--port`, and `--principal <producer>` naming an entry in a
  local file (`~/.cl-llm-memory/client.sexp`, `(("<producer>" .
  "<secret>"))`), so the `claude mcp add` line carries no secret:

```
claude mcp add --scope user memory -- sbcl --script \
  /path/to/cl-llm/scripts/memory-mcp-client.lisp --port 4009 \
  --principal claude-code/laptop
```

  `socat STDIO TCP:host:port` does the same without a principal where it
  exists.

## 6. Shutdown

One idempotent `stop`, in both modes, that never signals: set the
listener's `stopping` flag and join its thread, then close the listening
socket, so no new connection arrives; then `close-graph` on every store
in the scope, each with `gdb:*graph*` bound to that store and with
`:snapshot-p nil`; then `close-system-clock`. The two close arguments
are what makes the promise true: `close-graph` requires `*graph*` bound
to the store it closes, and its default takes a full logical snapshot
before removing the `.dirty` marker, unbounded work; without the
snapshot the marker removal and the index-root saves still run, so the
store is clean (recon C2, defended in `docs/agent-memory.md`). `stop`
runs on three paths: `run-server` returning on EOF (the client closed
the transport), SIGTERM through `sb-ext:*exit-hooks*` (SBCL runs the
hooks on SIGTERM under both `--script` and `--load`, measured in the
recon note; kraison/sitrep#25 recorded a service with NO hook, and is
not the citation), and normal exit. An in-flight tool call is cut and
its transaction either committed or did not. SIGKILL leaves at worst a
`.dirty` marker for the write-ahead log to recover on the next open,
never a torn close.

## 7. Errors

- Startup: a held store or clock, a non-loopback bind without
  principals, an unreadable principals file, a non-canonical producer in
  it -- one line on stderr, exit 1 (solo) or `start` signals (image).
- Per connection: a refused hello closes the socket with one stderr line
  naming the peer, never the secret.
- Per call: `c:llm-tool-error` -> text with `isError: true`; anything
  else -> `cl-mcp`'s internal-error response, the connection continues.

## 8. Testing

Every test is red first and named for its mechanism; every negative case
has a control.

- **Adapter, in process** (`tests-agent-mcp/`, system
  `cl-llm/agent/mcp/tests`, the clocked `with-stores` fixture): one MCP
  tool per cl-llm tool with string-keyed schemas and a `required`
  sequence; `cl-mcp`'s registry `call-tool` runs `recall` and returns the
  JSON text block; `conclude` given `evidence` as a list reaches the tool
  as a vector; a bad standing returns text with the error flag and the
  in-process message; the query tool appears only with `:query-tool t`.
- **Solo round trip, one subprocess:** `cl-mcp/client` spawns
  `run-memory-mcp.sh` on a scratch store, the environment set in the
  test image since the client passes none; `list-tools`, `conclude`,
  `recall` of the decision, then `disconnect`, then `uiop:wait-process`
  on the process handle captured beforehand, since `disconnect` does
  not wait (recon C8); assert the results, no `.dirty` in the store
  directory, and a clean reopen.
- **A subprocess harness of our own** (`sb-ext:run-program` with an
  environment, stderr captured, exit code read), because `cl-mcp/client`
  discards stderr and never reports an exit code (recon C7): a second
  solo server on the held store exits non-zero with the message and no
  handshake; and **SIGTERM** sent to a solo server mid-session leaves
  the store clean, which is the fact section 6 rests on.
- **Listener, in process, ephemeral loopback port**, speaking NDJSON as
  a client with `cl-mcp.json-rpc:make-request`,
  `cl-mcp.client:encode-request` and `cl-mcp.client:parse-client-message`
  (the server's `read-message`/`write-message` pair rejects responses;
  recon C6): a known secret's decisions
  carry its producer; a wrong secret is closed before `initialize`; no
  hello on loopback gets the image's producer; two concurrent connections
  each see the other's committed decision; `stop` refuses new
  connections and leaves graph and clock closed. The
  non-loopback-without-principals rule is tested on the configuration
  validator.
- **Runs:** the new suite, then memory and agent, foreground; CI's `test`
  workflow gains the suite and the `cl-mcp` and `opsis` clones.

## 9. Out of scope

- No HTTP or SSE transport: `cl-mcp` has none, and the relay gives every
  client the same access.
- No scope chosen by the model.
- No second holder of a store, ever; no mode lets two processes open one.
- No identity beyond a shared secret or the opt-in tailnet provider: no
  OS peer credentials, no TLS, no accounts. A stronger provider goes
  behind the same hello.
- No changes to the tools, their JSON or their refusals.
- No replacement of SWANK; the listener is an addition.
- No blackboard protocol; cl-mcp-server#8 stays closed.
- No graceful drain on shutdown.
- No saved core or executable; solo mode loads through Quicklisp.

## 10. Files

| file | change |
|---|---|
| `agent/mcp/packages.lisp`, `agent/mcp/adapter.lisp` (new) | `make-memory-server`, `%schema-alist`, `%arguments-table`, the handler wrapper |
| `agent/mcp/identity.lisp` (new) | the principals file, the hello, the two providers, the bind rule |
| `agent/mcp/listener.lisp` (new) | accept loop, per-connection server, `stop` |
| `agent/mcp/config.lisp` (new) | the environment to a scope: `CL_LLM_MEMORY_SCOPE`/`_WRITE`, shared by both scripts |
| `cl-llm.asd` | `cl-llm/agent/mcp` and `cl-llm/agent/mcp/tests` |
| `scripts/memory-mcp.lisp`, `scripts/run-memory-mcp.sh` (new) | solo mode |
| `scripts/memory-mcp-client.lisp` (new) | the relay |
| `scripts/memory-image.lisp`, `scripts/run-memory.sh` | the listener, `stop` closing it first |
| `tests-agent-mcp/` (new) | section 8 |
| `.github/workflows/test.yml`, `docs/ci.md` | the suite and the clones |
| `docs/agent-memory.md`, `README.md` | "The memory as an MCP server" |

## 11. Acceptance (from #57)

- A Claude Code session with the solo server can recall, conclude, trace
  and retrieve against a store it opened, and the store is clean after
  the session ends.
- The memory image serves two concurrent MCP connections with distinct
  producers; each sees the other's committed decisions.
- The round trip is tested through `cl-mcp/client` in the offline suite;
  CI clones `cl-mcp` and `opsis`.
- `docs/agent-memory.md` documents both modes, the principals file and
  the `claude mcp add` lines.
