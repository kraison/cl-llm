# S6b adversarial pass — verification (cl-llm#24)

Adversarial third pass over auditor A (`memory`) and auditor B
(`agent`). Every finding was re-derived from the code before it was
kept; every claimed test was opened; every engine premise a finding
rests on was checked against `~/work/vivace-graph-v3` at `4c9bc9f`
(read-only). Nothing was modified, no suite was run.

**After verification: Real 6, Latent 6, Documented 3, Refuted 1**
(from 9 Real, 8 Latent, 4 Documented across the two reports, before
merging).

Five pairs merged; one regrade up (A9/B4, Documented → Real); one
regrade down (A2, Real → Refuted).

## Verdict table

| id(s) | class | severity | verdict | reason |
|---|---|---|---|---|
| **A1 + B1** | A | Real | CONFIRMED | `recall` builds the series from one graph (`recall.lisp:77-78,96,103`); two open runs in two stores both render `"current": true`, neither naming the other, and GH #53 forbids the write that would close either. |
| **A3 + B5** | D (via B) | Real | CONFIRMED | `decisions-citing` returns bare ids unioned over the scope; `mem:trace` looks in one store and returns NIL; `trace-listing:263` and `annotate.lisp:52` then call a struct accessor on NIL. |
| **B2** | D + B | Real | CONFIRMED | `note-cite` last-wins (`scope.lisp:50-51`) vs `cite-store`'s first-in-scope scan; after `recall`, `retract` refuses a claim the write store holds. |
| **B3** | D | Real | CONFIRMED | `%claim-doc-id` carries no store (`claims/source.lisp:114-124`) while `%absence-evidence` deliberately does; two stores' copies fuse to one item, attributed to the first, with summed RRF score. |
| **A9 + B4** | E | Real (regraded up from A9's Documented) | CONFIRMED | The doc states only that writes *land* in one store; it nowhere states that validation is therefore blind to the scope, and the tool surface can mint a scope-wide duplicate identity with `"outcome": "concluded"`. |
| **A4** | D | Real (low) | CONFIRMED | `%write-evidence` dedupes on the cite alone (`trace.lisp:93-94`), so two stores' copies cited together collapse to one evidence claim naming one store. |
| **A5 + B7** | F | Latent | CONFIRMED | `store-name` is `symbol-name` on the graph name; two keywords downcasing to one string are distinct registry keys, so `%register-open-store`'s collision guard does not fire. |
| **A6** | B / D | Latent | CONFIRMED | `%claim-store` keeps only the first value of `resolve-node-graph`, so `:detached`/`:unknown` becomes "the write store" and is stamped permanently into the evidence `method` slot. |
| **A8** | G | Latent | CONFIRMED | No scope reader checks `gdb:*transaction*`; a caller batching a read-back inside `with-transaction` gets `cross-graph-transaction-error`. Loud, not wrong. |
| **B6** | B / D | Latent | CONFIRMED | `%find-decision` takes the first store answering; a replica in scope duplicates ids and mislabels every row. |
| **B8** | F | Latent (weakest kept) | CONFIRMED | `make-query-tool` closes over a bare store list with its own `%find-store`; `agent:find-store` is exported and has **zero** callers. Operator hazard, not a code defect. |
| **B9** | H | Latent | CONFIRMED | Namespace keywords are image-global and nothing records which store owns which namespace. Interpretive; I re-checked for a leak and found none. |
| **A7 + B10** | C | Documented (latent residue) | CONFIRMED | `agent-tools.md:496-498` states the limit and is still true, but understates: `trace` does not decline a cross-store instant, it applies the *deciding* store's `recorded-at` to another store's transaction axis. |
| **A10** | B | Documented | CONFIRMED | Spec §4.3's words are exact and still true; the residual risk is closed at the tool surface by `%evidence-pairs`. |
| **B11** | B / F | Documented | CONFIRMED | `agent-tools.md:182-186` is exact, pinned by a test asserting the *absence* of the key; the residual (out-of-scope vs genuinely gone read identically) is real and small. |
| **A2** | B / D | — | **REFUTED** as Real | `decisions-citing` is *specified* as a cite-keyed union ("`decisions-citing` unions the stores", spec §6 line 237), a cite is store-free by construction (verified: `claim-identity-key` carries no store), and the tool passes only a cite. The answer follows the contract; the residue is the design question, not a defect. |

---

## Confirmed Real findings

### R1 (A1 + B1) — supersession and `current` are computed inside one store

**Class A.** `memory/recall.lisp:71-106`, `:38-50` (`%successor`);
write side `memory/write.lisp:67-82`; merged and rendered by
`agent/memory-tools.lisp:23-33` and `agent/render.lisp:61-77`.

**Scenario.** Scope `(W P)`, producer `claude-code/test`, subject
`(:repo . "cl-llm")`, relation `ci-status`. `W` holds
`(:verdict . "green")` valid from `2026-09-01T08:00Z`, open-ended;
`P` holds `(:verdict . "red")` valid from `2026-09-02T08:00Z`,
open-ended. One series, split across the scope.

**Evidence.** `recall.lisp:77-78` builds `all` from
`(st:claims-touching graph 'belief ...)` — one graph — and
`:96` fills the `%series-key` table from that same list, so
`%successor` at `:103` can only ever name a claim in `graph`.
`:99-101` sets `current-p` to `(and current (%open-p c))`, and
nothing closed green's validity: `%current-predecessor`
(`write.lisp:77-82`) reads its own graph only, and the cross-store
close is forbidden — the brief's own engine fact, confirmed at
`transactions.lisp:319-324`. The merge at
`agent/memory-tools.lisp:29-33` interleaves the two rows correctly
and carries both stores' verdicts forward with `"current": true` and
`"superseded-by"` omitted on each. `memory/cite.lisp:77-86`
(`%changed-since`) has the same blind spot: `then` and `current` both
come from `resolve-cite`'s single `graph`, so a cite superseded only
in the other store reports `changed-since` NIL.

**Refutation attempted and failed.** The nearest documented defence is
spec §12 — "cross-store recall at one consistent instant (`#24`, S6b —
reads here are per store, merged)". It does not cover this: the
documented limit is about an *instant*, and `current`/`superseded-by`
are not instant-relative — they are computed from claim data.
`docs/agent-tools.md:107` says `current` is an always-present boolean
and `:133-140` describes the merge without qualifying it, so the doc
as a whole promises a scope-level answer.

