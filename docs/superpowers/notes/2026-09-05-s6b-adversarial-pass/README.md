# S6b adversarial pass over S6a (cl-llm#24), 2026-09-05

The first task under S6b, as #24's scoping decision set it: every
single-store or namespace-identity assumption S6a made that the
engine's validator does not check. Two auditors over disjoint files
(`01`, `02`), one adversarial verifier over both (`03`); the brief they
worked from is `00`. Read `03` first: its verdict table, the six
confirmed Real findings, and the three design questions they force.

Result: 6 Real, 6 Latent, 3 Documented, 1 refuted. Every Real finding
has an issue; the design questions are #24's next decision.
