# S6b adversarial pass — auditor B: the agent tool surface (cl-llm#24)

Files audited: `agent/scope.lisp`, `agent/agent.lisp`,
`agent/memory-tools.lisp`, `agent/planner-tools.lisp`,
`agent/render.lisp`, `agent/annotate.lisp`, `agent/prolog/*`,
`claims/source.lisp` (where `make-claim-source` lives), the fusion path
it feeds (`rag/bundle.lisp`, `rag/hybrid.lisp`), `tests-agent/`,
`tests-agent-prolog/`, and `docs/agent-tools.md`,
`docs/evidence-bundle.md` §10, `docs/agent-memory.md`,
`docs/superpowers/specs/2026-09-03-agent-tools-design.md`.
`memory/cite.lisp`, `memory/recall.lisp` and `memory/trace.lisp` were
read only to the depth needed to say what the tools do; findings in them
are reported here only where the defect is visible from the tool
surface.

Counts: **5 Real, 4 Latent, 2 Documented.**

---

## Real

### B1 — `recall` merges rows across stores but computes supersession and currency inside one store

**Where.** `agent/memory-tools.lisp:23-33` (the per-store loop and the
merge), rendered by `agent/render.lisp:61-77`; the per-store computation
is `memory/recall.lisp:96,103` via `%successor`
(`memory/recall.lisp:38-50`).

**Class.** A (one store holds the subject).

**Assumption.** That a `(producer, subject-namespace, subject-key,
relation)` belief series lives entirely inside one store, so
`superseded-by` and `current` computed per store are true of the scope.

**Two-store scenario.** Scope `(W P)`, write store `W`, producer
`claude-code/test`.

- `W`: `(:repo . "cl-llm") --ci-status--> (:verdict . "green")`, valid
  from `2026-09-01T08:00:00Z`, open-ended.
- `P`: the same subject, producer and relation, object
  `(:verdict . "red")`, valid from `2026-09-02T08:00:00Z`, open-ended.

`recall{subject-namespace:"repo", subject-key:"cl-llm",
relation:"ci-status"}` returns two records, red first. Green's record
reads `"current": true`, `"superseded-by": null`, `"valid-to": null`.
Within one store `record-belief` would have closed green's validity a
nanosecond before red's start (the mechanism the planner test comments
on at `tests-agent/planner-tools-tests.lisp:41-45`); across stores
nothing does. The scope's own answer to "what is the CI status" is two
mutually exclusive beliefs, both flagged current, neither naming the
other. The tool's own description promises "whether it is current, and
what superseded it" (`agent/memory-tools.lisp:9-13`).

**Would anything catch it.** No. The engine validator is per store and
sees no write here at all. There is no scope check.
`tests-agent/memory-tools-tests.lisp:84`
(`recall-interleaves-cross-store-newest-first`) **builds exactly this
fixture** — `old` in `w` at 09-01, `new` in `p` at 09-02 — and asserts
only the returned order of the object keys. It never reads `current` or
`superseded-by`, so it passes while the two fields it does not read are
wrong.

**Fix / design question.** The smallest honest fix is not to compute the
field at all when the scope is wider than the store: have the recall
tool omit `superseded-by` and downgrade `current` to a per-store
qualifier (`"current-in-store"`) whenever `(rest (scope-stores scope))`
is non-nil. The real fix is a scope-aware recall — `%successor` over the
union of the series across the scope — which needs a rule for comparing
validity starts across stores (available: validity is asserted domain
time, not an epoch) and a rule for what "superseded by a claim in a
store you may not write" means.

---

### B2 — `retract` refuses a belief the write store holds, because `recall` left the cite→store cache pointing at the last store that answered

**Where.** `agent/scope.lisp:50-51` (`note-cite`, an unconditional
`setf` — last writer wins) against `agent/scope.lisp:53-63`
(`cite-store`, whose fallback scan is first-in-scope-order wins);
`agent/memory-tools.lisp:23-28` (recall calls `note-cite` for every row
of every store, in scope order); `agent/memory-tools.lisp:221-224` (the
retract tool consults `cite-store` and errors if the answer is not the
write store).

