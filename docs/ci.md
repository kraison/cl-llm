# CI

`.github/workflows/test.yml` runs the offline suites (core, rag,
claims) on every push to `main` and on pull requests, on the ma-dev
self-hosted runner (per-repo runner, `gh-runner-cl-llm.service`
under the sitrep user).  The claims suite needs graph-db/spacetime,
resolved from the host's `~/src` pins; the tested cl-llm tree is the
pushed tree (quicklisp `local-projects` is neutralised).  Verdicts
land in sitrep's mirror via the checks leg (kraison/sitrep#42).