**Test gap.** `tests-agent/memory-tools-tests.lisp:84`
(`recall-interleaves-cross-store-newest-first`) builds this exact
fixture — `old` in `w` at 09-01, `new` in `p` at 09-02 — and asserts
only the order of the two object keys (`:94-96`). The two fields that
are wrong are never read. `tests-memory/store-tests.lisp:43`
(`a-second-store-is-queryable-and-separate`) asserts the assumption as
a control at `:49`.

**Smallest fix.** Two candidates, and they are not the same size.
Honest and cheap: when `(rest (scope-stores scope))` is non-nil, have
`%record-json` omit `superseded-by` and rename `current` to
`current-in-store`. Correct: give `recall` a `:scope` and build the
`%series-key` table over the union of the scope's `claims-touching`
answers, keeping each record's store.

**Local or design: design.** The cheap fix is local to
`agent/render.lisp`, but it only stops lying. The correct fix forces
Q1 below: if a series may span stores, no writer can ever close the
older run (GH #53), so `current-p` has to be redefined as "not
superseded anywhere in scope" rather than "still open here".

---

### R2 (A3 + B5) — a decision id carries no store, and `mem:trace` looks in one

**Class D via B.** `memory/trace.lisp:274-289` (`decisions-citing`
returns bare id strings, unioned over the scope); `:206-216` (`trace`
resolves the decision with `(%decision-claims graph id)` — `:scope` is
used *only* for evidence cites); `:258-272` (`trace-listing`
dereferences the result unconditionally);
`agent/annotate.lisp:48-55` and the call at `:134-135`.

**Scenario.** No identity collision needed. A decision recorded in `P`
cites a claim; `(mem:decisions-citing W cite :scope (list W P))`
returns `P`'s id — the union at `:279-282` is over every store in
scope. `(mem:trace W id :scope (list W P))` returns **NIL**, because
`%decision-claims` at `:180` asks `W` alone and `outcome` at `:211` is
NIL. `(mem:trace-listing W (list id) :scope (list W P))` then calls
`(decision-record-outcome NIL)` at `:264` and signals a type error.

The composition is live. `annotate-banners` (exported) runs
`%newest-decision-by` with `graph` = `(first stores)` and `scope` =
all stores; the loop body evaluates `(mem:decision-record-producer
rec)` at `:52` before any guard, so the first id from another store
aborts the pass. Reachable with the public API only: capture one dir
into both stores (`capture-memory-dir` derives every identity
component from the file — `capture.lisp:173-207` — so both stores mint
the same cite), run `annotate-banners (list P W) dir` once so a
decision citing the banner's `annotates` cite lands in `P`, then run
`annotate-banners (list W P) dir` with a model that declines. The
declined path has no shield: the `conclude` path is masked only by
`decisions-citing` being newest-first, so this run's own decision in
`W` sorts ahead and the loop returns before reaching `P`'s id.

**Documented contract violated.** `docs/agent-tools.md:471-472`:
"**NIL is a normal outcome, not an error**".

**Test gap.** None. Both annotate tests capture into `w` and leave `p`
empty (`tests-agent/annotate-tests.lisp:69-70`, `:201-202`), so
`decisions-citing` never returns a foreign id — and
`annotate-banners-reports-a-declined-note-as-nil` (`:200`) is exactly
the path that would crash if `p` held one.
`tests-memory/store-tests.lisp:118-121` asserts the union's ids and
never traces one. The counter-evidence that this is a gap rather than
a choice is inside the agent layer: `%find-decision`
(`agent/memory-tools.lisp:43-47`) exists purely to recover the store
the memory API dropped, and `docs/agent-tools.md:176` documents the
*tool* as "Found in whichever store of the scope holds it".

**Smallest fix.** `decisions-citing` returns `(id . store-name)` pairs
(or a second value); `trace` accepts a store, or searches `scope` for
the id the way `%find-decision` already does; `trace-listing` survives
a NIL `trace`; `annotate.lisp:50` resolves the store before tracing.

**Local or design: local.** Four functions, no semantic decision. (It
touches B6's territory — "the first store that answers" — but the
replica case is a separate question.)

---

### R3 (B2) — `retract` refuses a belief the write store holds, because `recall` moved the cache

**Class D with B.** `agent/scope.lisp:50-51` (`note-cite`, an
unconditional `setf`) against `:53-63` (`cite-store`, whose fallback
scan is first-in-scope-order); `agent/memory-tools.lisp:24-28` (recall
notes every row of every store, in scope order); `:221-225` (retract
consults `cite-store` and errors when the answer is not the write
store).

**Scenario.** Scope `(W P)`, write store `W`, both stores holding the
identical belief — the fixture
`tests-agent/memory-tools-tests.lisp:487-490` already builds, whose
own control at `:498-499` asserts "one cite names the copy in either
store". The model calls `recall`; the loop notes `W`, then overwrites
with `P`. The model calls `retract{cite}` meaning the copy it may
retract, and gets `store memory-private is not writable in this
scope` while `W` holds a live, current, retractable claim on that
cite.

**Evidence the inversion is decided by history, not data.** Retract
blind (no `recall` first) *succeeds* — `cite-store`'s fallback scan at
`:58-63` returns the first store, `W`. Build the scope as `(P W)` with
`:write-store W` and it also succeeds, because `recall` then ends on
`W`. Same data, same cite, same intent, opposite outcome. `retrieve`
pushes it the other way again: `%evidence-json`
(`agent/planner-tools.lisp:41-44`) notes the cite against the *first*
store, so the two read tools disagree and whichever ran last decides
what `retract` and `conclude` do.

**Doc.** `docs/agent-tools.md:264-266`: "A cite that resolves to a
store elsewhere in scope is an error result". The word "resolves" does
work the code does not do — a cache hit is not a resolution. Spec §6
(`:243-245`) describes the cache as "the store it was found in ... a
cite it has never returned is resolved by searching the scope, first
hit wins", which presumes one cite denotes one store.

**Test gap.** `retract-acts-on-the-write-store-only`
(`tests-agent/memory-tools-tests.lisp:308`) puts *different relations*
in the two stores (`ci-status` in `w`, `owner` in `p`), so the two
cites differ and the cache is never ambiguous; it also never calls
`recall` before `retract`.

**Smallest fix.** `note-cite` should not overwrite — `(unless
(nth-value 1 (gethash cite (scope-cites scope))) (setf ...))` — which
at least makes the cache agree with `cite-store`'s own fallback rule
and lets the write store win whenever it is first in scope.

**Local or design: the patch is local, the repair is a design
question.** Spec §2 rules "The model names subjects, never stores", so
the tool vocabulary has no way to name a `(store, cite)` pair even
though `recall`'s rendering shows the model that two exist. See Q2.

---

### R4 (B3) — `retrieve` collapses one identity held by two stores into one item

**Class D, consequence in A.** `claims/source.lisp:114-124`
(`%claim-doc-id`: subject endpoint, relation, object endpoint,
producer — no store) and `:60-73` (`render-claim` — no store either);
fused by `rag/hybrid.lisp:10-13` (`%chunk-key` = `(document-id .
text)`) and `rag/bundle.lisp:124-175`; the store is attributed
downstream from the surviving representative by
`agent/planner-tools.lisp:22-27,41-44`.

**Scenario.** `W` and `P` both hold `(:repo . "cl-llm")
--ci-status--> (:verdict . "green")`, same producer, same validity
start — the fixture at `memory-tools-tests.lisp:487-490`, or simply
one memory dir captured into both stores. `%claim-sources`
(`planner-tools.lisp:14-20`) builds one claim source per store. Both
copies produce byte-identical `document-id` **and** `text` (the
rendered extent is day-granularity, `%extent-line`), so `%chunk-key`
collides.

Three consequences, all verified in the code:

1. `reciprocal-rank-fusion` keeps one representative, "taken from the
   FIRST list it appears in" (`hybrid.lisp:17,23-25`), so the item's
   `"store"` is `cl-llm-memory` alone. `docs/agent-tools.md:302-305`
   says each evidence item "names its `store` when it came from one";
   here it names one of the two it came from, with nothing saying a
   second answered.
2. `%evidence-json` then charges that cite to the first store
   (`planner-tools.lisp:44`) — the opposite of the store `recall`
   leaves in the cache for the same cite (R3).
3. RRF **sums** (`incf`, `hybrid.lisp:24`), so a claim held by both
   stores scores twice. Concretely: `W` returns `[Y(1), X(2)]`, `P`
   returns `[X(1)]`; `X` scores `1/62 + 1/61 = 0.0325` against `Y`'s
   `1/61 = 0.0164` and displaces it, though `Y` outranked `X` in the
   only store where both live. Being in two stores is not relevance,
   and the reordering is invisible in the output.

**Test gap.** None. Every planner test seeds *distinct* claims per
store (`%seed-two-stores`,
`tests-agent/planner-tools-tests.lisp:6-9`). The asymmetry is the
proof the omission was not considered: `%absence-evidence` puts the
graph name in its document id on purpose — "so two stores' absences of
the same endpoint fuse to two items, not one"
(`claims/source.lisp:130-131`) — and that is pinned at
`planner-tools-tests.lisp:82-93`. Absences are store-tagged, present
claims are not. `memory-tools-tests.lisp:506-509` *knows* about the
collapse and uses it only as a hostile precondition for a `trace`
assertion.

**Smallest fix.** Append the store to `%claim-doc-id` exactly as
`%absence-evidence` does. One format string.

**Local or design: local**, with one contract consequence worth
stating out loud — the model then sees two items whose `text` is
identical and whose `store` differs, which is the truth and is what
`recall` already shows it.

---

### R5 (A9 + B4) — `conclude` validates one store, so a scope duplicate is accepted

**Class E.** `agent/memory-tools.lisp:171-184` passes
`(scope-write-store scope)` and nothing else into
`memory/trace.lisp:151-162`, whose only check is
`(gdb:validate-transaction graph)` at `:154`. The constraints behind
it are declared per graph name: `def-unique ... ,graph-name`,
`spacetime/claim.lisp:424-427` (verified).

**Scenario.** Scope `(W P)`, write store `W`.
*Case 1* — `W` already holds the belief at validity start `T`; the
model concludes the same subject/relation at the same `valid-from`;
`belief`'s `:unique` identity tuple is violated and the model reads
`{"outcome": "refused"}`. That is precisely
`retract-then-conclude-at-the-same-valid-from-is-refused`
(`memory-tools-tests.lisp:326`).
*Case 2* — the identical prior belief is in `P` instead, in scope and
returned by `recall`. `%current-predecessor` finds nothing in `W`,
`validate-transaction W` sees nothing, the write commits, and the
model reads `{"outcome": "concluded", "refusals": []}`.

Same model action, same scope contents, opposite result, nothing in
either saying which store decided it. The tool's own description says
"The write is validated before it commits"
(`agent/memory-tools.lisp:149-150`); it is, in one store of several.
The resulting state is the generator for R1, R3, R4 and R6.

**Why this is Real and not Documented (regrading A9).** The doc's
words are spec §2 lines 81-83: "cross-store *writes* need the deferred
two-phase commit (kraison/vivace-graph#93), which is why a tool set
writes to one store only." That documents *placement*. Nothing in
`docs/agent-memory.md`'s "Several stores" (`:190-203`), in
`docs/agent-tools.md`, or in the spec says that the validator is
therefore blind to the rest of the scope, or that the scope may end up
holding two claims with one identity key and one cite. Read the other
way — §2 sells the scope to the operator as one memory partitioned by
trust — the reader takes consistency to be scope-wide. A9 called the
doc "half true"; the half that is missing is the half that has
consequences, so the finding is a defect, not a documented limit.

**Test gap.** None. No test constructs case 2; every conclude test
writes a subject/relation the other store does not hold.

**Smallest fix.** A pre-write scope read, before `with-transaction`
opens — the only place a second store may legally be read (the same
discipline `conclude` already applies to `%evidence-of` at
`trace.lisp:146-147`, and see A8). Run the proposal's `(producer,
subject, relation)` series across the rest of the scope and either
refuse with a synthetic `"scope"` family or report the conflict
alongside `"concluded"`.

**Local or design: design.** Refusing changes what the tool set
promises the operator; reporting-and-writing changes what
`"concluded"` means. Both answer Q1.

---

### R6 (A4) — `%write-evidence` de-duplicates evidence by cite alone

**Class D.** `memory/trace.lisp:93-94`:
`(remove-duplicates pairs :key #'car :test #'string= :from-end t)`.
The pair is `(cite . store-name)`; the key is only the cite.

**Scenario.** `(mem:conclude W proposal :evidence (list in-w in-p)
...)` where `in-w` and `in-p` are the two stores' copies of one
belief. `%evidence-of` (`:77-88`) resolves each to its own store
correctly, producing `("…" . "cl-llm-memory")` and
`("…" . "memory-private")`; the dedupe then writes exactly **one**
evidence claim, naming the working store. The decision's record says
it rested on one store's copy when it rested on both, `trace` reports
one evidence item, and a `decisions-citing` filtered by store (were R2
or A2's fix applied) would not find it from the private side.

**Reachability.** `mem:conclude` is exported
(`memory/packages.lisp:45`) and its `:evidence` docstring advertises
claims as an input; `in-w`/`in-p` is the harness shape at
`memory-tools-tests.lisp:487-490`. Not reachable through the tool
surface — `%evidence-pairs` maps each cite to exactly one store — so
it is the direct API caller who hits it.

**Test gap.** None; `tests-memory/trace-tests.lisp` and
`store-tests.lisp` never pass two claims sharing a cite.

**Smallest fix.** Dedupe on the pair (`:test #'equal` over the whole
pair). One line.

**Local or design: local.** The comment at `:91-92` intends first-wins
by analogy with `%violation-families`, but that rule is keyed on a
violation's whole identity, whereas here the identity is the pair —
a mis-keyed intent, not a decision.

---

## Confirmed Latent findings

**A5 + B7 — `store-name` (class F).** `memory/schema.lisp:49-51` is
`(string-downcase (symbol-name (gdb:graph-name graph)))`, and every
store-shaped thing funnels through it: `conclude`'s evidence stamping
(`trace.lisp:146`), `%claim-store` (`:70-75`), `%store-in-scope`
(`:189-190`), `agent:find-store`, `%record-json`, and the prolog
tool's `%find-store`. Two halves, both verified. (i) The engine's
registry is EQUAL-keyed and documents its keys as "name (symbol or
string)" (`store-registry.lisp:12-15`, exact), and `*graphs*` is
EQUAL-keyed (`graph-class.lisp:3-12`), so a string-named store is a
legal engine object on which `symbol-name` signals a type error before
anything is written. (ii) `:CL-LLM-MEMORY` and `:|cl-llm-memory|` are
distinct keywords that downcase to one string; since
`%register-open-store` interns on the name object
(`graph-class.lisp:55`) and only raises `store-id-collision-error`
when the *same* store id is claimed by a different name or location
(`:58-66`), nothing refuses the pair, and thereafter `%store-in-scope`
and the evidence `method` slot cannot tell the two stores apart —
first-in-scope wins, silently. `make-scope` (`agent/scope.lisp:25-41`)
validates graph-ness, write-store membership and the caps, never name
distinctness. Latent because every harness names its graphs with
distinct keywords. Fix: `(string-downcase (string (gdb:graph-name
graph)))` plus one distinctness check in `make-scope`, which turns a
silent wrong answer into a construction-time `scope-error` — where
every other scope invariant is already caught.

**A6 — `%claim-store` conflates "cannot resolve" with "the write
store" (class B/D).** `memory/trace.lisp:70-75` takes only the first
value of `graph-db::resolve-node-graph`, which actually returns
`(values GRAPH STATUS STORE-ID)` with STATUS `:resolved`, `:detached`
or `:unknown` (`interface.lisp:7-20`, verified verbatim). `%evidence-of`
(`:77-88`) then reads NIL as "use `write-store`". Hold a claim read
from the private store, close that store, `conclude` citing it: STATUS
is `:detached`, and the evidence claim is stamped `"cl-llm-memory"`
permanently, in the claim's own `method` slot. Re-open the private
store later and `trace` resolves that cite against the **working**
store — `:absent` if it lacks the identity, and `:resolved` against
the wrong half when both stores hold the belief identically, defeating
what `memory-tools-tests.lisp:481` was written to guarantee. Latent
because it needs a closed or detached store, which the agent scope (all
graphs open) does not produce; `store-tests.lisp:103-121` proves only
the `:resolved` path. Fix: bind all three values; on `:detached` use
the registry's name for the tag, on `:unknown` signal a
`belief-argument-error` — the ruling the agent layer already applies to
cites ("never silently charged to the write store",
`agent/memory-tools.lisp:116-118`).

**A8 — the scope readers have no transaction guard (class G).**
`memory/trace.lisp:206`, `:258`, `:274`, `:192-204` and
`memory/cite.lisp:98` never look at `gdb:*transaction*`, though
`conclude` does (`:139-141`) for its own reason. A caller batching a
write and a read-back — `(gdb:with-transaction (:graph W) …
(mem:trace W id :scope (list W P)))` — gets
`cross-graph-transaction-error` out of the engine
(`transactions.lisp:319-324`, verified) from a function whose
docstring says nothing about transactions. Latent: no in-repo caller
does it (`capture-memory-dir`'s transaction wraps single-graph work
only, `capture.lisp:224-227`) and the failure is loud rather than
wrong. The correct-by-construction counter-example is worth keeping:
`conclude` computes its evidence pairs at `trace.lisp:146-147`,
**before** `with-transaction` opens at `:151`, precisely so
`%claim-store`'s cross-store scan happens outside the transaction —
which is also where R5's pre-write scope read would have to live. Fix:
one sentence per docstring, or the same `*transaction*` check
`conclude` makes.

**B6 — decision ids are assumed globally unique and `%find-decision`
takes the first store that answers (class B/D).**
`agent/memory-tools.lisp:43-47` is a `find-if` over `scope-stores`
with `:limit 1`, used by the trace tool (`:57-58`) and to label every
row of `decisions-citing` (`:99-101`); the union feeding it does not
dedupe (`memory/trace.lisp:279-282`). Ids are 128 random bits
(`trace.lisp:13-14`), so the risk is copying, not collision: if `P` is
a snapshot, replica or restored backup of `W` — a shape spec §2 itself
names ("operations (backup, retention, sharing)") — `decisions-citing`
returns one id twice and labels both `cl-llm-memory`, and `trace`
silently reconstructs `W`'s copy even when the caller meant `P`'s. The
assumption is stated outright in `docs/agent-tools.md:176-177`
("decision ids are random and unique"), which is why it stays Latent
rather than Documented: the doc names the premise but not the shape
that breaks it. Fix: dedupe on `(id . store)` and let `%find-decision`
return all matches, or rule a replica-in-scope out of contract in that
same sentence.

**B8 — the query tool closes over its own store list (class F).**
`agent/prolog/query.lisp:37,56` takes a bare `stores` list and
re-implements the lookup as `%find-store` (`:30-35`), while
`agent/scope.lisp:43-48`'s `find-store` is written, exported
(`agent/packages.lisp:17`) and — verified by grep over the whole tree —
**never called by anything**. An operator who builds an
untrusted-input session as `(make-agent-tools (list W) :producer p)`
and separately `(make-query-tool (list W P))` gives the model one tool
set that cannot see `P` and one that can walk every `belief` and
`trace` vertex in it. `docs/agent-tools.md:84-87` states the mechanism
("each close over their own scope") as a property rather than a
hazard. Latent and the weakest kept finding — no shipped call site
makes the mistake, and it is an operator error, not a defect; it earns
its place only because the exported, unused `find-store` shows a
scope-aware version was intended. Fix: give `make-query-tool` a
`scope`, or a constructor that returns it alongside the eight.

**B9 — namespace keywords are image-global with no per-store
vocabulary (class H).** `agent/render.lisp:28-32` (`%find-keyword`,
read path) and `:44-50` (`%keyword`, write path), consumed by
`agent/memory-tools.lisp:19-21` and `agent/planner-tools.lisp:6-12`.
`recall` interns `"repo"` once and asks every store about `:REPO`,
merging the answers into one list whose only discriminator is the
`store` field per record — and in `retrieve`, per R4, not even that. If
`P` uses `(:repo . …)` for customer repositories and `W` for source
repositories, the model is expected to infer the split from store
names; nothing declares, per store, which namespaces it owns. I
re-ran B's leak check and agree there is none: an unknown namespace
reads as an empty array whether or not the keyword happens to be
interned, and `decisions-citing` distinguishes only
canonical-but-unknown (empty) from uncanonical (error), so a model in
the untrusted scope learns nothing about the private store's
vocabulary. The bite is interpretive. The design decision is explicit
— "Topic is the subject namespace, not the container" (§2) — so the
gap is that nothing records or checks which stores are entitled to a
namespace. A per-store declared namespace list on
`define-memory-store` would make the drift checkable at construction.

---

## Confirmed Documented findings

**A7 + B10 — no cross-store consistent instant, and `trace` applies
the deciding store's clock to another store's history (class C).** The
doc's own words, `docs/agent-tools.md:496-498`: "**No cross-store
consistent instant.** Reads run per store and merge; one epoch
spanning several stores at once is S6b's job (`#24`), not this one's",
echoed by spec §2 (`:80-81`) and §12 (`:411-412`). **Still true, and
the merge half is honest** — `recall`'s ordering keys are validity
start (asserted domain time, comparable by construction) and then
`recorded-at`, with the genuine cross-store tie pinned to scope order
by `recall-breaks-a-genuine-cross-store-tie-by-scope-order`
(`memory-tools-tests.lisp:98`), which asserts both `(w p)` and `(p w)`
orderings on a fixture with equal validity start *and* equal
`recorded-at`. But the doc describes a *missing* capability and
understates one that is present and used: `memory/trace.lisp:250-255`
passes `at = (%recorded-instant outcome)` — the **deciding** store's
`recorded-at` — into `%resolve-in`, which hands it to `resolve-cite`
for a *different* store. I verified the engine premises. `:AS-OF` is a
wall-clock TIMESTAMP on the transaction axis, and the engine is
explicit that "No argument or result is an epoch; the mapping is the
per-version stamp in the claim's own data, so replicas answer from
their own applied history" (`spacetime/claim-query.lisp:239-247`);
`%st-now` is "LOCAL-TIME:NOW, strictly monotonic per image"
(`spacetime/claim.lisp:226-238`). Within one image that is one clock
across all its stores, so A's candidate 1 is correctly refuted and the
ordinary case is sound. What survives is the **cross-image residue,
which is Latent**: a store is single-process
(`docs/agent-memory.md:295-296`) and the deployment is one long-lived
image per store, so the private store's history was stamped elsewhere.
A private belief stamped 12:00:03 by a host 3 s fast, cited by a
working-store decision recorded at 12:00:01, resolves `:absent` — "not
yet created" — and `trace` reports the decision as resting on nothing,
with no marker distinguishing that from a genuinely missing claim. No
test can catch it: both stores in every harness are written by the one
test image, which is the single configuration where it cannot fail.
Smallest honest step now: one sentence in the `trace` section saying
the as-of instant is the deciding store's. When `#24` lands a real
cross-store read instant, `trace` is its first consumer and the
`cite-record` should carry which axis the as-of was taken on.

**A10 — evidence that names no store resolves in the deciding store
(class B).** `memory/trace.lisp:192-204` (`%resolve-in`'s `graph`
branch) and `:81` (`%evidence-of`: a bare cite string means the write
store). The doc's own words, spec §4.3 as quoted at `:234-237` and
§4.2, are exact: "a cite whose evidence claim names no store (unit 1
data) is resolved in `graph`", and `conclude`'s evidence accepts "a
cite string (store = the write graph)". **Still true**, and the
residual risk — a bare cite for a claim living elsewhere being charged
to the write store — is closed at the tool surface by `%evidence-pairs`
(`agent/memory-tools.lisp:115-122`), which resolves every cite through
`cite-store` and errors when it is not in scope, pinned by
`conclude-signals-on-an-evidence-cite-out-of-scope`
(`memory-tools-tests.lisp:396`). A direct `mem:conclude` caller still
gets the documented fallback. Worth one sentence in `resolve-cite`'s
docstring — the one `cite-record`'s already has, that the store is the
caller's to know — since the function will resolve a two-store cite
against whatever graph it is handed and report `:resolved`.

**B11 — an out-of-scope evidence cite is indistinguishable from a
deleted one (class B/F).** `memory/trace.lisp:199-204` returns a bare
`:absent` record with no store when `%store-in-scope` misses. The
doc's own words, `docs/agent-tools.md:182-186`: "A cite naming a store
the tool set was not built with reports `state: \"absent\"` and
carries **no `store` key at all** — never falling back to the
decision's own store, which would falsely suggest it was found."
**Still true**, and pinned unusually well by
`trace-omits-store-for-an-out-of-scope-evidence-cite`
(`memory-tools-tests.lisp:178`), which asserts both the state and the
*absence of the key* (`:192`, `(not (nth-value 1 (gethash "store"
ev)))`) rather than a null. The residual is that `:absent` is also
what a cite gets when the store **is** in scope and the claim is
genuinely gone (`memory/cite.lisp:118-119`), so a model reading a
trace cannot tell "you did not open the store this evidence lives in"
from "this evidence no longer exists" — the first is the operator's
fault and recoverable, the second is a fact about the memory. Fix: a
third `state`, `:out-of-scope`, set on the `%store-in-scope` miss.
Small and local, but it changes a rendered enum, so it is a contract
change on the tool's output.

---

## Refuted

**A2 — "`decisions-citing` unions on the cite string and ignores the
store each evidence claim recorded" (offered as Real).**

The mechanism A describes is real: `memory/trace.lisp:278` throws away
the store of a claim argument via `%cite-of`, and the union at
`:279-282` matches every evidence claim in scope whose object key is
that cite, never consulting `st:claim-method`. I re-derived it and it
holds. What does not hold is that this is a *wrong answer*:

1. **It is the specified contract, in the spec's own words.** Spec §6
   (`docs/superpowers/specs/2026-09-03-agent-tools-design.md:237`):
   "`decisions-citing` unions the stores." The docstring says the same
   ("unioned over every store in SCOPE (SS4.3)"), and
   `docs/agent-tools.md:198-200` renders it as "Every decision anywhere
   in scope whose evidence cites the claim".
2. **A cite is store-free by construction, verified in the engine.**
   `claim-identity-key` (`spacetime/claim-query.lisp:29-58`) carries
   producer, endpoints, relation and the extent start — no store, no
   node id. So "the decisions citing this cite" is a well-formed
   question with exactly the answer the function gives.
3. **The contrast with `trace` is not a contradiction.** `trace`
   resolves a *stored* pair — the evidence claim records both the cite
   and the store it was found in — so there the store is data.
   `decisions-citing` is handed a cite (from the tool, always) with no
   store; matching the argument claim's store against the recorded
   `method` would decide that a decision citing `B`'s copy does not
   cite `A`'s copy, which is the open question, not a settled
   invariant. A's own proposed fix would leave
   `store-tests.lisp:118-121` passing only by accident.
4. The harder variant A offers — two corpora whose note names collide,
   giving one cite two meanings — is genuine but is not about
   `decisions-citing`. It is the general cite-ambiguity hazard that
   already appears as R3 and R4, and it needs a shape not yet
   constructed.

**Verdict: REFUTED as a Real finding.** The residue is not a defect in
this function; it is design question Q2 below, which A2 states well and
which the confirmed Real findings force anyway.

### Candidates both auditors refuted, spot-checked and agreed

I re-checked the load-bearing ones rather than all twenty. `conclude`
does compute its evidence pairs at `trace.lisp:146-147`, before
`with-transaction` opens at `:151` (so no class-G path there);
`%current-among` (`cite.lisp:88-96`) draws its candidates from one
graph, so it cannot pick the wrong store's half; `%mint-id` is 128
random bits; `%evidence-pairs` does refuse an out-of-scope cite; and
`recall`'s cross-store tie-break is genuinely pinned in both scope
orders. A's candidate 2 (an undeclared second store answering silently
empty) and candidate 3 (two open graphs under one name) are correctly
refuted — the second one only for the same-spelling case, which is why
the type-distinct spelling survives inside A5 + B7.

