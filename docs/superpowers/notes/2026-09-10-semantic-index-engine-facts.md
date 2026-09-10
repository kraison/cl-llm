# Engine facts for the semantic endpoint index (#78)

**Spec:** `docs/superpowers/specs/2026-09-10-semantic-memory-indexing-design.md`
(§2.5, §4, §8).  **Date:** 2026-09-10.

**Sources.**  Engine: a clean clone of `experiment` at b787516 (read
only).  cl-llm: this worktree at 44844ff.  Line numbers are those
trees.  **Probes:** two foreground SBCL 2.6.6 runs, one process at a
time, against a source registry naming that clone (a copy of
registry-72 pointing at this worktree), scratch store `/tmp/x78/`
(deleted afterwards).  The probe loaded `cl-llm/memory` and
`cl-llm/rag/claims`, made a `:cl-llm-memory` store under the current
schema, closed it, then evaluated the spec's `def-vertex` (plus a
`def-index` and a `def-unique` on `(ev-namespace ev-key)`) and
reopened.  Outputs below are verbatim; "unverified" means not probed.

---

## E1. Adding a vertex class to an existing store

**Claim.**  A store created before `endpoint-vector` existed opens
under the new schema, gets the class as a new type of its own, and
accepts writes of it.  No migration step.

**Evidence.**  `def-vertex` (schema.lisp:812) expands to `def-node-type`
whose `%install-node-type` (schema.lisp:733-762) registers the meta
under the graph name, appends a manifest row, and instantiates into
the store only if it is already open.  `open-graph` calls
`update-schema` (graph.lisp:911), which walks every registered meta
for the graph name and calls `instantiate-node-type` (schema.lisp:
1115-1137).  A meta the store has never seen takes the "new TO THIS
STORE" branch: a registry type id, a class lock, `update-node-type`
(schema.lisp:1090-1107).  The manifest row is re-asserted on open
(schema.lisp:1054-1058).  `restore-vector-segments` runs after that
(graph.lisp:953) and skips an owner with no nodes (graph.lisp:259,
gate at 180).  cl-llm's stores are all made or opened through
`gdb:make-graph`/`gdb:open-graph` after the load-time
`(define-memory-store :cl-llm-memory)` (memory/schema.lisp:47;
harness: tests-memory/harness.lisp:16, tests-agent/harness.lisp:31,
agent/mcp/config.lisp:36-40, scripts/memory-image.lisp:90-94), so the
declaration always precedes the open, which is the ordering
vivace/schema.lisp:15-24 says a persisted class needs.

**Probe.**
```
[E1 types before] => (MEMORY-BANNER MEMORY-NOTE TRACE-BINARY TRACE-UNARY
                      TRACE ...)          ; no ENDPOINT-VECTOR
[E1 type after reopen] => (ENDPOINT-VECTOR 9)
[E1 manifest raw row] => (:TYPE ENDPOINT-VECTOR :KIND :VERTEX ...)
[E1 search before any write] => NIL ; :NO-SEGMENT-YET
[E1 write of the new class] => ENDPOINT-VECTOR
```

**Unverified.**  The reverse: an image WITHOUT the class (an older
cl-llm) opening a store that already holds `endpoint-vector` rows.
vivace/schema.lisp:15-24 says the open needs the class; treat a
rollback across that line as a question for the plan.

**Implication.**  Phase 1 can put the `def-vertex` in
`define-memory-store` and ship; every existing store adopts it on its
next open.

## E2. Clearing the vector slot on update removes the segment entry

**Claim.**  On a `tx-update`, a slot value that is not a
`(simple-array single-float (*))` -- unbound or NIL alike -- removes
the node's entry from the owner segment.

**Evidence.**  `apply-tx-write-to-vector-segments ((write tx-update))`
(transactions.lisp:1872-1884): `%node-segment-value` (1605-1610) reads
the slot under `ignore-errors` and returns NIL unless
`%conforming-vector-p` (1601); a NIL value takes the `segment-remove`
branch (1880-1884).  The validator skips a NIL value entirely
(1665-1695), so clearing never trips the dimension check.  The engine's
own test uses `(setf (slot-value v 'embedding) nil)` then `save`
(tests/segment-integration-tests.lisp:113-126).

