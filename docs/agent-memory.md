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
`(name digest start current-p superseded-by-digest)`; the test suite
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
`validate-writes`, and commits — or unwinds and records the refusal
structurally, one `refused` claim per constraint family. A refused
decision writes no belief and still records what it was looking at.

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
(`tests-memory/golden/trace.sexp`).

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
