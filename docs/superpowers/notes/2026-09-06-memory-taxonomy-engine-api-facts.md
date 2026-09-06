# Engine and library facts for the memory taxonomy unit (#64)

Recon of 2026-09-06 against vivace-graph `experiment` cde8a23 and
cl-llm `main` 6302511. Verified by reading source; the plan cites
these rather than guessing.

## Walking beliefs

- `gdb:map-vertices fn graph &key vertex-type include-subclasses-p
  collect-p include-deleted-p` (`vertex.lisp:185`). `vertex-type` is a
  class name symbol or a numeric type-id. Deleted vertices skipped by
  default. Under `gdb:call-with-read-snapshot` every vertex resolves at
  the reader's epoch. cl-llm's belief classes are
  `cl-llm.memory::belief-binary` and `belief-unary`, both vertex
  classes registered by `st:def-claim-classes` (`memory/schema.lisp`).
- Claim accessors used everywhere: `st:claim-subject-namespace`
  (keyword), `st:claim-subject-key` (string), `st:claim-relation`
  (string), `st:claim-object-namespace`, `st:claim-object-key`
  (binary only — probe with `(typep c 'belief-binary)`, as
  `memory/recall.lisp`'s `%object-key-for-order` does),
  `st:claim-current-p` (transaction-current, i.e. not retracted),
  `st:claim-producer`, `st:claim-standing`.
- `mem:with-scope-snapshots (scope) ...` refuses inside an open write
  transaction (`memory/scope.lisp:75`); `mem:check-scope scope
  :write-store g` validates membership.

## Endpoints and sources

- `claims:make-claim-source graph claim-class key-extractor &key
  renderer include-retracted` (`claims/source.lisp:41`). The extractor
  is `(lambda (query) ...)` returning a list of `(namespace-keyword .
  key-string)`. `collect-evidence` calls it once per fusion with the
  query string, walks `st:claims-touching` per endpoint with `:role
  :either`, dedups claims by `%claim-doc-id`, and emits one
  `:searched-empty` item per endpoint that yielded nothing.
- `%endpoints strings` (`agent/planner-tools.lisp:6`) parses
  `"namespace:key"` through `%keyword` (the #63 canonical check) into
  the same cons shape.
- `%claim-sources scope endpoints` (`:14`) builds one source per store
  with a constant extractor; `%seed scope query endpoints k` (`:75`)
  and `%retrieve-tool` (`:79`) both call it, so a per-call vocabulary
  must be computed once and threaded through both.
- `rag:fuse sources query &key k bounds` (`rag/bundle.lisp:124`);
  `agent:scope-sources scope` is the operator's extra sources (NIL in
  every test but the annotate consumer's).

## The agent layer

- Tools are assembled in `agent/agent.lisp`: `make-memory-tools` lists
  six, `make-planner-tools` two; `make-agent-tools` appends them. The
  MCP adapter test `every-agent-tool-registers-with-a-string-keyed-schema`
  asserts the count is 8 and names each; `docs/agent-tools.md`
  "Building the tools" says `;; => 8 tools`.
- `agent:clamp n cap`, `agent:scope-max-rows`, `agent:scope-k`,
  `agent:find-store scope name` (signals `scope-error` for an unknown
  name), `mem:store-name graph` (the graph name downcased).
- `%standing keyword` (`agent/render.lisp`) downcases a keyword;
  `%keyword string` validates canonical `[a-z0-9-]+` and interns;
  `%bool x` renders `:true`/`:false`; `json:jobject`, `json:to-json`,
  `json:parse`, `json:jget r "a" "b"` (nested get).
- Tool definition shape: `(llm:make-tool "name" "description"
  '((arg :type string :optional t) ...) (lambda (arg ...) json-string))`;
  `llm:llm-tool-error` is what a handler `error` becomes (adapter maps
  it to `isError`). Types: `string`, `integer`, `(list string)`.
- Test helpers (`tests-agent/harness.lisp`): `with-stores (w p)` two
  on-disk stores on one clock, store names `"cl-llm-memory"` and
  `"memory-private"`; `%belief g relation object &key start subject`
  writes a current `:observed` belief under `+p+` on `+subj+`
  `(:repo . "cl-llm")`; `%call tools "name" "arg" value ...` parses the
  JSON result; `%args`; `mem:retract-belief claim` inside
  `gdb:with-transaction (:graph g)` to retract.
- Memory test helpers (`tests-memory/harness.lisp`):
  `with-memory-graph (g)`, `%open-from ts`, `+p+`, `+subj+`, and
  `mem:record-belief g subject relation object :producer :standing
  :extent` inside `gdb:with-transaction (:graph g)`; `mem:record-absence
  g subject relation :standing :searched-empty ...` for a unary belief
  (see `memory/write.lisp:168` for the exact lambda list before use).

## Suites

- Run CI-style in a subprocess with the registry file
  `scratchpad/registry-64.lisp` (tree: this worktree; directories:
  `scratchpad/vg-experiment/`, `/home/raison/work/cl-mcp/`):
  `(ql:quickload :cl-llm/<sys>/tests :silent t)` then
  `(asdf:test-system :cl-llm/<sys>)` for `memory`, `agent`,
  `agent/prolog`, `agent/mcp`. Baselines at 6302511: memory 453,
  agent 278, prolog 40, agent/mcp 136.
