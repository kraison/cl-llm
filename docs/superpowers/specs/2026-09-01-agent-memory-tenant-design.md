# Tenant three: agent memory as claims — design (cl-llm #16)

**Unit of the spatiotemporal substrate programme** (`#15`; design
`2026-08-09-spatiotemporal-substrate-programme-design.md` §8). The write
path and record shape of the agent-memory tenant, split from the capstone
`#14` on 2026-08-17 because none of the capstone's three gates gates
*recording a belief and reading it back*. Approved in chat 2026-09-01.

Engine: vivace-graph `experiment` HEAD, unpinned (decided 2026-09-01 on
`#15`). Everything below names the engine surface it relies on.

## 1. What this is

A third `def-source` and claim family over `graph-db/spacetime`, map-less
(`:space :none`), whose claims are an agent's **beliefs**: subject,
relation, object, with a `standing` and a validity `temporal-extent`.
Three properties the hand-maintained memory files lack:

- *"I looked and there was nothing"* and *"I could not find out"* are
  writes, not the absence of a record.
- A belief that stopped being true is returned **as superseded**, naming
  what superseded it — never silently dropped, never silently current.
- A belief that was **wrong** is distinguishable from one that was
  **outdated**, and the wrong one remains readable as "was believed
  from t1 to t2".

It is deliberately the third tenant: beliefs are neither documents nor
places, so this is the consumer that tests the record's genericity from
a new angle. It proves nothing about registration (map-less) and nothing
about cross-namespace recall (`#24`).

## 2. The engine surface used

