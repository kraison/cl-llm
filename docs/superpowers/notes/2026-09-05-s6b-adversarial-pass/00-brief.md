# S6b adversarial pass over S6a — audit brief (cl-llm#24)

**Question.** S6a (cl-llm#14 units 1–3: `cl-llm/memory`, `cl-llm/agent`,
`cl-llm/rag/claims`) was built and proven against ONE store. #24's scoping
decision (2026-08-31) accepted the risk that it "may quietly assume it" and
made the first S6b task an adversarial pass for exactly that: every
namespace-identity or single-store assumption the code makes that the
engine's validator does not check.

**Vocabulary (engine, `~/work/vivace-graph-v3/docs/superpowers/specs/2026-08-20-namespaces-design.md`).**
A *store* is the transaction domain (one graph, one WAL); a *namespace* is a
Lisp package; a cl-llm *subject namespace* is a topic keyword inside a
belief's identity. "Cross-namespace" in #24 means across STORES: a scope of
several open stores, reads spanning them, one writable.

**Engine facts that bear (verified this week, kraison/vivace-graph#332):**
- A read-write transaction on store A refuses every read of store B
  (`cross-graph-transaction-error`, GH #53) — even under B's snapshot.
- Read snapshots compose per store (`call-with-read-snapshot`); under a
  shared system clock their epochs come from one counter and are
  comparable, equal only in a quiescent image; there is NO single instant
  across stores. Without the clock, epochs of different stores are not
  comparable at all.
- Claim identity keys (`claim-identity-key`) carry producer, endpoints,
  relation and (temporal) extent start — NOT the store. The same identity
  can exist in two stores; `def-unique` is per store.
- `def-claim-classes` registers indexes and constraints under ONE graph
  name; a family used in a second store must be declared under that name
  too (the agent-tools spec §2 records this).
- A node knows its home store (`node-graph`); `resolve-node-graph` scans
  open stores for an untagged id.
- Secondary-index membership is not snapshot-versioned (vivace-graph#345,
  unconfirmed): a claim deleted after a snapshot is invisible under it.

**Classes of assumption to hunt** (name the class in each finding):
A. *One store holds the subject.* Code that reads one store, or the first
   store that answers, where a subject's beliefs may be split across the
   scope (recall/supersession computed per store; a belief in A superseded
   by a later one in B).
B. *First-wins resolution.* A cite, identity key or decision id resolved
   in "the first store in scope holding it" (`scope.lisp` `cite-store`,
   `trace.lisp` `%resolve-in`'s fallback, `resolve-cite`), where two
   stores hold the same identity.
C. *Comparability across stores.* Ordering or comparing recorded-at /
   epochs / validity across stores as if one clock (recall's merge order,
   `claim-before-p`, `changed-since`, `at` resolution) — true only with
   the shared clock, and even then not one instant.
D. *Identity without the store.* Any key, cache, hash or JSON field keyed
   on a cite/identity key/decision id alone that can collide across
   stores (`scope-cites`, decision ids minted per store, banner keys,
   note names).
E. *Uniqueness the validator enforces per store only.* A write refused in
   one store that would have been a duplicate/supersession of a belief in
   another (conclude's validation reads one store).
F. *Store naming.* `store-name` = downcased graph-name keyword; anything
   that assumes keyword-named graphs, distinct names, or renders/parses a
   store name (JSON, cites, `method` slot) without saying which store.
G. *Transaction placement.* Any read of another store inside a
   write-store transaction (would signal GH #53), and any evaluation that
   silently sees the write store's uncommitted state but not others'.
H. *Vocabulary drift.* A subject namespace keyword meaning different
   things in different stores (`:repo` in private vs working), with no
   check; `%find-keyword`/canonical-namespace rules interned per image.

**For each finding report:** file:line; the class; the assumption in one
sentence; a concrete two-store scenario (stores A and B, subjects, what is
written where, what is called, what comes back wrong or what signals);
whether the engine validator, a scope check or an existing test would
catch it (name the test or say none); severity — Real (wrong answer or
signal reachable by a caller), Latent (only with a shape not yet
constructed), or Documented (already stated as a limit in docs/); and the
smallest fix or the design question it raises. Cite the docs' own words
where the limitation is already documented (`docs/agent-memory.md`,
`docs/agent-tools.md`, the three S6a specs) — a documented limit is a
finding of class Documented, not a defect, but say whether the doc is
still true.

**Method.** Read the code, not the docs first. For every candidate,
attempt to refute it from a second location before keeping it. Prefer
fewer findings that survive over many that do not. Do NOT modify any
file; do not run suites (the two-store harness `with-stores` in
`tests-agent/` shows how a two-store image is built if you need to reason
about one). Write the report to the path you are given.
