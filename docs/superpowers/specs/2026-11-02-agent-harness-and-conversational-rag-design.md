# Agent harness and conversational RAG (design)

kraison/cl-llm#85, widened by Kevin on 2026-11-01/02 to carry a
conversational knowledge-base chat as its first consumer. Agreed in a
brainstorm with Kevin; this document is the builder's brief.

Marking used below: **(Kevin)** is a decision Kevin made in the
brainstorm. **(builder's call, made)** is a choice the designer made
and Kevin can overturn while reading. **(left to the builder)** is
open.

## 1. Why

Two outcomes, both Kevin's:

1. **Lisp drives a local model.** Qwen 3.8 Flash-Next (UD-IQ4_XS) runs
   in llama-server on thoth. A Lisp image should run a bounded,
   accounted model run against it, the harness #85 describes.
2. **mine-action's KB chat becomes conversational.** Today every
   question stands alone: `kb-ask` builds a throwaway conversation,
   and `web/chat.js` sends only the current question. Kevin's example:
   he asks about the PFM-1, then asks "how is it armed?", and the chat
   does not know "it" is the PFM-1. **Follow-ups are the first
   priority (Kevin).**

Kevin also wants, later and as their own units (§10): the chat knowing
AMAV itself (its SOPs, practices, history; "our SOPs" should find
AMAV's SOPs, not IMAS's), and querying the hub's vivace-graph data
conversationally.

**Build as much as possible as generic cl-llm functionality, not
mine-action-specific tooling (Kevin).** mine-action supplies its
retrieval, persona and storage location; everything else is cl-llm.

## 2. Goals

1. A local llama-server model driven from the REPL through cl-llm's
   existing API: `ask`, `send`, tools and streaming, with a live test.
2. #85 as written: personas as data, `run-persona` returning a `run`
   record, the guards (wall clock, token budget, concurrency, daily
   budget), attribution, and accounting as claims.
3. Follow-up questions that work: the follow-up is rewritten into a
   standalone question before retrieval.
4. Conversations tied to a user, kept, resumable from any device
   **(Kevin)**. "New conversation" starts fresh and **keeps the old one
   to look back at (Kevin)**.
5. **Compaction (Kevin):** long conversations stay within what the
   model can read, without losing the saved record.
6. A different model per step (rewrite, answer, compaction), each
   swappable by configuration. Production's chat model,
   gpt-oss:120b-cloud, is sometimes flaky and **Kevin is not wedded to
   it**.
7. **Tested end to end on thoth-dev with Qwen as the chat model
   (Kevin).**

## 3. Non-goals

- A scheduler or message transport for personas. The caller provides
  the event (#85, "Not asked").
- AMAV awareness and graph lookups (§10).
- Interrupting a running tool body (§6.4).
- Changing production's chat model. That is a config change Kevin
  makes when he chooses.

## 4. Anti-goals

- **A follow-up answered about the wrong thing.** Mixing up two mines
  is the failure that hurts. The rewritten question is shown to the
  reader (§8.3) so a wrong rewrite is visible.
- **A half-finished turn saved as if complete.** A turn that fails or
  is stopped by a guard leaves the stored conversation as it was.
- **Compaction that loses the record.** Only what the model reads is
  condensed; the stored turns stay verbatim.
- **A guard that is advisory.** Every bound is fixed by the operator
  at construction; the model chooses arguments only (the rule
  `docs/agent-tools.md` already states).
- **cl-llm's core gaining threads.** The core stays thread-free, as
  the README promises for ECL and Clozure; anything needing a lock
  lives in a separate system.

## 5. Constraints

- **cl-llm's layering.** `cl-llm` depends on dexador, jzon and uiop
  only. `cl-llm/rag` adds cl-temporal-extent. `cl-llm/memory` and
  `cl-llm/agent` bring vivace-graph. Nothing generic may make
  `cl-llm/rag` depend on vivace-graph.
- **The existing tool loop** (`src/tool-loop.lisp`,
  `run-tool-loop`) has no hook between turns. `send` restores the
  conversation's messages when the loop exits non-locally; keep that.
- **mine-action's grounding rules** (`src/knowledge-answer.lisp`):
  the persona is composed WITH `cl-llm.rag:*grounding-instructions*`,
  never replacing it; temperature and max-tokens are passed
  explicitly; empty-because-truncated answers signal (#103); output
  goes through `%fold-llm-homoglyphs` (#105); `kb-retrieve-gated`
  applies the designation and supersession gates. The gates key on a
  designation (e.g. "PFM-1") appearing in the query.
- **mine-action's graphs.** The hub holds separate graph-db graphs
  (ops, knowledge, forensics). Reading a node under the wrong ambient
  `graph-db:*graph*` SEGVs the heap (mine-action `CLAUDE.md`, #130).
  `open-forensics-graph` (`src/forensics-graph.lisp`) is the pattern
  for opening a further graph without disturbing `*graph*`.
- **mine-action's user identity** is `%current-user` in
  `src/rest.lisp`, from the session cookie.
- **A mutating POST must join `*editor-post-paths*`** or a viewer can
  call it (mine-action's auth-gate tripwire). Saving one's own
  conversation is not an editor action, so the builder decides which
  gate applies and states it; the tripwire test must still pass.
- **Disclosure.** Production's chat model runs in Ollama's cloud, so
  today the question and its sources leave the host. With history,
  earlier questions, answers and summaries leave too, every turn. For
  KB questions this is accepted; it must be restated when graph
  lookups arrive (§10).
- **thoth's llama-server.** `infra/hosts/thoth/llama/serve-qwen.sh`:
  alias `qwen3.8-flash-next`, `127.0.0.1:8080`, OpenAI-compatible,
  bearer key from `~/.config/local-agent/thoth.key`, 131072-token
  context, `--reasoning-budget 8192`, unloads after 15 idle minutes.
  A cold first reply takes about 2 minutes (load plus prompt), so
  cl-llm's 60 s `*timeout*` must be raised for a cold call. Generation
  is about 24 tokens/s. The model is hybrid: llama-server resumes a
  prompt only from a saved checkpoint, so a request whose prefix
  changes early is re-evaluated in full (infra#141). Keep the system
  prompt and early history stable between turns.
- **thoth-dev.** A Lima VM on thoth running the hub on
  `127.0.0.1:9100`. From the VM, `host.lima.internal:8080` is thoth's
  llama-server, allowed by the VM's egress firewall. llama-server's
  key is installed in the VM's `/data0/thoth-dev-secrets/
  llama-server.key` by infra's `bin/install-thoth-dev-secrets`. The
  hub's config is `docker/ma-dev/config.ini` in mine-action.
- **mine-action's UI work.** A page-by-page redesign is under way
  (mine-action#416). Stage the chat page's changes as a mockup driven
  in a browser before building, and keep every existing function of
  the page: sources with their MT and supersession badges, figures,
  and "Save to eval".
- Kevin's Lisp rules: spaces only, 80 columns, terse comments that
  point to docs. Docs travel with every source change.

## 6. Unit 2: the harness (`cl-llm/harness`, #85)

### 6.1 Where it lives (builder's call, made)

A new system `cl-llm/harness` depending on `cl-llm` and
`bordeaux-threads` (for the concurrency limit). It holds personas,
`run-persona`, the run record and the guards. Accounting as claims
(§6.6) needs the memory store, so it lives in `cl-llm/agent`, which
depends on `cl-llm/harness`. This keeps `cl-llm/rag`'s conversational
piece (§8) free of vivace-graph while still running under the
harness.

### 6.2 Personas as data

A persona names:

- `name`, a canonical `[a-z0-9-]` string;
- a system prompt;
- tools, by name, resolved at run time against the deftool registry
  and against tool lists the caller passes (for example a subset of
  `agent:make-agent-tools`);
- a provider description (kind, base URL, model, and the *path* of an
  API-key file, never the key);
- generation parameters (temperature, max-tokens);
- budgets: max tool turns, tokens per run, wall-clock seconds per run,
  concurrent runs and queue length, tokens and runs per UTC day.

Loadable from a file and from a store. File format (left to the
builder), with one rule: reading a persona file never evaluates code
(`*read-eval*` off, values validated after reading, or JSON through
jzon). A persona can also be built in Lisp with a constructor, for
tests and for consumers like mine-action.

### 6.3 `run-persona`

```lisp
(run-persona persona input &key conversation producer tools)
;; => a RUN
```

- Without `conversation`, one fresh conversation (#85 as written).
  With one, the input is appended to it and the run continues it; the
  rollback rule of `send` applies, so a failed or stopped run leaves
  the conversation as it was **(widened from #85, Kevin's
  conversations)**.
- The `run` records: a run id, the persona's name, the producer, the
  input, started and finished instants, turns used, input and output
  tokens summed over every model call, the stop reason, any error,
  the final text, and every tool call with its result.
- Stop reasons: the model's own (`:end-turn`, `:max-tokens`,
  `:stop`), and the harness's (`:max-turns`, `:deadline`,
  `:token-budget`, `:daily-budget`, `:busy`, `:error`). A guard stop
  is a returned run with that stop reason, not a signalled condition
  **(builder's call, made)**: a resident process handles a run, it
  does not unwind from one.

### 6.4 Guards

- **Wall clock.** A deadline at start plus the persona's seconds,
  checked before every model call and every tool call. Each HTTP
  request's timeout is the smaller of `*timeout*` and the time left. A
  tool body is never interrupted **(builder's call, made)**: a thread
  interrupt inside a graph-db transaction is how a store gets
  corrupted. Tool authors can read the time left from the harness. The
  trap, documented: a slow tool overruns the deadline by its own
  duration.
- **Token budget per run.** Usage is summed after every response;
  when the sum reaches the budget, the run stops before the next call.
  Whether the next call's max-tokens is also clamped to what remains
  is left to the builder.
- **Concurrency per persona.** At most N runs at once and Q waiting;
  a run beyond that returns at once with `:busy`. In-image state.
- **Daily budget per persona.** Tokens and runs per UTC day,
  in-image counters. A restart resets them; v1 accepts that and says
  so in the docs. When accounting claims are recorded (§6.6), the
  counters may be seeded from them at start (left to the builder).

**The hook.** Rather than copying the tool loop, the builder adds a
per-turn hook to core's `run-tool-loop` and `send` (called before
each model call and after each response) through which the harness
checks its guards and stops the loop. The plain `ask` and `send`
behave exactly as now when no hook is given.

### 6.5 Attribution

The producer is `<persona>/<host>/<run-id>`, canonical
`[a-z0-9-/]`. This is already a supported shape: the memory store's
recall treats a producer ending in `/` as a prefix, so
`kb-chat/thoth/` answers for every run on thoth (#82). Each run is its
own belief series, and a later run's write outdates an earlier run's
open belief through the other-producers rule in `memory/write.lisp`.
The run id is canonical and unique within the host.

### 6.6 Accounting as claims (optional, `cl-llm/agent`)

`record-run` writes the run into a memory store as claims about the
persona: what ran, on what input, for how many tokens and how long,
and how it stopped. The claim family and relations are left to the
builder, following `docs/agent-memory.md`.

## 7. Unit 3: conversations (`cl-llm` core, plus a vivace store)

### 7.1 Conversations as data

Core cl-llm gains a round trip between a `conversation` and plain
data: messages with their parts (text, tool use, tool result), the
system prompt, parameters and model, but not the provider object. A
stored conversation also carries metadata the core does not interpret:
an id, an owner, a title, created and updated instants, and a
per-turn annotation slot (§8 puts the rewritten query and the sources
there).

### 7.2 The store interface (builder's call, made)

A small protocol: create, load, save, list a user's conversations
(newest first, with title and dates), and mark one current. "New
conversation" makes a fresh one current; the old one stays, readable
and resumable **(Kevin: keep it)**. Nothing is deleted by the reset.

Two implementations:

- **A file store** in core cl-llm, one JSON file per conversation
  under a directory, for scripts and tests.
- **A vivace-graph store** in a new system
  `cl-llm/conversation/vivace`, depending on `cl-llm` and
  `graph-db/core` only. It borrows a caller-owned graph, as
  `cl-llm/rag/vivace`'s stores do, and binds `graph-db:*graph*`
  around every operation, restoring the caller's.

### 7.3 Compaction (Kevin)

When the history the model would read passes a token budget, the
oldest turns are condensed into a running summary that is sent in
their place, and the most recent turns are sent in full. The summary
is made by the compaction model (§8.1) and stored with the
conversation, along with which turns it covers, so it is made once,
not every turn. The stored turns stay verbatim. Token counting is an
estimate (characters per token) unless the provider reports counts;
the builder states which. To keep llama-server's prompt cache useful,
compaction happens in steps (a block of turns at a time), not every
turn.

## 8. Unit 4: conversational RAG (`cl-llm/rag`)

### 8.1 One model per step (Kevin)

The conversational piece takes three providers: rewrite, answer,
compaction. Each defaults to the answer provider. The rewrite is a
small task, so a deployment can run it on a small local model and keep
it off the cloud.

### 8.2 A turn

1. **Rewrite.** If there is earlier history, the rewrite model turns
   the new question into a standalone one using the recent turns
   ("how is it armed?" becomes "How is the PFM-1 armed?"). The first
   question is used as asked. If the rewrite fails, the turn fails;
   it does not fall back to the raw question silently.
2. **Retrieve.** A caller-supplied function from the standalone
   question and K to hits. mine-action passes its gated retrieval.
3. **Carry forward.** The passages earlier turns used stay available:
   the turn's context is the new hits plus the previous turn's hits,
   de-duplicated, numbered once **(builder's call, made)**. How many
   turns back to carry is left to the builder, within the token
   budget.
4. **Answer.** The answer model sees the system prompt (the caller's
   persona composed with `*grounding-instructions*`), the compacted
   history, the numbered sources and the question as asked. It runs
   through `run-persona`, so the turn gets the harness's guards and a
   run record.
5. **Record.** The turn is appended to the stored conversation with
   its annotation: the standalone question, the sources' identities,
   and the run's tokens and timing. Only a completed turn is saved.

The result returns the answer text, the hits, the standalone question
and the run, so a caller can show each.

### 8.3 What the reader sees (builder's call, made)

The standalone question is returned with every answer so a UI can
show "Searched for: how is the PFM-1 armed?". mine-action shows it.

## 9. Units 1 and 5

### 9.1 Unit 1: Qwen from Lisp

- An example under `examples/` and a live test in `cl-llm/live`,
  opt-in like the existing ones, that build an
  `openai-compatible-provider` for `http://127.0.0.1:8080/v1`, model
  `qwen3.8-flash-next`, key read from the key file, and exercise
  `ask`, a two-turn `send`, one tool call and streaming.
- The server is started as infra starts it (`serve-qwen.sh`, or the
  thoth local-agent wrapper that starts it when nothing answers on
  :8080). cl-llm does not start servers.
- Check, and fix in cl-llm if needed: that llama-server's separate
  reasoning output does not leak into the answer text, that an answer
  is not empty because reasoning used the token budget (raise
  max-tokens for this model), and that tool calls parse.
- Finally, one persona run on Qwen under the harness once Unit 2
  lands.

### 9.2 Unit 5: mine-action's KB chat

- **A conversations graph of its own (Kevin: separate from ops),**
  opened alongside the knowledge and forensics graphs, following
  `open-forensics-graph`'s pattern, holding the
  `cl-llm/conversation/vivace` store. Name, directory key in
  `config.ini` and `config.ini.example`, and open order are the
  builder's; a new key gets a Deploy-notes entry in `CHANGELOG.md`.
- **Endpoints** for: ask within a conversation, list my
  conversations, open one, start a new one. Each acts only on the
  current user's conversations (`%current-user`); another user's id
  is refused as not found.
- **`kb-ask`'s rules carry over** to the conversational turn
  unchanged: gated retrieval, persona composed with the grounding
  instructions, explicit temperature and max-tokens, the
  truncation signal, homoglyph folding, and the `/api/kb/ask`
  response shape (answer, context, sources) plus the standalone
  question and the conversation id. The existing `/api/kb/ask` stays
  for the eval tooling.
- **Config:** the rewrite and compaction models get their own keys,
  defaulting to the chat model.
- **The page:** a "New conversation" button, a list of past
  conversations to open, "Searched for" under each answer, and every
  existing function kept (§5). Mockup first, driven in a browser,
  before building.
- **The test:** on thoth-dev, with the hub's chat provider pointed at
  `http://host.lima.internal:8080/v1`, model `qwen3.8-flash-next`,
  key from the VM's secrets. The PFM-1 exchange from §1 is the
  acceptance case: the follow-up's "Searched for" names the PFM-1,
  its sources are about the PFM-1, and reopening the conversation
  after a reload shows both turns.

## 10. Later units, not designed here

- **AMAV awareness.** A standing organisation brief the model always
  carries, and issuer metadata on KB documents so "our SOPs" can be
  filtered to AMAV's own. The registry records language, translation
  and format today, but not who issued a document.
- **Graph lookups.** Read-only, operator-bounded tools over the hub's
  graphs, run under the harness. NMAC landowner details and
  licence-restricted zone polygons must be unreachable by
  construction. The disclosure note in §5 must be revisited first.

## 11. Order and tracking

1. Qwen from Lisp (§9.1), first, because it is the test bed.
2. The harness (§6).
3. Conversations and compaction (§7).
4. Conversational RAG (§8).
5. mine-action's KB chat (§9.2).

Units 1-4 are cl-llm work on the `harness-85` branch, one commit per
task. Unit 5 is mine-action work on its own branch. The work spans two
repos and several sessions, so it gets a project board and a tracker
issue, with #85 and the new issues as sub-issues.

## 12. Acceptance

- Each cl-llm unit's offline suite passes, with new tests that fail
  when the behaviour they cover is removed. The mock provider drives
  the harness and conversational tests; the live tests run against
  Qwen.
- Unit 5: mine-action's suite passes, the auth-gate tripwire
  included, and the PFM-1 exchange works on thoth-dev as §9.2 states.