**Class.** D (identity without the store), with B (first-wins
resolution) as the inconsistent second half.

**Assumption.** That a cite denotes at most one store, so it does not
matter whether the cache records the first or the last store to hand
that cite back.

**Two-store scenario.** Scope `(W P)`, write store `W`. Both stores hold
the identical belief — same producer, endpoints, relation and validity
start — so both render the same cite (`claim-identity-key` carries no
store; `memory/cite.lisp:21-24`). This is the fixture
`tests-agent/memory-tools-tests.lisp:487-490` already builds and calls
"one cite names the copy in either store".

1. The model calls `recall` on that subject. It gets two records, one
   with `"store": "cl-llm-memory"`, one with `"store":
   "memory-private"`, and **the same `"cite"` on both**. The loop notes
   `W` then overwrites with `P`.
2. The model calls `retract{cite: <that cite>}`, meaning the copy it is
   allowed to retract. `cite-store` hits the cache, answers `P`, and the
   tool returns the error `store memory-private is not writable in this
   scope` — although `W`, the write store, holds a live, current,
   retractable claim on that exact cite.

The inversion is the tell: the same call **succeeds** if the model
retracts blind (no `recall` first — the fallback scan then finds `W`,
the first store), and succeeds if the operator built the scope as
`(P W)` with `:write-store W` (recall then ends on `W`). Same data, same
cite, same intent, opposite outcome decided by tool-call history and
scope order.

**Would anything catch it.** No. `retract-acts-on-the-write-store-only`
(`tests-agent/memory-tools-tests.lisp:308`) puts *different relations*
in the two stores (`ci-status` in `w`, `owner` in `p`), so the two cites
differ and the cache is never ambiguous; it also never calls `recall`
before `retract`. The doc states the rule as "A cite that resolves to a
store elsewhere in scope is an error result" (`docs/agent-tools.md:265`)
— the word "resolves" is doing work the code does not do. The engine
validator is not reached.

**Fix / design question.** Smallest fix: `note-cite` should not
overwrite (`(unless (nth-value 1 (gethash cite ...)) (setf ...))`),
which at least makes the cache agree with `cite-store`'s
first-in-scope-order fallback and makes the write store win whenever it
is first. That is a patch, not a repair: the design question is that
`§2` of the spec rules "The model names subjects, never stores"
(`docs/superpowers/specs/2026-09-03-agent-tools-design.md`, §2), so the
tool vocabulary has **no way to name a (store, cite) pair** even though
`recall`'s own rendering shows the model that two exist. Either
`retract` (and `conclude`'s `evidence`) grow an optional `store`
argument, or the cite rendered to the model gets a store prefix and is
parsed back — the latter changes the cite's contract and would need
`memory/cite.lisp`'s agreement.

---

### B3 — `retrieve` collapses one claim identity held by two stores into a single item, attributes it to the first store, and lets the duplicate outrank unique claims

**Where.** `claims/source.lisp:114-124` (`%claim-doc-id` — subject
endpoint, relation, object endpoint, producer; **no store**) and
`claims/source.lisp:60-73` (`render-claim` — no store either), fused by
`rag/hybrid.lisp:10-13` (`%chunk-key` = `(document-id . text)`) and
`rag/bundle.lisp:124-175`; the store is attributed downstream from the
surviving representative by `agent/planner-tools.lisp:22-27,41-56`.

**Class.** D (identity without the store), consequence in A.

**Assumption.** That a claim's uniqueness tuple is a unique fusion
identity across the sources being fused — true when the sources are
dense/sparse over one corpus, false when they are one claim source per
store (`agent/planner-tools.lisp:14-20`).

**Two-store scenario.** Same fixture as B2: `W` and `P` both hold
`(:repo . "cl-llm") --ci-status--> (:verdict . "green")`, same producer,
same validity start. `retrieve{query:"q", endpoints:["repo:cl-llm"]}`
builds one claim source per store. Each returns its copy; both copies
produce byte-identical `document-id` and `text`, so `%chunk-key`
collides and `reciprocal-rank-fusion` (`rag/hybrid.lisp:15-27`) keeps
one representative — "taken from the FIRST list it appears in", i.e.
the first store in scope order. Three caller-visible consequences:

1. The result has **one** evidence item where two stores answered, and
   its `"store"` is `cl-llm-memory` only. The design doc's contract for
   this field — "`store` and `cite` say where that one came from"
   (spec §7) and "each evidence item names its `store`"
   (`docs/agent-tools.md:303-305`) — is false here: the item names one
   of the two places it came from, with nothing saying a second
   answered.
2. `%evidence-json` then calls `note-cite` charging that cite to the
   first store (`agent/planner-tools.lisp:44`), which is the *opposite*
   of the store `recall` leaves in the cache for the same cite (B2). The
   two read tools disagree about where one cite lives, and whichever ran
   last decides what `retract` and `conclude` do.
3. RRF **sums** the two lists' contributions (`incf` at
   `rag/hybrid.lisp:23`), so the claim held by both stores scores
   `1/(60+1) + 1/(60+1)` against `1/(60+1)` for a claim held by one.
   With `k` small — the default is 5, and `retrieve` is the annotation
   pass's only read tool — a fact duplicated across stores displaces a
   distinct fact that exists in only one. Being in two stores is not
   relevance, and the rank change is not visible in the output.

