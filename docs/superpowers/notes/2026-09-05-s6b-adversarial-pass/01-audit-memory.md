# S6b adversarial pass — auditor A, `cl-llm/memory` (cl-llm#24)

Files audited: `memory/schema.lisp`, `write.lisp`, `recall.lisp`,
`cite.lisp`, `trace.lisp`, `capture.lisp`, `banners.lisp`;
`tests-memory/` for coverage; `docs/agent-memory.md` and the S6a specs
for documented limits. Engine facts checked against
`~/work/vivace-graph-v3` at 4c9bc9f (read-only). Nothing modified, no
suite run.

**Counts — Real 4, Latent 4, Documented 2.**

One fact is settled before the findings, because three of them rest on
it and it is *already known*: **a cite does not name a store.**
`claim-cite` (`memory/cite.lisp:21-24`) renders
`<pkg>::<parent>|<identity-key>`, and `claim-identity-key`
(`spacetime/claim-query.lisp:29-58`) carries producer, endpoints,
relation and the extent start — never the store. The suite says so
itself, as a control:
`tests-agent/memory-tools-tests.lisp:481` asserts
`(string= cite (mem:claim-cite in-w))` for one belief recorded
identically in both stores. `capture-memory-dir` makes that automatic
rather than hypothetical: every identity component of a captured
belief is derived from the file (`note-name`, the sha256 digest, the
`modified` stamp) plus the producer, so capturing one corpus into two
stores mints **string-identical cites** for two distinct claims
(`memory/capture.lisp:193-198`, `81-113`). `trace` handles this
deliberately (`%resolve-in`, `memory/trace.lisp:192-204`); the
findings below are the places that still key on the cite alone.

---

## Real

### A1. Supersession and `current` are computed inside one store

**Where.** `memory/recall.lisp:38-50` (`%successor`), `:71-106`
(`recall`, series built only from `(st:claims-touching graph ...)`);
the write side, `memory/write.lisp:67-82` (`%series`,
`%current-predecessor`).

**Class.** A (one store holds the subject).

**Assumption.** Every claim in a `(producer, subject, relation)` series
lives in the store being read, so the next claim by validity start —
and therefore whether a belief is still held — can be decided from
that store alone.

