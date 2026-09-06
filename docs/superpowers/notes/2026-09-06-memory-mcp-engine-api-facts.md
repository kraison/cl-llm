# Memory MCP server — engine and library facts

Recon for `docs/superpowers/specs/2026-09-06-memory-mcp-server-design.md`
(kraison/cl-llm#57), before the implementation plan. Read-only: nothing
here is a defect to fix, and nothing outside this file was changed.

**Trees.** cl-llm `feat/memory-mcp` (worktree of `main` 93ff6d0, spec
commit 1248062); cl-mcp `/home/raison/work/cl-mcp` `main`
(kraison/cl-mcp, v0.3.0); cl-mcp-server as a consumer example;
vivace-graph `experiment` cde8a23 (scratch clone). SBCL 2.6.6.

**Method.** Everything below is marked **VERIFIED (source)** — quoted
from the file at the given line — or **VERIFIED (image)** — measured in
one of two `sbcl --non-interactive` runs — or **inference**, which the
plan must turn into a red test rather than assume.

Two image runs were made, both loading from the worktrees through
`asdf:initialize-source-registry ... :ignore-inherited-configuration`
with `ql:*local-project-directories*` set to `NIL` (CI's recipe, §E10),
so the shared `/home/raison/work/cl-llm` and
`/home/raison/work/vivace-graph-v3` checkouts were never read —
confirmed by printing `asdf:system-source-file` for each system.

- **Run 1** settled cl-llm's `derive-schema` / `call-tool` behaviour,
  `cl-mcp`'s package externality, `read-line` over a concatenated
  stream, and usocket's basic shape. Its output was truncated in
  capture; the parts that mattered were re-measured in run 2.
- **Run 2** settled yason's decode defaults, list-vs-vector `required`,
  SIGTERM and exit hooks in two child SBCLs, and the accept/close
  question. It then aborted on a *read-time* error (a reference to
  `sb-introspect:` in an unloaded package), which is not caught by
  `handler-case`, so its graph-db half never ran.

**Consequence: three facts are unsettled and are marked so** — E9's
runtime `define-memory-store`, E8's `close-graph` on a store that is not
`gdb:*graph*`, and the wall-clock cost of `close-graph`'s snapshot.
They are the first three red tests the plan should write; see §S.

---

## E1. cl-mcp's schema encoding and argument decoding

**Decoding.** One call, one setting:

```lisp
;; cl-mcp/src/json-rpc.lisp:52-57
  (let ((data (handler-case
                  (yason:parse json-string :object-as :alist)
                ...
```

Everything else is yason's default. Measured (image), on this host with
this yason:

| JSON | Lisp | type |
|---|---|---|
| `{"n":1}` | `(("n" . 1))` | `CONS` (alist, string keys) |
| `["x","y"]` | `("x" "y")` | `CONS` — **a list, not a vector** |
| `true` / `false` | `T` / `NIL` | `BOOLEAN` / `NULL` |
| `null` | `NIL` | `NULL` — indistinguishable from `false` |
| `3` | `3` | `INTEGER` |
| `1.5` | `1.5d0` | `DOUBLE-FLOAT` |
| `{}` | `NIL` | `NULL` |

Globals confirmed at the same time: `yason:*parse-object-as*` =
`:HASH-TABLE`, `*parse-json-arrays-as-vectors*` = `NIL`,
`*parse-json-booleans-as-symbols*` = `NIL`. Only the `:object-as :alist`
argument overrides a default; arrays therefore always arrive as lists.
**VERIFIED (image + source).**

A real `tools/call` frame decodes to
`(("evidence" "c1" "c2") ("confidence" . 0.5d0) ("subject-key" . "k"))`
— note `("evidence" "c1" "c2")`, an alist entry whose `cdr` is a list.
**VERIFIED (image).**

**Encoding.** `tools-for-mcp` puts the stored schema straight into the
result:

```lisp
;; cl-mcp/src/tools.lisp:43-48
(defun tools-for-mcp (registry)
  "Format all tools in REGISTRY for MCP tools/list response."
  (loop for tool being the hash-values of registry
        collect `(("name" . ,(tool-name tool))
                  ("description" . ,(tool-description tool))
                  ("inputSchema" . ,(tool-input-schema tool)))))
