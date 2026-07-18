# EOD Domain-Expert Agent — Architecture Notes

**Date:** 2026-07-17
**Status:** Discussion capture (not a spec). A reference to think against, not an
approved design.

## Vision

A Lisp-based conversational domain expert that lives inside the vivace-graph
(VG) based mine-action software — an assistant EOD technicians can talk to while
demining Ukraine. It brings together several knowledge sources the user already
has or is building:

- **An LLM for user interaction** — the conversational front end (cl-llm).
- **Graph-based field data** (vivace-graph) — the team's own operational data,
  with **IMSMA** (GICHD's Information Management System for Mine Action)
  structured records arriving soon.
- **A collection of specialist demining literature** in Russian, Ukrainian, and
  English — much of it likely outside any existing LLM's training data.
- **Open-source historical information about the war in Ukraine** — from a
  separate OSINT project the user is already building.

Users are EOD ("EOD guys") working the actual demining problem in Ukraine.

## The overriding constraint: it must be safe to be wrong

This is life-safety critical. An assistant that confidently hallucinates a
render-safe procedure, a safety distance, or a fuze characteristic can get
someone killed. The architecture must be built inside-out around three
properties:

1. **Grounding + citation.** Every substantive claim traces to a source — the
   team's literature, a standard, or field data. No ungrounded procedural
   assertions, ever.
2. **Abstention as a feature.** "I don't have a vetted source for that — consult
   X / do not proceed" must be a first-class, *rewarded* output, not a failure.
   The model refusing is correct behavior.
3. **Advisory, never authoritative.** It surfaces information; the qualified
   technician decides. It never issues a "safe to proceed."

**The corpus is the asset.** Specialist RU/UK demining literature and fresh
Ukraine OSINT are largely outside any base model's training. So the model's job
is not to *know* — it is to *retrieve, ground, and synthesize from the team's
sources*, and say so. This reframes the system from "smart chatbot" to
"librarian + analyst over your knowledge."

## The shape of the system (layered)

```
  Conversation / UX     cl-llm ask/send (multilingual, concise, source-flagged)   [HAVE]
  Orchestration         retrieve -> ground -> answer-or-abstain                     [NEW, thin]
  Tools (deftool)       graph queries · literature retrieval · OSINT lookup ·       [PATTERN HAVE]
                        ordnance-designation lookup
  Retrieval (RAG)       chunk+embed corpus; hybrid dense+sparse; cross-lingual      [DEFERRED -> build]
  Knowledge stores      vivace-graph (field + IMSMA + spatial) · literature index · [HAVE + NEW]
                        OSINT store (the other project)
  Inference             local model (Ollama) and/or cloud                           [HAVE both]
  Trust scaffolding     eval suites, groundedness scorers, red-team, human review   [HAVE eval]
```

The genuinely new work is the **retrieval layer** and the **orchestration
discipline**; the rest is assembly of pieces already built in cl-llm.

## Design forks (with leanings; all are the user's to decide)

1. **Scope of authority — the safety decision.** *Identification +
   reference-retrieval aid* (finds and returns authoritative content verbatim,
   with citation, never synthesizes a procedure) vs. a *fuller advisor* that
   generates procedural guidance. Lean: the former for the first system — it
   captures most of the value (fast ID; "what does our literature/standards say
   about X"; "what's been found near here") while structurally excluding the
   highest-lethality failure mode. Widen scope later, deliberately.

2. **Local vs. cloud inference.** Ukraine field ops raise real OPSEC /
   data-sovereignty concerns (hazard locations, unit data, IMSMA) and likely
   **intermittent connectivity** at sites — both argue for **local models on
   rugged hardware** (the Ollama path already validated). Cloud (Claude) is more
   capable but sends data out and needs connectivity. May split by tier: local
   for field, cloud for reach-back analysis in the office.

3. **Retrieval architecture — where the hard engineering is.**
   - **Multilingual is not free.** A query in English should surface relevant
     *Russian* passages → cross-lingual embeddings (bge-m3, multilingual-e5,
     nomic — all runnable locally via Ollama, keeping data in-country).
   - **Exact designations matter more than usual.** "TM-62M" vs "TM-62P",
     "9N235", fuze model numbers — pure semantic embeddings blur these →
     **hybrid retrieval** (dense embeddings + sparse keyword/BM25) so exact
     ordnance designations hit precisely.
   - **Where do vectors live?** Store embeddings as vivace-graph node properties
     and do nearest-neighbor there (unifies literature with field data in one
     store), or a dedicated ANN index. This is the "build a focused cl-llm RAG"
     piece finally getting a real requirement to design against.

4. **Deterministic pipeline vs. free agentic loop.** For a safety system, lean
   toward a *more structured* flow — always retrieve, always cite, template the
   answer with explicit uncertainty / consult flags — over free tool-calling
   that might skip retrieval and improvise. The bounded tool loop already built
   is great for graph queries; *answer synthesis* wants tighter rails.

5. **Three different retrieval problems.** Graph = relational/spatial (deftool
   queries: "ordnance types found within N km of this grid," "prior tasks at
   this site"). Literature = dense text retrieval. OSINT = temporal + geospatial
   event data. The orchestrator decides which to hit per question — and much of
   the value is *joining* them ("this looks like X; here's what our literature
   says about X, and where X has been reported in this oblast").

## Decompose ruthlessly

This is genuinely 4–5 independent subsystems (RAG index, graph tools, OSINT
integration, orchestration, a domain eval harness). The way not to drown: a
**thin first slice that proves the risky part** — and the risky part is
*trustworthy grounded retrieval over the corpus*, not the chat.

**Candidate first slice:** English-corpus literature RAG for ordnance
ID / reference Q&A, local model, with mandatory citation and a built eval set —
no graph, no OSINT, no multilingual yet. If that earns EOD techs' trust on
questions where the right answer is *known* (measured with the eval harness),
the whole idea is de-risked and there is a spine to hang graph / OSINT /
multilingual onto. If it *can't* be made reliably grounded, that's learned
cheaply before betting the graph and IMSMA integration on it.

## Open questions to resolve before designing

- **Who's the user and where?** A tech at the hazard with a tablet (offline,
  gloved, stressed, seconds matter) is a very different system than an analyst
  doing reach-back planning in an office (connected, deep, can wait). Possibly
  both, in tiers — but the field case dominates the hard constraints.
- **Where's the safety line?** How much does it *say* vs. *retrieve-and-cite*?
  That one call cascades through every other decision.
- **What's the "known-good answer" set?** For a safety domain, an
  eval/validation corpus isn't optional — and building it is also how you
  discover what the system actually needs to answer. A few dozen real questions
  with authoritative answers from the literature/standards would seed it.

## How it maps to what's already built in cl-llm

- **Conversation, tools, streaming, providers** — done (core client, merged).
- **`deftool` in-process pattern** — exactly the mechanism for VG graph queries
  running in the Lisp image (the motivating use case for that design).
- **Evaluation harness (`cl-llm/eval`)** — done; the vehicle for *proving*
  groundedness/abstention before field trust. Needs a domain eval set and
  groundedness/faithfulness scorers.
- **Local / Ollama (incl. cloud proxy)** — validated; the sovereignty/offline
  inference path.
- **Embeddings / RAG** — deferred in the core spec as an explicit non-goal
  ("likely a separate cl-llm-rag system later"). **This is its motivating use
  case.** Building it is the natural next step and the current focus.
- **Local LoRA / fine-tuning** — further out; a corpus this specialized may
  eventually justify it, but retrieval-grounding comes first.

## Immediate next step

Design and build the **embeddings / RAG addition to cl-llm** — a necessary tool
for anything in this domain. That is a new subsystem and gets its own
brainstorm → spec → plan → build cycle, designed against the demanding EOD
requirements above (multilingual cross-lingual retrieval, hybrid dense+sparse,
provenance/citation, local-first embeddings, and integration with vivace-graph).