**Two-store scenario.** Producer `claude-code/odm`, subject
`(:repo . "cl-llm")`, relation `"ci-status"`. Store A (working) holds
object `(:verdict . "green")` over `[2026-09-01T08:00Z, unknown)`;
store B (private) holds `(:verdict . "red")` over
`[2026-09-02T08:00Z, unknown)` — one series, split across the scope.
`(recall A '(:repo . "cl-llm") :relation "ci-status")` returns one
record with `current-p` T and `superseded-by` NIL. The agent tool
merges the two stores' answers (`agent/memory-tools.lisp:24-33`) and
renders `"current": true` with no `superseded-by` for green
(`agent/render.lisp:61-77`; per the spec, `current` is an
always-present boolean). The model reads "green is current" while red
supersedes it. `%changed-since` (`memory/cite.lisp:77-86`) has the
same blind spot: a cite superseded only in the other store reports
`changed-since` NIL. The write side cannot repair it either —
`%current-predecessor` sees only its own store, so writing red in B
never closes green's validity in A, and it *may not*: closing A's
claim from a transaction on B is `cross-graph-transaction-error`
(GH #53).

**What would catch it.** Nothing. Worse: the shape is already built
and stepped past. `tests-agent/memory-tools-tests.lisp:84`
(`recall-interleaves-cross-store-newest-first`) writes exactly this
split series — same producer, same subject, same relation, older in
`w`, newer in `p` — and asserts only the *order* of the two rows, not
`current` or `superseded-by`. `tests-memory/store-tests.lisp:96`
(`a-second-store-is-queryable-and-separate`) asserts the assumption as
a control ("the first store is untouched"). The engine cannot help:
`def-unique` and the temporal-disjointness rule are declared per graph
name (`spacetime/claim.lisp:422-427`), so two overlapping open runs in
two stores are legal in both. Docs are silent — `docs/agent-memory.md`
"Several stores" and the agent-tools spec §6 promise only that
"`recall` merges the stores' answers under unit 1's order rule".

**Smallest fix.** Give `recall` an optional `:scope` and build the
`%series-key` table over the union of the scope's `claims-touching`
answers, keeping each record's own store; `%successor` then names a
claim in another store, and `current-p` becomes scope-true. Rendering
already has a `store` field per record for the successor's cite to be
read against.

**Design question this raises (the important one).** May a
`(producer, subject, relation)` series span stores at all? If yes,
supersession is a read-time computation over the scope and *no writer
can ever close the older run* — GH #53 forbids the cross-store write —
so `current-p` must be redefined as "not superseded anywhere in
scope", never as "still open here". If no, the tools must refuse a
write whose series already lives in another store; `conclude` could
check that over the scope **before** it opens its transaction, which is
the only place such a check can legally read a second store.

---

### A2. `decisions-citing` unions on the cite string and ignores the store each evidence claim recorded

**Where.** `memory/trace.lisp:274-289` — the union is
`(st:claims-touching g 'trace :claim cite :role :object
:relation "evidence")` over every store in scope; `st:claim-method`,
which holds the store name `%write-evidence` wrote there
(`:90-96`), is never consulted.

**Class.** B (first/any-wins resolution) with D (identity without the
store).

**Two-store scenario.** Both stores hold the identical belief — the
`trace-names-the-store...` test's own setup, or simply the same memory
corpus captured into both. Decision `D_w` in A cites A's copy (its
evidence claim's `method` = `"cl-llm-memory"`); decision `D_p` in B
cites B's copy (`method` = `"memory-private"`). Then
`(decisions-citing A in-w :scope (list A B))` returns **both** ids —
`D_p` rests on B's node, not on the claim the caller handed in. The
caller passed a *claim*, whose store `%cite-of` throws away at
`:278`. A worse variant needs no duplicate belief at all: two
different corpora whose note names collide (capture keys are the
frontmatter `name` and `"<name>#<position>"`, `capture.lisp:82`,
`173-178`) give one cite two different meanings across the two stores.

**What would catch it.** No test.
`tests-agent/memory-tools-tests.lisp:194`
(`decisions-citing-orders-newest-first-across-stores`) has two
decisions in two stores but both cite the *same* claim, so the union
is right there by construction. The refutation attempt is what makes
this a finding: `trace` goes to real trouble for the opposite
invariant — the agent-tools spec §6 states it as "a belief held
identically by two stores still reports the half this decision cited"
— and `decisions-citing`, one function below it in the same file,
contradicts it.

**Smallest fix.** When `claim-or-cite` is a claim, resolve its store
(`%claim-store`) and keep only evidence claims whose `st:claim-method`
is that name or NIL (the unit-1 exemption `%resolve-in` already
honours); when it is a bare cite, take an optional store name. Two
lines in the `loop`.

---

### A3. `decisions-citing` returns ids stripped of their store, and `trace` can only look in one

**Where.** `memory/trace.lisp:274-289` returns bare id strings;
`:206-215` (`trace`) looks the decision up with
`(%decision-claims graph id)` — one store — and returns NIL when it is
not there; `:258-272` (`trace-listing`) then dereferences that NIL.

**Class.** D (identity without the store).

**Two-store scenario.** No identity collision needed — the plain
cross-store-evidence feature suffices. A decision recorded in the
private store B rests on a claim in the working store A (evidence pair
`(cite . "cl-llm-memory")`). `(decisions-citing A cite :scope (list A
B))` returns B's decision id. `(trace A id :scope (list A B))` returns
**NIL** — "no such decision was recorded" — for a decision that plainly
exists in scope. `(trace-listing A (list id))` is worse: it calls
`(decision-record-outcome NIL)` and signals a structure type-error.
The composition is live in the repo: `agent/annotate.lisp:48-55`
(`%newest-decision-by`) loops the ids from `decisions-citing` straight
into `(mem:trace graph id :scope scope)` and then
`(mem:decision-record-producer rec)` — a type-error the moment the
private store holds a decision citing a working-store banner claim,
which is exactly what `annotate-banners` is for.

**What would catch it.** No test. The counter-evidence that this is a
gap and not a design choice is in the agent layer:
`agent/memory-tools.lisp:43-47` had to add `%find-decision`, which
re-scans the whole scope for each returned id purely to recover the
store the API dropped — and the tool's JSON contract (agent-tools spec
§6) is `{id, store}`, so the store is part of the answer everywhere
except in the function that computes it.
`tests-memory/store-tests.lisp:156` asserts the union's ids and never
traces one.

**Smallest fix.** Return `(id . store-name)` pairs (or `(values ids
stores)`), and have `trace` accept a store or search `scope` for the
id — the two-line `%find-decision` the agent already wrote. Failing
that, `trace-listing` must at minimum survive a NIL `trace` rather
than signalling from a structure accessor.

---

### A4. `%write-evidence` de-duplicates evidence by cite alone, collapsing two stores' copies into one

