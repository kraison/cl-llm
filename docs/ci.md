# CI

`.github/workflows/test.yml` runs the offline suites (core, rag,
claims, memory, agent, agent/prolog, agent/mcp) once per push to
`main` and once per pull request, on the ma-dev self-hosted runner
(per-repo runner, `gh-runner-cl-llm.service` under the sitrep user).
The claims suite needs graph-db/spacetime, refreshed each run to
vivace-graph EXPERIMENT head (plus cl-temporal-extent master, cl-mcp
main and opsis main) in `~/ci-deps-cl-llm` -- its own dir, because the
mine-action runner shares this user and concurrent refreshes of one
checkout would race.  Decided 2026-09-01: the earlier host-pin floor
failed against tests needing same-day engine work.  The tested cl-llm
tree is the pushed tree (quicklisp `local-projects` is neutralised).
The agent/prolog suite's guard runs on `graph-db/query` (#44).  The
agent/mcp suite's process tests spawn the solo server
(`scripts/run-memory-mcp.sh`) as a child process that builds through
`CL_LLM_ASDF_REGISTRY`, set for the step to the four cloned trees so
the child sees the same engine and libraries the parent image loaded.
Verdicts land in sitrep's mirror via the checks leg
(kraison/sitrep#42).

A green run is only evidence for the suites whose summary lines
(`Did N checks`) appear in the job log: `asdf:test-system` on a
system with no `:in-order-to` test-op is a silent no-op, and the
claims step was exactly that from 2026-08-31 to 2026-09-01 (#26).
Read the log once when a step is added, not just the verdict.

## The hosted workflow is a manual fallback

`.github/workflows/ci.yml` (GitHub-hosted, core suite only, fresh
SBCL and Quicklisp each run) triggered on the same pushes and pull
requests until 2026-09-06, so the core suite ran twice per event.  It
now runs only on `workflow_dispatch`: use it from the Actions tab when
the self-hosted runner is down and a verdict is needed on the core
suite alone.

## The live suites are not run here

`cl-llm/live`, `cl-llm/rag/live` and `cl-llm/agent/live` hit real
endpoints and need a provider key, so none of them is in CI's suite
list; every live test skips cleanly (FiveAM's `skip`) under
`CL_LLM_LIVE` unset, which is the environment CI runs in, so the
`asdf:test-system` calls above are the whole story here. Run one by
hand, from a checkout with a key exported:

```bash
CL_LLM_LIVE=1 sbcl --eval '(asdf:test-system :cl-llm/agent/live)'
```