**Would anything catch it.** No. Every planner test seeds *distinct*
claims per store (`%seed-two-stores`,
`tests-agent/planner-tools-tests.lisp:6-9`). The **absence** path is
tested for exactly this collapse and passes — because
`%absence-evidence` deliberately puts the graph name in its document id
"so two stores' absences of the same endpoint fuse to two items, not
one" (`claims/source.lisp:126-138`, pinned by
`retrieve-clamps-k-and-a-recognised-endpoint-with-nothing-is-searched-empty`,
`tests-agent/planner-tools-tests.lisp:82-93`). The asymmetry is the
proof that the omission in `%claim-doc-id` is not considered: absences
are store-tagged, present claims are not.
`trace-names-the-store-the-decision-resolved-against`
(`tests-agent/memory-tools-tests.lisp:481`) knows about the collapse —
its comment reads "RETRIEVE collapses the two copies and caches cite ->
the first store, which is exactly the wrong half here" — but uses it
only as a *hostile precondition* for a `trace` assertion; nothing
asserts about `retrieve`'s own output, and `docs/` says nothing about
it.

**Fix / design question.** Smallest fix: append the store to
`%claim-doc-id` the way `%absence-evidence` already does
(`(graph-db:graph-name (claim-source-graph source))`), which makes the
two copies fuse to two items each naming its own store and removes the
rank inflation. That costs one thing worth deciding: `render-claim`'s
text is still identical, so the model sees two items reading the same
line with different `store` values — which is the truth, and is what
`recall` already shows.

---

### B4 — `conclude` validates only in the write store, so the same write is refused or accepted depending on which store holds the prior belief

**Where.** `agent/memory-tools.lisp:171-184` (the conclude tool passes
`(scope-write-store scope)` and nothing else) into
`memory/trace.lisp:151-162`, whose only check is
`(gdb:validate-transaction graph)` at `memory/trace.lisp:154`.

**Class.** E (uniqueness the validator enforces per store only).

**Assumption.** That the write store's validators see everything the
scope believes, so a clean `"outcome": "concluded"` means the write was
consistent with the memory the model was reading.

**Two-store scenario.** Scope `(W P)`, write store `W`.

- Case 1: `W` already holds `(:repo . "cl-llm") --ci-status-->
  (:verdict . "green")` with validity start `T`. The model concludes the
  same subject/relation at the same `valid-from`. `belief`'s `:unique`
  identity tuple is violated, the transaction is refused, and the model
  reads `{"outcome": "refused", "refusals": [...]}` — the property
  `retract-then-conclude-at-the-same-valid-from-is-refused`
  (`tests-agent/memory-tools-tests.lisp:326`) exists to lock in.
