# Agent skills

A **skill** is a markdown file an agent runtime loads when its
description matches the task at hand. It is how you tell an agent
*when* to reach for the memory and *how* to use it well — neither of
which the MCP tool schemas can express on their own.

This matters more than it first appears. The tools in
`docs/agent-tools.md` are reached over MCP, in another process, and
nothing about them enters a model's context automatically. Many
runtimes defer MCP tools behind a search, so a model may not even see
them listed. Left alone, an agent with the memory configured will
mostly not use it — not from unwillingness, but because nothing points
at it. A skill is the pointer.

## `graph-memory/`

Covers reading (`recall` vs `retrieve` vs `trace`), the standings and
what each claims about how you know, evidence and cites, supersession
versus retraction, and the mistakes that actually bite — a JSON `null`
for an optional argument being refused rather than defaulted, a
reconstructed cite resolving nowhere, an inconsistent namespace making
`recall` silently miss what an earlier session wrote.

Every behavioural claim in it was exercised against a running server
before it was written down.

## Installing

The format is shared across runtimes; the directory differs.

| Runtime | Path |
|---|---|
| Claude Code | `~/.claude/skills/graph-memory/` |
| Hermes | `~/.hermes/skills/<category>/graph-memory/` |
| Cross-runtime alias | `~/.agents/skills/graph-memory/` |

```sh
cp -r examples/skills/graph-memory ~/.claude/skills/
```

Then configure the MCP server itself — `docs/agent-memory.md`, "The
memory as an MCP server". The skill assumes the tools are reachable; it
does not configure them.

## Adapting it

Two things are worth changing for your own deployment:

- **Namespace conventions.** The skill suggests `person`, `project`,
  `repo`, `service`, `decision`. Namespaces are minted on demand with no
  registry, so consistency is the whole game — if your domain has its
  own vocabulary, name it here, and an agent will reuse it instead of
  inventing near-synonyms a later `recall` will miss.
- **The write threshold.** "Write when a fact is established, not merely
  mentioned" is deliberately conservative, because a store full of
  conversational noise is the token-heavy file the graph exists to
  replace. Loosen it if you want a fuller record, but do it knowingly.