### A verification note on citations

Auditor A's line numbers into `tests-memory/` are drifted by roughly
+47 throughout (`store-tests.lisp:96` for a test at `:43`, `:156` in a
153-line file). The substance of every one of those claims checks out
at the real line; the numbers do not. A's citations into `memory/*.lisp`
and into the engine, and all of auditor B's citations, were accurate
everywhere I checked them.

---

## What the pass says about S6b's design

The six confirmed Real findings are not six bugs. They are three
questions the S6a code answered locally, in four places, with three
different answers.

### Q1. Is a `(producer, subject, relation)` belief series a cross-store object?

Forced by R1 (supersession computed per store) and R5 (the validator
sees one store). The engine has already ruled out the obvious answer:
GH #53 means no transaction on `B` may close a claim in `A`, so a
cross-store series can never be *closed*, only *observed*.

- **(a) Yes, and supersession is read-time.** `recall` takes a
  `:scope` and computes `%successor` over the union; `current-p`
  is redefined as "not superseded anywhere in scope", never "still
  open here"; a superseded claim keeps an open `valid-to` forever, and
  the JSON has to say so. `conclude` gains the pre-write scope read
  (the only legal place to read a second store is before its
  transaction opens — `trace.lisp:146-147` already establishes the
  pattern) and reports the conflict rather than refusing it.
