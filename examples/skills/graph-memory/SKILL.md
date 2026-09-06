---
name: graph-memory
description: Use when asked why something broke, what was decided, or when a name, version or incident is unfamiliar; before answering that something does not exist, did not happen or is a false premise; and when a durable fact about a person, project, service or decision is established or corrected.
version: 1.4.0
license: MIT
metadata:
  hermes:
    tags: [memory, provenance, graph, mcp, cl-llm]
---

# Graph memory (cl-llm)

A bitemporal, cited memory served over MCP by `cl-llm/agent/mcp`. Unlike
a memory file, nothing here enters context automatically: it is read
only when a tool is called. Treat it as the durable record — what an
earlier session concluded, when it held, and what it rested on.

**Core principle: every belief carries provenance.** A stored fact has a
producer, a standing, a validity window and, when it was inferred, the
cites it rests on. Storing a bare assertion that could have carried
evidence wastes the one thing this store offers over a text file.

## Read at scan time, not mid-answer

**Query the store while forming the answer, not after drafting one.**
The triggers below are properties of the *incoming message* — a
"why did X break" question, an unfamiliar name — and are all
recognisable before any investigation starts. Read then.

A trigger phrased as an internal state ("when about to answer that
something does not exist") fires too late to help: that state is only
reached after investigating and reasoning to a conclusion, by which
point an answer is already built and the store's role degrades to
contradicting it. Worse, the investigation feels thorough — commands
ran, files were read, evidence was cited — and thoroughness in the
wrong source reads as sufficiency. Match on the question, not on the
conclusion.

In a repo, a "why did X break" question also pulls hard toward
`git log`, `grep` and the logs, because that is what a coding agent
reaches for. Those answer *what is true now*. Run them, but run the
store's read in the **same batch** — not as a fallback when they come
up empty, and not only when the user pushes back.

## A question's shape decides whether you reach for the store

**The wording of the question, not its subject, is what pulls an agent
toward the filesystem or the store.** A question naming a *date*
("why did X break on 2026-05-22") invites a calendar/git/log search
that can plausibly terminate in "nothing from that period exists" —
a confident wrong answer built entirely from local evidence. The same
question naming an *opaque identifier* ("why did incident drift-b8dc70
fail") matches nothing on disk, so querying the store is the only
sensible move.

Measured across five models on identical stored facts: date-shaped
phrasing produced 1/4 retrieval, identifier-shaped produced 4/4. The
models and the skill were unchanged; only the phrasing moved.

The lesson is not about phrasing your own queries — it is that a
date-shaped or otherwise "searchable-looking" question is exactly where
this skill's triggers are most likely to be missed, and where a local
investigation feels most sufficient. Treat a question that *invites*
grep as a reason to read the store in the same batch, not a reason to
skip it.

## Before you answer "no"

**The most expensive failure is reporting an absence you never checked.**
Before telling the user that something does not exist, did not happen,
is a false premise, or that you have no record of it — read the memory
first.

Local inspection and the memory answer different questions. `grep`,
`ls`, a version string, the source tree: these answer *what is true
now*. They hold no record of *what happened*. A past event — an
incident, a migration, a decision — leaves nothing in the filesystem
and everything in the store. Confidence built on local inspection is
misplaced exactly there, and feels strongest exactly there.

An absence claim requires having looked. This store's own vocabulary
draws the line: `searched-empty` means you looked in a nameable place
and found nothing; `uncovered` means nothing has looked. Reporting the
second as though it were the first is the error this rule exists to
prevent — in a tool result or in prose.

**A name you cannot account for is a trigger, not a dismissal.** When
the user references a specific version, incident, migration, release,
project or person you have no context for, that unfamiliarity is the
*reason to search*. A past session is the most likely place it was
recorded, and being unable to place it is what distinguishes a
question worth a lookup from one you can already answer.

## When to use

Read before answering when:

- you are about to say something does not exist or did not happen —
  the case most often missed (see above)
- the user names a version, incident, project, person or decision you
  cannot account for
- the question is about the past: "why did X break", "what happened
  with Y", "when did we decide Z" — including questions that
  *presuppose* an event rather than asking about one
- the subject is durable: a named person, project, repo, service, host
- you are asked what is known about something, why it was concluded,
  or what evidence supports it

Write when a fact is **established**, not merely mentioned:

- the user states a durable preference, ownership, or convention
- an investigation concludes something checkable
- a previous belief is superseded or found wrong
- you looked for something and it was not there (that is a *record*)

**Do NOT write:** conversational chatter, task progress, transient state,
anything re-derivable in seconds, or restatements of what is already
stored. A store full of noise is the token-heavy file you were avoiding.

## Choosing a read

| Situation | Tool |
|---|---|
| Unfamiliar name, unsure of the namespace or key | `list-taxonomy` first — it prints what the store names — then `recall` or `retrieve` |
| Known subject: namespace + key | `recall` |
| Fishing; subject uncertain; want ranked evidence | `retrieve` with the question as the query — it finds endpoints by key token |
| Have a decision id; want its reasoning and evidence | `trace` |
| Have a cite; want what rests on it | `decisions-citing` |
| Want the window/region evidence implies, without fetching | `plan-bounds` |
| Structured scan across the store | `query` (Prolog, read-only) |

`recall` is exact and ordered (newest validity first). `retrieve` is
fuzzy and ranked, and its items carry the cites you pass to `conclude`.
A `recall` miss is **not** proof of absence: it is exact on
(namespace, key), so a subject filed under a namespace you guessed
wrong reads as empty. Call `list-taxonomy` to see the namespaces and
keys the store actually holds, or `retrieve` with the question as the
query, before reporting that nothing is recorded.

`retrieve` finds its own endpoints: the query is split into tokens and
matched against every key the store holds, so "why did the ledger
freeze in May" reaches `incident:ledger-freeze-2026-05-22` with no
endpoints given. Its result lists `endpoints`, what was actually
consulted. A query that names nothing the store holds is an **error**
pointing at `list-taxonomy`, never an empty bundle — an empty
`evidence` array means "looked, found nothing".

**Namespaces are lowercase.** Every tool prints them that way,
`query` included, and an uncanonical spelling (`DECISION`) is an
error naming the string, not a silent miss.

## Standing: say how you know

| Standing | Meaning |
|---|---|
| `observed` | You saw it directly — a command's output, a file, the user stating a fact about themselves |
| `asserted` | A source claims it; you are recording the claim |
| `inferred` | You reasoned to it (default) — cite the evidence |

For absence, `conclude-absence` takes its own standing, and it is
**required**, not defaulted:

| Standing | Meaning |
|---|---|
| `searched-empty` | Looked in a nameable place; nothing there |
| `indeterminate` | Could not find out |
| `uncovered` | Nothing has looked yet |

## Writing well

Subject and object are each `namespace` + `key`, both plain strings.
Namespaces are canonical `[a-z0-9-]+` and are **minted on demand** —
there is no registry, so be consistent: reuse `person`, `project`,
`repo`, `service`, `decision` rather than inventing near-synonyms.
An uncanonical namespace reads back as empty, never an error.

`rule` names *why* you concluded, and is how a later session judges the
claim. Use a stable, meaningful name (`owner-says`, `ci-observed`,
`inferred-from-commit`), not a description of the moment.

Cite evidence whenever the belief is `inferred`. A cite is an **opaque
string**: pass back byte-for-byte what a result gave you. Do not
construct, edit or prettify one.

```
retrieve  query="who maintains vivace-graph" endpoints=["project:vivace-graph"]
   -> item with cite "cl-llm.memory::belief|...|works-on|((...))"

conclude  subject-namespace=person  subject-key=kevin
          relation=maintains
          object-namespace=project  object-key=vivace-graph
          rule=inferred-from-works-on
          standing=inferred
          evidence=["cl-llm.memory::belief|...|works-on|((...))"]
```

`decisions-citing` on that evidence cite now returns the decision, and
`trace` on its id replays the reasoning. That chain is the point.

An `observed` belief with an empty `evidence` array is a claim that you
saw something directly and can point at nothing. For a causal or
historical claim — a root cause, an outcome, what broke — that is
almost always the wrong standing. Use `asserted` when recording what a
source told you, or `inferred` with the cites you reasoned from.

## Correcting the record

- **Superseded** — a newer belief on the same **(producer, subject,
  relation)** closes the old one automatically. Just `conclude` the new
  fact; do not retract first.
- **A generic relation silently eats parallel facts.** Supersession
  keys on (producer, subject, relation) and does *not* look at the
  object. Writing three different rules about one subject under one
  broad relation — `style-rule`, `governed-by`, `has-property` — leaves
  only the last one `current`; the earlier two are closed within
  milliseconds, each `superseded-by` an unrelated fact. Nothing is
  refused and every write returns `concluded`, so a bulk load looks
  clean while most of it is already historical.

  When a subject has several coexisting facts of the same kind, give
  each its own specific relation (`indentation-rule`, `line-length-rule`,
  `comment-style-rule`), not one umbrella. Reserve a broad relation for
  a genuinely single-valued property, where a new value *should* replace
  the old.
- **Supersession is producer-scoped.** Concluding the same subject and
  relation under a *different* producer does not supersede: both
  beliefs stay `current`, each attributed to its own client. That is
  deliberate — one client must not silently overwrite another's
  testimony — but it means correcting a belief another producer wrote
  takes an explicit `retract` of its cite, then a fresh `conclude`.
  Check the producer in the cite before assuming a re-`conclude` fixed
  anything; `recall` afterwards and confirm only one record is
  `current`.
- **Wrong** — `retract` the cite. This closes its *transaction* period
  and leaves validity as recorded: the claim stays on disk and stays
  traceable. Retraction is not deletion, and only works on a belief in
  the writable store.

## Verify a bulk load, do not trust the receipts

**`outcome: "concluded"` means the write committed, not that the belief
is current.** After loading more than a handful of facts, `recall` a
subject you wrote several times and count how many come back
`current: true`. Silent supersession (above) is invisible in the write
receipts and shows up only on read.

`retrieve` is the sharper check: it returns only what a later session
would actually surface. A subject you wrote three facts about that
comes back with one is the signature of a relation collision.

`list-taxonomy` after a load is the cheapest check of all: the
namespaces, relations and key counts it prints are what actually
landed.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Reading the store only after drafting an answer from logs | The conclusion is already built; the store gets used to contradict it rather than to form it. Read at scan time |
| Waiting for the user to ask "did you check the graph?" | The prompt should never be needed; the question itself was the trigger |
| Answering "that doesn't exist" from local inspection alone | The filesystem records current state, not past events. The store may hold exactly what you just denied |
| Treating an unfamiliar name as a false premise | Unfamiliarity is the reason to search, not grounds to dismiss |
| Treating a `recall` miss as proof of absence | `recall` is exact on (namespace, key); `list-taxonomy` shows what is there, `retrieve` finds it from the question |
| Passing JSON `null` for an optional argument | Refused, not defaulted — **omit the key** instead |
| Omitting `standing` on `conclude-absence` | Missing-argument error; it is required there |
| Treating empty `records` as an absence | Empty means *nothing recorded*; an absence is a record with a standing |
| Editing or reconstructing a cite | Resolves nowhere; the write errors |
| Several coexisting facts under one broad relation | Supersession ignores the object; only the last stays `current`. Use one specific relation per fact |
| Treating `concluded` receipts as a verified load | Receipts confirm the commit, not currency. `recall` and count `current: true` |
| Putting a producer name in an object slot | `producer` is validated against `canonical-producer-p` and the write is refused; record it as `principal`/`client` instead |
| Inventing a new namespace per session | Recall silently misses what earlier sessions wrote; `list-taxonomy` shows the ones in use |
| Assuming the MCP listener serves the production store | One host can run several memory images on different ports over different store dirs. Confirm `CL_LLM_MEMORY_STORE` in the listener's environ before trusting a load or an absence |
| Writing `inferred` with no `evidence` | Loses the chain this store exists for |
| Writing `observed` for a causal claim with no evidence | Overclaims how you know; use `asserted` or `inferred` |
| Confusing Hermes's `memory` tool with this store | `memory` edits MEMORY.md and has NO read action — `action='recall'` errors with "Use: add, replace, remove". Reaching for it to *read* invites an accidental `add`, which then reads back as if it were a recorded fact |
| Retracting to "fix" an outdated fact | Use supersession — `conclude` the new value |
| Re-concluding to fix another client's belief | Supersession is producer-scoped; both stay `current`. Retract the original cite first |

## Reading results

- Absent fields are **omitted**, never `null`. `truncated` and `current`
  are always present.
- `truncated: true` means more existed past the cap — narrow the query
  or raise `k`; the caps are the operator's and you cannot exceed them.
- `current: false` with `superseded-by` names what replaced a belief.
- A refusal comes back as `outcome: "refused"` with `refusals[]` and
  writes nothing. It is a result to read, not an error to retry blindly.

## Setup

Tools appear as `recall`, `trace`, `decisions-citing`, `conclude`,
`conclude-absence`, `retract`, `list-taxonomy`, `retrieve`,
`plan-bounds`, and `query` (when enabled). Two deployments:

- **Solo** — the client spawns `scripts/run-memory-mcp.sh`; one process
  per session. A graph-db store has exactly one holder, so a second
  client is refused.
- **Listener** — one memory image holds the store and serves many
  clients over loopback through `scripts/memory-mcp-client.lisp`. Use
  this when more than one agent (say a CLI session and a background
  gateway) shares one memory. Distinct principals give each client its
  own producer, so authorship stays distinguishable.

See `docs/agent-memory.md` and `docs/agent-tools.md` in cl-llm.
