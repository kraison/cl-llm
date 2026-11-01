# Agent harness and conversational RAG (design)

kraison/cl-llm#85, widened on 2026-11-02 to carry conversations,
compaction and a conversational retrieval turn. The first consumer is
a knowledge-base chat in mine-action, whose own design (private)
covers the wiring there. This document covers only what lands in
cl-llm, which is public: nothing below depends on that application's
domain.

Marking used below: **(owner)** is a decision the repository owner
made. **(builder's call, made)** is a choice the designer made and the
owner can overturn while reading. **(left to the builder)** is open.

## 1. Why

Two outcomes:

1. **Lisp drives a local model.** A model served by llama-server on
   the same machine should be driven from the REPL through cl-llm's
   existing API, and should run a bounded, accounted model run: the
   harness #85 describes.
2. **A knowledge-base chat becomes conversational.** Today a RAG
   answer stands alone: `rag-ask`, like most callers, builds a
   throwaway conversation per question. A user who asks "tell me about
   device X" and then "how is it powered?" gets the second question
   searched cold, with nothing to say what "it" is. **Follow-ups are
   the first priority (owner).**

**As much as possible is generic cl-llm functionality (owner).** A
consumer supplies its retrieval function, its system prompt and its
storage location; the rest is here.

## 2. Goals

1. A local llama-server model driven through `ask`, `send`, tools and
   streaming, with a live test.
2. #85 as written: personas as data, `run-persona` returning a `run`
   record, the guards (wall clock, token budget, concurrency, daily
   budget), attribution, and accounting as claims.
3. Follow-up questions that work: the follow-up is rewritten into a
   standalone question before retrieval.
4. Conversations as data, kept in a store, tied to an owner,
   resumable. Starting a new conversation keeps the old one, readable
   and resumable **(owner)**.
5. **Compaction (owner):** long conversations stay within what a
   model can read, without losing the stored record.
6. A different provider per step (rewrite, answer, compaction), each
   swappable by configuration.

## 3. Non-goals

- A scheduler or message transport for personas. The caller provides
  the event (#85, "Not asked").
- Interrupting a running tool body (§6.4).
- Any consumer's UI or HTTP endpoints.

## 4. Anti-goals

- **A follow-up answered about the wrong subject.** The standalone
  question is returned with every answer (§8.3) so a consumer can show
  what was searched, and a wrong rewrite is visible.
- **An answer grounded in an earlier answer.** A grounded answer rests
  on the sources retrieved for it. History may help the model
  understand the question; it must not become a source (§8.2).
- **A half-finished turn stored as if complete.** A turn that fails
  or is stopped by a guard leaves the stored conversation as it was.
- **Compaction that loses the record.** Only what a model reads is
  condensed; stored turns stay verbatim.
- **A guard that is advisory.** Every bound is fixed by the operator
  at construction; the model chooses arguments only, as
  `docs/agent-tools.md` already states for the agent tools.
- **cl-llm's core gaining threads.** The core stays thread-free, as
  the README promises for ECL and Clozure; anything needing a lock
  lives in a separate system.

## 5. Constraints

- **Layering.** `cl-llm` depends on dexador, jzon and uiop only.
  `cl-llm/rag` adds cl-temporal-extent. `cl-llm/memory` and
  `cl-llm/agent` bring vivace-graph. Nothing here may make
  `cl-llm/rag` depend on vivace-graph.
- **The tool loop** (`src/tool-loop.lisp`, `run-tool-loop`) has no
  hook between turns. `send` restores the conversation's messages
  when the loop exits non-locally; keep that.
- **`rag-ask`'s rule:** a caller's system prompt is composed WITH
  `*grounding-instructions*`, never in place of it. The conversational
  turn keeps that rule.
- **llama-server** as the local endpoint: OpenAI-compatible, bearer
  key from a file, a large context, reasoning output separate from the
  answer. A cold first reply includes the model load and can take
  minutes, so cl-llm's 60 s `*timeout*` must be raised for a cold
  call. Some models are hybrid (recurrent layers): llama-server
  resumes a prompt only from a saved checkpoint, so a request whose
  prefix changes early is re-evaluated in full. Keep the system prompt
  and early history stable between turns.
- The owner's Lisp rules: spaces only, 80 columns, terse comments
  that point to docs. Docs travel with every source change.

## 6. Unit 2: the harness (`cl-llm/harness`, #85)

### 6.1 Where it lives (builder's call, made)

A new system `cl-llm/harness` depending on `cl-llm` and
`bordeaux-threads` (for the concurrency limit). It holds personas,
`run-persona`, the run record and the guards. Accounting as claims
(§6.6) needs the memory store, so it lives in `cl-llm/agent`, which
then depends on `cl-llm/harness`. `cl-llm/rag`'s conversational turn
(§8) runs under the harness without depending on vivace-graph; it
therefore depends on `cl-llm/harness`, or the turn lives in a small
system of its own that depends on both (left to the builder).

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

**Loading (builder's call, made).** A small lookup protocol (find a
persona by name) with a file backend in `cl-llm/harness`. #85's "or a
store" is met by the protocol: a store backend is added when a
consumer needs one, not invented ahead of one. The file format is left
to the builder, with one rule: reading a persona file never evaluates
code (`*read-eval*` off and values validated after reading, or JSON
through jzon). A persona can also be built in Lisp with a constructor.

### 6.3 `run-persona`

```lisp
(run-persona persona input &key conversation producer tools)
;; => a RUN
```

- Without `conversation`, one fresh conversation (#85 as written).
  With one, the input is appended to it and the run continues it; the
  rollback rule of `send` applies, so a failed or stopped run leaves
  the conversation as it was.
- The `run` records: a run id, the persona's name, the producer, the
  input, started and finished instants, turns used, input and output
  tokens summed over every model call, the stop reason, any error, the
  final text, and every tool call with its result.
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
  documented trap: a slow tool overruns the deadline by its own
  duration.
- **Token budget per run.** Usage is summed after every response;
  when the sum reaches the budget, the run stops before the next call.
  Whether the next call's max-tokens is also clamped to what remains
  is left to the builder.
- **Concurrency per persona.** At most N runs at once and Q waiting;
  a run beyond that returns at once with `:busy`. In-image state.
- **Daily budget per persona.** Tokens and runs per UTC day, in-image
  counters. A restart resets them; v1 accepts that and says so in the
  docs. When accounting claims are recorded (§6.6), the counters may
  be seeded from them at start (left to the builder).

**The hook.** Rather than copying the tool loop, the builder adds a
per-turn hook to core's `run-tool-loop` and `send` (called before
each model call and after each response) through which the harness
checks its guards and stops the loop. `ask` and `send` behave exactly
as now when no hook is given.

### 6.5 Attribution

The producer is `<persona>/<host>/<run-id>`, canonical
`[a-z0-9-/]`. The memory store already supports this shape: recall
treats a producer ending in `/` as a prefix, so `<persona>/<host>/`
answers for every run on that host (#82). Each run is its own belief
series, and a later run's write outdates an earlier run's open belief
through the other-producers rule in `memory/write.lisp`. The run id is
canonical and unique within the host.

### 6.6 Accounting as claims (optional, `cl-llm/agent`)

`record-run` writes a run into a memory store as claims about the
persona: what ran, on what input, for how many tokens and how long,
and how it stopped. The claim family and relations are left to the
builder, following `docs/agent-memory.md`.

## 7. Unit 3: conversations (core, plus a vivace store)

### 7.1 Conversations as data

Core cl-llm gains a round trip between a `conversation` and plain
data: messages with their parts (text, tool use, tool result), the
system prompt, parameters and model, but not the provider object. A
stored conversation also carries metadata the core does not interpret:
an id, an owner, a title, created and updated instants, and a per-turn
annotation slot (§8 puts the standalone question and the sources'
identities there).

### 7.2 The store protocol (builder's call, made)

Create, load, save, list an owner's conversations (newest first, with
title and dates), and mark one current. Starting a new conversation
makes a fresh one current; the old one stays, readable and resumable.
Nothing is deleted by starting afresh.

Two implementations:

- **A file store** in core cl-llm, one JSON file per conversation
  under a directory, for scripts and tests.
- **A vivace-graph store** in a new system
  `cl-llm/conversation/vivace`, depending on `cl-llm` and
  `graph-db/core` only. It borrows a caller-owned graph, as
  `cl-llm/rag/vivace`'s stores do, and binds `graph-db:*graph*`
  around every operation, restoring the caller's: an application that
  holds several graphs in one image must never read a node under the
  wrong one.

### 7.3 Compaction (owner)

When the history a model would read passes a token budget, the oldest
turns are condensed into a running summary sent in their place, and
the most recent turns are sent in full. The summary is made by the
compaction provider (§8.1) and stored with the conversation, with the
turns it covers, so it is made once, not every turn. Stored turns stay
verbatim. Token counts are an estimate (characters per token) unless
the provider reports them; the builder states which. Compaction
happens in steps (a block of turns at a time), not every turn, so a
server's prompt cache stays useful.

A summary condenses what was *asked and decided*; under §8.2's
grounding rule it is never a source for a grounded answer.

## 8. Unit 4: the conversational retrieval turn

### 8.1 One provider per step (owner)

The turn takes three providers: rewrite, answer, compaction. Each
defaults to the answer provider. Rewriting is a small task, so a
deployment can run it on a small local model.

### 8.2 A turn

1. **Rewrite.** With earlier history, the rewrite provider turns the
   new question into a standalone one ("how is it powered?" becomes
   "How is device X powered?"). It reads the recent turns, questions
   and answers, compacted when long: its output is only a search query,
   shown to the reader, never an answer. The first question is used as
   asked. A failed rewrite fails the turn; it never falls back to the
   raw question silently.
2. **Retrieve.** A caller-supplied function from the standalone
   question and K to hits.
3. **Answer.** The answer provider sees the system prompt (the
   caller's, composed with `*grounding-instructions*`), the numbered
   sources, the standalone question and the question as asked. What it
   sees of earlier turns is a caller option:
   - `:questions`, the default **(owner, 2026-11-02)**: earlier
     questions and their standalone forms only, so no earlier answer
     can become a source;
   - `:turns`: earlier questions and answers, compacted.

   Carrying earlier turns' sources into this turn is a second option,
   off by default **(owner, 2026-11-02)**. When on, carried hits pass
   through a caller-supplied filter against the new standalone question
   before they join the context, so a change of subject does not bring
   the old subject's passages along.

   The answer runs through `run-persona`, so the turn gets the
   harness's guards and a run record.
4. **Record.** The completed turn is appended to the stored
   conversation with its annotation: the standalone question, the
   sources' identities, and the run's tokens and timing.

### 8.3 What it returns (builder's call, made)

The answer text, the hits, the standalone question and the run, so a
consumer can show "Searched for: …" beside each answer.

## 9. Unit 1: a local model from Lisp

- An example under `examples/` and a live test in `cl-llm/live`,
  opt-in like the existing ones (an environment variable naming the
  base URL, model and key file), that build an
  `openai-compatible-provider` for a llama-server endpoint and
  exercise `ask`, a two-turn `send`, one tool call and streaming.
- cl-llm does not start servers; the example says how a llama-server
  is expected to be running.
- Check, and fix in cl-llm if needed: that llama-server's separate
  reasoning output does not leak into the answer text; that an answer
  is not empty because reasoning used the whole token budget (the
  example sets max-tokens to allow for it); that tool calls parse.
- Once Unit 2 lands, one persona run against the local model.

## 10. Order and tracking

1. A local model from Lisp (§9): first, because it is the test bed.
2. The harness (§6).
3. Conversations and compaction (§7).
4. The conversational turn (§8).

All four on the `harness-85` branch, one commit per task. mine-action's
wiring follows in that repository.

## 11. Acceptance

- Each unit's offline suite passes, with new tests that fail when the
  behaviour they cover is removed. The mock provider drives the harness
  and conversational tests.
- The live tests pass against a local llama-server model.
- The follow-up case, run through the mock provider: a second question
  using "it" is rewritten to name the first question's subject, the
  retrieval function receives the rewritten question, and under
  `:questions` the answer request contains no earlier answer text.