| Need | Engine | Where |
|---|---|---|
| a claim family with validity in its identity | `def-claim-classes … :temporal t` (kraison/vivace-graph#296) | `spacetime/claim.lisp` |
| transaction time, stamped and closable | `claim-transaction-extent`, `claim-recorded-at`, `retract-claim`, `claim-current-p` (kraison/vivace-graph#148) | `spacetime/claim-query.lisp` |
| read by endpoint, bounded by validity | `claims-touching … :role :current :at :during` | same |
| audit by producer | `claims-by-producer` (kraison/vivace-graph#145) | same |
| canonical strings | `canonical-relation-p`, `canonical-producer-p` (kraison/vivace-graph#160) | `spacetime/claim.lisp` |
| the source contract | `def-source`, seven facets, `:none` explicit | `spacetime/source.lisp` |

Two facts that shape the design: **there is no engine supersession
operation** — it is a tenant convention (documents materialise a
`superseded-by` claim; sitrep computes it from `recorded-at`); and
**there is no as-of read over transaction time** (out of scope in the
engine's `docs/transaction-time-design.md`).

## 3. The record

```lisp
(st:def-claim-classes belief <graph> :temporal t)
```

A **belief** is a `belief-binary`:

| slot | value |
|---|---|
| subject | `(namespace . key)`, caller-supplied — the thing the belief is about |
| relation | canonical string, the predicate (`"suite-result"`, `"production-host"`) |
| object | `(namespace . key)` — the value; namespaces are the caller's vocabulary |
| producer | canonical string naming the agent, `"<agent>/<host>"` (`"claude-code/odm"`); required, never defaulted |
| standing | `:observed` `:inferred` `:asserted` — how the agent came to hold it |
| confidence, method, rule-version | as the substrate defines them; optional |
| extent | validity: when the belief holds. Start known; end `unknown-bound` while current |
| transaction extent | stamped by the engine; closed by retraction |

An **absence** is a `belief-unary` — subject and relation, no object —
with an absence standing and the *search* as its extent:

| standing | meaning |
|---|---|
| `:searched-empty` | looked in a nameable place at that time, nothing there |
| `:indeterminate` | tried, could not find out |
| `:uncovered` | recorded that nothing has looked |

`:determined-empty` is not written by this tenant: it means emptiness
follows from the subject itself, which is a fact about a document or a
place, not a belief.

Identity is the engine's temporal-family tuple: `(producer subject object
relation extent-start)`. Two consequences the caller must know:

- the same value can hold again later (a suite green → red → green) as
  three claims with disjoint validity — the engine refuses an overlap;
- a *retracted* claim keeps its identity slot, so retracting and then
  re-asserting the identical belief with the identical start is refused.
  It is also meaningless; the remedy is to record the corrected belief.

## 4. Two axes: outdated vs. wrong

**Supersession** (validity axis). Recording a belief on a `(producer,
subject, relation)` that already has a current belief *closes the
predecessor's validity end* at the successor's start (copy / `setf
claim-extent` / save). Both claims remain. "What superseded it" is
**computed** — the next claim in the series by validity start — never
stored, so it cannot go stale. This is the Allen-relations rule applied
to supersession, and the same choice sitrep made on the other axis.

**Correction** (transaction axis). `retract-belief` calls `retract-claim`:
the transaction extent closes, the validity extent is untouched — the
belief was never true, and what remains says exactly when it was
believed. The corrected belief is then recorded as usual. Retracted
claims are excluded from recall unless asked for.

The two are not interchangeable, and `record-belief` never retracts: an
agent that wants to say "I was wrong" must say so.

## 5. Write path

All three run inside the caller's `with-transaction`; none opens one.
Producer is required; relation and producer are checked with the
engine's canonical predicates *before* the write so the error names the
argument, not the slot.

```lisp
(record-belief graph subject relation object
               &key producer standing extent confidence method
                    rule-version)
  ;; => the new claim.  Closes the current predecessor's validity at
  ;; EXTENT's start, if one exists.  STANDING must be a presence standing.

(record-absence graph subject relation
                &key producer standing extent)
  ;; => the new unary claim.  STANDING must be an absence standing.
  ;; EXTENT defaults to an instant at now, :semantics :validity.

(retract-belief claim &key (at (local-time:now)))
  ;; => CLAIM, transaction extent closed.  Signals on a claim already
  ;; retracted.
```

`extent` for `record-belief` defaults to `[now, unknown)` with
`:semantics :validity :standing :asserted`. A caller recording a belief
about the past supplies the extent.

## 6. Read path

```lisp
(recall graph subject &key relation producer at include-retracted)
  ;; => a list of BELIEF-RECORDs, ordered
```

A `belief-record` wraps the claim with what the caller would otherwise
recompute wrongly:

| field | meaning |
|---|---|
| `claim` | the engine claim |
| `current-p` | validity end open **and** transaction current |
| `superseded-by` | the next claim in the same `(producer subject relation)` series by validity start, or NIL |
| `retracted-at` | the transaction extent's end, or NIL |
| `standing`, `extent` | the claim's own, surfaced for the reader |

Filters: `relation` and `producer` narrow the series; `at` (a timestamp)
returns only beliefs valid at that instant. **Not** via
`claims-touching`'s `:at` (see §9): the tenant's own predicate — start
no later than `at`, end unknown or no earlier than `at`. Retracted
claims are excluded unless `include-retracted`.

**Order is the contract** (programme §11): validity start descending,
ties by `recorded-at` descending, then by object key. A reordering is a
regression. `recall` never sorts on the way out beyond this rule.

## 7. Dogfood capture: the memory corpus

The proving corpus is the agent's own memory directory
(`~/.claude/projects/*/memory/*.md`: frontmatter `name`, `description`,
`metadata.type`, `metadata.modified`; a `MEMORY.md` index). 232 files
across five projects at the time of writing, with 25+ hand-written
supersession banners.

`capture-memory-dir graph dir &key producer` does two deterministic
things per note, and **nothing that needs an LLM or parses prose**:

1. a `memory-note` source node — identity `:memory-note` / `name`;
   `:time` from `modified` (validity start, open end); `:indexed-text`
   the body, so the corpus can later be a RAG chunk source unchanged;
   `:sensitivity (:class :restricted)` — memory is private;
   `:attribution :none`, `:space :none`, `:registration :none`;
2. one belief: subject `(:memory-note . name)`, relation `"content"`,
   object `(:digest . <sha256 of body>)`, standing `:asserted`, validity
   start `modified`.

A second capture after an in-place edit yields a new digest, so the
old content claim is superseded rather than overwritten — the "486
pass / 1 fail" case (`#16`) becomes visible as history instead of being
erased. Turning the banners *inside* the notes into modelled
supersession claims is the capstone's acceptance (`#14`), not this
unit's.

The test harness is **capture-and-diff** (programme §11): a fixture
corpus, captured, edited, captured again; the recall over the fixture
is compared to a committed golden with ordering as the contract, the
same discipline as `tests-rag`'s golden.

## 8. Layering and boundaries

- New ASDF system `cl-llm/memory`, directory `memory/`, package
  `cl-llm.memory`; depends on `graph-db/spacetime` (which carries
  `cl-temporal-extent`) and nothing else. **Not** on `cl-llm` core — it
  needs no LLM — and not on `cl-llm/rag`; the programme's §5 diagram
  places `cl-llm/memory` beside the graph-backed subsystems, and `cl-llm`
  core stays graph-free.
- Beliefs become bundle evidence through `cl-llm/rag/claims` with a
  key-extractor over the belief namespace — existing code, no new
  source class.
- Nothing here names a tenant of another repo; subject and object
  namespaces are the caller's.
- Tests: `tests-memory/`, `cl-llm/memory/tests`, on a real on-disk
  graph as `tests-claims` does; wired into CI's `test.yml` **with the
  `:in-order-to` test-op** (the trap `docs/ci.md` records).

## 9. Findings recorded on the way

- **No as-of read over transaction time.** The capstone's decision
  trace ("what was believed at a past instant") needs one; the data is
  retained (closed transaction extents), the query is not. To file on
  vivace-graph when `#14` starts, with this tenant as its consumer.
- **Retraction keeps identity** (§3). Documented here; not a defect.
- **An unknown end bound is not clamped by its start.** Found by the
  first `recall :at` test: `[2026-09-03, unknown]` against the instant
  2026-09-02 yields the Allen set `(:after :finished-by :before)`, so
  `extents-disjoint-p` is NIL and `claims-touching :at` returns an
  open-ended claim that starts *after* the instant. Every open-ended
  extent in the programme is exposed (a plan not yet finished, a run
  still in force). Filed as kraison/cl-temporal-extent#2; `recall`
  uses its own predicate until it lands.

## 10. Acceptance

- A third source declared through the onboarding contract, `:space
  :none`, beside the two existing tenants.
- Beliefs recorded and read back with standing and validity, and the
  three absence standings distinguishable in both directions: a write
  of each reads back as itself, and a read of each is never a NIL.
- A superseded belief recalled **as superseded**, naming what superseded
  it, and never as current.
- A corrected belief recalled only on request, with when it was
  believed.
- Capture-and-diff over a real memory corpus, ordering as the contract.
- No traversal, no tool surface, no planner, no LLM.