- Case 2: the *identical* prior belief is in `P` instead, still fully in
  scope and still returned by `recall`. `def-unique` is per store, so
  `W`'s validator sees nothing, the write commits, and the model reads
  `{"outcome": "concluded", "refusals": []}`.

Same model action, same scope contents, opposite result, with nothing in
either result saying which store decided it. The tool's own description
says "The write is validated before it commits"
(`agent/memory-tools.lisp:149`); it is, in one store of several. Case 2
is also the generator for B1, B2 and B3 — it is the reachable way a
scope acquires two stores holding one identity.

**Would anything catch it.** No. The engine validator is precisely the
thing that is per store. No scope check exists. No test constructs case
2; every conclude test writes a subject/relation the other store does
not hold.

**Fix / design question.** There is no cheap correct fix — a
cross-store validating write needs the two-phase commit the spec defers
(`§2`: "cross-store *writes* need the deferred two-phase commit
(kraison/vivace-graph#93), which is why a tool set writes to one store
only"). The cheap *honest* fix is a pre-write scope read: before
staging, run the proposal's `(producer, subject, relation)` series
across the rest of the scope and either refuse with a synthetic family
(`"scope"`) or return the conflict alongside `"concluded"` so the model
is told. The design question is whether "one store writable" was meant
to imply "consistency is per store", because §2 sells the scope to the
operator as *one* memory partitioned by trust, and this is the seam
where that framing stops holding.

---

### B5 — `annotate-banners` traces every decision id against the write store only, so an id from another in-scope store signals instead of returning the documented NIL

**Where.** `agent/annotate.lisp:48-55` (`%newest-decision-by`), called
at `agent/annotate.lisp:132-135` with `write` = `(first stores)` and
`scope` = all of `stores`.

**Class.** A (one store holds the subject) via B (an id resolved in the
wrong store).

**Assumption.** That every id `mem:decisions-citing` returns for a cite,
having been unioned over the whole scope
(`memory/trace.lisp:274-289`), can be traced in the write store.

**Two-store scenario.** `annotate-banners (list W P) dir`. The banner
fixtures were captured into `W`, so `%banner-annotates-cite` finds the
`annotates` cite `C`. Store `P` — the shared/private half — already
holds a decision citing `C`: an earlier annotation pass run as
`(list P W)`, or another agent's decision over the same banner identity
(the cite carries no store, so `P`'s copy of that banner has the same
cite).

The model declines this banner (replies `no`, the case
`annotate-banners-reports-a-declined-note-as-nil`,
`tests-agent/annotate-tests.lisp:200`, is written for). No decision is
written this run, so `%newest-decision-by` walks the whole
`decisions-citing` list. It reaches `P`'s id, calls
`(mem:trace W id :scope stores)` — `%decision-claims` finds no
`:decision id` trace claim in `W`, `trace` returns `NIL`
(`memory/trace.lisp:216`), and `(mem:decision-record-producer NIL)`
signals a type error. `annotate-banners` aborts mid-pass; every banner
after this one is never annotated, and the caller gets a condition
where the documented contract is "**NIL is a normal outcome, not an
error**" (`docs/agent-tools.md:471-472`).

The `conclude` path masks it only by luck: `decisions-citing` is
newest-first and this run's own decision (written into `W`) sorts ahead
of any pre-existing one, so the loop returns before reaching `P`'s id.
The declined path has no such shield.

**Would anything catch it.** No. Both annotate tests capture into `w`
only and leave `p` empty
(`tests-agent/annotate-tests.lisp:70,202`), so `decisions-citing`
never returns an id from the second store. The `%trace-tool` surface
*is* guarded — it calls `%find-decision` first
(`agent/memory-tools.lisp:43-47,57-58`) — which makes the unguarded
call in `annotate.lisp` an inconsistency within the same package.

**Fix / design question.** One line: resolve the store first, exactly as
the trace tool does, e.g.
`for g = (%find-decision-store id stores)` / `for rec = (and g (mem:trace g id :scope scope))`
with `(and rec (string= producer ...))`. `%find-decision` is already
written and takes a `scope` struct; either generalise it to a plain
store list or build a throwaway scope. Worth asking separately whether
`%newest-decision-by` should consider decisions from stores it cannot
write at all — a `P`-side decision by the same producer *is* a real
prior annotation, so the answer is probably yes, and the current code
would have returned it as this run's result had it not crashed.

---

## Latent

### B6 — decision ids are assumed globally unique, and `%find-decision` takes the first store that answers

**Where.** `agent/memory-tools.lisp:43-47` (`%find-decision`, a
`find-if` over `scope-stores`), used by the trace tool
(`:57-58`) and to label every row of `decisions-citing`
(`:99-101`); the union that feeds it does not dedupe
(`memory/trace.lisp:279-282`).

**Class.** B and D.

**Assumption.** Stated outright in the docs: "Found in whichever store
of the scope holds it — **decision ids are random and unique**"
(`docs/agent-tools.md:176-177`). Ids are 128 random bits
(`memory/trace.lisp:13-14`), so collision is not the risk — copying is.

**Two-store scenario.** `P` is a snapshot, replica or restored backup of
`W` (an ordinary operational shape: the spec lists "operations (backup,
retention, sharing)" among the four needs a separate store serves,
§2). Both hold decision `d` and its evidence claims.
`decisions-citing{cite: C}` returns `d` **twice**, and each row is
labelled `"store": "cl-llm-memory"` because `%find-decision` stops at
the first store. `trace{decision-id: d}` reconstructs `W`'s copy
silently, even if the caller meant `P`'s (which may differ — `P`'s copy
may have been reaped or its evidence retracted since the snapshot).

