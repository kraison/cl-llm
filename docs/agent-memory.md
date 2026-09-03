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
until when. Nothing here parses prose or calls a model; turning the
hand-written supersession banners *inside* the notes into claims is the
capstone's job (kraison/cl-llm#14).

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
stores hold is not mistaken for the wrong copy. `split-cite` reads the
subject namespace with `find-symbol`, never `intern`: a cite naming a
namespace nothing was ever recorded under is a `belief-argument-error`,
so no caller-supplied string can mint a keyword.

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

## What this is not

The tool surface is `docs/agent-tools.md` (kraison/cl-llm#14 unit 2);
no LLM, no banner parsing (kraison/cl-llm#14 units 2 and 3) and no
cross-namespace recall (#24).
And no registration: this tenant is map-less by design and proves
nothing about it.

Two engine findings from building it are recorded in the spec's §9:
there is no as-of read over transaction time (kraison/vivace-graph#300),
and an unknown end bound was not clamped by its start
(kraison/cl-temporal-extent#2, fixed the same day).
