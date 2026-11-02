# Local model from Lisp, and the agent harness: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive a local llama-server model from Lisp (#88), and run a
named persona as a bounded, attributed, guarded run (#85).

**Architecture:** Unit 1 adds tests, an example and any decoding fixes
to core cl-llm. Unit 2 is a new system `cl-llm/harness` (`cl-llm` +
`bordeaux-threads`): personas as data, a `run` record, and
`run-persona`, which enforces its guards by handing the existing
`llm:send` loop a wrapping provider and wrapped tools, so core's tool
loop is unchanged. Accounting as claims goes in `cl-llm/agent`.

**Tech stack:** SBCL, ASDF, FiveAM, bordeaux-threads 0.9.4, jzon (via
`cl-llm.json`), llama-server (OpenAI-compatible) for the live tests.

**Spec:** `docs/superpowers/specs/2026-11-02-agent-harness-and-conversational-rag-design.md`
(§6 and §9). Units 3 and 4 (#89, #90) get their own plan after this one
lands.

## Global constraints

- Lisp: spaces only, never tabs; hard limit 80 columns in code,
  comments, docstrings and strings; terse comments that point to
  `docs/`, the spec or an issue.
- Core `cl-llm` stays thread-free and keeps its dependencies (dexador,
  jzon, uiop). Only `cl-llm/harness` may depend on `bordeaux-threads`.
- `cl-llm/harness` must not depend on vivace-graph or `cl-llm/memory`.
- `ask` and `send` behave exactly as today.
- A guard stop is a returned run, never a signalled condition. A tool
  body is never interrupted.
- An API key never appears in a persona, a run, a log line or an error
  message. A persona names a key *file*.
- Persona files are never evaluated: `*read-eval*` is NIL.
- Canonical names: persona names `[a-z0-9-]+`; producers `[a-z0-9-/]+`.
- Every task that changes source also changes docs: `README.md`,
  `examples/README.md`, `docs/agent-harness.md` (new) or the spec.
- Public repository: nothing domain-specific to any consumer in code,
  tests, docs or commit messages.
- **TEST(system):** run a suite in a fresh image against this worktree,
  never the main checkout (local-projects links the main one):

  ```sh
  sbcl --non-interactive \
    --eval '(push #p"<worktree>/" asdf:*central-registry*)' \
    --eval '(format t "~&SRC ~a~%" (asdf:system-source-directory "cl-llm"))' \
    --eval '(ql:quickload :SYSTEM/tests :silent t)' \
    --eval '(asdf:test-system :SYSTEM)' 2>&1 | tail -25
  ```

  Passing means the `SRC` line names the worktree and the summary says
  `Fail: 0`. For core, SYSTEM is `cl-llm`; for the harness,
  `cl-llm/harness`; for the agent, `cl-llm/agent`.
- **LIVE:** the live suite runs only with `CL_LLM_LIVE=1`, plus
  `CL_LLM_LLAMA_BASE_URL` (e.g. `http://127.0.0.1:8080/v1`),
  `CL_LLM_LLAMA_MODEL` (the server's model alias) and
  `CL_LLM_LLAMA_KEY_FILE` (its API key file, if it has one). Start
  llama-server first and wait for `GET /health` to answer `ok`. A cold
  first reply loads the model and can take minutes.

## Review focus

1. **A response with no usage** (some servers omit it): the run still
   completes; its token totals count what was reported, and the token
   budget counts missing usage as zero. Test in Task 4.
2. **A persona file with an unknown key or a `#.` form:** refused with
   an error naming the key or the reader error; nothing is evaluated.
   Test in Task 2.
3. **A missing or unreadable key file:** the run returns `:error`
   naming the path, and no key text appears anywhere in the run. Test
   in Task 4.
4. **The model names a tool it was not offered:** core signals a
   protocol violation; the run returns `:error` and a supplied
   conversation is left as it was. Test in Task 4.
5. **The deadline passes while a run waits in the queue:** it returns
   `:deadline` promptly instead of waiting on. Test in Task 5.

---

### Task 1: a local llama-server model from Lisp (#88)

**Files:**
- Modify: `tests/openai.lisp` (append tests)
- Modify: `live/live.lisp` (append tests), `live/packages.lisp` if a
  helper needs exporting
- Create: `examples/local-llama.lisp`
- Modify: `examples/README.md` (catalog row), `README.md` (one line
  under the local / OpenAI-compatible paragraph pointing to the example)

**Interfaces:**
- Consumes: `llm:openai-compatible-provider` (`:base-url`, `:model`,
  `:api-key`), `llm:decode-response`, `llm:parse-stream-event`.
- Produces: nothing later tasks call. The live helper
  `llama-provider ()` in `cl-llm.live` is reused by Task 7.

- [ ] **Step 1: Write the failing offline tests** in
  `tests/openai.lisp`:

  ```lisp
  (test openai-reasoning-content-is-not-answer-text
    ;; llama-server puts reasoning in message.reasoning_content
    (let* ((p (make-instance 'llm:openai-compatible-provider
                             :base-url "http://x/v1" :model "m"))
           (r (llm:decode-response
               p (json:parse "{\"model\":\"m\",\"choices\":[{\"message\":
                 {\"role\":\"assistant\",\"content\":\"pong\",
                  \"reasoning_content\":\"think think\"},
                 \"finish_reason\":\"stop\"}],
                 \"usage\":{\"prompt_tokens\":5,\"completion_tokens\":7}}"))))
      (is (string= "pong" (llm:response-text r)))
      (is (= 7 (llm:usage-output-tokens (llm:response-usage r))))))

  (test openai-reasoning-delta-is-ignored-in-streams
    (let ((p (make-instance 'llm:openai-compatible-provider
                            :base-url "http://x/v1" :model "m")))
      (is (eq :ignore
              (llm:parse-stream-event
               p (sse:make-sse-event
                  :data "{\"choices\":[{\"delta\":
                         {\"reasoning_content\":\"hm\"}}]}"))))))
  ```

  Use the test package's existing nicknames for `json` and `sse`; check
  `tests/packages.lisp` and the existing `make-sse-event` arguments.

- [ ] **Step 2: Run them.** TEST(cl-llm). Expected: both pass already
  (they pin behaviour), or a failure shows the decoding bug to fix in
  `src/providers/openai.lisp`. Ablate once to prove each test bites:
  temporarily make `decode-response` append `reasoning_content` to the
  text, see the first test fail, revert.

- [ ] **Step 3: Write the live tests** in `live/live.lisp`, each
  skipped unless `live-enabled-p` and `CL_LLM_LLAMA_BASE_URL` is set,
  each binding `llm:*timeout*` to 300 and `llm:*max-tokens*` to 12000
  (reasoning shares the budget):
  - `live-llama-ask`: "Reply with exactly the word: pong" → the text
    contains `pong` (case-insensitive) and does not contain `<think>`.
  - `live-llama-conversation`: two `llm:send` calls on one
    conversation ("My name is Ada. Reply OK." then "What is my name?
    One word.") → the second text contains `ada`.
  - `live-llama-tool`: the existing `live-add` tool pattern, "Use the
    live-add tool to add 17 and 25. Reply with just the number." → the
    text contains `42`.
  - `live-llama-streaming`: `with-streamed-response` + `do-deltas` on
    "Count: one two three" → at least one delta, and the concatenation
    contains `three`.

  `llama-provider ()` builds the provider from the three environment
  variables; the key is read with `uiop:read-file-line` and trimmed.

- [ ] **Step 4: Write `examples/local-llama.lisp`** in the style of
  `examples/quickstart.lisp`: package `examples/local-llama`, a
  `provider (&key base-url model key-file)` function, and a `run`
  function that demonstrates `ask`, a two-turn `send`, a tool call and
  streaming, each bound with `llm:*timeout*` 300. Top-of-file comment:
  how the server is expected to be running (llama-server with
  `--jinja`, an API key file), and that a reasoning model needs
  max-tokens room for its reasoning.

- [ ] **Step 5: Docs.** Add the catalog row to `examples/README.md`
  ("local llama-server model: ask, conversation, tool, streaming; yes,
  a local llama-server"), and the README pointer.

- [ ] **Step 6: Run offline and live.** TEST(cl-llm): `Fail: 0`. Then
  LIVE: start the server, run
  `(fiveam:run! 'cl-llm.live::cl-llm-live-suite)` with the LIVE
  environment; the four `live-llama-*` tests pass. If one fails, use
  superpowers:systematic-debugging before changing anything.

- [ ] **Step 7: Commit.**

  ```bash
  git add tests/openai.lisp live/live.lisp examples/local-llama.lisp \
          examples/README.md README.md
  git commit -m "feat(live): drive a local llama-server model from Lisp (#88)"
  ```

  Close #88 with a comment naming the commit and the live run's result.

### Task 2: the harness system and personas as data

**Files:**
- Modify: `cl-llm.asd` (systems `cl-llm/harness`,
  `cl-llm/harness/tests`)
- Create: `harness/packages.lisp`, `harness/persona.lisp`
- Create: `tests-harness/packages.lisp`, `tests-harness/suite.lisp`,
  `tests-harness/persona-tests.lisp`
- Create: `docs/agent-harness.md` (personas section); modify
  `README.md` (one line linking it)

**Interfaces:**
- Produces, in package `cl-llm.harness` (consumers give it the local
  nickname `harness`):
  - `(make-persona &key name system tools provider parameters
    (max-turns llm:*max-tool-turns*) max-run-tokens max-seconds
    (max-concurrent 1) (max-queued 0) daily-token-budget
    daily-run-budget) => persona`. NAME canonical `[a-z0-9-]+`, else
    `persona-error`. TOOLS a list of tool-name strings or `llm:tool`
    objects. PROVIDER an `llm:provider` or a description plist
    `(:kind :openai-compatible :base-url S :model S :api-key-file S)`
    or `(:kind :anthropic :model S)`. PARAMETERS a plist of
    `:temperature :max-tokens :top-p :stop`.
  - Readers: `persona-name persona-system persona-tools
    persona-provider persona-parameters persona-max-turns
    persona-max-run-tokens persona-max-seconds persona-max-concurrent
    persona-max-queued persona-daily-token-budget
    persona-daily-run-budget`.
  - `(persona-make-provider persona) => llm:provider`: a provider
    object as given, or one built from the description, reading the key
    file at call time (`persona-error` naming the path, never its
    contents, when unreadable).
  - `(load-persona-file pathname) => persona`.
  - `(defgeneric find-persona (source name))`; `(make-persona-directory
    pathname) => source`, whose `find-persona` loads
    `<dir>/<name>.persona`, or returns NIL when absent.
  - Condition `persona-error` (an `error`), with a readable report.

- [ ] **Step 1: Write the failing tests** in
  `tests-harness/persona-tests.lisp`:
  - `persona-name-must-be-canonical`: `(make-persona :name "Bad Name"
    ...)` signals `persona-error`; `"summariser-2"` is accepted.
  - `persona-file-round-trip`: write a file containing
    `(:name "echo" :system "Be terse." :tools ("tool-echo")
    :provider (:kind :openai-compatible :base-url "http://x/v1"
    :model "m" :api-key-file "/nonexistent") :parameters
    (:temperature 0.2) :budgets (:max-turns 3 :max-seconds 30))`;
    `load-persona-file` returns a persona whose name, system, tools,
    parameters, max-turns and max-seconds equal those values.
  - `persona-file-unknown-key-refused`: a file with `:sytem` signals
    `persona-error` whose report contains `SYTEM` (case-insensitive).
  - `persona-file-never-evaluated`: a file whose `:system` value is
    `#.(error "evaluated")` signals `persona-error`, and the condition
    is not the `"evaluated"` error.
  - `persona-directory-finds-by-name`: `find-persona` on a directory
    with `echo.persona` returns it; on `"absent"` returns NIL.
  - `persona-key-file-unreadable`: `persona-make-provider` with
    `:api-key-file "/nonexistent/key"` signals `persona-error` whose
    report contains `/nonexistent/key`.
  - `persona-key-file-read-at-call-time`: write `k1` to a temp key
    file, build the persona, overwrite with `k2`, then
    `(llm:provider-api-key (persona-make-provider p))` is `"k2"`.

- [ ] **Step 2: Run them.** TEST(cl-llm/harness). Expected: fail to
  load (system not defined).

- [ ] **Step 3: Define the systems** in `cl-llm.asd`: `cl-llm/harness`
  depends on `"cl-llm" "bordeaux-threads"`, module `harness`, serial;
  `cl-llm/harness/tests` depends on `"cl-llm/harness" "fiveam"`, module
  `tests-harness`, with a `:perform test-op` that runs suite
  `:cl-llm-harness` and errors on failure, like `cl-llm/eval/tests`.
  Add `:in-order-to ((test-op (test-op "cl-llm/harness/tests")))`.

- [ ] **Step 4: Implement `harness/persona.lisp`.** The file format is
  one plist with top-level keys `:name :system :tools :provider
  :parameters :budgets`; `:budgets` holds the `make-persona` budget
  keywords. Read it with `with-standard-io-syntax`, `*read-eval*` NIL
  and `*package*` the keyword package, exactly one form; any reader
  error becomes `persona-error`. Validate every key and type before
  constructing.

- [ ] **Step 5: Run the tests.** TEST(cl-llm/harness): `Fail: 0`.
  Ablate `*read-eval*` NIL once and see
  `persona-file-never-evaluated` fail; revert.

- [ ] **Step 6: Docs.** `docs/agent-harness.md`: what a persona is, the
  file format with one complete example, the lookup protocol, and the
  rule that a persona names a key file, never a key. README links it.

- [ ] **Step 7: Commit** `feat(harness): personas as data (#85)`.

### Task 3: the run record and attribution

**Files:**
- Create: `harness/run.lisp`, `tests-harness/run-tests.lisp`
- Modify: `cl-llm.asd` (component order), `docs/agent-harness.md`
  (the run, the producer)

**Interfaces:**
- Produces:
  - Class `run` with readers `run-id run-persona-name run-producer
    run-input run-started run-finished run-elapsed run-turns
    run-input-tokens run-output-tokens run-stop-reason run-error
    run-text run-tool-calls run-response`. STARTED and FINISHED are
    universal times; ELAPSED is seconds (a real) from the harness clock;
    TOOL-CALLS is a list, oldest first, of plists `(:name S :arguments
    LIST :result S :error-p BOOL)`.
  - `(make-run-id) => string`, canonical `[a-z0-9-]+`, of the form
    `r-<base36 universal time>-<base36 counter>-<base36 random>`,
    lowercase.
  - `(host-principal) => string`: `machine-instance` up to the first
    `.`, lowercased, every character outside `[a-z0-9-]` replaced by
    `-`.
  - `(run-producer-for persona-name run-id &key producer) => string`:
    `<persona>/<host-principal>/<run-id>`, or `<producer>/<run-id>`
    when PRODUCER (itself `<agent>/<host>`) is given; signals
    `persona-error` unless the result is canonical `[a-z0-9-/]+`.
  - `*clock*`: a function of no arguments returning seconds as a real,
    default from `get-internal-real-time`. Tests rebind it.

- [ ] **Step 1: Failing tests:** `run-id-canonical-and-distinct` (1000
  ids, all match `^[a-z0-9-]+$`, all distinct);
  `host-principal-canonical` (matches `^[a-z0-9-]+$`, contains no
  `.`); `producer-default-shape` (`"echo"`, id `"r-1"` gives
  `"echo/<host>/r-1"`); `producer-prefix-given` (`:producer
  "agent/box"` gives `"agent/box/r-1"`); `producer-uncanonical-refused`
  (`:producer "Agent/Box"` signals `persona-error`).
- [ ] **Step 2: Run.** TEST(cl-llm/harness): the new tests fail.
- [ ] **Step 3: Implement** `harness/run.lisp` per the interfaces.
- [ ] **Step 4: Run.** TEST(cl-llm/harness): `Fail: 0`.
- [ ] **Step 5: Docs:** the run record's fields and the producer
  grammar in `docs/agent-harness.md`, noting that the memory store's
  recall reads `<persona>/<host>/` as a prefix (#82).
- [ ] **Step 6: Commit** `feat(harness): the run record and its
  producer (#85)`.

### Task 4: `run-persona` with its per-run guards

**Files:**
- Modify: `src/tools.lisp`, `src/packages.lisp` (export `copy-tool`),
  `tests/tools.lisp` (one test)
- Create: `harness/guard.lisp`, `harness/run-persona.lisp`,
  `tests-harness/run-persona-tests.lisp`
- Modify: `cl-llm.asd`, `docs/agent-harness.md`, and the spec §6.4
  ("The hook" becomes the wrapping approach below)

**Interfaces:**
- Consumes: Tasks 2-3; `llm:send`, `llm:*timeout*`,
  `llm:llm-tool-error`, `llm:llm-error-tool-name`.
- Produces:
  - Core: `(llm:copy-tool tool &key function) => tool`, a new tool
    with TOOL's name, description, schema and parameter metadata, and
    FUNCTION in place of its own.
  - `(run-persona persona input &key conversation producer tools) =>
    run`. TOOLS are `llm:tool` objects the caller offers; a persona's
    tool name resolves first against them, then `llm:find-tool`; an
    unresolved name ends the run with `:error`.
  - `(time-left) => real or NIL`: seconds until the current run's
    deadline, for tool bodies; NIL outside a run or with no deadline.
  - Stop reasons on the run: the model's (`:end-turn :max-tokens
    :stop`), and `:max-turns :deadline :token-budget :error`
    (`:busy` and `:daily-budget` arrive in Task 5).

**How the guards work (decided here; record it in the spec):**
`run-persona` builds a fresh conversation (or borrows the supplied
one, see below) whose provider is a `guarded-provider`, an
`llm:provider` subclass wrapping `persona-make-provider`'s result. Its
`llm:chat-request` method: checks the deadline and the token budget
and stops the run if either is spent; binds `llm:*timeout*` to the
smaller of its current value and the ceiling of `time-left` (when
`*timeout*` is NIL, to the ceiling of `time-left`; with no deadline, it
is left alone); calls the inner provider; counts the turn and adds the response's usage (NIL
counts as zero) to the run. Each offered tool is replaced by
`llm:copy-tool` with a function that checks the deadline, calls the
original, and records the call. Stopping signals a harness-internal
condition that is a `condition`, not an `error`, so core's tool
handlers do not catch it; `run-persona` handles it around `llm:send`,
which rolls the conversation back. Core's
`llm-tool-error` with a NIL tool name, raised when the turn count
equals the persona's max turns, maps to `:max-turns`. Any other
`error` maps to `:error`, recorded on the run.

**A supplied conversation:** the run appends INPUT to it and continues
it; on success the user turn and the replies stay. The persona's
system prompt, guarded provider and parameters apply for the run; the
conversation's own system, provider and parameters slots are restored
afterwards, on every exit.

- [ ] **Step 1: Failing tests** in `tests-harness/run-persona-tests.lisp`,
  all with `llm:make-mock-provider` responders that return scripted
  `llm:response` objects (with `llm:usage`) in order:
  - `run-completes-and-records`: one text response, usage 10/5 → stop
    `:end-turn`, text as scripted, turns 1, tokens 10 and 5, STARTED ≤
    FINISHED, producer starts with `"<name>/"`.
  - `run-records-tool-calls`: a tool-use response for `tool-echo` with
    `{"text":"hi"}`, then text → `run-tool-calls` is one plist with
    `:name "tool-echo"`, `:result "echo:hi"`, `:error-p` NIL.
  - `run-max-turns`: the responder always asks for a tool;
    `:max-turns 2` → stop `:max-turns`, turns 2.
  - `run-token-budget`: two tool-use responses with usage 60/0 each,
    `:max-run-tokens 100` → stop `:token-budget` after turn 2, never a
    third request (count the responder's calls).
  - `run-deadline-before-request`: `*clock*` advances 10 s per call;
    `:max-seconds 15` → stop `:deadline` before the responder is called
    a second time.
  - `run-timeout-follows-deadline`: the responder records
    `llm:*timeout*`; with `:max-seconds 30` and a fixed clock, the
    recorded value is ≤ 30.
  - `run-no-usage-still-completes` (Review focus 1): a response with no
    usage → stop `:end-turn`, tokens 0 and 0.
  - `run-key-file-error` (Review focus 3): a description provider with
    a missing key file → stop `:error`, `run-error` mentions the path;
    with a key file containing `SEKRIT` but an unreachable base URL,
    `(search "SEKRIT" (format nil "~a" (run-error r)))` is NIL.
  - `run-unoffered-tool` (Review focus 4): the model names `"nope"` →
    stop `:error`; a supplied conversation's message list is EQUAL to
    its list before the run.
  - `run-continues-supplied-conversation`: a conversation with one
    earlier user/assistant pair, system `"orig"` → after the run it has
    four messages and its system is `"orig"` again.
  - `run-tool-sees-time-left`: a tool returning `(time-left)` under
    `:max-seconds 60` → the recorded result parses to a number ≤ 60.
  And in `tests/tools.lisp`: `copy-tool-swaps-function-only` (same
  name, schema and parameter names; `call-tool` uses the new
  function).

- [ ] **Step 2: Run.** TEST(cl-llm) and TEST(cl-llm/harness): the new
  tests fail.
- [ ] **Step 3: Implement** `llm:copy-tool` in `src/tools.lisp` and
  export it.
- [ ] **Step 4: Implement** `harness/guard.lisp` (the guarded provider,
  the stop condition, `time-left`, tool wrapping) and
  `harness/run-persona.lisp`.
- [ ] **Step 5: Run.** TEST(cl-llm) and TEST(cl-llm/harness):
  `Fail: 0`. Ablate the deadline check in the guarded provider and see
  `run-deadline-before-request` fail; revert.
- [ ] **Step 6: Docs.** `docs/agent-harness.md`: `run-persona`, each
  guard, `time-left`, and the trap that a slow tool overruns the
  deadline by its own duration (and that `*retries*` can stretch one
  request). Update the spec's §6.4 hook paragraph to the wrapping
  approach.
- [ ] **Step 7: Commit** `feat(harness): run-persona and its per-run
  guards (#85)`.

### Task 5: concurrency and daily budgets per persona

**Files:**
- Create: `harness/state.lisp`, `tests-harness/state-tests.lisp`
- Modify: `harness/run-persona.lisp`, `cl-llm.asd`,
  `docs/agent-harness.md`

**Interfaces:**
- Produces:
  - Per-persona state keyed by persona name, in one table guarded by a
    `bt:lock`: active runs, waiting runs, the UTC day
    (`(floor (funcall *wall-clock*) 86400)`), tokens and runs that day.
  - `*wall-clock*`: a function returning universal time, default
    `get-universal-time`. Tests rebind it.
  - `(persona-usage name) => (values tokens-today runs-today active
    waiting)`.
  - `(reset-persona-state &optional name)`: clears one name or all;
    for tests and operators.
  - `run-persona` gains the stops `:busy` (more than max-concurrent
    active and max-queued waiting) and `:daily-budget` (the day's runs
    or tokens already at their budget at start, or the day's tokens
    reaching it before a later request).
- Ordering inside `run-persona`: daily check, then a slot (wait in the
  queue with `bt:condition-wait`'s `:timeout` set to `time-left`, or
  without a timeout when there is no deadline), then the run; the slot
  is released on every exit; the day's run count rises when a slot is
  acquired; tokens are added after each response.

- [ ] **Step 1: Failing tests:**
  - `busy-when-full`: max-concurrent 1, max-queued 0; a run whose
    responder blocks on a semaphore holds the slot in a thread; a
    second `run-persona` returns `:busy` at once. Release, join.
  - `queued-run-proceeds`: max-queued 1; the second run waits, then
    completes `:end-turn` after the first is released.
  - `deadline-while-queued` (Review focus 5): max-queued 1,
    `:max-seconds 1`, real clock; the second run returns `:deadline`
    within 3 s while the first still holds the slot.
  - `daily-run-budget`: `:daily-run-budget 2`; the third run in one
    day returns `:daily-budget` without calling the responder.
  - `daily-budget-rolls-over`: after that, advance `*wall-clock*` one
    day; the next run completes.
  - `daily-token-budget`: `:daily-token-budget 50`, one run using 60
    tokens; the next run returns `:daily-budget`.
  Each test calls `reset-persona-state` first; threads are always
  joined in an `unwind-protect`.
- [ ] **Step 2: Run.** TEST(cl-llm/harness): the new tests fail.
- [ ] **Step 3: Implement** `harness/state.lisp`, and wire it into
  `run-persona`.
- [ ] **Step 4: Run.** TEST(cl-llm/harness): `Fail: 0`, twice in a row
  (the thread tests must not flake).
- [ ] **Step 5: Docs:** the two budgets, the queue, and that a restart
  resets the day's counters (v1).
- [ ] **Step 6: Commit** `feat(harness): concurrency and daily budgets
  per persona (#85)`.

### Task 6: accounting as claims (`cl-llm/agent`)

**Files:**
- Modify: `cl-llm.asd` (`cl-llm/agent` gains `"cl-llm/harness"`; a new
  component), `agent/packages.lisp` (export)
- Create: `agent/accounting.lisp`, `tests-agent/accounting-tests.lisp`
- Modify: `docs/agent-harness.md` (accounting), `docs/agent-tools.md`
  (one line pointing there)

**Interfaces:**
- Consumes: `harness:run` readers; `mem:conclude`, `mem:recall`
  (`docs/agent-memory.md`).
- Produces: `(agent:record-run graph run &key (scope (list graph)))
  => list of decisions`. It records, under the run's producer, that the
  run ran as its persona, how it stopped, its input and output tokens,
  its elapsed seconds and its start. The claim family, relations and
  namespaces are the implementer's, following `docs/agent-memory.md`;
  every namespace and relation canonical.

- [ ] **Step 1: Failing test** `record-run-is-recallable`, in the
  existing two-store fixture: build a `harness:run` by running a mock
  persona to `:end-turn`; `record-run` into the working store; every
  returned decision's outcome is `:concluded`; recall over the run's
  subject, with producer `"<persona>/<host>/"` (a prefix), returns the
  persona name, the stop reason `end-turn` and the token counts.
- [ ] **Step 2: Run.** TEST(cl-llm/agent): the new test fails.
- [ ] **Step 3: Implement** `agent/accounting.lisp`.
- [ ] **Step 4: Run.** TEST(cl-llm/agent): `Fail: 0`, the existing
  agent tests included.
- [ ] **Step 5: Docs.** The accounting section, with the claims it
  writes.
- [ ] **Step 6: Commit** `feat(agent): record a harness run as claims
  (#85)`.

### Task 7: a persona run on the local model, and the example

**Files:**
- Create: `examples/agent-harness.lisp`
- Modify: `examples/README.md`, `live/live.lisp`, `cl-llm.asd`
  (`cl-llm/live` gains `"cl-llm/harness"`)

**Interfaces:**
- Consumes: everything above; `llama-provider` from Task 1.

- [ ] **Step 1: Write the live test** `live-llama-persona-run`: a
  persona built in Lisp with the llama provider, the `live-add` tool,
  `:max-seconds 600`, `:max-run-tokens 60000`, `:max-turns 4`; input
  "Use the live-add tool to add 17 and 25. Reply with just the number."
  → stop `:end-turn`, text contains `42`, one tool call named
  `live-add`, input tokens > 0.
- [ ] **Step 2: Write `examples/agent-harness.lisp`:** an offline part
  (a mock persona, a guard stopping it, the run record printed) and a
  live part in `run` (a persona file for a local llama-server model,
  loaded with `load-persona-file`, run with a tool). Catalog row in
  `examples/README.md`.
- [ ] **Step 3: Run.** LIVE: `live-llama-persona-run` passes. Load the
  example and run its offline part in a fresh image without error.
- [ ] **Step 4: Commit** `feat(harness): a persona run on a local model,
  and the example (#85)`.
- [ ] **Step 5: Close out.** Close #85 with a comment saying what met
  each of its five asks, linking the commits.