**Probe.**  Copy, clear, save, then search (k=5, same query that hit).
```
[E2 slot-makunbound + save] => T
[E2 slot after makunbound] => (NIL NIL)       ; slot-boundp, value
[E2 search after makunbound] => NIL ; :OK
[E2 live count] => 0
[E2 search after restore] => ((1.0 . #(...)))
[E2 setf nil + save] => T
[E2 search after nil] => NIL ; :OK
[E2 slot after nil] => (T NIL)
```

**Implication.**  Either idiom works; the dirty predicate must test
"holds a conforming vector", not `slot-boundp`, because a
`makunbound` reloads unbound while NIL reloads bound.

## E3. Dropping and recreating a segment with a new dimension

**Claim.**  There is no exported drop.  An empty segment keeps its
dimension, on disk and across a clean reopen; the only ways to change
it are (a) delete `vseg-<owner>-<slot>.dat` while the store is closed,
after which the open rebuilds nothing when no node holds a conforming
vector, or (b) the internal `graph-db::rebuild-vector-segment` with
every vector cleared, which is documented unsafe against a concurrent
`vector-search`.

**Evidence.**  Segment file name: `%segment-file` (transactions.lisp:
1612-1617).  Lazy create with the first vector's length:
`%ensure-segment` (1619-1650); an on-disk file that was not registered
is adopted, never overwritten (1633-1647).  Dimension check against a
registered segment: `validate-vector-segment-dimensions` (1665-1695).
`rebuild-vector-segment` (segment.lisp:606-729): closes the old
segment, `remhash`, `delete-file`, and creates no segment when no node
has a conforming vector (652-654, 713-715); its docstring (630-650)
says it is safe only when quiescent.  `restore-vector-segments`
(graph.lisp:202-277): a present clean file is opened as-is (240-244);
a missing file with nodes of the owner type triggers the rebuild
(259-264), which is silent when it creates nothing.  Exports: only
`rebuild-vector-segment-batched` (package.lisp:206), which is additive.

**Probe (run 1, all vectors cleared, segment still registered).**
```
[E3 dim 8 while empty segment is open] ERROR VECTOR-DIMENSION-VIOLATION:
  vector length 8 does not match established segment dimension 4
[E3 segment dimension kept] => 4
[E3 rebuild-vector-segment in process] => NIL
[E3 file after rebuild] => NIL
[E3 table after rebuild] => NIL ; NIL
[E3 dim 8 after in-process drop] => "bad-deploy"
[E3 new segment dimension] => 8
```
**Probe (run 2, clean reopen of the same store, every vector NIL).**
```
[E3 segment after clean reopen (all entries removed earlier)]
  => (:DIMENSION 8 :LIVE 0)
[E3 every endpoint-vector's slot] => (("ledger-rollback" NIL)
                                      ("bad-deploy" NIL))
[E3 dim 16 with empty-but-present segment] ERROR VECTOR-DIMENSION-
  VIOLATION: ... length 16 does not match established segment dimension 8
[E3 delete file while closed] => (T)
[E3 table after reopen without file] => NIL ; NIL
[E3 search with no segment] => NIL ; :NO-SEGMENT-YET
[E3 dim 16 after file drop] => "x"
[E3 dimension now] => 16
```
No warning was printed on the reopen without the file.

**Implication.**  §4.3 step 4 "the sweep drops the segment file
before the first write (an engine operation)" has no safe in-process
engine operation while the image serves `retrieve`: the plan must
either do the drop at open time before the listener starts (delete
the file with the store closed, or call the internal rebuild before
any search can run), or serialise the worker's drop against
`retrieve`'s `vector-search` with a lock of cl-llm's own.  Clearing
every vector is not enough on its own.

## E4. `vector-search`'s return and node resolution

**Claim.**  `(score . id)` conses, best first; SCORE a `single-float`
full cosine (the engine divides by the query norm); ID a 16-byte
`(simple-array (unsigned-byte 8) (16))`.  Second value `:ok`,
`:no-such-class`, `:not-a-vector-index-slot` or `:no-segment-yet`.
`:filter` is a function of that id, called inside the scan before the
vector is read; it never sees a node.  Resolution is
`gdb:lookup-vertex id :graph g`, which returns deleted nodes too.