- **(b) No, a series belongs to one store.** Then the tools must
  *refuse* a write whose series already lives in another store —
  again in that pre-transaction window — and `recall`'s merged output
  must stop presenting two stores' answers as one list, or at least
  stop calling either of them `current`.
- **(c) Neither: stop claiming a scope-level answer.** Rename the
  field `current-in-store`, omit `superseded-by` whenever the scope is
  wider than one store, and let the model see that the question is
  per-store. Cheapest, honest, and forecloses nothing.

Note that (a) and (b) disagree about what S6b is *for*: (a) makes the
scope one memory, (b) makes it several memories read together.

### Q2. Is a cite resolvable without a store?

Forced by R3 (the cache's last-wins vs the scan's first-wins), R4 (the
fusion identity), R6 (the evidence dedupe) and the refuted A2. Verified
fact: `claim-identity-key` carries no store, so today one cite can name
two claims, and four consumers each guess differently — `recall`
records the last store, `retrieve` the first, `cite-store` the first in
scope order, `trace` the store its evidence claim recorded (the one
place the ambiguity was found and fixed).

- **(a) A cite denotes a belief, store-free.** Then every operation
  that acts on *a claim* — `retract`, `conclude`'s evidence,
  `decisions-citing` — needs a store alongside the cite, and the model
  must be allowed to name a store. That contradicts spec §2's "The
  model names subjects, never stores", so it is a rule change, not a
  patch.
