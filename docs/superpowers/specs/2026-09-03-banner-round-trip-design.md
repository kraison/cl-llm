# The banner round-trip — design (cl-llm #14, S6a unit 3)

**Unit 3 of three under the single-namespace capstone S6a** (`#14`;
programme `#15`). Unit 1 (the decision trace, PR #31) and unit 2 (the
agent tool surface, PR #33) are on `main`. This unit closes the
capstone's last acceptance line: *"The dogfood corpus round-trips:
existing hand-written supersession banners become modelled
supersession claims without loss."* Approved in chat 2026-09-03.

Engine: vivace-graph `experiment` HEAD, unpinned; designed against
`73ad4e2`.

## 1. What this is

The proving corpus is the agent's own memory directory: 165 notes
across the projects at the time of writing. Where a fact stopped being
true, the notes say so **by hand**, in prose, with a banner. Tenant
three (`#16`) captured each note's content as a belief and made an
in-place edit a supersession; this unit captures the banners
themselves, so a reader asking `recall` about a note learns it is
superseded from a claim with a validity start, not from a paragraph.

Two halves, split by what a computer can read without guessing:

- **Deterministic.** A scanner finds the banners by their line shape
  and records each one as a source node holding its text, plus
  asserted beliefs for the facts the shape carries: that the note
  carries the banner, and, when the banner names a `[[link]]` and its
  kind is a replacement, that the note is superseded by the linked
  note. Golden-tested; no model.
- **Model-assisted, opt-in.** For a banner whose target is prose — an
  `UPDATE` that "overturns the above", a `CORRECTION` naming a theory —
  a model reads the note through unit 2's tools and records what the
  banner overturns as a **decision** through `conclude`, citing the
  banner belief. Live-tested for structure; never in the golden.

Author's facts are asserted beliefs under the capture producer; the
agent's readings are inferred decisions under the agent's producer.
That distinction is the design.

## 2. The corpus, measured 2026-09-03

| shape | notes | example first line |
|---|---|---|
| `superseded` | 4 | `> ⚠ **SUPERSEDED 2026-07-22 — premise no longer true.** … See [[android-sqlite-peer]].` |
| `update` | 3 | `**UPDATE 2026-07-09 (branch …):**` / `> **UPDATE 2026-07-16b — … DIAGNOSED …**` |
| `correction` | 3 | `**CORRECTION — measured on-device 2026-07-01 (…).**` / `**CORRECTION to [[test-suite-roadmap]]: …**` |
| `stale` | 1 | `⚠ **STALE ON HOSTS — written 2026-07-05, when odm WAS production …**` |
| prose only | 9 | "is no longer true", "out of date" with no banner |

Every `superseded` banner is a blockquote at the top of the body, dated,
with a reason and a link. `update` and `correction` are bold headings
mid-body, sometimes inside a blockquote, whose date may sit inside the
sentence or be absent, followed by the paragraph they introduce. The
nine prose-only notes have no shape to scan; they are the model's, and
not this unit's, since even their candidates cannot be found without
reading.

## 3. The scanner

`(scan-banners body) => list of BANNER` — a pure function of the note
body, in `memory/banners.lisp`, parsing no prose:

| slot | value |
|---|---|
| `kind` | `:superseded` `:update` `:correction` `:stale` |
| `position` | 1-based order in the note |
| `date` | a timestamp parsed from the first `YYYY-MM-DD` in the heading line, or NIL |
| `link` | the first `[[name]]` in the banner text, or NIL |
| `text` | the banner's whole text: the heading and, for a blockquote, every following `> ` line; otherwise every following line to the next blank line |
| `line` | the 1-based line number of the heading, for diagnostics |

A heading matches when the line, after an optional `> ` and an optional
`⚠ `, starts with `**` followed by one of the four words (case-sensitive:
the corpus is consistent). `STALE ON HOSTS` matches `STALE`. Nothing
else matches: `**Standing rules**` is not a banner.

The scanner is tested on the four real shapes copied verbatim into the
fixture corpus, a note with two banners (positions 1 and 2), and a note
with a bold heading that is not a banner.

## 4. The record

Inside `define-memory-store`, a third source beside `memory-note`:

```lisp
(st:def-source memory-banner ,graph-name
    ((banner-key      :type string)     ; "<note>#<n>", the identity
     (banner-note     :type string)     ; the note's name
     (banner-position :type integer)
     (banner-kind     :type string)     ; "superseded" "update" ...
     (banner-date     :type string)     ; RFC 3339, or the note's MODIFIED
     (banner-dated-p  :type boolean)    ; NIL when DATE fell back
     (banner-link     :type string)     ; "" when none
     (banner-text     :type string))
  :identity     (:namespace :banner :key-slot banner-key)   ; "<note>#<n>"
  :space        :none
  :time         (:extent-fn memory-banner-validity-extent) ; [date, unknown)
  :attribution  :none
  :sensitivity  (:class :restricted)
  :registration :none
  :indexed-text (:text-fn banner-text))
```

`banner-key` is `"<note>#<position>"`, so `(:banner . "android-ecl-port#1")`
names the banner from any claim. The text on the node is the
**without-loss** half: `retrieve` finds it and a reader can quote it.

Per banner, beliefs under the capture producer, standing `:asserted`,
validity `[date, unknown)`:

| relation | object | when |
|---|---|---|
| `carries` | `(:banner . "<note>#<n>")`, `method` = kind | every banner |
| `superseded-by` | `(:memory-note . <link>)` | `superseded` and `stale` banners with a link |

An `update` or `correction` is an addendum: it corrects part of a note,
it does not replace the note, so it never writes `superseded-by` even
when it links. `recall` on a superseded note shows a current
`superseded-by` belief — the reader-facing outcome. The note's own
`content` series is untouched: a superseded note still has the content
it has.

Idempotency is unit 1's: the same banner captured twice is the same
identity tuple on both node and beliefs, a no-op; a banner edited in
place updates the node's text under the same identity and the beliefs
stand; a banner that gains a date moves nothing — the belief's validity
start is part of its identity, so a changed date is a new belief and
the old one supersedes, which is exactly what happened to the note.

**Capture.** `capture-memory-dir` gains the banner pass: after the
note's content belief, scan the body and record each banner in the same
transaction. A new keyword `:banners` (default T) turns it off for a
caller that wants unit 1's behaviour. The tenant-three golden
`tests-memory/golden/capture.sexp` is untouched, since its fixture
notes carry no banner and `capture-listing` does not list banners.

**Listing.** `(banner-listing graph dir)` renders, per note in name
order then position, `(note position kind date link text-digest
dated-p)` with `date` NIL when the banner fell back to the note's
stamp, as `capture-listing` does. Golden `tests-memory/golden/banners.sexp`
over a fixture corpus holding one note of each shape plus the two-banner
note, ordering as the contract, green twice.

## 5. The model pass

`(annotate-banners stores dir &key provider producer (max-tool-turns 4))`
in `cl-llm/agent`, file `agent/annotate.lisp` — the first consumer of
the tool surface. It scans `dir` with the same scanner, keeps notes
with an `update`, `correction` or `stale` banner, and for each runs one
`llm:ask` with a scope over `stores` (the first is the write store) and
a tool set of **three**: `recall`, `retrieve`, `conclude`. The system
prompt states the job in the tools' vocabulary:

> You are annotating one note of an agent's memory. Call `recall` on
> subject-namespace `memory-note`, subject-key `<name>`, to read its
> claims; the record with relation `carries` is the banner. Read the
> banner text (retrieve with endpoint `banner:<name>#<n>` if you need
> it). Then call `conclude` once: subject-namespace `memory-note`,
> subject-key `<name>`, relation `overturns`, object-namespace
> `proposition`, object-key one sentence stating what the banner
> overturns, standing `inferred`, rule `read-banner`, rule-version
> `<model>`, evidence the banner record's `cite`. Then reply `done`.

`producer` is the agent's, required, distinct from the capture
producer. The function returns a list of `(note . decision-or-nil)`:
a note the model did not conclude on is `nil`, reported, never an
error — the model may decline, and a declined annotation is not a
failure of the pass. Every bound is the operator's: `max-tool-turns`,
the scope, the provider; the tool caps are `make-agent-tools`'
defaults.

Nothing in the pass parses the model's text; what it wrote is in the
store, as a decision, with the banner belief as evidence, and `trace`
shows it.

## 6. Layering

- `memory/banners.lisp` (scanner, listing) joins `cl-llm/memory`: no
  new dependency. The source declaration goes into
  `define-memory-store`.
- `agent/annotate.lisp` joins `cl-llm/agent`: needs core (`ask`),
  memory, and the tools it already has. No new dependency.
- `cl-llm/agent/live`, directory `live-agent/`, gated on `CL_LLM_LIVE`
  exactly as `cl-llm/live` is, never run by `test-system` on the
  offline systems and not in CI.

## 7. Testing

- **Scanner**: the six cases of §3, in `tests-memory/banner-tests.lisp`.
- **Capture**: on `with-two-stores`, a `superseded` note recalls a
  current `superseded-by` naming the link and a `carries` with the
  kind; an `update` note carries and writes no `superseded-by`; a
  second capture writes nothing new (control: claim counts); the
  banner node holds the text; a banner without a date has `dated-p`
  NIL and starts at the note's stamp.
- **Golden**: `banner-listing` over the fixture corpus; green twice.
- **The pass, offline**: `annotate-banners` over the fixture corpus with
  a `mock-provider` whose responder reads the last tool result and
  scripts the `conclude` call. Asserts: one decision per candidate
  note, none for a `superseded`-only note; the decision's evidence cite
  equals the `carries` record's cite byte for byte; the producer is the
  agent's; the tool set offered was exactly three (assert on the
  `tools` the mock saw — it ignores them, so assert on the scope's
  tools via the loop's request).
- **The pass, live**: `cl-llm/agent/live`, skipping without
  `CL_LLM_LIVE`; on the fixture corpus, at least one decision, its
  evidence `:resolved`, rule `read-banner`, rule-version non-empty.
  Structure only; no judge.
- **Unit 1 and 2 goldens** unchanged.

## 8. Docs

`docs/agent-memory.md` gains "Banners": the four shapes, the record,
the listing. `docs/agent-tools.md` gains a paragraph on
`annotate-banners` as the surface's first consumer. README: one line.
`docs/ci.md`: the live suite is not run in CI.

## 9. Acceptance

From `#14`: **the dogfood corpus round-trips** — every hand-written
banner in the real corpus's four shapes becomes a `memory-banner` node
with its text and asserted `carries`/`superseded-by` claims, pinned by
a golden over those shapes. And the capstone's other lines are
exercised by the model pass: a decision with a trace whose evidence is
the banner, made through the validated tool surface.

Not delivered, filed: `trace-listing` with a scope (`#34`); recording
the rule on a refused decision (`#35`); the nine prose-only notes,
which need reading before they can even be found (a later pass over
`annotate-banners`' candidate rule, once this one has run on the real
corpus).