**Evidence.**  graph.lisp:279-311 (signature and docstring);
segment.lisp:989 `segment-scan`; vertex.lisp:107-125 `lookup-vertex`
on a string or a 16-byte array, "regardless of its deleted flag".
cl-llm's only caller: vivace/store.lisp:527-543 -- `lookup-vertex` on
`(cdr pair)` and a `gdb:deleted-p` filter.

**Probe.**
```
[E4 vector-search] => ((1.0 . #(186 166 78 88 29 242 130 21 139 60 107
                                211 55 40 48 1)))
[E4 hit shape] => (SINGLE-FLOAT (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (16)) 16)
[E4 lookup-vertex on the id] => (ENDPOINT-VECTOR :INCIDENT
                                 "ledger-rollback" "m1")
[E4 filter sees the id] => (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (16))
```

**Implication.**  `nearest-endpoints` maps each hit through
`lookup-vertex`, drops `deleted-p`, and reads `(ev-namespace . ev-key)`
off the vertex; a `:filter` cannot read `ev-model`, so the model
check happens after resolution (or the vector is cleared on a model
change, per E9).

## E5. Unique lookup on a two-slot key

**Claim.**  cl-llm declares no `def-unique` of its own today; the
engine separates enforcement from lookup, so the two-slot key needs
BOTH a `def-unique` (commit-time refusal) and a `def-index` (lookup),
each named.  No derived slot is needed.

**Evidence.**  `def-unique` (unique-constraint.lisp:545-576): "enforced
at commit ... not merely indexed, unlike DEF-INDEX".  `def-index`
(index.lisp:886-908) accepts a slot LIST for a tuple index;
`index-lookup` (994-1013) takes a list VALUE for it; `%require-index`
(977-992) signals `query-precondition-error` unless a `:index` slot or
a `def-index` covers the tuple (a `def-unique` alone is not consulted
there -- from the code, not probed).  The engine's own claim families
declare their identity this way and NAME every declaration, because
an unnamed spec emitted by a macro cannot be replaced by a later
version of that macro (spacetime/claim.lisp:412-427).  cl-llm's
existing lookups are single-slot `gdb:index-lookup` calls over
`def-source` key slots (memory/capture.lisp:68, 88;
memory/banners.lisp:113).