**Would anything catch it.** No. No test opens two stores holding one
decision id. The engine has no reason to object.

**Severity.** Latent: it needs a store shape (a replica in scope) that
S6a never constructs, and the doc names the assumption rather than
hiding it.

**Fix.** Dedupe `decisions-citing`'s ids on `(id . store)` rather than
`id`, and have `%find-decision` return all matches so the tool can
render one row per store. Or decide that a replica in scope is out of
contract and say so in `docs/agent-tools.md` beside the uniqueness
sentence.

### B7 — `store-name` is a downcased symbol name, nothing checks the names in a scope are distinct, and every name→store lookup is first-wins

**Where.** `memory/schema.lisp:49-51` (`store-name`);
`agent/scope.lisp:25-41` (`make-scope` validates only `%graph-p`,
membership of the write store, and the caps — never name distinctness);
the three first-wins lookups: `agent/scope.lisp:43-48` (`find-store`),
`memory/trace.lisp:189-190` (`%store-in-scope`, which is what resolves
every stored evidence cite) and `agent/prolog/query.lisp:30-35`
(`%find-store`, the model-facing `store` argument).

**Class.** F (store naming).

**Assumption.** That the downcased `graph-name` is a unique, stable
identifier for a store — it is the *only* link a stored trace claim has
to the store its evidence lives in ("an evidence claim records **which
store** the claim it cites was found in, in its `method` slot",
`docs/agent-memory.md:196-198`).

**Two-store scenario.** Two graphs whose names downcase to the same
string — `:CL-LLM-MEMORY` and `|cl-llm-memory|` are distinct keywords
with the same `string-downcase (symbol-name ...)`; so are two graphs
opened on different directories under one name keyword. `make-scope`
accepts them. `trace` then resolves every evidence cite recorded as
`"cl-llm-memory"` against whichever comes first in scope order, reports
that store's `state` and `changed-since`, and the tool renders the
ambiguous name as if it were an answer. The query tool's `store`
argument likewise reaches only the first.

**Severity.** Latent: it needs a scope no current code builds, and the
engine may refuse two open graphs under one name (not verified —
`~/work/vivace-graph-v3` was out of bounds for this pass).

**Fix.** One check in `make-scope`: reject a `stores` list whose
`store-name`s are not distinct. That is cheap and turns a silent wrong
answer into a construction-time `scope-error`, which is where every
other scope invariant is already caught.

