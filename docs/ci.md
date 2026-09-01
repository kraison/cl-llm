# CI

`.github/workflows/test.yml` runs the offline suites (core, rag,
claims) on every push to `main` and on pull requests, on the ma-dev
self-hosted runner (per-repo runner, `gh-runner-cl-llm.service`
under the sitrep user).  The claims suite needs graph-db/spacetime,
refreshed each run to vivace-graph EXPERIMENT head (plus
cl-temporal-extent master) in `~/ci-deps-cl-llm` -- its own dir,
because the mine-action runner shares this user and concurrent
refreshes of one checkout would race.  Decided 2026-09-01: the
earlier host-pin floor failed against tests needing same-day engine
work.  The tested cl-llm tree is the pushed tree (quicklisp
`local-projects` is neutralised).  Verdicts
land in sitrep's mirror via the checks leg (kraison/sitrep#42).