**Forms (the probe's, in `cl-llm.memory`).**
```lisp
(gdb:def-index endpoint-vector (ev-namespace ev-key) ,graph-name
  :name ev-endpoint-index)
(gdb:def-unique endpoint-vector (ev-namespace ev-key) ,graph-name
  :name ev-endpoint-identity)
(gdb:index-lookup g 'endpoint-vector '(ev-namespace ev-key)
                  (list :incident "ledger-rollback"))
```
**Probe.**
```
[E5 index-lookup two-slot] => ("ledger-rollback")
[E5 index-lookup miss] => NIL
[E5 duplicate key refused] ERROR UNIQUE-CONSTRAINT-VIOLATION: Unique
  constraint on ENDPOINT-VECTOR.(EV-NAMESPACE EV-KEY) violated: value
  (:INCIDENT "ledger-rollback") is already held by node baa64e58...
```

**Implication.**  `define-memory-store` gains both declarations, named;
the "created if absent" step in §4.2 is `index-lookup` then
`make-endpoint-vector`, inside the caller's transaction.

## E6. The trace record, `decisions-citing`, `render-claim`

**Claim.**  A decision is a set of `trace-binary` claims with subject
`(:decision . id)`: `"concluded"` -> `(:claim . cite)` (method = rule,
rule-version, confidence), or `"attempted"` -> `(:rule . rule)` plus
`"refused"` -> `(:violation . family)` (method = the report text), and
one `"evidence"` -> `(:claim . cite)` row per cite (method = the store
name).  There is no report text on a concluded decision: its "why" is
the rule name and the cited evidence only.  `decisions-citing` takes a
claim or a cite and returns `(id . store-name)` pairs, newest first.
`render-claim` prints one line: endpoints, relation, producer,
standing, validity days.

**Evidence.**  `%trace-claim` (memory/trace.lisp:62-70); `conclude`'s
writes (233-246); `%write-refusal` (133-153, its own transaction);
`%write-evidence` (92-101); `decision-record` (257-265) and `trace`
(309-372); `decisions-citing` (400-423, `claims-touching ... :role
:object :relation "evidence"`).  `render-claim` (claims/source.lisp:
60-73; extent line 75-83).

**Probe.**
```
[E6 render binary] => "incident:ledger-rollback root-cause
  cause:bad-deploy (claude-code/test, observed, 2026-09-10..?)"
[E6 render unary] => "incident:ledger-rollback postmortem
  (claude-code/test, searched-empty, 2026-09-10..2026-09-10)"
[E6 decisions-citing] => (("16e770c8ec907ce3b933924fe9b23cff"
                           . "cl-llm-memory"))
[E6 trace record] => (:RULE "close-after-fix" :OUTCOME :CONCLUDED
  :EVIDENCE ("cl-llm.memory::belief|claude-code/test|:incident|...")
  :CONCLUSION "cl-llm.memory::belief|...|:status|closed|status|...")
[E6 trace claims of the decision]
  => (("evidence" :CLAIM "cl-llm.memory::belief|..." "cl-llm-memory")
      ("concluded" :CLAIM "cl-llm.memory::belief|..." "close-after-fix"))
```

**Implication.**  §2.2's decision line is rule + outcome (+ the
refusal family texts on a refused one); "its report text" exists only
for refusals.  `decisions-citing` costs one `claims-touching` per
store per belief, so a profile with N beliefs is N such calls; and a
decision is written in `conclude`'s transaction, not the belief
writer's (see the contradictions below).

## E7. The vocabulary walk and one endpoint's current beliefs

**Claim.**  `mem:vocabulary` is count-index backed on both paths after
#70; `vocabulary-endpoints` is the distinct `(namespace . key)` list
in either role.  One endpoint's current beliefs in both roles is a
single `claims-touching` with `:role :either :current t`.

**Evidence.**  memory/vocabulary.lisp:52-76 (`st:claim-namespaces`,
`st:claim-keys`, `st:claim-relations`, all `:counts t :current`),
docstring 85-90: sub-linear, resolves no node once the maps exist;
trap: inside `with-as-of` it walks.  `claims-touching` signature
(spacetime/claim-query.lisp:281-283): `&key (role :either) current at
during relation limit offset as-of as-of-epoch`; `claim-current-p`
(469-474).  Recall's own reads are `:role :subject` without `:current`
and filter afterwards (memory/recall.lisp:83-98); its `current-p` also
requires `%open-p` and no successor (137-138).

**Probe** (a store with three beliefs on one subject).
```
[E7 claims-touching either current] => ("incident:ledger-rollback
  root-cause cause:bad-deploy (...)" "incident:ledger-rollback
  postmortem (...)" "incident:ledger-rollback status status:closed (...)")
[E7 vocabulary endpoints] => ((:INCIDENT . "ledger-rollback")
                              (:CAUSE . "bad-deploy") (:STATUS . "closed"))
[E7 vocabulary time 100x] => 13.001        ; ms, so ~0.13 ms per call
```

**Implication.**  The sweep is `(vocabulary-endpoints (vocabulary g))`
under `with-scope-snapshots`, then per endpoint
`(st:claims-touching g 'belief ns key :role :either :current t)`
filtered by `%open-p` (memory/write.lisp:57-65, unexported) for §2.1's
"current in recall's sense".

## E8. The write path's touch points

**Claim.**  Every belief write runs inside the caller's transaction.
The touch points are: `record-belief`'s supersession close and its
create; `record-absence`'s create (a `belief-unary`); `retract-belief`'s
`st:retract-claim`; and `%assert-from-file`'s retract-then-record.  An
idempotent `record-belief` returns before any write.