```

and `convert-for-json` walks it:

```lisp
;; cl-mcp/src/json-rpc.lisp:85-116 (elided middle)
(defun convert-for-json (value)
  ...
    ((null value) #())
    ((stringp value) value)
    ((numberp value) value)
    ((hash-table-p value) value)
    ((vectorp value)
     (map 'vector #'convert-for-json value))
    ((json-object-p value)
     (let ((ht (make-hash-table :test #'equal)))
       ...))
    ((listp value)
     (map 'vector #'convert-for-json value))
    (t value)))
```

So an alist becomes an object, a list of strings becomes an array, a
vector becomes an array, and a *hash table passes through untouched* —
yason encodes it as an object. Measured: a `("required" . ("a" "b"))`
and a `("required" . #("a" "b"))` encode **identically** to
`{"required":["a","b"]}`; `("required" . nil)` encodes as
`{"required":[]}`; and an `equal` hash table under `"properties"`
encodes as `{"properties":{"subject":{"type":"string"}}}`.
**VERIFIED (image).**

The two are **not** interchangeable on the validation path:

```lisp
;; cl-mcp/src/tools.lisp:52-61
(defun validate-tool-args (args schema)
  "Validate ARGS against the tool's input SCHEMA.
Signals INVALID-PARAMS if required arguments are missing."
  (let ((required (cdr (assoc "required" schema :test #'string=))))
    (dolist (req-name required)
      (unless (assoc req-name args :test #'string=)
        (error 'invalid-params ...
```

`dolist` over a vector is a `TYPE-ERROR`. Measured: with a list
`required`, a present argument validates `T` and a missing one signals
`CL-MCP.CONDITIONS:INVALID-PARAMS "Missing required argument: b"`; with
a vector `required`, even a *complete* argument set signals
`TYPE-ERROR: The value #("a" "b") is not of type LIST`.
**VERIFIED (image).**

The working example in cl-mcp's own consumer agrees:

```lisp
;; cl-mcp-server/src/tools.lisp:51-56
   :schema `(("type" . "object")
             ("required" . ("code"))
             ("properties"
              . (("code"
                  . (("type" . "string")
                     ("description" . "Common Lisp code to evaluate")))
```

**Consequence.** `%schema-alist` must emit `required` as a **proper
list of strings**. `properties` may stay a hash table (it encodes
correctly and nothing walks it), but converting it to a nested alist is
equally correct and easier to assert on in a test; either way, `enum`
and `items` may be left as vectors/hash tables. `%arguments-table` must
accept a **string-keyed alist whose array values are lists**, and hand
back an `equal` hash table with those arrays turned into **vectors**
(§E2). A JSON `{}` and an absent `arguments` both arrive as `NIL`.

---

## E2. cl-llm's tool contract

**`tool-schema` is nested hash tables with vectors.**

```lisp
;; cl-llm/src/tools.lisp:153-172 (tail)
    (json:jobject :type "object"
                  :properties properties
                  :required (coerce (nreverse required) 'vector))))
```

`json:jobject` builds an `equal` hash table and **omits any NIL value**
(`src/json.lisp:56-64`), so `"required"` is present even when empty
(`#()` is not NIL) and a `nil` default never appears. Enum members are a
vector (`src/tools.lisp:129-131`, `(map 'vector ...)`); an array
parameter nests `("items" . <hash>)` (`src/tools.lisp:80-85`). Measured
on a representative lambda list: `required` came back as a
`(SIMPLE-VECTOR 3)`, `enum` as a vector, `items` as a hash table.
**VERIFIED (image + source).** Read together with §E1 this is the single
most consequential finding: **cl-llm produces a vector where cl-mcp
requires a list.**

**`call-tool` and `positional-arguments`.**

```lisp
;; cl-llm/src/tools.lisp:287-298
  (loop for spec in (tool-parameter-specs tool)
        collect
        (multiple-value-bind (value presentp)
            (if arguments (gethash (parameter-spec-name spec) arguments) (values nil nil))
          (cond
            (presentp value)
            ((parameter-spec-required-p spec)
             (error 'c:llm-tool-error
                    :tool-name (tool-name tool)
                    :underlying (format nil "Missing required parameter ~s."
                                        (parameter-spec-name spec))))
            (t (parameter-spec-default spec))))))
```

```lisp
;; cl-llm/src/tools.lisp:300-309
(defun call-tool (tool arguments)
  ...
  (handler-case
      (apply (tool-function tool) (positional-arguments tool arguments))
    (c:llm-error (e) (error e))
    (error (e)
      (error 'c:llm-tool-error :tool-name (tool-name tool)
                               :underlying (princ-to-string e)))))
```

Measured through a synthetic tool: a supplied vector argument arrives as
a `(SIMPLE-VECTOR 1)`; an omitted optional gets its declared default
(`7`, not `NIL`); `arguments` = `NIL` behaves as "everything omitted";
a missing required parameter and a signalling body both come back as
`LLM-TOOL-ERROR` reading
`"Tool t1 signalled an error: Missing required parameter \"a\"."` and
`"Tool t2 signalled an error: boom q"`. **VERIFIED (image).**

```lisp
;; cl-llm/src/conditions.lisp:58-65
(define-condition llm-tool-error (llm-error)
  ((tool-name :initarg :tool-name :initform nil :reader llm-error-tool-name)
   (underlying :initarg :underlying :initform nil :reader llm-error-underlying))
  (:report (lambda (condition stream)
             (format stream "~:[A tool~;Tool ~:*~a~] signalled an error~@[: ~a~]"
                     (llm-error-tool-name condition)
                     (llm-error-underlying condition))))
  ...
```

`llm-tool-error` is exported from `cl-llm` (`src/packages.lisp:68`)
alongside `llm-error-tool-name` and `llm-error-underlying`; the agent
packages nickname `cl-llm.conditions` as `c`. `tool-name`,
`tool-description`, `tool-schema`, `tool-function`, `make-tool` and
`call-tool` are exported from `cl-llm` (`src/packages.lisp:97-99`);
**`tool-parameter-names` and `tool-parameter-specs` are not** — the
adapter must not need them, and a test that wants them uses `cl-llm::`.
**VERIFIED (source).**

**Array-typed parameters read with `across`.** Every one of them, so
`%arguments-table` must vectorize by schema type, not by guess:

```lisp
;; cl-llm/agent/memory-tools.lisp:111-118
(defun %evidence-pairs (scope evidence)
  ...
  (loop for cite across (or evidence #())
```

```lisp
;; cl-llm/agent/planner-tools.lisp:6-12
(defun %endpoints (strings)
  ...
  (loop for s across (or strings #())
```

The complete set of `(list ...)` parameters is four:
`conclude.evidence` (`agent/memory-tools.lisp:154`),
`conclude-absence.evidence` (`:195`), `retrieve.endpoints`
(`agent/planner-tools.lisp:90`) and `plan-bounds.endpoints` (`:130`) —
all `:type (list string) :optional t`. Passing yason's decoded list
straight through gives
`SIMPLE-TYPE-ERROR ... is ("c1"), not a VECTOR` (measured in run 1),
which `llm:call-tool` would wrap into an `llm-tool-error` and the MCP
client would see as `isError: true` with a Lisp type error in the text.
**VERIFIED (image + source).**

**Tool results are JSON strings.** Every tool body ends in
`(json:to-json (json:jobject ...))` — `memory-tools.lisp:42, 79, 98`,
`%decision-json` at `:120`, `retract` at `:253`, and the planner tools
at `planner-tools.lisp:115, 135`. So the MCP text content block is the
tool's return value verbatim. **VERIFIED (source).**

**`make-agent-tools` and the query tool.**

```lisp
;; cl-llm/agent/agent.lisp:14-23
(defun make-agent-tools (stores &key write-store producer sources
                                     (k 5) (max-rows 50))
  "The agent's tools over STORES (readable, in scope order) writing to
WRITE-STORE (default the first), as PRODUCER, with SOURCES added to the
planner and K / MAX-ROWS as the caps.  Every bound is fixed here; the
model chooses arguments only (SS5)."
  (let ((scope (make-scope stores :write-store write-store
                                  :producer producer :sources sources
                                  :k k :max-rows max-rows)))
    (append (make-memory-tools scope) (make-planner-tools scope))))
```

Eight tools, in this order: `recall`, `trace`, `decisions-citing`,
`conclude`, `conclude-absence`, `retract` (`agent.lisp:5-9`), then
`retrieve`, `plan-bounds` (`:11-12`). There is **no `:query-tool`
keyword**; the adapter must append it itself.

```lisp
;; cl-llm/agent/prolog/query.lisp:37-42
(defun make-query-tool (stores &key (max-rows 50) (max-inferences 100000)
                                    (timeout 5))
  "The QUERY tool over STORES (names a model may pass as store; the
first is the default).  Effects off, one snapshot, MAX-INFERENCES and
TIMEOUT (seconds) are the operator's; MAX-ROWS too, further clamped by
the engine's own GRAPH-DB:*QUERY-DEFAULT-LIMIT* (1000, SS8)."
```

It takes the **store list**, not a scope, and so does not share the
scope's cite cache (`agent/scope.lisp:47-52`) — a cite the model gets
from `query` is not registered as coming from any store, and
`%evidence-pairs`'s fallback scan (`cite-store`, `scope.lisp:54-64`)
is what resolves it. `make-scope` also requires a canonical producer
(`scope.lisp:29-31`, `st:canonical-producer-p`) and positive integer
caps, signalling `agent:scope-error` otherwise. **VERIFIED (source).**

What it needs loaded is `graph-db/query`, **not** `graph-db/gui`:

```lisp
;; cl-llm.asd:281-290
(defsystem "cl-llm/agent/prolog"
  :description "A guarded free-text Prolog tool for the agent (#14 unit 2)."
  :license "MIT"
  ;; graph-db/query is the web-free home of the #279 guard
  ;; (kraison/vivace-graph#322, since #329).
  :depends-on ("cl-llm/agent" "graph-db/query")
```

changed by efaaf4e (#44), on `main` since. **VERIFIED (source).**

`cl-llm:encode-tool` is a *provider* generic (`src/protocol.lisp:49`,
methods in `providers/anthropic.lisp:110` and `providers/openai.lisp:90`)
and is not a reusable schema renderer for MCP.

---

## E3. `cl-mcp:run-server` over a socket

```lisp
;; cl-mcp/src/server.lisp:165-190 (head)
(defun run-server (server &key (input *standard-input*) (output
                                                         *standard-output*))
  "Run the MCP server loop. Blocks until EOF on INPUT.
Handles MCP handshake, tool dispatch, and error recovery.
Emits opsis events at protocol lifecycle points."
  (let ((source (mcp-server-name server)))
    ...
    (setf (mcp-server-output server) output)
    (unwind-protect
         (loop
           (handler-case
               (let ((request (read-message input)))
                 (unless request
                   ...
                   (return))
```

- **Framing is NDJSON via `read-line`**, nothing else:

```lisp
;; cl-mcp/src/transport.lisp:6-18
(defun read-message (&optional (stream *standard-input*))
  "Read a single JSON-RPC message from stream.
   Messages are newline-delimited JSON (NDJSON).
   Returns nil on EOF, json-rpc-request on success.
   ...
  (loop
    (let ((line (read-line stream nil nil)))
      (unless line
        (return nil))
      (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
        (unless (zerop (length trimmed))
          (return (cl-mcp.json-rpc:parse-message trimmed)))))))
```

  A plain character stream is enough; no bivalence, no element-type
  requirement. Empty lines are skipped. EOF returns `NIL` and
  `run-server` returns normally. **VERIFIED (source).**

- **The concatenated-stream trick works, but only with the newline.**
  Measured: `(make-concatenated-stream (make-string-input-stream "LINE1<newline>") rest)`
  read back `"LINE1" "LINE2" "LINE3" :EOF`; **without** the trailing
  newline the same construction read back `"LINE1LINE2"` — `read-line`
  runs straight across the component boundary. Two `read-message` calls
  over a concatenated pair returned `"initialize"` then `"tools/list"`
  then `NIL`. **VERIFIED (image).** The hello replay must re-append the
  newline it consumed.

- **`read-message` / `write-message` are not external in `cl-mcp`.**
  Measured: `(find-symbol "READ-MESSAGE" "CL-MCP")` → `:INHERITED`,
  `(find-symbol "READ-MESSAGE" "CL-MCP.TRANSPORT")` → `:EXTERNAL`; same
  for `WRITE-MESSAGE`; `RUN-SERVER` is `:EXTERNAL` in `CL-MCP` and
  absent from `CL-MCP.TRANSPORT`. The `cl-mcp` export list
  (`src/packages.lisp:87-110`) covers the server API and the conditions
  only. **VERIFIED (image + source).** Use
  `cl-mcp.transport:read-message`.

- **`write-message` writes a *response* struct**
  (`transport.lisp:20-24`, `encode-response`), and `read-message` parses
  a *request* — `validate-and-build-request` requires a `"method"` field
  (`json-rpc.lisp:65-69`), so a server response fed to `read-message`
  signals `invalid-request`. Neither is a client-side pair.

- **One server object per connection.** `run-server` writes the stream
  into the shared struct slot and clears it on the way out
  (`server.lisp:176`, `:214`), and the write lock is per struct
  (`server.lisp:20`). Two concurrent `run-server` calls on one server
  would have the first to finish blank the other's output slot, and
  would serialise their writes for no reason. **VERIFIED (source).**

- **`initialize` ignores its params.**

```lisp
;; cl-mcp/src/server.lisp:84-95
(defun %handle-initialize (server id)
  "Handle the initialize request."
  (let ((empty-obj (make-hash-table :test #'equal)))
    (make-success-response
     :id id
     :result `(("protocolVersion" . ,(mcp-server-protocol-version server))
               ("serverInfo" . (("name" . ,(mcp-server-name server))
                                ("version" . ,(mcp-server-version server))))
               ...
```

  `clientInfo` never reaches a handler, and a handler receives only its
  `arguments` (`tools.lisp:104-106`). There is no per-connection state
  anywhere on the server struct. **VERIFIED (source).** This is the
  reason the design's hello is right, and the reason the per-connection
  producer must be closed over by building a fresh server per socket.

- **Errors.** `json-rpc-error` inside the loop answers with the
  condition's own code and `:id nil`; any other `error` answers `-32603`
  "Internal error: ~a"; both keep looping (`server.lisp:191-213`).
  Inside `%handle-request`, `method-not-found` and `invalid-params`
  answer with their codes and the request's id, everything else
  `-32603` (`server.lisp:143-161`). `isError` comes from a handler's
  **second return value**:

```lisp
;; cl-mcp/src/server.lisp:110-120
    (multiple-value-bind (content error-p)
        (cl-mcp.tools:call-tool (mcp-server-tools server) name arguments)
      (make-success-response
       :id id
       ...
       :result (if error-p
                   `(("content" . ,content) ("isError" . t))
                   `(("content" . ,content)))))))
```

  and `call-tool` passes it through (`tools.lisp:104-106`), normalising
  a string result into `(("type" . "text") ("text" . <string>))`
  (`tools.lisp:73-83`). **VERIFIED (source).**

- **Threading.** `run-server` is single-threaded per stream; the only
  `bt` use in the server is the output lock. `bordeaux-threads` is
  already a `cl-mcp` dependency (`cl-mcp.asd:11`). **VERIFIED (source).**

---

## E4. `cl-mcp/client` for the tests

```lisp
;; cl-mcp/src/client/client.lisp:179-187
      (let ((process (uiop:launch-program
                      (client-command client)
                      :input :stream
                      :output :stream
                      :error-output nil)))
```

- **`uiop:launch-program`, no environment, no directory.**
  `make-client` takes `:name :version :command :on-tools-changed` only
  (`client.lisp:50-59`); `command` is a list of strings. The child
  inherits the parent image's environment, so a test must
  `setf (uiop:getenv "CL_LLM_MEMORY_STORE")` **before** `connect`, or
  the wrapper script must take the store on argv. **VERIFIED (source).**
- **The child's stderr is discarded** (`:error-output nil`). A test that
  asserts the refusal message must launch the subprocess itself.
- **`disconnect` closes stdin, joins with a 5 s cap, then always
  terminates:**

```lisp
;; cl-mcp/src/client/client.lisp:236-254 (elided middle)
  (when (client-stdin client)
    (ignore-errors (close (client-stdin client)))
    (setf (client-stdin client) nil))
  ...
      (bt:timeout ()
        (ignore-errors
          (bt:destroy-thread (client-reader-thread client)))))
    (setf (client-reader-thread client) nil))
  ;; Kill process if still alive
  (when (client-process client)
    (ignore-errors (uiop:terminate-process (client-process client)))
    (setf (client-process client) nil))
  t)
```

  It never waits for the exit and never reports the exit code, and
  `client-process` / `client-stdin` / `client-stdout` are **not
  exported** (`src/client/packages.lisp:25-52`). A "the store is clean
  afterwards" assertion must capture `cl-mcp.client::client-process`
  before `disconnect` and `uiop:wait-process` it. Note the hazard: if
  `close-graph` takes longer than 5 s after EOF, `disconnect` sends
  SIGTERM into a close in progress. **VERIFIED (source).**
- **Returns.** `list-tools` → a list of plists
  `(:name :description :input-schema)`, the schema as decoded alists
  (`client.lisp:260-285`). `call-tool` → `(:content C :is-error NIL)`,
  and it **signals** on a tool-domain error:

```lisp
;; cl-mcp/src/client/client.lisp:310-315
      (when is-error
        (restart-case
            (error 'mcp-tool-error
                   :tool-name name
                   :content   content
                   :message   (format nil "Tool ~a returned an error" name))
```

  with restarts `use-value` and `skip-tool`. `mcp-tool-error`,
  `tool-error-content` and `tool-error-name` are exported from
  **`cl-mcp.client.conditions`**, not from `cl-mcp.client`
  (`src/client/packages.lisp:4-16`). A protocol-level error becomes
  `mcp-protocol-error` instead. **VERIFIED (source).**
- **The client cannot be attached to existing streams.** `connect`
  always launches a subprocess; there is no stream constructor. For the
  listener tests, use the exported "protocol utilities (exported for
  testing)": `cl-mcp.json-rpc:make-request` +
  `cl-mcp.client:encode-request` to write, and
  `cl-mcp.client:parse-client-message` to read
  (`src/client/protocol.lisp:10-22`, `:28-38`). **VERIFIED (source).**
- The handshake sends `protocolVersion "2025-11-25"`
  (`client.lisp:214`); the server answers with its own `"2025-06-18"`
  (`server.lisp:12`) and ignores what it was sent.

---

## E5. SBCL process facts

**Exit hooks do run on SIGTERM.** Measured with two children this image
started and killed itself, each pushing a hook that writes a marker
file:

| launch | exit code | status | hook ran |
|---|---|---|---|
| `sbcl --script child.lisp` | `0` | `:EXITED` | yes |
| `sbcl --disable-debugger --no-userinit --load child.lisp` | `0` | `:EXITED` | yes |

Both children were alive immediately before the signal and had written
the marker by the time `process-wait` returned. **VERIFIED (image).**

**But the spec's citation is wrong.** §6 says "SBCL runs the hooks on
SIGTERM, measured in kraison/sitrep#25", and `scripts/memory-image.lisp`
:80-83 says the same. The record in
`/home/raison/work/sitrep/docs/superpowers/plans/2026-08-30-u6b-host-deployment.md`
:316-320 says the opposite outcome:

> 3. **The service cannot survive a restart** (#25). SIGTERM leaves the store's
>    `.dirty` marker and the next start refuses with
>    `STORE-NOT-CLOSED-CLEANLY-ERROR`. Recovered by removing the marker, which is
>    the procedure `graph-db`'s own condition documents — but every reboot needs a
>    human until `run-forever` handles SIGTERM.

#25 measured a service that had **no hook installed**. The behaviour the
memory image relies on is real, but it was measured here, not there.
**VERIFIED (image); the citation is a §C correction.**

**`sb-ext:exit :abort t`** skips unwinding and the exit hooks; the
memory image uses it only on the refusal path, *before* the hook is
pushed (`scripts/memory-image.lisp:96, 101, 103`). **VERIFIED (source).**

**Streams.** A `--script` child's `*standard-output*` /
`*standard-input*` are character streams; a socket stream from usocket
reports `:UTF-8` (§E6). All of `run-server`'s I/O is character I/O, so
no external-format work is needed beyond making sure the process locale
does not give a `:LATIN-1` default — set it in the wrapper
(`LANG`/`LC_ALL`) rather than relying on inheritance. **inference** for
the locale half; the stream types are **VERIFIED (image)**.

**Driving a child from a test.** `(sb-ext:run-program ... :input :stream
:output :stream :error nil :wait nil)` then `sb-ext:process-kill p
sb-unix:sigterm`, a poll on `sb-ext:process-alive-p`,
`sb-ext:process-wait`, and `sb-ext:process-exit-code` / `process-status`
all behaved as documented. **VERIFIED (image).** `:environment` takes a
list of `"NAME=value"` strings; `(sb-ext:posix-environ)` is the base to
extend.

---

## E6. usocket and threads

`usocket` is present (a dexador dependency, so already in cl-llm's
closure). Measured:

- `(usocket:socket-listen "127.0.0.1" 0 :reuse-address t :element-type
  'character)` binds an ephemeral port; `usocket:get-local-port` returns
  it (44585, 32935 across runs), `get-local-address` returns
  `#(127 0 0 1)`.
- `socket-accept` blocks; a connect wakes it and returns a stream socket.
  On the accepted socket, `usocket:socket-stream` has
  `(stream-element-type ...)` = `CHARACTER` and
  `(stream-external-format ...)` = `:UTF-8` with no `:external-format`
  argument given; `usocket:get-peer-address` = `#(127 0 0 1)` and
  `get-peer-port` the client's ephemeral port. A line written on the
  server side was read back on the client side.
- **Closing the listening socket does NOT unblock a blocked
  `socket-accept`.** A thread parked in `socket-accept` was still parked
  3 s after `usocket:socket-close` on the listener; the join timed out.
  This is standard POSIX `close(2)` behaviour and it is the mechanism,
  not a usocket quirk.
- What *does* work: `usocket:wait-for-input sock :timeout 0.5
  :ready-only t` returns `(NIL NIL)` when nothing is pending, so an
  accept loop can poll; and a **self-connect** to the listener's own
  port wakes a blocked accept immediately (measured `:ACCEPTED`).
- After the listener is closed, `socket-accept` signals
  `USOCKET:BAD-FILE-DESCRIPTOR-ERROR` and `wait-for-input` signals a
  `TYPE-ERROR` — so a loop that polls must check its own "stopping"
  flag before touching the socket again.

**VERIFIED (image), all of the above.**

**Consequence.** §5's "an accept loop runs in its own thread" and §6's
"close the listener socket first, so no new connection arrives" do not
compose: closing the socket leaves the accept thread parked on a dead
fd. The listener needs either (a) a `stop` flag plus
`wait-for-input :timeout`, re-checking the flag each tick — no wakeup
needed and no fd touched after close, or (b) a self-connect wakeup
before the close. (a) is simpler and has no race.

---

## E7. The memory image today

`scripts/memory-image.lisp` is 104 lines. `start` (`:46-78`) reads six
environment variables through `%env`, sets `gdb:*system-directory*`,
opens the clock, then `open-graph` or `make-graph` depending on whether
`schema.dat` exists, binds `gdb:*graph*`, starts SWANK and prints one
line. `*producer*` is set from `CL_LLM_MEMORY_PRODUCER` (default
`claude-code/<machine-instance>`) and is otherwise only printed — no
tools are built today.

```lisp
;; cl-llm/scripts/memory-image.lisp:80-104
(defun stop ()
  "Close the store, then the clock; never signals.  Installed as an
exit hook because SBCL runs *EXIT-HOOKS* on SIGTERM (measured in sitrep
#25), so a stop from the shell or systemd leaves no .dirty marker."
  (when *graph*
    (ignore-errors (gdb:close-graph *graph*))
    (setf *graph* nil gdb:*graph* nil))
  (when *clock*
    (ignore-errors (gdb:close-system-clock *clock*))
    (setf *clock* nil)))

(handler-case (start)
  (gdb:store-not-closed-cleanly-error (c)
    (format *error-output* "~&memory image: ~A~%Another image may hold ~
the store.  If none does, delete its .dirty marker and start again.~%" c)
    (finish-output *error-output*)
    (sb-ext:exit :code 1 :abort t))
  (gdb:system-clock-in-use (c)
    ...
    (sb-ext:exit :code 1 :abort t)))
(push #'stop sb-ext:*exit-hooks*)
(loop (sleep 86400))
```

- `stop` is idempotent by slot-nulling and never signals
  (`ignore-errors` on both closes). Note it calls `close-graph` with the
  default `:snapshot-p t` (§E8).
- The hook is pushed **after** `(start)` returns, so a refusal exits
  with hooks skipped and nothing half-open.
- The main thread is `(loop (sleep 86400))`. `swank:create-server ...
  :dont-close t` spawns its own thread and does not need the main one,
  so a listener thread started at the end of `start` and joined/flagged
  in `stop` fits without touching the main loop. **VERIFIED (source).**
- `run-memory.sh` exports six variables and `exec`s
  `sbcl --dynamic-space-size ${CL_LLM_MEMORY_HEAP_MB:-4096}
  --disable-debugger --load "$REPO/scripts/memory-image.lisp"`. It does
  **not** export `CL_LLM_MEMORY_CLOCK`, though `memory-image.lisp:54-55`
  reads it (default `~/.cl-llm-memory/clock/`). **VERIFIED (source).**
- `docs/agent-memory.md` "Running a memory image" is §356-407, ending
  just before "## What this is not" at :409. Its variable table is at
  :372-380 and its closing paragraph already states the
  single-process/`.dirty` rule. The new "The memory as an MCP server"
  section belongs immediately after it, at :407, before "What this is
  not". **VERIFIED (source).**

---

## E8. Store and clock refusals

**`.dirty` on create and on open.**

```lisp
;; vivace-graph/graph.lisp:724-729 (make-graph)
  ;; A .dirty under LOCATION means a live holder or a crashed store --
  ;; creating over either is wrong.  Refuse before any side effect
  ;; (GH #246); previously this surfaced as a raw FILE-ERROR after
  ;; heap/table/index files had already been created.
  (when (probe-file (format nil "~A.dirty" location))
    (error 'store-not-closed-cleanly-error :location location))
```

```lisp
;; vivace-graph/graph.lisp:804-809 (%open-graph-1)
  (let ((path (pathname location))
        (dirty-file (format nil "~A/.dirty" location))
        ...
    (when (probe-file dirty-file)
      (error 'store-not-closed-cleanly-error :location location))
```

The marker is written during the open (`:532-533`, `:954`) and deleted
only by `close-graph`:

```lisp
;; vivace-graph/graph.lisp:1329-1333
      (let ((dirty-file (format nil "~A/.dirty" (location graph))))
        (handler-case (delete-file dirty-file)
          (file-error ()
            (warn 'dirty-marker-already-gone-warning
                  :location (location graph)))))
```

**VERIFIED (source).** So a second holder is refused *by the filesystem
marker*, not by a lock — which means the refusal is as reliable as the
previous holder's clean shutdown, and a crashed store refuses the next
honest opener too. That is the design's intent (§4 "Refusal to
double-hold") and it is correct.

**The clock is refused by `flock`.**

```lisp
;; vivace-graph/system-clock.lisp:73-90 (elided middle)
(defun open-system-clock (location &key (block-size 4096))
  "Open or create the system clock in directory LOCATION.  Ids resume above
the persisted ceiling, so a crash never reissues one.  Signals
SYSTEM-CLOCK-IN-USE if another live process holds LOCATION (GH #182)."
  (ensure-directories-exist location)
  (let ((fd (%posix-open (%clock-lock-file location)
                         (logior +o-creat+ +o-rdwr+)))
        ...
           (unless (handler-case
                       (%posix-flock fd (logior +lock-ex+ +lock-nb+))
                     ...
             (error 'system-clock-in-use :location location))
```

`close-system-clock` releases by closing the fd (`:113-116`) and its
docstring warns that a stranded lock "would refuse every later open in
this image, for the life of the process". **VERIFIED (source).** This is
a stronger guard than `.dirty`: it is a real kernel lock, it is released
on process death, and it survives a crash cleanly.

**`close-graph` does a snapshot by default.**

```lisp
;; vivace-graph/graph.lisp:1222-1233 (head)
(defmethod close-graph ((graph graph) &key (snapshot-p t))
  "Cleanly close GRAPH: stop replication, flush and unmap all on-disk
structures (heap, indexes, vertex/edge tables), remove the .dirty marker, and
deregister it.  With :SNAPSHOT-P true (the default) a snapshot backup is taken
first.  Must be called with *GRAPH* bound to GRAPH (the snapshot path relies on
it).  Failing to close a graph leaves its .dirty marker in place, forcing
recovery on the next OPEN-GRAPH.
```

Two consequences, both load-bearing for §6:

1. The snapshot is a logical backup whose cost scales with the store,
   and it runs **before** `.dirty` is removed. `snapshot` itself takes
   `(txn-lock graph)` and writes a full file
   (`vivace-graph/txn-log.lisp:8-55`); `backup.lisp:444` rebinds
   `*graph*` mid-way ("map-vertices' all-types branch reads `*graph*`"),
   which is why the docstring demands the binding. The cost is
   **unmeasured here** (run 2 aborted before it) — **inference**, but
   the mechanism is source-verified, and the memory note
   "Live graph copies are torn" records the ma-dev server taking ~10
   minutes to stop for exactly this reason on a large store.
2. `close-graph` on a store that is not `gdb:*graph*` violates a
   documented precondition. The memory image gets away with it today
   because it holds exactly one store. A multi-store `stop` closing
   every store in the scope does not. **VERIFIED (source) for the
   requirement; the failure mode is unmeasured — inference.**

**Concurrent transactions.** `close-graph` contains no wait for, and no
refusal of, an in-flight transaction from another thread: it
deregisters (`:1240-1243`), saves index roots, snapshots, then closes
the lhashes and unmaps the heap, finally setting `(graph-open-p graph)`
to `NIL` (`:1334`). Nothing blocks. So a `stop` racing a live tool call
tears that call, not the store — the design's "an in-flight tool call is
cut and its transaction either committed or did not" is right about the
store and optimistic about the caller, which will see an error from a
closed lhash rather than a clean refusal. **VERIFIED (source).**

---

## E9. Environment to scope

```lisp
;; cl-llm/memory/schema.lisp:7-47 (elided middle)
(defmacro define-memory-store (graph-name)
  "Declare the belief and trace families and the memory-note and
memory-banner sources in GRAPH-NAME.  Returns GRAPH-NAME.  Callable
from any package: DEF-CLAIM-CLASSES derives its class names from the
parent symbol's package (kraison/vivace-graph#323), so BELIEF-BINARY
and friends always live here."
  `(progn
     (st:def-claim-classes belief ,graph-name :temporal t)
     (st:def-claim-classes trace ,graph-name)
     (st:def-source memory-note ,graph-name
     ...
     ',graph-name))

(define-memory-store :cl-llm-memory)
```

- `graph-name` is **spliced unevaluated**. Only `:cl-llm-memory` is
  declared by the library; `tests-agent/harness.lisp:13` declares
  `:memory-private` itself, with the comment "a second declaration is
  the engine's supported idempotent case (kraison/vivace-graph#196)".
- The classes are named after the *parent symbol* (`belief`, `trace`),
  not the graph — `def-claim-classes` interns `BELIEF-UNARY` /
  `BELIEF-BINARY` in `(symbol-package parent)`
  (`vivace-graph/spacetime/claim.lisp:360-363`) — so a second
  declaration binds the **same** classes to an **additional** graph
  name via `graph-db:def-vertex ... ,graph-name`
  (`claim.lisp:377-388`). It does not create a second class family.
- Two stores must have **distinct** graph names: the engine's registry
  is keyed on the name (`graph.lisp:534`, `(setf (gethash name *graphs*)
  graph)`), and `mem:check-scope` refuses "two stores are named ~a"
  (`memory/scope.lisp:51-53`).
- `check-scope` also requires every store in a multi-store scope to be
  on **one system clock** (`memory/scope.lisp:59-72`) — which the solo
  script's "open the clock, then the store with `:system-clock`" already
  satisfies, as long as it passes the same clock to every store.

**VERIFIED (source).**

**Unsettled.** Whether `(eval `(mem:define-memory-store ,name))` with a
runtime `name` compiles and registers correctly — the expansion is
`def-vertex` / `def-value-constraint` / `def-source` forms which are
ordinary macros, so it *should*, but the engine's declaration machinery
is named-spec-identity sensitive (`claim.lisp:410-418`, the ⚠ block) and
this was not executed. **inference — the plan's first red test.** If it
does not work, the fallback is a small fixed set of declared names
(`:cl-llm-memory`, `:memory-private`, plus a handful) and a startup
refusal for any other name in `CL_LLM_MEMORY_SCOPE`, which is a
configuration restriction, not a redesign.

---

## E10. CI

```yaml
# cl-llm/.github/workflows/test.yml:24-37
        run: |
          mkdir -p ~/ci-deps-cl-llm
          for spec in "vivace-graph experiment" \
                      "cl-temporal-extent master"; do
            set -- $spec
            if [ -d ~/ci-deps-cl-llm/$1/.git ]; then
              git -C ~/ci-deps-cl-llm/$1 fetch -q origin
              git -C ~/ci-deps-cl-llm/$1 checkout -qf origin/$2
            else
              git clone -q -b $2 https://github.com/kraison/$1 \
                ~/ci-deps-cl-llm/$1
            fi
            echo "$1 @ $(git -C ~/ci-deps-cl-llm/$1 rev-parse --short HEAD)"
          done
```

The loop hard-codes `https://github.com/kraison/$1`, so **opsis needs
either a second loop or an owner field in the spec** — opsis is
`quasi/opsis`:

```
$ git -C ~/quicklisp/local-projects/opsis remote -v
origin	git@github.com:quasi/opsis.git (fetch)
$ git -C ~/quicklisp/local-projects/opsis branch --show-current
main
```

`cl-mcp` is `kraison/cl-mcp`, branch `main`
(`git -C /home/raison/work/cl-mcp remote -v`; only `main` exists).
Both are present on this host: `cl-mcp` at `/home/raison/work/cl-mcp`
(symlinked into `~/quicklisp/local-projects/cl-mcp.asd`) and opsis at
`~/quicklisp/local-projects/opsis/`, which defines `opsis/conditions`
(`opsis.asd:1`) among six systems. **VERIFIED (source).**

The registry form to extend, and the reason the symlinks do not save
CI:

```yaml
# cl-llm/.github/workflows/test.yml:40-54
          sbcl --dynamic-space-size 4096 --non-interactive \
            --load "$HOME/quicklisp/setup.lisp" \
            --eval '(setf ql:*local-project-directories* nil)' \
            --eval '(asdf:initialize-source-registry
                      (list :source-registry
                            (list :tree (uiop:getcwd))
                            (list :directory
                                  (merge-pathnames
                                   "ci-deps-cl-llm/vivace-graph/"
                                   (user-homedir-pathname)))
                            (list :directory
                                  (merge-pathnames
                                   "ci-deps-cl-llm/cl-temporal-extent/"
                                   (user-homedir-pathname)))
                            :ignore-inherited-configuration))' \
```

`ql:*local-project-directories*` is nil'd and the registry ignores the
inherited configuration, so `cl-mcp` and `opsis` **must** be cloned into
`~/ci-deps-cl-llm` and added as two more `(list :directory ...)` entries
— nothing else will find them. Quicklisp's own dist searcher is
unaffected by `:ignore-inherited-configuration`, which is why `yason`,
`fiveam` and `usocket` still resolve; this recipe was reused for both
image runs here and confirmed to resolve every system from the intended
tree.

`docs/ci.md:14-17` says the agent/prolog suite "additionally quickloads
`graph-db/gui` and its web dependencies (ningle, clack, cl-json)" — also
stale since efaaf4e (§E2); worth correcting in the same commit that adds
the new suite, since the plan touches that file anyway.

---

## §C — corrections to the spec

### C1. `required` must be a list; `derive-schema` gives a vector

§3 leaves "`required` as the sequence form `cl-mcp`'s own tools use — a
recon item settles list vs vector" open. Settled: **a list**. Both forms
*encode* to the same JSON array (§E1), so a `tools/list` golden would
pass either way, but `cl-mcp.tools:validate-tool-args` `dolist`s the
value, and a vector raises a `TYPE-ERROR` that `%handle-request` turns
into a `-32603` internal error — on **every** call to **every** tool
with a required parameter, which is all nine. A `tools/list`-only test
would not catch it. `%schema-alist` must `(coerce ... 'list)` the
`"required"` vector specifically; `enum` and `items` may stay vectors
and hash tables.

### C2. `stop` under SIGTERM is not bounded work, and closes the wrong graph

§6 promises `stop` "does no work that could outlast the unknown grace
period". `close-graph`'s default `:snapshot-p t` takes a full logical
backup before removing `.dirty` (§E8), and its docstring requires
`*GRAPH*` to be bound to the graph being closed — which a loop over a
multi-store scope satisfies for at most one store. Two decisions the
plan must take explicitly and defend in `docs/agent-memory.md`:
`:snapshot-p nil` in the shutdown path (the `.dirty` removal and the
index-root saves are unconditional, so the store is still clean), and
`(let ((gdb:*graph* g)) (gdb:close-graph g ...))` per store. Neither is
a design change; both are corrections to "one idempotent `stop`".

### C3. Closing the listening socket does not stop the accept loop

§6's ordering — "close the listener socket first, so no new connection
arrives" — assumes the accept thread notices. Measured: it does not
(§E6); it stays parked on a closed fd, and any later `socket-accept` or
`wait-for-input` on that socket signals. The listener must own a
`stopping` flag and poll `usocket:wait-for-input ... :timeout`, checking
the flag between ticks and never touching the socket after the close.
This changes `agent/mcp/listener.lisp`'s shape, not the design.

### C4. The sitrep #25 citation says the opposite of what it is cited for

§6 and `scripts/memory-image.lisp:80-83` both cite kraison/sitrep#25 as
the measurement that SBCL runs `*exit-hooks*` on SIGTERM. #25's record
(§E5) is that SIGTERM **left** the `.dirty` marker, on a service that
had installed no hook. The behaviour is nonetheless real — measured here
under both `--script` and `--load --disable-debugger`, exit code 0, hook
executed. The plan should re-cite it to this note (or to its own test)
and, since it is touching the file anyway, fix the comment in
`memory-image.lisp`.

### C5. The query tool loads `graph-db/query`, not `graph-db/gui`

§3: "loading `graph-db/gui` as it does in `make-query-tool` today". It
does not, since efaaf4e (#44): `cl-llm/agent/prolog` depends on
`graph-db/query`, the web-free home of the guard (§E2). The adapter's
`:query-tool t` path pulls in no web stack, which makes the solo mode's
load noticeably cheaper and removes ningle/clack from the CI story.

### C6. `read-message`/`write-message` are the wrong pair for the listener tests

§8 has the listener tests "speaking NDJSON with `cl-mcp`'s
`read-message`/`write-message`". Both are external in
**`cl-mcp.transport`**, not in `cl-mcp` (§E3), and they are the
*server's* pair: `read-message` parses a request and rejects a response,
`write-message` writes a response struct. A test playing client must use
`cl-mcp.json-rpc:make-request` + `cl-mcp.client:encode-request` to
write and `cl-mcp.client:parse-client-message` to read — all exported,
and documented in `src/client/packages.lisp:26` as "exported for
testing".

### C7. `cl-mcp/client` cannot see the refusal message or the exit code

§8's "a second solo server on the held store exits non-zero with the
message and no handshake" cannot be written through the client:
`connect` passes `:error-output nil`, so the stderr line is discarded,
and `disconnect` never reports an exit code and does not export the
process. That test needs its own `uiop:launch-program` /
`sb-ext:run-program` harness capturing stderr and waiting for the exit
(§E4, §E5). The same harness serves the SIGTERM test.

### C8. `disconnect` does not wait for the child, and can cut a slow close

The "no `.dirty` in the store directory, and a clean reopen" assertion
must wait for the child to exit before probing the directory:
`disconnect` closes stdin, joins the reader for at most 5 s, then
unconditionally `uiop:terminate-process`es (SIGTERM) and nulls the
process slot. Capture `cl-mcp.client::client-process` before
`disconnect` and `uiop:wait-process` it. If a store's clean close ever
exceeds 5 s, `disconnect` interrupts it — another argument for
`:snapshot-p nil` (C2).

### C9. `make-agent-tools` takes no `:query-tool`, and the query tool is scope-blind

§3's "`make-memory-server` calls `agent:make-agent-tools` with the same
arguments" is right, but `:query-tool` is not among them: the adapter
must call `pl:make-query-tool` separately and append. Note the tool
takes the store **list**, not the scope, so it neither reads nor seeds
the scope's cite cache; a cite obtained from `query` and then passed to
`conclude` as evidence resolves only through `cite-store`'s fallback
scan. That is existing behaviour, not something the adapter changes, but
the spec's "the guarded Prolog tool ... joins the set" reads as if it
were scope-aware.

### C10. `clientInfo` is unavailable, and per-connection state has no home

§5's hello is load-bearing for a reason the spec does not state:
`%handle-initialize` ignores its params entirely, and a tool handler
receives only `arguments` (§E3). There is no way to reach the connection
from inside a handler. The per-connection producer must therefore be
closed over by building a **fresh `mcp-server` and a fresh tool set per
socket** — which the spec says, and which is also required because
`run-server` stores the output stream in the server struct.

### C11. `CL_LLM_MEMORY_SCOPE` needs a runtime schema declaration, unproven

§4 says each name in the scope is "a graph name whose schema
`define-memory-store` declared" — but the macro takes an unevaluated
name and only `:cl-llm-memory` is declared by the library (§E9). The
config layer must `eval` a `define-memory-store` per name at startup,
which this recon did **not** get to execute. Make it the first red test;
if it fails, restrict `CL_LLM_MEMORY_SCOPE` to a declared allow-list and
refuse the rest at startup with the same one-line-and-exit-1 treatment
as the other startup errors.

### C12. Numbers arrive as doubles

`k` and `limit` are `:type integer`, and `agent:clamp` requires
`(integerp n)` (`agent/scope.lisp:66-68`), silently substituting the cap
otherwise. yason decodes `5` as an integer but `5.0` as a
`DOUBLE-FLOAT` (§E1), so a client that sends a JSON float gets the cap
with no complaint. Not a defect in anything the spec touches; worth one
line in the adapter's docstring so it is a known behaviour rather than a
surprise.

### C13. Two small omissions in the environment story

`run-memory.sh` does not export `CL_LLM_MEMORY_CLOCK` although
`memory-image.lisp` reads it (§E7) — the new `run-memory-mcp.sh` should
export the full set including `_CLOCK`, and `docs/agent-memory.md`'s
table should list it. And `cl-mcp/client` has no `:environment`: the
solo round-trip test must set the variables in the test image (or the
wrapper must take the store on argv) before `connect` (§E4).

---

## §S — the shape of the smallest correct change

In dependency order. Signatures are what the facts above force; nothing
here is a design decision the spec did not already take.

### `agent/mcp/packages.lisp` (new)

`cl-llm.agent.mcp`, `(:use #:cl)`, local nicknames `llm` = `cl-llm`,
`c` = `cl-llm.conditions`, `agent` = `cl-llm.agent`, `mem` =
`cl-llm.memory`, `gdb` = `graph-db`, `st` = `graph-db.spacetime`, `mcp`
= `cl-mcp`, `mcp.tools` = `cl-mcp.tools`, `mcp.tr` =
`cl-mcp.transport`. Export `make-memory-server`, the config reader, the
listener's `start-listener`/`stop-listener`, and the principals API.
Depends on `cl-llm/agent` and `cl-mcp` only; the query tool is pulled in
by the *scripts*, not by the system, so `cl-llm/agent/mcp` does not drag
`graph-db/query` into every consumer.

### `agent/mcp/adapter.lisp` (new)

```lisp
(defun %schema-alist (schema))            ; hash-table -> string-keyed alist,
                                          ; "required" coerced to a LIST (C1)
(defun %array-parameters (tool))          ; the schema's array-typed names,
                                          ; as a list of strings
(defun %arguments-table (arguments array-names))
                                          ; alist -> equal hash table;
                                          ; a name in ARRAY-NAMES gets
                                          ; (coerce value 'vector) (E2)
(defun %handler (tool))                   ; (lambda (arguments) ...) =>
                                          ; (values json-string)  |
                                          ; (values message t) on llm-tool-error
(defun register-llm-tool (server tool))   ; name, description, %schema-alist,
                                          ; %handler
(defun make-memory-server (stores &key write-store producer sources
                                       (k 5) (max-rows 50) query-tool
                                       (name "cl-llm-memory")
                                       (version "0.1")))
```

`%handler` catches `c:llm-tool-error` only and returns
`(values (princ-to-string e) t)`; every other condition propagates to
`run-server`, per §7. `make-memory-server` calls
`mcp:make-server :name :version`, then `agent:make-agent-tools` with the
same arguments, then — when `query-tool` — appends
`(pl:make-query-tool stores :max-rows max-rows)`, registering each.

### `agent/mcp/config.lisp` (new)

```lisp
(defun env (name &optional default))
(defun parse-scope (spec))                ; "name=dir,name=dir" -> ((name . dir))
(defun declare-store-schemas (names))     ; eval define-memory-store per name (C11)
(defun open-scope (&key spec write clock-dir system-dir buffer-pool))
                                          ; => (values stores write-store clock)
(defun close-scope (stores clock))        ; :snapshot-p nil, gdb:*graph* bound
                                          ; per store (C2); never signals
```

`open-scope` opens the clock first and passes it to every store, so
`mem:check-scope`'s one-clock rule holds (§E9); it lets
`gdb:store-not-closed-cleanly-error` and `gdb:system-clock-in-use`
through for the scripts to report (§4, §7).

### `agent/mcp/identity.lisp` (new)

```lisp
(defun read-principals (path))            ; (("producer" . "secret") ...),
                                          ; each canonical (st:canonical-producer-p)
(defun check-bind (address principals))   ; refuses non-loopback without
                                          ; principals; the tested validator (§8)
(defun loopback-p (address))
(defun parse-hello (line))                ; => (values principal secret) | nil
(defun resolve-identity (provider line peer default))
                                          ; => producer | :refused
```

`parse-hello` must return the *unconsumed* line too, or the caller must
keep it, because the replay needs `(concatenate 'string line
(string #\Newline))` (§E3).

### `agent/mcp/listener.lisp` (new)

```lisp
(defstruct listener socket thread stopping bind port stores write-store
                    clock principals provider default-producer)
(defun start-listener (&key bind port stores write-store provider
                            principals-path default-producer query-tool))
(defun stop-listener (listener))          ; sets STOPPING, joins, then closes (C3)
(defun %accept-loop (listener))           ; usocket:wait-for-input :timeout 0.5,
                                          ; re-check STOPPING each tick
(defun %serve-connection (listener socket))
                                          ; read the hello line, resolve identity,
                                          ; build a per-connection server, then
                                          ; (mcp:run-server server
                                          ;   :input (make-concatenated-stream ...)
                                          ;   :output (usocket:socket-stream socket))
```

One `mcp-server` per connection (C10). Per-connection thread. On EOF
`run-server` returns and the connection thread closes its socket and
exits; `stop-listener` does not close live connections (§9: no graceful
drain).

### `scripts/memory-mcp.lisp` + `scripts/run-memory-mcp.sh` (new)

The image script mirrors `memory-image.lisp`'s structure: all load
output to `*error-output*` (as `cl-mcp-server/run-server.lisp:7-8` does),
`open-scope`, `make-memory-server`, `push #'stop sb-ext:*exit-hooks*`
*after* the open succeeds, then
`(mcp:run-server server :input *standard-input* :output *standard-output*)`,
then `stop` and `(sb-ext:exit :code 0)`. The refusal paths print one
line and `(sb-ext:exit :code 1 :abort t)` before the hook is pushed.
The shell wrapper exports the same seven variables `run-memory.sh` does
plus `_CLOCK`, `_SCOPE`, `_WRITE` and `_QUERY_TOOL` (C13), and sets
`LC_ALL`/`LANG` so the child's streams are UTF-8 (§E5).

### `scripts/memory-mcp-client.lisp` (new)

`sbcl --script`; `usocket:socket-connect`, optional hello line, two
`bt:make-thread` pumps, exit on either EOF. Reads the secret from
`~/.cl-llm-memory/client.sexp`.

### `cl-llm.asd`

`cl-llm/agent/mcp` (`:depends-on ("cl-llm/agent" "cl-mcp")`, pathname
`agent/mcp/`, files packages / adapter / config / identity / listener)
and `cl-llm/agent/mcp/tests` (`:depends-on ("cl-llm/agent/mcp"
"cl-llm/agent/prolog" "cl-llm/agent/tests" "cl-mcp/client" "fiveam")`,
pathname `tests-agent-mcp/`). **Both need the `:in-order-to
((test-op (test-op ...)))` link and a `:perform` that errors on failure**
— without it `test-system` is a silent no-op (`cl-llm.asd:187-190`,
kraison/cl-llm#26).

### `tests-agent-mcp/` — the two fixtures the tests need

**1. A subprocess harness** (solo mode, the SIGTERM test, and the
double-hold refusal — none of which `cl-mcp/client` can express, C7):

```lisp
(defun %launch-solo (store-dir &key clock-dir system-dir extra-env)
  ;; sb-ext:run-program "/usr/bin/env" (list "sbcl" "--script" script)
  ;;   :environment (append extra-env (sb-ext:posix-environ))
  ;;   :input :stream :output :stream :error :stream :wait nil
  ;; => process
  )
(defun %term-and-wait (process &key (grace 12))
  ;; sb-ext:process-kill process sb-unix:sigterm
  ;; poll sb-ext:process-alive-p; sb-ext:process-wait
  ;; => (values exit-code stderr-string)
  )
```

For the `cl-mcp/client` round trip, set the environment in the **test
image** before `connect` (C13) and keep the process handle:

```lisp
(let ((client (cl-mcp.client:make-client
               :command (list "/abs/path/scripts/run-memory-mcp.sh"))))
  (cl-mcp.client:connect client)
  ...
  (let ((p (cl-mcp.client::client-process client)))
    (cl-mcp.client:disconnect client)
    (uiop:wait-process p))          ; before probing for .dirty (C8)
  ...)
```

Assert `isError` by catching `cl-mcp.client.conditions:mcp-tool-error`
and reading `tool-error-content` (§E4).

**2. An ephemeral-port listener harness** (listener mode):

```lisp
(defmacro with-listener ((var &rest args) &body body))
  ;; start-listener :bind "127.0.0.1" :port 0, then read the bound port
  ;; back with usocket:get-local-port on the listener's socket
(defun %connect-and-hello (port &optional principal secret)
  ;; usocket:socket-connect "127.0.0.1" port  (element-type 'character,
  ;; external format :UTF-8 by default -- E6)
  ;; write the hello line + #\Newline, force-output
  )
(defun %rpc (stream method params)
  ;; (write-string (cl-mcp.client:encode-request
  ;;                 (cl-mcp.json-rpc:make-request :id n :method method
  ;;                                               :params params)) stream)
  ;; (write-char #\Newline stream) (force-output stream)
  ;; (cl-mcp.client:parse-client-message (read-line stream))   -- C6
  )
```

The stores come from `tests-agent`'s clocked `with-stores`
(`tests-agent/harness.lisp:15-51`), which already opens two graphs on one
`open-system-clock` and tears them down — reuse it rather than write a
third fixture. Note it declares `:memory-private` at load time
(`harness.lisp:13`); the C11 test must use a *third*, runtime-declared
name to be non-vacuous.

### Test order (each red first, each named for its mechanism)

1. `A-RUNTIME-DECLARED-STORE-NAME-OPENS` — C11, and the gate on
   `CL_LLM_MEMORY_SCOPE`. Run it before writing `config.lisp`.
2. `A-REQUIRED-LIST-VALIDATES-AND-A-VECTOR-DOES-NOT` — C1, with the
   vector case as its control. This is the one the spec left open.
3. `THE-SHUTDOWN-CLOSES-EVERY-STORE-WITH-GRAPH-BOUND` — C2, with a
   two-store scope and an assertion on both `.dirty` markers.
4. `A-LIST-VALUED-ARRAY-ARGUMENT-REACHES-THE-TOOL-AS-A-VECTOR` — E2, on
   `conclude`'s `evidence`, through `cl-mcp.tools:call-tool`.
5. `STOP-ENDS-THE-ACCEPT-LOOP` — C3, asserting the thread is gone and a
   new connect is refused, with a control that the loop was accepting.
6. `A-REFUSED-HELLO-CLOSES-BEFORE-INITIALIZE` — assert on the closed
   stream, not on a timeout.
7. `SIGTERM-LEAVES-THE-STORE-CLEAN` — C4/C7, through the subprocess
   harness, with `.dirty` absence and a clean reopen as the assertion.

### Commands the plan must use

```sh
# the new suite, foreground, from the worktree root
sbcl --dynamic-space-size 4096 --non-interactive \
  --eval '(ql:quickload :cl-llm/agent/mcp/tests)' \
  --eval '(asdf:test-system :cl-llm/agent/mcp)'

# then the suites it could have broken
sbcl --dynamic-space-size 4096 --non-interactive \
  --eval '(ql:quickload (list :cl-llm/memory/tests :cl-llm/agent/tests))' \
  --eval '(asdf:test-system :cl-llm/memory)' \
  --eval '(asdf:test-system :cl-llm/agent)'
```

Read `Did N checks` out of each run and record the counts (deleted tests
keep suites green). CI's step gains two clones and two registry entries:

```yaml
for spec in "kraison vivace-graph experiment" \
            "kraison cl-temporal-extent master" \
            "kraison cl-mcp main" \
            "quasi opsis main"; do
  set -- $spec   # $1 owner, $2 repo, $3 branch
  ...            # https://github.com/$1/$2 -> ~/ci-deps-cl-llm/$2
done
```

plus `(list :directory (merge-pathnames "ci-deps-cl-llm/cl-mcp/" ...))`
and the same for `opsis/` in the `initialize-source-registry` form, and
`(asdf:test-system :cl-llm/agent/mcp)` at the end of the eval chain
(§E10).