### B8 — the query tool closes over its own store list, unrelated to the memory tools' scope

**Where.** `agent/prolog/query.lisp:37,56` (`make-query-tool` takes a
bare `stores` list and re-implements the lookup as
`%find-store`, `:30-35`) against `agent/scope.lisp:43-48`, where
`find-store` is written, exported (`agent/packages.lisp:17`) and **never
called by anything in the repo**.

**Class.** F, with the trust boundary of §2 behind it.

**Assumption.** That the two constructions will be handed the same
stores. Nothing enforces it: `make-agent-tools` builds a `scope` with a
write store, a producer and a cite cache; `make-query-tool` builds
nothing but a closure over a list.

**Two-store scenario.** An operator builds an untrusted-input session as
`(make-agent-tools (list W) :producer p)` — the private store correctly
out of scope, exactly the lateral-movement defence §2 describes — and
then, from a different call site, `(make-query-tool (list W P))`. The
model gets one tool set that cannot see `P` and one that can walk every
`belief` and `trace` vertex in it. The doc reads "`make-agent-tools` and
`make-query-tool` each close over their own scope, so several scopes in
one image are simply several tool sets" (`docs/agent-tools.md:84-87`) —
which is a true statement of the mechanism and a description of the
hazard rather than a warning about it.

**Severity.** Latent: it is an operator mistake, not a code defect, and
no shipped call site makes it. It is listed because the exported,
unused `find-store` shows a scope-aware version was intended and the
prolog system took a different route.

**Fix.** Give `make-query-tool` a `scope` (it needs only
`scope-stores`), or add a `make-agent-tools`-side constructor that
returns the query tool alongside the eight, so the two lists cannot
diverge.

### B9 — namespace keywords are image-global, and the scope merges on them with no per-store vocabulary check

**Where.** `agent/render.lisp:28-32` (`%find-keyword`, read path — a
bare `find-symbol` in `:keyword`) and `:44-50` (`%keyword`, write path —
`intern` after the canonical check); consumed by
`agent/memory-tools.lisp:19-21` and `agent/planner-tools.lisp:6-12`.

**Class.** H (vocabulary drift).