**Where.** `memory/trace.lisp:90-96` —
`(remove-duplicates pairs :key #'car :test #'string= :from-end t)`.
The pair is `(cite . store-name)`; the key is only the cite.

**Class.** D (identity without the store).

**Two-store scenario.** `(conclude A proposal :evidence (list in-w
in-p) ...)` where `in-w` and `in-p` are the two stores' copies of the
identical belief — `%evidence-of` correctly resolves each to its own
store (`:77-88`), producing `("…|…" . "cl-llm-memory")` and
`("…|…" . "memory-private")` — and then exactly one evidence claim is
written, naming the working store. The decision's record says it rested
on one store's copy when it rested on both; `trace` reports one
evidence item, and `decisions-citing` from the private side (A2) will
not find this decision through B's copy.

**What would catch it.** No test; `tests-memory/trace-tests.lisp` and
`store-tests.lisp` never pass two claims that share a cite. Note the
comment at `:91-92` explicitly intends first-wins, so this is a
mis-keyed intent rather than an oversight: the rule it cites
(`%violation-families`' first-per-family) is keyed on the whole
identity of a violation, whereas here the identity is the pair. Not
reachable through the tool surface — `%evidence-pairs`
(`agent/memory-tools.lisp:115-122`) maps each cite to exactly one
store — so it is the direct `mem:conclude` caller who hits it, and the
`:evidence` docstring advertises claims as a supported input.

**Smallest fix.** Dedupe on the pair: `:test #'equal` with
`:key #'identity`, or a `:test` comparing both halves.

---

## Latent

### A5. `store-name` assumes graph names are symbols, and that distinct stores print distinctly

**Where.** `memory/schema.lisp:49-51`:
`(string-downcase (symbol-name (gdb:graph-name graph)))`. Everything
store-shaped funnels through it — `conclude` on every write
(`trace.lisp:146`), `%claim-store` (`:70-75`), `%store-in-scope`
(`:189-190`), and the agent's `find-store` / `%record-json`.

**Class.** F (store naming).

**Two-store scenario.** The engine's store registry is EQUAL-keyed and
documents its keys as "name (symbol or string)"
(`store-registry.lisp:12-15`), and `*graphs*` is EQUAL-keyed too
(`graph-class.lisp:3-5`), so `(define-memory-store "memory-private")`
and `(make-graph "memory-private" dir)` are a fully working memory
store — every declaration, `def-vertex` included, takes the name as a
literal. Put it in a scope and the first `store-name` call signals
`The value "memory-private" is not of type SYMBOL`: `conclude` dies
before writing anything, and `%store-in-scope` dies for every cite in
`trace`. Second half: `:memory-private` and `"memory-private"` are
*different* registry keys with different store ids, so both may be
open at once, and `store-name` maps them to one string — after which
`%store-in-scope` and the evidence `method` slot cannot tell them
apart and first-in-scope wins.

**What would catch it.** No test; every harness names its graphs with
keywords (`tests-memory/store-tests.lisp:15-22`). The ordinary
same-name case *is* engine-guarded — `%register-open-store` signals
`store-id-collision-error` for two open graphs interning to one store
id at different locations (`graph-class.lisp:40-68`) — which is why
only the type-distinct spelling survives.

**Smallest fix.** `(string-downcase (string (gdb:graph-name graph)))`
— `string` accepts symbols and strings — plus a note in
`define-memory-store` that two stores in one scope must have
distinct `store-name`s, since nothing else can enforce it.

---

### A6. `%claim-store` conflates "cannot resolve" with "the write store"

**Where.** `memory/trace.lisp:70-75` takes only the first value of
`graph-db::resolve-node-graph`; `:77-88` (`%evidence-of`) then reads
NIL as "use `write-store`".

**Class.** B (first-wins resolution) / D.

**Two-store scenario.** `resolve-node-graph` returns
`(values GRAPH STATUS STORE-ID)` with STATUS `:resolved`, `:detached`
(the registry knows the tag, no open graph carries it) or `:unknown`
(`interface.lisp:7-42`). Hold a claim read from the private store,
close that store, then `(conclude A proposal :evidence (list claim))`:
STATUS is `:detached`, `%claim-store` returns NIL, and the evidence
claim is stamped `"cl-llm-memory"` — permanently, in the claim's own
`method` slot. Re-open the private store later and `trace` resolves
that cite against the **working** store: `:absent` if the working
store lacks the identity, and — when both stores hold the belief
identically — `:resolved` against the wrong half, defeating precisely
what `tests-agent/memory-tools-tests.lisp:481` was written to
guarantee. The same silent fallback covers `:unknown` (v5, untagged
ids with `*system-directory*` unbound, where the scan only sees open
stores).

**What would catch it.** No test — `store-tests.lisp:115` proves the
happy path (`:resolved`) only. Latent because it needs a closed or
detached store, which the agent scope (all graphs open) does not
produce.

**Smallest fix.** Bind all three values; on `:detached` use
`graph-db::store-registry-name-for` on the tag (the engine's own
`lookup-vertex-anywhere` does exactly this), and on `:unknown` signal
a `belief-argument-error` rather than charging the write store — the
ruling the agent layer already applies to cites ("never silently
charged to the write store", `agent/memory-tools.lisp:116-118`).

---

### A7. Cross-store `:as-of` compares one store's wall clock against stamps another image minted

**Where.** `memory/trace.lisp:250-255` passes
`at = (%recorded-instant outcome)` — the *deciding* store's
`recorded-at` — into `%resolve-in`, which hands it to `resolve-cite`
(`memory/cite.lisp:98-117`) for a store that may be a different one.

**Class.** C (comparability across stores).

**Two-store scenario.** `:as-of` is not an epoch — the engine is
explicit ("No argument or result is an epoch; the mapping is the
per-version stamp in the claim's own data",
`spacetime/claim-query.lisp:239-248`) — and stamps come from `%st-now`,
"LOCAL-TIME:NOW, **strictly monotonic per image**"
(`spacetime/claim.lisp:226-236`). Within one image that is one clock
across all its stores, so the ordinary case is sound. But a store is
single-process (`docs/agent-memory.md:296`) and the deployment is one
long-lived image per store: the private store's history was stamped by
*another* image, possibly on another host. A private belief stamped
12:00:03 by a host 3 s fast, cited by a working-store decision recorded
at 12:00:01, resolves `:absent` — "not yet created" — and `trace`
reports the decision as resting on nothing, with no signal. The
agent-tools spec §2 already flags the neighbourhood: "one epoch across
stores is done (kraison/vivace-graph#94), so cross-store *reads* at one
instant are S6b's job (`#24`)". `%resolve-in` performs cross-store
as-of reads today, outside any snapshot and with no epoch — the doc's
"S6b's job" line is now only half true.

**What would catch it.** No test; both stores in every harness are
written by the one test image, which is the one configuration where
this cannot fail.

**Smallest fix.** Nothing small on the clock; the honest step is to
record it as a limit next to §4.3 and, when S6b lands cross-store
reads, resolve each store under its own `call-with-read-snapshot` and
carry the per-store instant on the `cite-record` rather than reusing
the deciding store's.

---

### A8. The scope readers have no transaction guard, though `conclude` has one

**Where.** `memory/trace.lisp:206` (`trace`), `:258`
(`trace-listing`), `:274` (`decisions-citing`), `:192-204`
(`%resolve-in`), and `memory/cite.lisp:98` (`resolve-cite`) — none
looks at `gdb:*transaction*`. `conclude` does (`:139-141`), for its
own reason.

**Class.** G (transaction placement).

**Two-store scenario.** `(gdb:with-transaction (:graph A) …
(mem:trace A id :scope (list A B)))` — a caller batching a write and a
read-back — signals `cross-graph-transaction-error` out of the engine
(`transactions.lisp:320-325`), naming a node id, from a function whose
docstring says nothing about transactions. Latent: no in-repo caller
does it (`capture-memory-dir`'s transaction wraps only single-graph
work, `capture.lisp:225-226`), and the failure is loud rather than
wrong.

**What would catch it.** No test. The correct-by-construction
counter-example is worth keeping: `conclude` computes its evidence
pairs at `trace.lisp:146-147`, **before** `with-transaction` opens at
`:151`, precisely so `%claim-store`'s cross-store scan happens outside
the transaction.

**Smallest fix.** One sentence per docstring ("reads the scope; call
outside a transaction"), or the same `gdb:*transaction*` check
`conclude` makes, raised as a `belief-argument-error` naming the
store.

---

## Documented

### A9. `conclude` validates one store, so a scope-level duplicate is not refused

**Where.** `memory/trace.lisp:154` — `(gdb:validate-transaction
graph)`, whose write set is one transaction on one graph
(`evaluator.lisp:134-141`); the commit-time constraints behind it
(`def-unique`, the temporal-disjointness rule) are declared per graph
name (`spacetime/claim.lisp:422-427`).

**Class.** E (uniqueness the validator enforces per store only).

**Status.** Documented, and the doc is *half* true. The agent-tools
spec §2 states the write-side limit and its reason: "cross-store
*writes* need the deferred two-phase commit
(kraison/vivace-graph#93), which is why a tool set writes to one store
only." That covers `conclude` returning `:concluded` for a proposal
that duplicates a belief held in another store — writes land in one
place by design. What no doc states is the **read-side consequence**:
the two accepted writes then form one series nobody can close (A1) and
carry one cite (A2, A4). The `docs/agent-memory.md` "Several stores"
section should say so; as written, a reader takes "the first store is
untouched" to be the whole story.

### A10. Evidence that names no store resolves in the deciding store

**Where.** `memory/trace.lisp:192-204` (`%resolve-in`'s `graph`
branch) and `:81` (`%evidence-of`: a bare cite string means the write
store).

**Class.** B (first-wins resolution).

**Status.** Documented and still true. Agent-tools spec §4.3: "a cite
whose evidence claim names no store (unit 1 data) is resolved in
`graph`", and §4.2: `conclude`'s evidence accepts "a cite string
(store = the write graph)". The residual risk — a bare cite for a
claim that lives elsewhere being charged to the write store — is
closed at the tool surface, where `%evidence-pairs`
(`agent/memory-tools.lisp:115-122`) resolves every cite through
`cite-store` and errors when it is not in scope ("never silently
charged to the write store"). A direct `mem:conclude` caller still
gets the documented fallback. `resolve-cite`'s own docstring should
gain the sentence `cite-record`'s already has — that the store is the
caller's to know — since the function will resolve a two-store cite
against whatever graph it is handed and report `:resolved`.

---

## Candidates refuted (do not re-raise)

1. **`resolve-cite` compares epochs across stores.** No: `:as-of` is a
   wall-clock TIMESTAMP matched against per-version stamps, "No
   argument or result is an epoch"
   (`spacetime/claim-query.lisp:239-248`), and `%st-now` is strictly
   monotonic per image (`spacetime/claim.lisp:226-236`), so one image's
   stores share one clock. Only the cross-image case survives, as A7.
2. **A second store used without `define-memory-store` answers
   silently empty.** No: the claim indexes are declared per graph name,
   and `%require-index` signals `query-precondition-error` for an
   undeclared one (`index.lisp:973-988`) — so `recall` *and*
   `record-belief` (through `%current-predecessor`) fail loudly in an
   undeclared store. Loud, not silent.
3. **Two open stores with the same graph name make `%store-in-scope`
   ambiguous.** Engine-guarded: `%register-open-store` signals
   `store-id-collision-error` when two open graphs intern to one store
   id at different locations (`graph-class.lisp:40-68`). Only the
   type-distinct spelling (`:x` vs `"x"`) evades it — folded into A5.
4. **`conclude` reads another store inside its transaction (GH #53).**
   No: `pairs` is computed at `trace.lisp:146-147`, before
   `with-transaction` opens at `:151`. Deliberate; kept as the
   counter-example in A8.
5. **A model's bare cite from the private store is charged to the write
   store.** Closed at the tool surface by `%evidence-pairs`
   (`agent/memory-tools.lisp:115-122`), which refuses a cite not in
   scope. The direct-API fallback is the documented contract — A10.
6. **Decision ids collide across stores.** No: `%mint-id` is 128
   random bits (`trace.lisp:13-14`). The reachable defect is the
   *missing* store on the id, not a collision — A3.
7. **`%current-among` picks the wrong half of a two-store cite.** No:
   its candidate list comes from `claims-touching` on **one** graph
   (`cite.lisp:98-107`), so the other store's copy never enters it; the
   store choice is made earlier, in `%resolve-in`.
8. **`claim-before-p` is not a total order, so a cross-store merge is
   unstable.** Not at the merge site: the agent uses `stable-sort`
   (`agent/memory-tools.lisp:29-33`) and scope order is the documented,
   tested tiebreak (`tests-agent/memory-tools-tests.lisp:98`). Within
   one store a full tie would be one identity key, which `def-unique`
   forbids.
9. **`banners.lisp` carries a store assumption.** It does not:
   `scan-banners` and its helpers are pure text over a string. Only
   `banner-listing` touches a graph, per store, and its key exposure is
   the capture key covered in A2's scenario.
10. **Capture could retract another store's beliefs.**
    `%retract-removed-banners` and `%retract-stale-superseded-by`
    (`capture.lisp:149-171`) both go through
    `claims-touching graph` / `%current-predecessor graph` with the
    producer filter; nothing reaches a second store.
