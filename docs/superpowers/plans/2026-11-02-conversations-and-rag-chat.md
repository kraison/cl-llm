# Conversations and the conversational retrieval turn: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conversations kept as data in a store, compacted for the model
(#89), and a RAG turn that understands follow-ups by rewriting them into
standalone questions (#90).

**Architecture:** Core `cl-llm` gains a `stored-conversation` (a
conversation plus id, owner, title, times, a running summary and one
annotation per turn), its JSON form, a store protocol with a file
store, and compaction driven by a caller's summarise function. A new
system `cl-llm/conversation/vivace` stores conversations in a
caller-owned graph-db graph. A new system `cl-llm/rag/chat`
(`cl-llm/rag` + `cl-llm/harness`) runs a turn: rewrite, retrieve,
answer, each model call a harness run.

**Tech stack:** SBCL, ASDF, FiveAM, jzon (via `cl-llm.json`),
graph-db/core (vivace-graph `experiment`), bordeaux-threads (through
`cl-llm/harness` only).

**Spec:** `docs/superpowers/specs/2026-11-02-agent-harness-and-conversational-rag-design.md`
(§7 and §8; §8.2 step 3 carries the owner's 2026-11-02 answers).

**Branch:** `conversations-89-90`, stacked on `harness-85`, so the
review of `harness-85` stays stable. The plan for the harness put all
four units on one branch; this splits them (executor's call).

## Global constraints

- Lisp: spaces only; a hard 80-column limit in code, comments,
  docstrings and strings; terse comments that point to `docs/`, the
  spec or an issue.
- Core `cl-llm` stays thread-free and keeps its dependencies (dexador,
  jzon, uiop). `cl-llm/rag` gains no dependency: the turn lives in
  `cl-llm/rag/chat`. `cl-llm/conversation/vivace` depends on `cl-llm`
  and `graph-db/core` only.
- Reading stored JSON never interns symbols from it, except the four
  known parameter keys (`:temperature :max-tokens :top-p :stop`).
- Conversation ids are canonical `[a-z0-9-]+` (they become file names
  and index keys).
- The stored record keeps every turn verbatim; compaction changes only
  what a model reads.
- Only a completed turn is stored. A failed or stopped turn leaves the
  stored conversation exactly as it was.
- The answer model never sees an earlier answer under the default
  history `:questions` (owner, 2026-11-02).
- Public repository: nothing domain-specific to any consumer in code,
  tests, docs or commit messages; no host names or private paths.
- Every task that changes source also changes docs: `README.md`,
  `examples/README.md`, `docs/conversations.md` (new) or the spec.
- **TEST(system):** in a fresh image against this worktree, with
  vivace-graph `experiment` first on the registry (cl-llm/memory needs
  its `reset-vector-segment`; a local checkout may be behind):

  ```sh
  sbcl --non-interactive \
    --eval '(push #p"<vivace-graph experiment checkout>/" asdf:*central-registry*)' \
    --eval '(push #p"<worktree>/" asdf:*central-registry*)' \
    --eval '(format t "~&SRC ~a~%" (asdf:system-source-directory "cl-llm"))' \
    --eval '(ql:quickload :SYSTEM/tests :silent t)' \
    --eval '(asdf:test-system :SYSTEM)' 2>&1 | tail -25
  ```

  Passing: `SRC` names the worktree and the summary says `Fail: 0`.
  SYSTEM is `cl-llm`, `cl-llm/conversation/vivace` or `cl-llm/rag/chat`.
  After any ablation, delete the ablated file's FASL on restore.
- **LIVE:** as in the harness plan: `CL_LLM_LIVE=1` plus
  `CL_LLM_LLAMA_BASE_URL`, `CL_LLM_LLAMA_MODEL`,
  `CL_LLM_LLAMA_KEY_FILE`; a llama-server already running.

## Review focus

1. **Another owner's id:** `load-conversation` with `:owner` returns
   NIL for a conversation someone else owns, so a consumer can answer
   "not found". Test in Task 2.
2. **Non-ASCII text** (Cyrillic, typographic quotes, emoji) survives
   the JSON round trip and both stores byte for byte. Tests in Tasks 1
   and 4.
3. **The first question of a conversation** is used as asked: the
   rewrite model is never called. Test in Task 5.
4. **One turn larger than the whole budget:** compaction never folds
   the kept recent turns, never loops, and returns. Test in Task 3.
5. **Retrieval returns nothing:** the answer still runs, with an empty
   sources block, and the turn completes. Test in Task 5.

---

### Task 1: stored conversations and their JSON (core)

**Files:**
- Create: `src/stored-conversation.lisp`
- Modify: `cl-llm.asd` (after `"mock"`), `src/packages.lisp` (exports)
- Create: `tests/stored-conversation.lisp`; modify `cl-llm.asd`'s
  `cl-llm/tests` components
- Create: `docs/conversations.md` (the data section); `README.md` (one
  line linking it)

**Interfaces:**
- Produces, in `cl-llm` (exported):
  - Class `stored-conversation`, accessors
    `stored-conversation-id`, `-owner`, `-title`, `-created`,
    `-updated` (universal times), `-conversation` (an
    `llm:conversation`), `-summary` (string or NIL), `-summarized`
    (count of leading messages the summary covers, default 0),
    `-turns` (list, oldest first, of annotation hash-tables, `equal`
    test, string keys), `-current-p`.
  - `(make-stored-conversation &key owner title system parameters
    model id) => stored-conversation`: a fresh, empty conversation;
    ID defaults to `(make-conversation-id)`; CREATED = UPDATED = now.
  - `(make-conversation-id) => string`: `c-<base36 time>-<base36
    counter>-<base36 salt>`, lowercase, from a random state made fresh
    per image (`(make-random-state t)`).
  - `(stored-conversation-to-json sc) => string`;
    `(stored-conversation-from-json string) => stored-conversation`.
    The JSON object: `version` 1, `id`, `owner`, `title`, `created`,
    `updated`, `current`, `system`, `model`, `parameters` (object),
    `summary`, `summarized`, `messages` (array of `{role, content}`,
    content an array of parts: `{type:"text", text}`,
    `{type:"tool-use", id, name, arguments}`, `{type:"tool-result",
    "tool-use-id", content, error}`), `turns` (array of objects).
    Unknown top-level keys are ignored on read; a missing optional key
    reads as its default. The provider is never stored.
  - `(record-turn sc question answer &optional annotation) => sc`:
    append a user message QUESTION and an assistant message ANSWER to
    the conversation, push ANNOTATION (a hash-table, default empty)
    onto the turns, set UPDATED.

- [ ] **Step 1: Failing tests** in `tests/stored-conversation.lisp`:
  - `conversation-id-canonical-and-distinct`: 1000 ids match
    `^[a-z0-9-]+$`, start with `c-`, all distinct.
  - `stored-conversation-json-round-trip`: a conversation with system
    `"Be terse."`, parameters `(:temperature 0.2 :max-tokens 100)`,
    model `"m"`, a user text message, an assistant message with a text
    part and a tool-use part (`id "t1"`, name `"add"`, arguments
    `{"a":1,"b":2}`), a user tool-result message (`"3"`, error NIL),
    summary `"S"`, summarized 2, current T and one turn annotation
    `{"standalone":"x"}` → after to-json/from-json every field above is
    equal, part types and order preserved, `(gethash "a" arguments)`
    is 1, and the annotation's `"standalone"` is `"x"`.
  - `stored-conversation-non-ascii` (Review focus 2): a user message
    `"Що таке ПФМ-1? «тест» 🙂"` round-trips `string=`.
  - `stored-conversation-unknown-keys-ignored`: JSON with an extra
    top-level `"future":1` and no `"summary"` key reads; summary NIL.
  - `record-turn-appends-pair`: after `record-turn sc "q" "a" ann`,
    the conversation has two more messages (user `"q"`, assistant
    `"a"`), turns has one more entry EQ to ANN, UPDATED ≥ CREATED.
- [ ] **Step 2: Run.** TEST(cl-llm): the new tests fail (undefined).
- [ ] **Step 3: Implement** `src/stored-conversation.lisp`.
- [ ] **Step 4: Run.** TEST(cl-llm): `Fail: 0`.
- [ ] **Step 5: Docs:** `docs/conversations.md`: what a stored
  conversation holds, the JSON shape, what is never stored.
- [ ] **Step 6: Commit** `feat(conversation): stored conversations
  and their JSON (#89)`.

### Task 2: the store protocol and a file store (core)

**Files:**
- Create: `src/conversation-store.lisp`, `tests/conversation-store.lisp`
- Modify: `cl-llm.asd`, `src/packages.lisp`, `docs/conversations.md`

**Interfaces:**
- Consumes: Task 1.
- Produces (exported generic functions; STORE is any store object):
  - `(new-conversation store owner &key title system parameters
    model) => sc`: create, save, and make it the owner's current one;
    the previous current one stays, no longer current.
  - `(load-conversation store id &key owner) => sc or NIL`: NIL when
    absent, or when OWNER is given and differs.
  - `(save-conversation store sc) => sc`.
  - `(list-conversations store owner) => list of sc`, newest UPDATED
    first.
  - `(current-conversation store owner) => sc or NIL`.
  - `(make-conversation-current store sc) => sc`: SC current, every
    other conversation of its owner not.
  - `(make-file-conversation-store directory) =>
    file-conversation-store`: one `<id>.json` per conversation.
    Listing reads every `*.json` in the directory; a file that does not
    parse is skipped with a `warning`, never an error.

- [ ] **Step 1: Failing tests,** each on a scratch directory:
  - `file-store-new-is-current`: `new-conversation` twice for
    `"ada"` → `current-conversation` is the second; the first loads
    and is not current; `list-conversations` returns both, second
    first.
  - `file-store-load-owner-scoped` (Review focus 1): a conversation
    of `"ada"` loads by id; with `:owner "bob"` → NIL.
  - `file-store-save-persists-turns`: `record-turn` then
    `save-conversation`; a fresh store object on the same directory
    loads it with the two messages and the annotation.
  - `file-store-make-current`: three conversations, make the first
    current → exactly one of the three is current, and it is the first.
  - `file-store-skips-a-corrupt-file`: write `"not json"` to
    `x.json` beside one good conversation → `list-conversations`
    returns the good one and signals a `warning` (caught with
    `handler-bind` + `muffle-warning`, counted = 1).
  - `file-store-non-ascii` (Review focus 2): a Cyrillic title and
    message survive save and load in a fresh store object.
- [ ] **Step 2: Run.** TEST(cl-llm): the new tests fail.
- [ ] **Step 3: Implement** `src/conversation-store.lisp`. Write a
  file through a temporary name in the same directory, then rename it
  over the target, so a crash never leaves half a file (rename over
  an existing file: delete the target first on implementations that
  refuse; see the Lisp traps note on `rename-file`).
- [ ] **Step 4: Run.** TEST(cl-llm): `Fail: 0`.
- [ ] **Step 5: Docs:** the protocol and the file store.
- [ ] **Step 6: Commit** `feat(conversation): the store protocol and
  a file store (#89)`.

### Task 3: compaction (core)

**Files:**
- Create: `src/compaction.lisp`, `tests/compaction.lisp`
- Modify: `cl-llm.asd`, `src/packages.lisp`, `docs/conversations.md`

**Interfaces:**
- Consumes: Task 1.
- Produces (exported):
  - `*chars-per-token*`, default 4.
  - `(estimate-tokens messages) => integer`: the characters of every
    text and tool part, divided by `*chars-per-token*`, rounded up.
  - `(compact-conversation sc &key summarize (budget 6000)
    (keep-recent 4) (block 4)) => (values sc compacted-p)`. When the
    messages after `summarized` estimate over BUDGET, fold the oldest
    BLOCK turns that are not among the last KEEP-RECENT turns into the
    summary: call `(funcall summarize previous-summary messages)` with
    the messages being folded, store the returned string as the
    summary, advance `summarized` past them. Repeat until under budget
    or nothing foldable remains. A turn starts at a user message whose
    parts are text (tool-result user messages belong to the turn
    before them); folding never splits a turn. SUMMARIZE returning a
    non-string signals an `llm-error`.
  - `(conversation-for-model sc &key system) => llm:conversation`: a
    fresh conversation of the messages after `summarized`, with SYSTEM
    (default the stored one) followed by the summary, when there is
    one, under the line `Summary of the earlier conversation:`. Same
    parameters and model; no provider.

- [ ] **Step 1: Failing tests:**
  - `estimate-tokens-counts-text`: one message of 40 characters →
    10 with `*chars-per-token*` 4.
  - `compaction-under-budget-is-a-no-op`: two short turns, budget
    1000 → compacted-p NIL, summarize never called, summarized 0.
  - `compaction-folds-oldest-block`: six turns of ~100 characters,
    budget 60 tokens, keep-recent 2, block 2 → summarize was called,
    its second argument began with the first turn's question, the
    summary is what it returned, `summarized` points at a user text
    message, and the last two turns are still after it.
  - `compaction-keeps-recent-and-terminates` (Review focus 4): one
    turn of 10,000 characters, budget 10, keep-recent 1 → returns,
    compacted-p NIL, summarize never called.
  - `compaction-folds-tool-turns-whole`: a turn with a tool-use and a
    tool-result message, then a second turn → after folding one turn,
    `summarized` is the index of the second turn's question.
  - `conversation-for-model-carries-summary`: summary `"S"`,
    summarized 2 → the system contains `"Summary of the earlier
    conversation:"` and `"S"`, and the messages are the stored ones
    from index 2; the stored conversation is unchanged (EQUAL message
    list before and after).
- [ ] **Step 2: Run.** TEST(cl-llm): the new tests fail.
- [ ] **Step 3: Implement** `src/compaction.lisp`.
- [ ] **Step 4: Run.** TEST(cl-llm): `Fail: 0`. Ablate the
  keep-recent bound once and see
  `compaction-keeps-recent-and-terminates` fail (guard the test body
  with a timeout if the ablation can loop); restore, delete the FASL.
- [ ] **Step 5: Docs:** compaction, the estimate, where the summary
  goes, and that the record is never changed by it.
- [ ] **Step 6: Commit** `feat(conversation): compaction (#89)`.

### Task 4: a conversation store in a graph (`cl-llm/conversation/vivace`)

**Files:**
- Modify: `cl-llm.asd` (systems `cl-llm/conversation/vivace` and its
  tests)
- Create: `conversation-vivace/packages.lisp`,
  `conversation-vivace/store.lisp`
- Create: `tests-conversation-vivace/packages.lisp`, `suite.lisp`
  (graph fixture as `tests-vivace/suite.lisp` does it: a fresh
  `gdb:*system-directory*`, the small buffer pool, scratch graph
  directories deleted afterwards), `store-tests.lisp`
- Modify: `docs/conversations.md`

**Interfaces:**
- Consumes: Task 2's generic functions.
- Produces, in package `cl-llm.conversation.vivace`:
  - `(define-conversation-store graph-name)`: a macro that declares, in
    GRAPH-NAME, a vertex type `stored-conversation-vertex` with slots
    `cv-id`, `cv-owner` (strings), `cv-updated` (integer), `cv-current`
    (boolean) and `cv-json` (string: Task 1's JSON), and `def-index`es
    on `cv-id` and on `cv-owner`. Call it before the graph is opened,
    as `define-memory-store` is.
  - `(make-graph-conversation-store graph) => graph-conversation-store`
    with methods for every Task 2 generic. Every operation binds
    `graph-db:*graph*` to GRAPH and restores the caller's; writes go in
    `gdb:with-transaction`; updates use `gdb:copy` and `gdb:save`.
    Lookups use `gdb:index-lookup`, never a scan.

- [ ] **Step 1: Failing tests,** mirroring Task 2's:
  `graph-store-new-is-current`, `graph-store-load-owner-scoped`,
  `graph-store-save-persists-turns` (close and reopen the graph, then
  load), `graph-store-make-current`, `graph-store-non-ascii` (Review
  focus 2), and `graph-store-restores-ambient-graph`: with
  `gdb:*graph*` bound to a second scratch graph, every operation leaves
  it EQ to that graph afterwards.
- [ ] **Step 2: Run.** TEST(cl-llm/conversation/vivace): fails to load.
- [ ] **Step 3: Define the systems and implement.**
- [ ] **Step 4: Run.** TEST(cl-llm/conversation/vivace): `Fail: 0`.
- [ ] **Step 5: Docs:** the graph store, `define-conversation-store`
  before open, and that it borrows the caller's graph.
- [ ] **Step 6: Commit** `feat(conversation): a conversation store in
  a graph (#89)`, then close #89 with what met each item.

### Task 5: the conversational turn (`cl-llm/rag/chat`)

**Files:**
- Modify: `cl-llm.asd` (systems `cl-llm/rag/chat`, its tests)
- Create: `rag-chat/packages.lisp`, `rag-chat/turn.lisp`
- Create: `tests-rag-chat/packages.lisp`, `suite.lisp`,
  `turn-tests.lisp`
- Modify: `docs/conversations.md` (the turn), `README.md`

**Interfaces:**
- Consumes: Tasks 1-3; `harness:make-persona`, `harness:run-persona`,
  the run readers; `rag:assemble-context`, `rag:hit`, `rag:chunk`,
  `rag:*grounding-instructions*`.
- Produces, in package `cl-llm.rag.chat`:
  - `*rewrite-instructions*`: the rewrite system prompt (rewrite the
    last question as one standalone search query naming its subject;
    reply with the query only).
  - `(make-rag-chat &key answer-persona retrieve (k 5)
    (assemble #'rag:assemble-context) rewrite-persona
    compaction-persona (history :questions) carry-forward carry-filter
    (history-budget 6000) (keep-recent 4)) => rag-chat`. RETRIEVE is a
    function of (query k) returning `rag:hit`s. ASSEMBLE turns hits
    into the numbered context. REWRITE-PERSONA defaults to the answer
    persona's provider and budgets, named `<answer>-rewrite`, system
    `*rewrite-instructions*`, no tools, max-turns 1;
    COMPACTION-PERSONA likewise, `<answer>-compact`.
  - `(rag-chat-turn chat sc question &key store) => rag-turn`. Steps,
    spec §8.2: compact SC (summarize = a compaction-persona run); if
    SC has earlier turns, rewrite (a rewrite-persona run over the
    compacted history as text, questions and answers, then
    `Question: <question>`), else use QUESTION; retrieve with the
    standalone question; answer (an answer-persona run whose system is
    the persona's composed with `*grounding-instructions*`, and whose
    input is, under `:questions`, the earlier questions (as asked,
    with their standalone forms), then `SOURCES:` + the assembled
    context, then `QUESTION: <as asked>` and, when it differs,
    `STANDALONE: <rewritten>`). On success, `record-turn` with an
    annotation `{"standalone", "sources": [{"document-id","title"}],
    "run": {"id","stop","input-tokens","output-tokens"}}`, and
    `save-conversation` when STORE is given.
  - Class `rag-turn`, readers `rag-turn-answer`, `rag-turn-hits`,
    `rag-turn-standalone`, `rag-turn-stop-reason` (`:end-turn` on
    success, else the failing run's stop reason, or `:error`),
    `rag-turn-error`, `rag-turn-runs` (plist `:rewrite :answer
    :compaction`, each a `harness:run` or NIL). A turn never signals.

- [ ] **Step 1: Failing tests** with mock providers (a responder that
  records each request's system and last user text):
  - `first-turn-skips-rewrite` (Review focus 3): an empty SC → the
    rewrite provider was called 0 times; RETRIEVE received QUESTION
    exactly; the turn is recorded; stop `:end-turn`.
  - `follow-up-is-rewritten` (the spec's acceptance): SC with turn
    `"Tell me about device X"` / `"Device X is ..."`; rewrite responder
    answers `"How is device X powered?"`; question `"how is it
    powered?"` → RETRIEVE received `"How is device X powered?"`;
    `rag-turn-standalone` is that; the answer request's user text
    contains it.
  - `questions-history-hides-answers`: same SC, the earlier answer
    text `"ANSWER-ONE"` → the answer request (system and user text) does
    not contain `"ANSWER-ONE"` and does contain `"Tell me about device
    X"`.
  - `grounding-instructions-composed`: the answer request's system
    contains the persona's system and `rag:*grounding-instructions*`.
  - `empty-retrieval-still-answers` (Review focus 5): RETRIEVE returns
    NIL → the answer still runs and the turn completes.
  - `failed-rewrite-fails-turn`: the rewrite responder returns an
    empty string → stop is not `:end-turn`, RETRIEVE never called, SC
    unchanged (message count and turns EQUAL before and after).
  - `failed-answer-leaves-sc-unchanged`: the answer responder asks for
    a tool the persona does not offer → the answer run stops `:error`,
    the turn's stop is `:error`, and SC is unchanged (message count and
    turns EQUAL before and after).
  - `turn-annotation-recorded`: after a successful turn the last
    annotation's `"standalone"` is the standalone question and its
    `"sources"` has one entry per hit with the chunk's document id.
  - `turn-saves-to-store`: with a file store, the saved conversation
    reloads with the new turn.
- [ ] **Step 2: Run.** TEST(cl-llm/rag/chat): fails to load.
- [ ] **Step 3: Define the systems and implement** `rag-chat/turn.lisp`.
- [ ] **Step 4: Run.** TEST(cl-llm/rag/chat): `Fail: 0`. Ablate the
  `:questions` filter (send the earlier answers) and see
  `questions-history-hides-answers` fail; restore, delete the FASL.
- [ ] **Step 5: Docs:** the turn, its three personas, what each model
  sees, and the result.
- [ ] **Step 6: Commit** `feat(rag-chat): the conversational turn
  (#90)`.

### Task 6: history `:turns`, carry-forward, and compaction in the turn

**Files:**
- Modify: `rag-chat/turn.lisp`, `tests-rag-chat/turn-tests.lisp`,
  `docs/conversations.md`

**Interfaces:**
- Consumes: Task 5.
- Produces: no new names; `:history :turns`, `:carry-forward t` with
  `:carry-filter` (a function of (standalone-question hits) returning
  the hits to keep; default keeps none), and compaction inside the
  turn behave as below.

- [ ] **Step 1: Failing tests:**
  - `turns-history-shows-answers`: `:history :turns` → the answer
    request contains the earlier answer, via `conversation-for-model`
    (the earlier pair arrives as messages, not inside the user text).
  - `carry-forward-goes-through-the-filter`: turn 1 retrieves hit A;
    turn 2 retrieves hit B with `:carry-forward t` and a filter that
    keeps hits whose text contains `"keep"`; A's text contains
    `"keep"` → turn 2's context holds both A and B, numbered once; with
    a filter that keeps nothing → only B. Carried hits come from the
    previous turn's annotation, which then stores each source's
    `"text"` too.
  - `carry-forward-off-by-default`: the same two turns without
    `:carry-forward` → turn 2's context holds only B, and annotations
    store no `"text"`.
  - `turn-compacts-long-history`: `:history-budget` 20 and six earlier
    turns → the compaction provider was called, SC's summary is its
    reply, and the rewrite request contains the summary.
- [ ] **Step 2: Run.** TEST(cl-llm/rag/chat): the new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** TEST(cl-llm/rag/chat): `Fail: 0`; TEST(cl-llm):
  `Fail: 0`.
- [ ] **Step 5: Docs:** the two options and the compaction point.
- [ ] **Step 6: Commit** `feat(rag-chat): turns history, carry-forward
  and compaction (#90)`.

### Task 7: a follow-up on the local model, and the example

**Files:**
- Create: `examples/rag-chat.lisp`
- Modify: `examples/README.md`, `live/live.lisp`, `cl-llm.asd`
  (`cl-llm/live` gains `"cl-llm/rag/chat"`)

**Interfaces:**
- Consumes: everything above; `llama-provider` and `with-llama` in
  `cl-llm.live`.

- [ ] **Step 1: Live test** `live-llama-rag-chat-follow-up`: a
  `rag:make-index` over a mock embedder with three short documents
  (two devices, each named, and one unrelated); answer and rewrite
  personas on the llama provider; turn 1 `"Tell me about the
  Zephyr-9 pump."`, turn 2 `"How is it powered?"` → turn 2's
  standalone question contains `zephyr-9` (case-insensitive), both
  turns stop `:end-turn`, and the stored conversation has four
  messages.
- [ ] **Step 2: Example** `examples/rag-chat.lisp`: an offline part
  (mock providers and a mock embedder, two turns, the standalone
  question and the sources printed) and a live `run` against a local
  llama-server, with a file store so a rerun resumes the conversation.
  Catalog row.
- [ ] **Step 3: Run.** LIVE: the test passes. The example's offline
  part runs in a fresh image.
- [ ] **Step 4: Commit** `feat(rag-chat): a follow-up on a local model,
  and the example (#90)`, then close #90 with what met it.