- **(b) A cite denotes a claim in a store.** The rendered cite gains a
  store prefix, `claim-cite`/`split-cite` change contract, `%chunk-key`
  and `%claim-doc-id` inherit the store for free, and the four guessing
  rules collapse into one. Most invasive; also the only option that
  makes the four consumers agree by construction.
- **(c) Keep the cite store-free and make the *guess* uniform.** One
  rule — first store in scope order, cache never overwriting — applied
  everywhere, plus the store rendered next to every cite so the model
  can see when two exist. Cheap, and it converts R3 from a wrong signal
  into a deterministic one, but it leaves R4's fusion collapse
  untouched.

### Q3. What does the shared clock buy the merge order — and on whose axis does a cross-store `trace` resolve?

Forced by A7 + B10. Within one image `%st-now` is one monotonic clock
across every store it holds, so the merge order and the as-of
resolution are sound *today* and the documented limit is honest. But
`trace` already does more than the doc admits: it evaluates store `B`'s
transaction history at store `A`'s timestamp, and stores are
single-process, so in the real deployment `B`'s stamps were minted by
another image — possibly another host.

- **(a) Declare the shared clock a precondition of a scope** — every
  store in a scope must have been stamped by images sharing one system
  clock — document it, and check nothing.
- **(b) Carry the axis on the record.** When `#24` gives the scope a
  cross-store read instant, resolve each store under its own
  `call-with-read-snapshot` and put the per-store instant on the
  `cite-record`, so the answer says which clock it was taken on.
- **(c) Do neither, and add the one sentence** to
  `docs/agent-tools.md`'s `trace` section saying the as-of instant is
  the deciding store's — which at least makes the limit checkable.

The choice matters more than it looks: (a) is a constraint on
deployment, (b) is the first real consumer of the cross-store read
instant `#24` is supposed to deliver, and (c) is the honest holding
position until one of them is chosen.
