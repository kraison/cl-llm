# CI

`.github/workflows/test.yml` runs the offline suites (core, rag,
claims, memory, agent, agent/prolog) on every push to `main` and on
pull requests, on the ma-dev self-hosted runner (per-repo runner,
`gh-runner-cl-llm.service` under the sitrep user).  The claims suite
needs graph-db/spacetime, refreshed each run to vivace-graph
EXPERIMENT head (plus cl-temporal-extent master) in
`~/ci-deps-cl-llm` -- its own dir, because the mine-action runner
shares this user and concurrent refreshes of one checkout would
race.  Decided 2026-09-01: the earlier host-pin floor failed against
tests needing same-day engine work.  The tested cl-llm tree is the
pushed tree (quicklisp `local-projects` is neutralised).  The
agent/prolog suite additionally quickloads `graph-db/gui` and its web
dependencies (ningle, clack, cl-json) from Quicklisp on the runner --
the guard pipeline `cl-llm/agent/prolog` runs lives there
(kraison/vivace-graph#322).  Verdicts land in sitrep's mirror via the
checks leg (kraison/sitrep#42).

A green run is only evidence for the suites whose summary lines
(`Did N checks`) appear in the job log: `asdf:test-system` on a
system with no `:in-order-to` test-op is a silent no-op, and the
claims step was exactly that from 2026-08-31 to 2026-09-01 (#26).
Read the log once when a step is added, not just the verdict.

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