**Evidence.**  memory/write.lisp: `record-belief` 103-134 -- idempotent
return 122-123, `%close-validity pred` 127 (a `copy`/`save` of the
predecessor, 84-97), `make-belief-binary` 128-134; docstring 111 "Must
run inside the caller's WITH-TRANSACTION".  `record-absence` 168-187
creates a `belief-unary` whose default extent is an instant (170-173).
`retract-belief` 189-199.  `%assert-from-file` 136-166 (capture path).
The owners of the transactions: `conclude` (memory/trace.lisp:233-246),
the retract tool (agent/memory-tools.lisp:250-251), the capture
(memory/capture.lisp), and the tests' `%belief` helpers.

**Probe.**
```
[E8 absence is open-p?] => (T NIL)      ; claim-current-p, %open-p
[E8 belief is open-p?] => (T T)
```

**Implication.**  The clearing goes at write.lisp:127 (the
predecessor's object endpoint), after 128 (subject and object of the
new belief), after 183 (the absence's subject) and after 199 (the
retracted claim's endpoints); each is already inside the caller's
transaction.  But see the contradictions: an absence is never
`%open-p`, and decisions are written elsewhere.

## E9. The rag embedder

**Claim.**  `embed` returns one `(simple-array single-float (*))` for a
string, a list of them for a list, each L2-normalised by
`as-embedding`.  `openai-compatible-embedder` takes `:base-url`
(required), `:model`, `:api-key` (falls back to `OPENAI_API_KEY`); it
posts to `<base-url>/embeddings` and exposes `embedder-model` only --
no dimension, no floor.  `mock-embedder` has `embedder-dimension`
(default 32) and a NIL model unless given one.  `fallback-embedder`
tries a list in order with a cooldown and inherits the first's model.

**Evidence.**  rag/embed.lisp: type 5; `as-embedding` 28-59; `embedder`
61-62 (`model` slot); `embed` 65-67; openai class 71-77, constructor
79-81, method 111-124; fallback 127-173; mock 176-204.  Exports
rag/packages.lisp:10-12 (`embedder-dimension` is exported but is a
reader on `mock-embedder` only).

**Probe.**
```
[E9 mock embed type] => ((SIMPLE-ARRAY SINGLE-FLOAT (32)) 32 0.99999994)
[E9 mock model / dimension] => (NIL 8)
[E9 openai embedder dimension reader?] => ("m" NIL
                                           "http://127.0.0.1:1/v1/embeddings")
[E9 list input] => 2
```

**Implication.**  `ev-model :type string` refuses a NIL model, so the
configuration must require `CL_LLM_MEMORY_EMBED_MODEL` and the test
embedder must carry a model name.  The dimension is known only from
the first `embed`; the floor (R3, "a field of the embedder
configuration") does not exist on any embedder and must be added --
on the scope, or as a wrapper struct `(embedder model floor)`.

## E10. Threads in the image

**Claim.**  cl-llm uses `bt:make-thread`, `bt:join-thread` and
`bt:thread-alive-p` only; no condition variable, lock or semaphore
anywhere.  `bordeaux-threads` is a dependency of `cl-llm/agent/mcp`
only, not of `cl-llm/memory`.  The image's stop order is listener,
store, clock.

**Evidence.**  agent/mcp/listener.lisp:38 (thread), 44-56
(`stop-listener`: set a flag, join, close the socket), 58-59;
scripts/memory-mcp-client.lisp:52, 79.  cl-llm.asd:314 (`cl-llm/agent/
mcp` depends on `bordeaux-threads`); cl-llm.asd:209 (`cl-llm/memory`
depends on `graph-db/spacetime`, `ironclad`, `babel` only).
scripts/memory-image.lisp `stop` 146-162: `stop-listener`, then
`close-graph :snapshot-p nil`, then `close-system-clock`; pushed on
`sb-ext:*exit-hooks*` at 170 so SIGTERM runs it.

**Implication.**  Phase 3's worker in `cl-llm/memory` adds
`bordeaux-threads` to that system (graph-db already loads it, so no
new code arrives).  `stop` gains `stop-endpoint-indexer` between the
listener stop and the `close-graph`; the worker must be joined, not
signalled, before the store closes, and the stop flag must wake a
worker parked on the condition variable (`bt:condition-notify` under
the same lock).

## E11. The solo server's lifecycle

**Claim.**  `start` opens the scope and builds the server; the process
runs `cl-mcp:run-server` to EOF, then `stop`, then exits 0.  `stop` is
also the exit hook, pushed only after a successful open.

**Evidence.**  scripts/memory-mcp.lisp: `stop` 42-47 (`mcp:close-scope`,
idempotent); `start` 49-77 (`mcp:open-scope` 65-73, `make-memory-server`
75-77); the top level 89-109: hook pushed at 105, `run-server` at 106,
`stop` at 108, `exit` at 109; `%die` 79-87 stops before an abort exit.
`open-scope`/`close-scope` are agent/mcp/config.lisp:42-84.

**Implication.**  Start the worker after `start` returns (line 89's
binding, before 106) and stop it inside `stop` before `close-scope`,
so both the normal exit and the SIGTERM hook order it correctly; a
`%die` path never has a worker.

## E12. The test harness

**Claim.**  The agent suite's fixture is `with-stores (w p)`
(tests-agent/harness.lisp:50-51, two on-disk stores on one clock,
15-48); beliefs are written with `%belief` (62-67); tools are called
with `%call` (94-96).  Today's only injection is `make-agent-tools
... :sources (list ...)`; there is no embedder argument.

**Evidence.**  `make-agent-tools (stores &key write-store producer
sources (k 5) (max-rows 50))` (agent/agent.lisp:14-23) builds a
`scope` (agent/scope.lisp:13-38: `stores write-store producer sources
k max-rows cites`).  `%claim-sources` (agent/planner-tools.lisp:14-35)
builds one `make-key-extractor` per store under the scope snapshot;
`%check-consulted` (47-52) is the refusal.  The stub source pattern:
tests-agent/planner-tools-tests.lisp:199-206 (`%stub-source` with a
`rag:collect-evidence` method), used at 209-211.  The memory suite's
fixture is `with-memory-graph (g)` (tests-memory/harness.lisp:26-27).

**Implication.**  Phase 2 adds `:embedder` to `make-agent-tools` and
`scope`; the synonym-table test embedder is a `rag:embedder` subclass
with an `embed` method in the test package, injected the way
`%stub-source` is.

---

## Where the spec and the sources disagree

1. **Absences never enter a profile (§2.1 vs §4.2).**  `record-absence`
   writes an instant extent by default (write.lisp:170-173), and
   `%open-p` is NIL for it (probe E8).  Under §2.1's "current in
   recall's sense" an absence is never a profile line, so the §4.2
   touch on `record-absence` clears a vector only to re-embed the same
   text.  Decide: exempt absences from touching, or admit them to the
   profile with a different currency test.

2. **Decisions change profiles without a belief write (§2.2 vs §4.2).**
   The profile carries the decisions citing a belief, but a decision
   is written by `conclude`'s own transaction (trace.lisp:233-246) or
   `%write-refusal`'s (140-149), touching no belief; and its evidence
   may cite beliefs in OTHER stores in scope (the `(cite . store)`
   pairs, 79-90, 215-216).  §4.2's touch set misses this: `conclude`
   must also clear the endpoints of every cited belief, in the store
   each cite names, or decisions must leave the profile.

3. **No safe in-process segment drop (§4.3 step 4).**  E3: the only
   engine operation that drops a segment is the internal
   `rebuild-vector-segment`, documented unsafe against a concurrent
   `vector-search`; clearing every vector keeps the dimension.  The
   drop belongs at open time, before the listener, or under a cl-llm
   lock shared with `retrieve`.

4. **"A unique index" is two declarations (§2.5).**  E5: `def-unique`
   enforces, `def-index` looks up; both, both named.

5. **`ev-model` needs a model name the embedders may not have (§5,
   R7).**  E9: `mock-embedder`'s model is NIL; the floor is not an
   embedder field and must be added by the plan.

6. **"embedding unbound" is two states (§2.5, §4.1).**  E2: a
   `makunbound` reloads unbound, a NIL reloads bound-NIL; both drop
   the entry.  Define dirty as "not a conforming vector".

7. **The refusal's report text (§2.2 item 3).**  E6: only a refused
   decision has report text (its violation families); a concluded one
   has the rule name and the cited evidence.
