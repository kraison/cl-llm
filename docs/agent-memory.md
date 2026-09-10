# Agent memory (`cl-llm/memory`)

The third tenant of `graph-db/spacetime`: an agent's **beliefs** as
claims (kraison/cl-llm#16). Design:
`docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md`; this
page is the user's view of it. Everything here runs against vivace-graph
`experiment` and needs no LLM — the system depends on
`graph-db/spacetime`, `ironclad` and `babel` only.

## What a belief is

A belief is a binary claim in the `belief` family, declared
`:temporal t` so its validity **start** is part of its identity and a
belief can hold, lapse and hold again:

| part | value |
|---|---|
| subject | `(namespace . key)` — what the belief is about; your vocabulary |
| relation | a canonical string (`[a-z0-9-]`), the predicate |
| object | `(namespace . key)` — the value |
| producer | a canonical string naming the agent, `"<agent>/<host>"`; required |
| standing | `:observed`, `:inferred` or `:asserted` |
| extent | validity — when it holds; open-ended while current |

An **absence** is a unary claim — subject and relation, no object — whose
standing says what happened when the agent looked: `:searched-empty`
(looked, nothing there), `:indeterminate` (could not find out),
`:uncovered` (nothing has looked). Each is a write; a read that finds
*nothing recorded* returns NIL, which is none of them.

```lisp
;; mem = cl-llm.memory, gdb = graph-db
(gdb:with-transaction (:graph g)
  (mem:record-belief g '(:repo . "cl-llm") "ci-status"
                     '(:verdict . "green")
                     :producer "claude-code/odm" :standing :observed)
  (mem:record-absence g '(:repo . "cl-llm") "release-date"
                      :producer "claude-code/odm"
                      :standing :searched-empty))
```

All three writers run inside *your* transaction; none opens one.
Arguments are checked before the write, so a keyword relation or a
missing producer is a `belief-argument-error` naming the argument.

## Outdated is not wrong

Two axes, deliberately kept apart.

**Supersession** — the belief was true and stopped being. Recording a
different object on a `(producer, subject, relation)` that already has
a current belief closes the old one's validity just before the new
one's start. Both remain; what superseded what is *computed* at read
time from the series, never stored, so it cannot go stale.

```lisp
(gdb:with-transaction (:graph g)
  (mem:record-belief g '(:repo . "cl-llm") "ci-status"
                     '(:verdict . "red")
                     :producer "claude-code/odm" :standing :observed))
;; green's validity now ends 1 ns before red's start
```

Recording the object that is already held is idempotent. A successor
that would start at or before its predecessor is refused
(`belief-successor-before-predecessor`) — that is not supersession, it
is a correction, and you must say so:

**Correction** — the belief was never true. `retract-belief` closes its
*transaction* extent and leaves validity alone, so what remains says
exactly when it was believed. Retracted beliefs are hidden from recall
unless asked for. Only a `belief` may be passed: a `trace` claim is a
decision's own record, not an opinion to withdraw, and it is refused
with a `belief-argument-error`.

```lisp
(gdb:with-transaction (:graph g)
  (mem:retract-belief claim))
```

## Recall, and its order

```lisp
(mem:recall g '(:repo . "cl-llm") :relation "ci-status")
;; => (#S(belief-record :current-p t :superseded-by nil ...)
;;     #S(belief-record :current-p nil :superseded-by <the green> ...))
```

Each `belief-record` carries the claim plus `current-p` (validity open
*and* transaction current), `superseded-by` (the next claim in the
series, or NIL), `retracted-at` (or NIL), and the claim's own `standing`
and `extent`. Filters: `:relation`, `:producer`, `:at` (a timestamp —
only beliefs valid then, and a belief valid *then* but superseded since
is not current), `:include-retracted`.

**Order is the contract:** validity start descending, then `recorded-at`
descending, then object key. A reordering is a regression.

## What a store names

```lisp
(mem:with-scope-snapshots ((list g))
  (mem:vocabulary g))
;; => #S(vocabulary :namespaces #<hash "repo" "verdict" ...>
;;                  :relations #<hash "ci-status" ...>
;;                  :endpoints ((:repo . "cl-llm") (:verdict . "green")))
```

`vocabulary` answers under the caller's snapshot: every namespace with
its subject and object claim counts and the keys filed under it, every
relation with its count, and every distinct endpoint. Retracted claims
are skipped unless `:include-retracted`. The agent's `list-taxonomy`
and the key extractor behind `retrieve` are its two consumers (#64).

One path fills that struct: the engine's claim vocabulary API
(kraison/vivace-graph#350) over the family's own count indexes
(kraison/vivace-graph#361). Names and counts are index lookups on both
paths, `:include-retracted` or not, so `vocabulary` is sub-linear in
the store's claims and resolves no node outside an as-of extent — once
the engine has built the count maps, which a fresh graph's first count
query does by one scan (#70). Inside a `with-as-of` extent the counters
have no history, so the engine falls back to a walk that resolves
nodes. Nothing is cached either way.

## Endpoint profiles

Every endpoint `(namespace . key)` gets a profile: the endpoint as
words, then one line per belief that is current in recall's sense --
not retracted, its validity still open -- the endpoint's own beliefs
as subject first, then as object, newest validity first, capped at
`*profile-cap*` lines (default 32). An absence's (`record-absence`)
default extent is an instant, so it is never open and never a profile
line; an absence given an explicit open `:extent` would be a profile
line, and `record-absence` never touches its endpoint either way. An
endpoint with no current belief has no profile.

This is the text the semantic endpoint index (#78) embeds. Every
belief write -- `record-belief`'s create and the supersession it may
perform, and `retract-belief` -- clears the touched endpoints' stored
vectors in the same transaction, so a store's index is never stale
against beliefs it no longer holds; with no embedder configured the
`endpoint-vector` vertices exist but carry no vector, and the store is
lexical-only (spec 2026-09-10-semantic-memory-indexing-design SS2,
SS4.2).

### The dirty set, the drain and the rebuild

Nothing records dirtiness: an endpoint **is** dirty when it has a
current belief and its `endpoint-vector` holds no conforming vector, or
one from another model. `dirty-endpoints` derives that from the store's
vocabulary, so it survives a crash, an exit or a lost worker unchanged.

`drain-endpoint-vectors` embeds that set in the calling thread and
returns the number embedded, and as a second value the endpoints whose
profile outran the passes below. It takes an embedding *function* (text to
a `(simple-array single-float (*))`) and a model name, never a
`cl-llm/rag` embedder: `cl-llm/memory` depends on no LLM. Per store it
first runs `materialise-endpoint-vectors`, which gives every vocabulary
endpoint a vector-less vertex, so from then on the drain and the write
path only ever update existing nodes.

Then, per endpoint, up to `*embed-passes*` (4) passes of: render the
profile under a read snapshot, call the embedder **outside every
transaction**, then in one transaction re-render and store the vector
only when the text is unchanged. The embedder stays outside because it
is a network round trip and the engine's ninth attempt at a
transaction runs the body under the global transaction-manager lock,
which would stall every writer -- and would bill a hot endpoint for
nine embeddings. The two windows a racing write can land in are both
closed: one that commits before the re-render changes the text, so
nothing is stored and the pass repeats; one that commits after it
fails the store's validation, because `touch-endpoints` saves every
live vertex of the endpoint whether or not it held a vector, and that
write-set entry is the only thing a create-only writer -- a first
belief, nothing superseded -- gives the drain to validate against. An
endpoint whose profile changes under all four passes is left dirty
rather than embedded from a text it no longer has, as is one whose
embedder signalled; the next drain retries it.

`rebuild-endpoint-vectors` clears every vector first, so it re-embeds
clean endpoints too -- a model or a corpus change. `nearest-endpoints`
searches the segment and answers `((namespace . key) . cosine)` best
first, one entry per endpoint.

A *dimension* change is not something the drain can absorb: an empty
segment keeps its dimension, and the engine's only drop is unsafe
against a concurrent search. `reset-endpoint-segment` clears every
vector and drops the segment, returning `T` when it reset; it must run
at start, before anything can search (spec SS4.3).

### The worker

One worker per process draws the drain off the write path.
`start-endpoint-indexer` takes the stores, an embedding function and a
model name, and returns an `endpoint-indexer` it also parks in
`*endpoint-indexer*` -- stopping and joining whatever worker was there
first, so a re-entered start never orphans one. It starts with
`pending` set, so the first thing it does is a sweep of everything
already dirty. After that it sleeps
in a condition wait until `notify-endpoint-indexer` -- called with no
argument it wakes `*endpoint-indexer*`, and is a no-op when there is
none -- sets the flag and wakes it under the same lock, so a notify
racing the wait cannot be lost.

The flag is cleared *before* the drain runs, so a write that lands
mid-drain sets it again and is picked up by the next pass rather than
lost: `drain-endpoint-vectors` takes each store's dirty set once, and
one pass is not promised to empty it.

**Who notifies.** `record-belief` and `retract-belief` do not: they know
nothing of a worker, and a memory image with no indexer must not pay
for one. The agent tools do -- `conclude` and `retract` call
`notify-endpoint-indexer` once their transaction has committed, and
`conclude-absence` does not, because an absence touches no endpoint. A
program that writes through `record-belief` directly is therefore
responsible for its own notify; without one the endpoint waits for the
worker's next sweep, and stays reachable lexically meanwhile. The agent
side of this -- `make-agent-tools`' `:embedder`, and how `retrieve`
uses the index -- is in `docs/agent-tools.md`.

An embedder error is logged to `*error-output*` once per outage, not
once per attempt, and retried after a backoff that doubles from the
`:backoff` argument (default 1 s) up to 60 s. That backoff is a
**deadline**, not a hint: a notify does not cut it short, only a stop
does, and past it the worker drains whether or not one arrived. The
write path notifies on every write, so without that an import against
a down embedder would buy one failing round trip -- plus a full
materialise and dirty sweep -- per write. The log goes to the
`*error-output*` in force when `start-endpoint-indexer` was called, not
the global one a new thread would otherwise see.

Any error-free drain ends the outage state, so a *later* failure is
logged as its own outage rather than swallowed. But only a drain that
actually embedded something announces the recovery: an empty drain
proves nothing about the embedder, so it clears the state silently.

The worker calls itself idle only when a drain finished with no notify
outstanding **and** no store has a dirty endpoint left. An endpoint
whose profile outran all four passes is not an error and not drained
either: it stays dirty, so the worker waits the initial backoff and
drains again instead of idling, and names it on `*error-output*` once
per worker -- an endpoint rewritten faster than it can be embedded is
an embedder-speed problem an operator should see. `wait-endpoint-indexer` polls that flag --
`(wait-endpoint-indexer w :timeout 10)`, `T` when idle, `NIL` on the
timeout -- which is what a script or a test uses to mean "the index
has caught up"; `endpoint-indexer-embedded` is the running count.

`stop-endpoint-indexer` sets the stop flag, wakes the thread through
the same condition variable -- so a worker idle or mid-backoff stops
at once rather than after its delay -- joins it, and clears
`*endpoint-indexer*`. It never signals: a worker that died rather than
returned is logged, not re-signalled, because stop is usually called
from a cleanup form. Stop the worker before closing its stores.

## Capturing a memory directory

The proving corpus is the agent's own memory files
(`~/.claude/projects/*/memory/*.md`). `capture-memory-dir` makes, per
note, one `memory-note` source node (map-less, `:restricted`, its body
text-indexed) and one belief — subject `(:memory-note . name)`, relation
`"content"`, object `(:digest . sha256)` — valid from the note's
`modified` stamp:

```lisp
(mem:capture-memory-dir g #p"~/.claude/projects/-home-me-proj/memory/"
                        :producer "claude-code/odm")
```

Capture again after editing a note in place and the old content claim
is **superseded, not overwritten** — the "suite is 486 pass / 1 fail"
that had been false for days stays readable as what was believed, and
until when. Capture also reads each note's hand-written banners by
their line shape and records them as claims (no prose parsing, no
model — see "Banners" below); reading a banner's prose and concluding
what it overturns is `annotate-banners`, in `cl-llm/agent`
(`docs/agent-tools.md`).

`capture-listing` renders a directory's recall as rows of
`(name digest start current-p superseded-by-digest)`, starts at second
precision like every listing in this tenant (#36); the test suite
diffs it against `tests-memory/golden/capture.sexp`.

## Decisions and their trace

A **decision** is what `conclude` records: a belief or an absence written
from evidence under a named rule — or a refusal, and why (design:
`docs/superpowers/specs/2026-09-02-decision-trace-design.md`,
kraison/cl-llm#14 unit 1). The trace is claims in a second family,
`trace`, on the endpoint `(:decision . id)`, so the reverse question —
which decisions rest on this belief — is an index lookup. `trace`
shadows `cl:trace`; refer to it as `mem:trace` (a local nickname) and
do not `:use` the package.

```lisp
(mem:conclude g (list :belief '(:repo . "cl-llm") "releasable"
                      '(:verdict . "yes") :standing :inferred)
              :producer "claude-code/odm"
              :evidence (list ci-belief push-belief)   ; claims or cites
              :rule "green-and-pushed" :rule-version "1")
;; => #S(decision :outcome :concluded :claim <the belief> ...)
```

`conclude` **owns its transaction** (call it outside `with-transaction`):
it stages the write, validates the transaction's delta with the engine's
`validate-transaction`, and commits — or unwinds and records the refusal
structurally: one `refused` claim per constraint family, and one
`attempted` claim naming the rule it was applying, so `trace` reports
the rule on the refused path too (#35). A refused decision writes no
belief and still records what it was looking at.

Evidence is cited **by claim identity**
(`"cl-llm.memory::belief|<identity-key>"`, `claim-cite`), so a cite
survives retraction and regeneration. `trace` reads a decision back
**as of its own instant**: every cite resolves to the version believed
then (`:resolved`), or reports `:reaped` (past the family's retention)
or `:absent` (swept), and a resolved cite carries `changed-since` —
`:retracted`, `:superseded`, `:updated` or NIL. The as-of version is what
you get; the current one only sets the flag. A `cite-record` from
`trace` also carries `cite-record-store`, the name of the store the
cite was actually resolved against (NIL when none was), so a cite two
stores hold is not mistaken for the wrong copy. `split-cite` applies
the write path's namespace rule: the subject namespace must be
canonical (`[a-z0-9-]+`, `st:canonical-relation-p`) or the cite is a
`belief-argument-error` — validated first, then interned, so a
caller string can only ever mint a recoverable name. A cite over a
canonical namespace nothing was recorded under parses fine and
resolves `:absent`; it is not an error, because a fresh image must be
able to trace a decision before it has read a claim under that
namespace.

```lisp
(mem:trace g (mem:decision-id d))
;; => #S(decision-record :outcome :concluded :rule "green-and-pushed"
;;       :evidence
;;       (#S(cite-record :state :resolved :changed-since :superseded ...)
;;        #S(cite-record :state :resolved :changed-since nil ...)) ...)
(mem:decisions-citing g ci-belief)   ; => decision ids, newest first
```

**Order is the contract:** evidence in cite-string order, refusals in
family order, `decisions-citing` by `recorded-at` descending then id.
`trace-listing` renders decisions as rows for capture-and-diff
(`tests-memory/golden/trace.sexp`); it takes the same `:scope` as
`trace` for cross-store evidence (#34).

## Several stores

`mem:define-memory-store` declares the `belief` and `trace` families
and the `memory-note` source under a graph name of your choosing;
`schema.lisp` is `(define-memory-store :cl-llm-memory)`, and a further
store is one more call, e.g. `(define-memory-store :memory-private)`.
The families' class names are shared across stores — that is the
engine's model — so an evidence claim records **which store** the
claim it cites was found in, in its `method` slot; `mem:trace` and
`mem:decisions-citing` both take a `:scope` (a list of open graphs) to
resolve those cross-store cites, defaulting to `(list graph)` when
omitted. Building a tool surface a model calls over several stores —
scope, caps, the writable one — is `docs/agent-tools.md`
(kraison/cl-llm#14 unit 2).

## Scopes

A scope is a list of open stores in trust order, most trusted first.
Every reader (`recall`, `resolve-cite`, `trace`, `decisions-citing`)
and `conclude` take `:scope`, defaulting to the store they were called
on. `check-scope` refuses an empty list, a closed or repeated store,
two stores with one name, a write store outside the list, and a
multi-store scope whose stores are not attached to one system clock
(one regime, never a wall-clock fallback). Scope reads run under one
read snapshot per store, composed by the engine with no single instant
across stores, and are refused inside an open write transaction: the
engine refuses only the foreign half, and the own-store half would show
uncommitted state.

**One memory, trust-ordered supersession.** `recall` builds one series
over the scope. A belief supersedes an older one across stores only
from a store of equal or higher trust; a lower-trust belief is listed
beside a higher one and never marks it superseded. A record names its
store and, when superseded, the successor's cite and store. Nothing is
written: no store closes another's validity.

**`conclude` at the boundary.** Before its transaction opens, a belief
proposal is read against the series over the scope. A governing prior
in a higher-trust store refuses the proposal with the `scope-conflict`
family, naming the cite and its store; one in a lower-trust store is
overridden at read time and recorded as an evidence row with that
store's name. An absence has no series and takes no pre-read. The
pre-read is advisory like the validation report; the commit is the
enforcement.

**Cites** stay store-free and resolve in the first store in scope order
holding their identity; every rendered cite carries the store it
resolved in. `decisions-citing` returns `(id . store-name)` pairs and
`trace` finds a decision in the first store holding it, naming it in
`decision-record-store`. A decision carries one evidence row per cite,
whatever number of stores hold that cite: the trace family's identity
has no room for the store, so the row names the first store in scope
order among those cited (#51). `belief-record-store` and
`belief-record-superseded-by-store` hold graph objects;
`cite-record-store` and `decision-record-store` hold store-name
strings.

**The clock belongs to the image.** A store attached to a system clock
draws its epochs from it; the attachment lives in memory and in the
clock's journal, not in the store, so a store reopened without the
clock silently resumes its own counter, continuing the same integers.
The memory image opens one clock (`CL_LLM_MEMORY_CLOCK`, default
`~/.cl-llm-memory/clock/`) before its stores, passes it on every open,
and closes it last. Every decision records its commit epoch
(`decision-epoch`, `decision-record-epoch`); the number is comparable
across stores only for decisions recorded under the shared clock. Under
a clocked scope, `trace` resolves every cite at the decision's commit
epoch; a decision recorded before the engine stamped one, or read on a
clockless single store, resolves at its recorded instant, and the
record says which (`decision-record-axis`, `:epoch` or `:instant`).
`resolve-cite` takes the axis directly — the positional `at` or
`:epoch`, exactly one of them; an `:epoch` read of a store with no
system clock is the engine's `epoch-axis-unavailable`, a caller error.
`changed-since` reports a supersession from another store under the
trust rule: `:superseded`, with `cite-record-superseded-by` holding
the successor's `(cite . store-name)`.

## Banners

The proving corpus's notes carry hand-written supersession banners in
prose — a fact stopped being true, and someone said so in the body
rather than editing it out. `scan-banners` (`memory/banners.lisp`,
spec `2026-09-03-banner-round-trip` §3) finds four line shapes, each a
`**WORD ...**` (or `> **WORD ...**`, or `⚠ **WORD ...**`) heading a
paragraph or a blockquote:

- `SUPERSEDED` — the note's premise no longer holds; usually links to
  its replacement.
- `UPDATE` — new information layered on, nothing retracted.
- `CORRECTION` — the note was wrong, possibly about a specific claim
  elsewhere; may link to what it corrects.
- `STALE` — the note describes a past state (a host, a branch) that
  has since moved on; usually links to the current state.

A banner's **date** is the first `YYYY-MM-DD` on its heading line, or
NIL when undated; its **link** is the first `[[name]]` anywhere in its
text, or NIL; word matching is on a boundary, so `UPDATE` never
matches `UPDATED`.

Capture (`%capture-banner`, `memory/capture.lisp`, spec §4) turns each
scanned banner into a `memory-banner` source node — `bn-key`
(`"<note>#<position>"`), `bn-note`, `bn-position`, `bn-kind`,
`bn-date` (RFC 3339, the banner's own date or the note's `modified`
stamp when undated), `bn-dated-p`, `bn-link`, `bn-text` — and one
`annotates` belief:

```
(:banner . "<note>#<n>") --annotates--> (:memory-note . name)
```

with `method` the banner's kind. **The banner is the subject**, not
the note: a belief series is single-valued per `(producer, subject,
relation)`, and a note can carry several banners, so the note cannot
be the subject of `annotates` without one banner's claim silently
superseding another's. A reader reaches a note's banners the other
way round, through the claims touching it as *object* — `recall
(:memory-note . name)` for the note's own beliefs, or
`claims-touching :role :either` to include what points at it.

A `SUPERSEDED` or `STALE` banner that carries a link additionally
writes `(:memory-note . name) --superseded-by--> (:memory-note .
link)`, straight on the note this time — that relation is
single-valued per note by design, so when a note carries more than
one such banner only the **last by position** writes it
(`%last-replacing-banner`); the others still get their own
`annotates` claim.

Capture reflects the file as truth (`%assert-from-file`,
`memory/write.lisp`), and the two beliefs above split differently
between supersession and correction because their objects don't move
the same way. `annotates`' object is always the banner's own note —
the same banner key always names the same note — so it can never be a
supersession; a re-dated or re-kinded banner under the same key is
always a **correction**: `record-belief`'s own idempotent path would
otherwise keep the old date or kind unchanged, so `%assert-from-file`
retracts the current claim and records the file's state fresh instead
(`a-re-dated-banner-corrects-not-supersedes`, which bumps a banner's
date later and still gets a correction, not a supersession).
`superseded-by`'s object is the *link*, which can genuinely change
from one capture to the next: a different link with a later validity
start is an ordinary **supersession** of the note's series, the same
as any other belief; a different link with a non-later start, or the
same link re-dated, is a **correction**. Either way only the last
replacing banner by position ever writes it.

A banner dropped from the file — the author deleted or folded it in —
must not leave its claims looking current: after writing the banners
the current scan still finds, capture retracts any of this producer's
`annotates` beliefs whose subject key `"<note>#<n>"` names a position
past what is present now, and, when no replacing banner with a link
remains, retracts a current `superseded-by` belief on the note too
(`%retract-removed-banners`, `%retract-stale-superseded-by`,
`memory/capture.lisp`, finding 2, #14 unit 3 final review). A note
with two banners where only the second is removed keeps the first's
`annotates` belief untouched — retraction is per banner, by position,
not a blanket sweep of the note's claims.

`capture-memory-dir` takes a `:banners` keyword (default `T`); passing
`:banners nil` restores unit 1's behaviour exactly — content beliefs
only, no banner nodes or claims.

`banner-listing` renders a directory's banners as capture-and-diff
rows — per note in name order, per banner in position order,
`(note position kind date link text-digest dated-p)` — diffed against
`tests-memory/golden/banners.sexp` in the test suite.

## Running a memory image

A graph-db store is single-process — an mmap'd heap and a `.dirty`
marker — so the Lisp image behind each session cannot open the same
store. `scripts/run-memory.sh` starts **one** long-lived SBCL that
loads `cl-llm/agent`, opens the store (or makes it when absent) and
serves SWANK on loopback; a session reaches it through cl-mcp-server's
`remote-*` tools and runs Lisp and Prolog against it directly. There
is no JSON front end: that is the multi-agent service, designed
separately (kraison/cl-llm#39).

```sh
scripts/run-memory.sh   # logs to stdout; SIGTERM or Ctrl-C closes the store
```

| variable | default |
|---|---|
| `CL_LLM_MEMORY_STORE` | `~/.cl-llm-memory/working/` |
| `CL_LLM_MEMORY_SYSTEM` | `~/.cl-llm-memory/system/` |
| `CL_LLM_MEMORY_GRAPH` | `cl-llm-memory` |
| `CL_LLM_MEMORY_SWANK_PORT` | `4008` (loopback only) |
| `CL_LLM_MEMORY_PRODUCER` | `claude-code/<hostname>` |
| `CL_LLM_MEMORY_BUFFER_POOL` | `2000` |
| `CL_LLM_MEMORY_CLOCK` | `~/.cl-llm-memory/clock/` |
| `CL_LLM_ASDF_REGISTRY` | the checkout the script lives in |

The image builds from the trees in `CL_LLM_ASDF_REGISTRY`
(colon-separated, ahead of Quicklisp's own search), the same variable
the solo server reads, and its banner ends with `graph-db <dir>`
naming the engine it resolved -- a mismatched checkout shows there,
not at the first missing symbol (#72).

The image refuses a store left dirty (`store-not-closed-cleanly-error`,
exit 1) rather than open a torn one; the exit hook closes the graph on
SIGTERM, so a clean stop leaves no marker. Its package,
`cl-llm.memory-image`, holds `*graph*` (also bound as `gdb:*graph*`)
and `*producer*`, with local nicknames `mem`, `gdb`, `st` and `agent`.

From a session, with `remote-connect name=memory port=4008` (read
mode), reads run unarmed in that package:

```lisp
(mem:recall *graph* '(:memory-note . "android-ecl-port")
            :relation "superseded-by")
```

Prolog runs with `package=GRAPH-DB`. Name a type as a keyword or a
qualified symbol — `run-query-goals` interns bare heads in `*package*`
(kraison/vivace-graph#322), so `belief-binary` alone matches nothing:

```lisp
(select (:limit 5) (?c ?r)
  (is-a ?c :belief-binary) (node-slot-value ?c relation ?r))
```

Writes need the target armed: add `"memory"` to the armable targets
in `~/.config/cl-mcp-server/config.sexp`, `remote-arm memory`, then
`(mem:conclude *graph* … :producer *producer* …)` as in "Decisions and
their trace", and `remote-disarm` when done. Every form, refusals
included, is in `remote-ledger`.

## The memory as an MCP server

The agent tools reach any MCP client from this repo, without
cl-mcp-server or the blackboard: `cl-llm/agent/mcp` registers each
tool from `make-agent-tools` on a `cl-mcp` server, the schema converted
to `cl-mcp`'s form, the decoded arguments converted back, a refusal
returned as text with `isError`. The scope -- stores in trust order,
the write store, the producer, the caps -- is configuration; no tool
takes a store, so the model names subjects and never stores, as
`docs/agent-tools.md` promises.

### Solo: one process per session

```
claude mcp add --scope user memory -- /path/to/cl-llm/scripts/run-memory-mcp.sh
```

The client launches `scripts/memory-mcp.lisp` through the wrapper. It
reads the memory image's variables (the table above, plus
`CL_LLM_MEMORY_CLOCK`), opens the clock and then the store on it, and
serves stdin/stdout; every other byte goes to stderr. A multi-store
scope is `CL_LLM_MEMORY_SCOPE=private=/dir,working=/dir` in trust
order with `CL_LLM_MEMORY_WRITE` naming the write store (default the
last); `CL_LLM_MEMORY_QUERY_TOOL=1` adds the guarded Prolog tool. The
child builds from the trees in `CL_LLM_ASDF_REGISTRY` (default: the
checkout the script lives in), as the image does (#72). A store
another process -- the memory image, or another session's solo server
-- already holds makes it exit 1 before any handshake: graph-db stores
have one holder, and there is no mode that lets two processes open
one. Which refusal it is depends on the clock: in the default
configuration both share `~/.cl-llm-memory/clock/`, the clock opens
first, so the message is "Another image holds the clock at that
location"; the store's own "Another image may hold the store" appears
when the two point at different clock directories. The test
`a-second-solo-server-on-a-held-store-refuses` asserts both.

### In the image: a listener, many sessions

The memory image listens on `CL_LLM_MEMORY_MCP_PORT` at
`CL_LLM_MEMORY_MCP_BIND`. Each connection gets its own server and its
own producer; a listener that will not start -- a taken port, a bad
bind, a malformed principals file -- is reported on stderr and skipped,
the banner reads `mcp off`, and the image keeps its store and its
SWANK.

| variable | default |
|---|---|
| `CL_LLM_MEMORY_MCP_PORT` | `4009`; set but empty turns the listener off (#75) |
| `CL_LLM_MEMORY_MCP_BIND` | `127.0.0.1` |
| `CL_LLM_MEMORY_PRINCIPALS` | `~/.cl-llm-memory/principals.sexp` |
| `CL_LLM_MEMORY_IDENTITY` | `secret` (or `tailscale`) |
| `CL_LLM_MEMORY_QUERY_TOOL` | empty; `1` adds the guarded Prolog tool |
| `CL_LLM_MEMORY_K` | `5`; the retrieval cap for every connection |
| `CL_LLM_MEMORY_MAX_ROWS` | `50`; the row cap for every connection |

The caps are the image's, not the caller's: `CL_LLM_MEMORY_K` and
`CL_LLM_MEMORY_MAX_ROWS` bound retrieval and rows for every connection,
as `make-agent-tools` does in process, so the model chooses arguments
and never a bound. `listener-caps-reach-the-tools` asserts a listener
started with `:max-rows 1` returns one record and `truncated` true.

A client connects through the relay:

```
claude mcp add --scope user memory -- sbcl --script \
  /path/to/cl-llm/scripts/memory-mcp-client.lisp --port 4009 \
  --principal claude-code/laptop
```

or through `socat STDIO TCP:127.0.0.1:4009` without a principal.

**Identity.** With nothing configured, a loopback connection writes as
the image's producer. Named principals are a file,
`CL_LLM_MEMORY_PRINCIPALS` (default `~/.cl-llm-memory/principals.sexp`):

```lisp
(("claude-code/laptop" . "a-long-random-secret")
 ("hermes/laptop"      . "another"))
```

The relay sends one hello line before any JSON-RPC, naming its
principal and the secret it reads from `--secret-file PATH`, else
`CL_LLM_MEMORY_CLIENT`, else `~/.cl-llm-memory/client.sexp` (same
shape; #73); a match sets the connection's producer, a mismatch closes
the connection before the handshake, and a connection from off
loopback with no hello is refused. The relay exits 0 when the session
ends -- EOF on its stdin half-closes the socket, and every reply still
coming is written to stdout before it exits (#74) -- 2 when a hello
was sent and the listener closed without answering, with one stderr
line naming the principal and the secret's path (#73), and 1 on
anything else (a missing secret file names its path). The relay cannot
tell a refusal from a session that sent no request at all, so a
principal with an empty stdin also exits 2. Binding to any
non-loopback address with no principals file is refused at startup.
`CL_LLM_MEMORY_IDENTITY=tailscale` swaps the provider for the peer's
tailnet node (`claude-code/<node>`, refused when that is not a
canonical producer),
for hosts on one tailnet; it is off by default.

Loopback is not an authentication boundary on a multi-user host: any
local process can reach the port, and SWANK on 4008 already grants such
a process strictly more than the tool surface does. Telling one local
caller from another is what the principals file is for.

**Arguments** are the tool surface's, unchanged (`docs/agent-tools.md`),
with one MCP-level rule: a JSON `null` for an optional argument such as
`standing` is refused, not defaulted. The key is present and `null`
decodes as NIL, so the tool sees NIL rather than its declared default
and answers with the refusal as text with `isError`; omit the key to
get the default.

### Telling an agent to use it

Configuring the server makes the tools *reachable*; it does not make an
agent *reach for them*. Nothing about an MCP server enters a model's
context on its own, and several runtimes defer MCP tools behind a
search, so an agent may not see them listed at all. Left at that, a
session will mostly answer from its own context and never call
`recall` -- the store stays empty and honest, which is the safe
failure but a failure all the same.

What closes the gap is a **skill**: a markdown file the runtime loads
when its description matches the task, naming when to read, when a
fact is worth a `conclude`, and the conventions -- namespaces,
standings, evidence -- that keep one session's writes legible to the
next. `examples/skills/graph-memory/` is a working one, with
`examples/skills/README.md` covering installation per runtime and what
to adapt.

### Shutdown

Both modes close the store on EOF, on SIGTERM (SBCL runs its exit
hooks on SIGTERM), and on normal exit, in one idempotent `stop`: the
listener first, then each store with `*graph*` bound and without the
snapshot `close-graph` takes by default -- that snapshot is unbounded
work before the `.dirty` marker clears, and a backup is a separate
operation -- then the clock. Claude Code sends a spawned stdio server
SIGTERM and then SIGKILL after an undocumented grace period, sends no
MCP-level goodbye, and never respawns a crashed stdio server; whether
concurrent sessions share a user-scoped stdio server is undocumented,
and the solo mode assumes they do not, which is why a held store is
refused rather than shared. SIGKILL leaves at worst a `.dirty` marker
for the write-ahead log to recover on the next open.

## What this is not

The tool surface is `docs/agent-tools.md` (kraison/cl-llm#14 unit 2);
no cross-namespace recall (#24). Banner *parsing* is this module's
(`memory/banners.lisp`, `memory/capture.lisp`); reading a banner and
concluding what it overturns is a model's job, over the tool surface
— `cl-llm/agent`'s `annotate-banners` (`docs/agent-tools.md`).
And no registration: this tenant is map-less by design and proves
nothing about it.

Two engine findings from building it are recorded in the spec's §9:
there is no as-of read over transaction time (kraison/vivace-graph#300),
and an unknown end bound was not clamped by its start
(kraison/cl-temporal-extent#2, fixed the same day).