**Assumption.** Two of them. First, that a subject namespace means the
same thing in every store of a scope — `recall` interns `"repo"` once
and asks every store about `:REPO`, merging the answers into one list
whose only discriminator is the `store` field on each record (and in
`retrieve`, per B3, not even that). Second, that "never interned"
implies "nothing recorded", which is `%find-keyword`'s whole
justification ("never mints one, so a namespace nothing was ever
recorded under reads as an empty result") — sound only while nothing
else in the image interns that name, and the `:keyword` package is
shared with every library loaded.

**Two-store scenario.** `P` (private) uses `(:repo . "...")` for the
customer repositories it tracks; `W` (working) uses it for source
repositories. `recall{subject-namespace:"repo", subject-key:"acme"}`
returns both stores' beliefs interleaved by validity, and the model is
expected to infer the vocabulary split from the store names. Nothing
declares, per store, which namespaces it owns.

**Severity.** Latent. I looked for a cross-scope information leak here
and did not find one: `recall` returns an empty array for an unknown
namespace whether or not the keyword happens to be interned, and
`decisions-citing` distinguishes only canonical-but-unknown (empty) from
uncanonical (error), so a model in the untrusted scope learns nothing
about the private store's vocabulary. The bite is interpretive, not a
signal.

**Fix / design question.** Nothing small. The design decision is
explicit — "Topic is the subject namespace, not the container" (§2) —
so the namespace is *meant* to be scope-global vocabulary; the gap is
that nothing records, or checks, which stores are entitled to a
namespace. A per-store declared namespace list on
`define-memory-store` would make the drift checkable at construction
rather than discoverable at read.

---

## Documented

### B10 — no cross-store consistent instant; and `trace` applies the deciding store's `recorded-at` to another store's transaction axis

**Where.** The merge order `agent/memory-tools.lisp:29-33`
(`claim-before-p` over rows from several stores); the as-of resolution
`memory/trace.lisp:217,252-255` → `memory/cite.lisp:98-128`
(`:as-of at`, where `at` is the outcome claim's `recorded-at` **from the
deciding store**), rendered by `agent/memory-tools.lisp:76-77` and
`agent/render.lisp:79-90`.

**Class.** C (comparability across stores).

**The documented limit, in the docs' own words.**
`docs/agent-tools.md:496-498`: "**No cross-store consistent instant.**
Reads run per store and merge; one epoch spanning several stores at once
is S6b's job (`#24`), not this one's." And spec §2: "one epoch across
stores is done (kraison/vivace-graph#94), so cross-store *reads* at one
instant are S6b's job (`#24`)".

**Is the doc still true.** Yes, and the merge half of it is honest —
`recall`'s ordering keys are validity start (asserted domain time,
comparable by construction) and then `recorded-at`, with the genuine
cross-store tie pinned to scope order by
`recall-breaks-a-genuine-cross-store-tie-by-scope-order`
(`tests-agent/memory-tools-tests.lisp:98`). But the doc's wording
describes a *missing* capability, and understates one that is present
and used: `trace` does not merely decline a single instant, it takes one
store's transaction timestamp and evaluates another store's history at
it. In the scenario of `trace-and-decisions-citing-across-the-scope`
(`tests-agent/memory-tools-tests.lisp:155`) — decision in `W`, evidence
in `P` — the `state`, `standing`, `extent` and `changed-since` the model
reads for that evidence item are `P`'s history as of `W`'s clock. Under
the shared system clock that is defensible; for a store whose
`recorded-at` values came from elsewhere (a restore, an import, an image
without the shared clock) the "version believed then" is arbitrary, and
the output carries no marker distinguishing the two cases.

**Fix / design question for S6b.** When `#24` gives the scope a real
cross-store read instant, `trace` is the first consumer and its
`cite-record` should carry which axis the as-of was taken on. Until
then, one sentence in `docs/agent-tools.md`'s `trace` section saying the
as-of instant is the deciding store's would make the limit checkable.

### B11 — an out-of-scope evidence cite is indistinguishable from a deleted one

**Where.** `memory/trace.lisp:199-204` (`%resolve-in` returns a bare
`:absent` record with no store when `%store-in-scope` misses),
rendered by `agent/render.lisp:79-90` and
`agent/memory-tools.lisp:76-77`.

**Class.** B / F.

**The documented limit, in the docs' own words.**
`docs/agent-tools.md:182-186`: "A cite naming a store the tool set was
not built with reports `state: "absent"` and carries **no `store` key at
all** — never falling back to the decision's own store, which would
falsely suggest it was found."

**Is the doc still true.** Yes, exactly, and it is pinned by
`trace-omits-store-for-an-out-of-scope-evidence-cite`
(`tests-agent/memory-tools-tests.lisp:178`), which asserts both the
`"absent"` state and the *absence of the key* rather than a null. The
residual is that `:absent` is also what a cite gets when the store **is**
in scope and the claim is genuinely gone
(`memory/cite.lisp:118-119`), so the model reading a trace cannot tell
"you did not open the store this evidence lives in" from "this evidence
no longer exists" — a difference that matters, because the first is the
operator's fault and recoverable and the second is a fact about the
memory. The doc explains the design (not falsely claiming it was found)
without noting that the two cases now render identically.

**Fix.** A third `state` — `:out-of-scope` — beside `:absent` and
`:reaped`, set on the `%store-in-scope` miss. Small and local; it does
change a rendered enum, so it is a contract change on the tool's output.

---

## Candidates raised and refuted

- **Class G, a read of another store inside the write store's
  transaction (would signal `cross-graph-transaction-error`, GH #53).**
  Traced every `with-transaction` reachable from the tools. `conclude`
  refuses to run inside an open transaction at all
  (`memory/trace.lisp:139-141`), and `%evidence-pairs`' cross-store scan
  is argument evaluation, so it completes before the transaction opens.
  `%retract-tool` resolves the store *then* opens the transaction
  (`agent/memory-tools.lisp:221,251`). `%write-evidence` records the
  other store as a **string** in the `method` slot, never a node
  reference (`memory/trace.lisp:90-96`) — which is exactly what keeps
  the write transaction single-store. No path found.

- **`%source-store` / `%evidence-json` mis-attributing evidence to a
  store.** `%source-store` matches the evidence's own
  `claim-source-graph` against the scope by identity
  (`agent/planner-tools.lisp:22-27`); for a claim held by one store it is
  correct, and for an operator source it correctly yields `NIL`. The
  defect is upstream in the fusion identity (B3), not here.

- **The `query` tool reading across stores via S1's `claim/7`-style
  functors through `*claim-scope*`.** `*claim-scope*` has zero
  occurrences anywhere in cl-llm (`rg` over the whole tree); the tool
  binds nothing and hands `run-guarded-prolog` exactly one graph
  (`agent/prolog/query.lisp:24-28,56`). `query-names-a-store-in-scope`
  (`tests-agent-prolog/query-tests.lisp:26`) pins that a query against
  the working store returns no rows for a belief that exists only in the
  private store, and that an out-of-scope store name is an error result.
  Whether the engine's own claim functors could widen that is not
  answerable from this worktree — `~/work/vivace-graph-v3` was out of
  bounds — but on the cl-llm side there is nothing to find.

- **`decisions-citing`'s cross-store "newest first" as a class C
  defect.** It compares `recorded-at` across stores
  (`memory/trace.lisp:284-289`), which is the documented shared-clock
  case, the tie-break is a total order on the id string, and
  `decisions-citing-orders-newest-first-across-stores`
  (`tests-agent/memory-tools-tests.lisp:194`) pins the ordering with the
  newer decision in the second store. Deterministic and specified;
  folded into B10 rather than kept.

- **`recall`'s cross-store tie-break being arbitrary.** I expected the
  `stable-sort` to expose hash or sort-stability order. It does not:
  rows are pushed and `nreverse`d into scope order before the sort, and
  `recall-breaks-a-genuine-cross-store-tie-by-scope-order`
  (`tests-agent/memory-tools-tests.lisp:98`) asserts both orderings,
  `(w p)` and `(p w)`, on a fixture with equal validity start *and*
  equal `recorded-at`. Refuted, and well tested.

- **`trace` charging evidence to the wrong store from the cite cache.**
  Refuted from two places: `%resolve-in` reads the store from the
  decision's own evidence claim rather than the cache
  (`memory/trace.lisp:192-204`), the trace tool deliberately does not
  call `note-cite` and says why (`agent/memory-tools.lisp:59-62`), and
  `trace-names-the-store-the-decision-resolved-against`
  (`tests-agent/memory-tools-tests.lisp:481`) proves it with `retrieve`
  called first specifically to poison the cache. This is the one place
  the cache ambiguity was found and fixed; B2 and B3 are the places the
  same fix was not applied.

- **`%decision-json` calling `mem:trace` on the write store with no
  `:scope`** (`agent/memory-tools.lisp:140-142`), which I expected to
  signal or return NIL for a decision citing another store's claim.
  `%resolve-in` returns an `:absent` cite-record for an unknown store
  name rather than signalling, `mem:trace` always finds the write
  store's own outcome claim (both `conclude` paths write one), and
  `%decision-json` reads only `refusals`. Wasted work, no defect.

- **`conclude` silently charging an unresolvable cite to the write
  store.** Refuted: `%evidence-pairs` errors on a cite `cite-store`
  cannot resolve and always passes `(cite . store-name)` pairs
  (`agent/memory-tools.lisp:115-122`), so `%evidence-of`'s write-store
  default (`memory/trace.lisp:81`) is unreachable from the tool surface.
  Pinned by `conclude-signals-on-an-evidence-cite-out-of-scope`
  (`tests-agent/memory-tools-tests.lisp:396`).
