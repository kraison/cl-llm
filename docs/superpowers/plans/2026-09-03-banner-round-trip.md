# Banner Round-Trip (S6a unit 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the memory corpus's hand-written supersession banners
into claims: a deterministic scanner and capture pass with a golden,
and an opt-in model pass that records what a prose banner overturns
as a traced decision through the agent tool surface.

**Architecture:** `memory/banners.lisp` scans a note body for four line
shapes and yields `banner` structs. `capture-memory-dir` records each
banner as a `memory-banner` source node (its text, its date) plus
asserted beliefs under the capture producer: the banner `annotates`
the note, and, for a replacing banner with a link, the note is
`superseded-by` the linked note. `banner-listing` is the golden's
shape. `agent/annotate.lisp` runs one scripted `ask` per prose-target
note with three tools and records the model's reading through
`conclude`, citing the `annotates` belief. A live suite exercises the
pass against a real provider, gated on `CL_LLM_LIVE`.

**Tech Stack:** SBCL, ASDF, fiveam; `cl-llm/memory` (graph-db/spacetime,
ironclad, babel), `cl-llm/agent` (cl-llm core, memory, rag/claims);
local-time, cl-temporal-extent. No new dependency.

**Spec:** `docs/superpowers/specs/2026-09-03-banner-round-trip-design.md`
(§3 scanner, §4 record, §5 model pass, §7 tests). Two amendments are
made by this plan (Task 2, Task 3) and recorded in the spec when they
land. Companions: `docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md`
§7 (capture), `docs/agent-memory.md`, `docs/agent-tools.md`.

## Global Constraints

- **Lisp style:** spaces only, never tabs; **hard 80-column limit** on
  code, comments, docstrings and strings, including lines copied from
  this plan — wrap them. Comments terse, pointing at the spec section.
- **Dependencies:** `cl-llm/memory` stays on graph-db/spacetime,
  ironclad, babel; `cl-llm/agent` on cl-llm, cl-llm/memory,
  cl-llm/rag/claims. No new dependency. No regex library: the scanner
  is hand-written character scanning.
- **The scanner parses no prose**: line shapes only (spec §3).
- **Two producers, never confused:** capture writes `:asserted` beliefs
  under the capture producer; the model pass writes `:inferred`
  decisions under the agent's producer.
- **Goldens are byte-stable:** `tests-memory/golden/capture.sexp` and
  `tests-memory/golden/trace.sexp` must not change; the new
  `tests-memory/golden/banners.sexp` carries no host-bound value and is
  green twice.
- **Order is the contract; absence is not a value; negative tests carry
  a control.**
- **Engine:** vivace-graph `experiment` HEAD at `~/work/vivace-graph-v3`
  (at or after `73ad4e2`; do not modify). Run suites in a subprocess,
  never a shared REPL image.
- **Docs travel with the code:** the last task is the doc pass; no push
  before it, and none by an implementer at all. Commit trailer on every
  commit:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016XhUGNmKWzsBV8PftSVfVo
```

**Running tests.** Always as a subprocess:

```bash
cd ~/work/cl-llm
sbcl --dynamic-space-size 4096 --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" \
  --eval '(ql:quickload (list :cl-llm/memory/tests :cl-llm/agent/tests) :silent t)' \
  --eval '(asdf:test-system :cl-llm/memory)' \
  --eval '(asdf:test-system :cl-llm/agent)' 2>&1 | grep -E 'Did [0-9]+ checks|Pass:|Fail:'
```

One test: `--eval '(unless (fiveam:run! (quote PACKAGE::TEST-NAME)) (sb-ext:exit :code 1))'`.
Baselines: memory 199, agent 119. A run that prints no `Did N checks`
line ran nothing (`docs/ci.md`).

**Branch:** `feat/banner-round-trip` (exists; the spec is on it).

---

## File structure

| File | Responsibility |
|---|---|
| `memory/banners.lisp` (create) | `banner` struct, `scan-banners`, date and link extraction, `banner-listing` |
| `memory/schema.lisp` (modify) | `memory-banner` source inside `define-memory-store`; its extent-fn |
| `memory/capture.lisp` (modify) | `%capture-banners`; `capture-memory-dir :banners` |
| `memory/packages.lisp` (modify) | exports |
| `agent/annotate.lisp` (create) | `annotation-tools`, `annotate-banners` |
| `agent/packages.lisp` (modify) | exports |
| `cl-llm.asd` (modify) | components; `cl-llm/agent/live` |
| `tests-memory/fixtures/banners/*.md` (create) | six notes: the four real shapes, a two-banner note, a bold non-banner |
| `tests-memory/banner-tests.lisp` (create) | scanner, capture, listing, golden |
| `tests-memory/golden/banners.sexp` (create) | the golden |
| `tests-agent/annotate-tests.lisp` (create) | the pass, scripted |
| `live-agent/packages.lisp`, `live-agent/live.lisp` (create) | the live suite |
| `docs/agent-memory.md`, `docs/agent-tools.md`, `README.md`, `docs/ci.md`, spec (modify) | docs and amendments |

---

### Task 1: The scanner and the fixture corpus

**Files:**
- Create: `memory/banners.lisp` (scanner half; `banner-listing` comes in Task 2)
- Create: `tests-memory/fixtures/banners/` — six `.md` files
- Create: `tests-memory/banner-tests.lisp`
- Modify: `memory/packages.lisp`, `cl-llm.asd` (`cl-llm/memory`: `(:file "banners")` after `capture`; `cl-llm/memory/tests`: `(:file "banner-tests")` after `store-tests`)

**Interfaces:**
- Produces: `(defstruct banner kind position date link text line)`;
  `(scan-banners body) => list of banner`, positions 1-based in order;
  `banner-kind` ∈ `:superseded :update :correction :stale`;
  `banner-date` a `local-time:timestamp` at 00:00:00Z or NIL;
  `banner-link` a string or NIL; `banner-text` the banner's lines
  joined with newlines, verbatim (blockquote markers kept).

- [ ] **Step 1: The fixture corpus**

Create `tests-memory/fixtures/banners/` with these six files. Each has
frontmatter in the corpus's shape (`name`, `description`, `metadata:`
with `type` and `modified`).

`superseded.md` (the real shape, verbatim from the corpus):

```markdown
---
name: superseded
description: A note whose premise stopped being true
metadata:
  type: project
  modified: 2026-07-01T10:00:00Z
---
> ⚠ **SUPERSEDED 2026-07-22 — premise no longer true.** The Android field app no longer
> runs ECL or embeds vivace-graph; it uses a SQLite-based VG replication peer. ECL was
> abandoned as too buggy. See [[android-sqlite-peer]]. The detail below is still accurate
> *about ECL*, but does not describe how the field app works today.

The body proper. It talks about ECL at length.
```

`update.md`:

```markdown
---
name: update
description: A note with a dated update mid-body
metadata:
  type: project
  modified: 2026-07-05T10:00:00Z
---
The original finding, still here.

**UPDATE 2026-07-09 (branch `fix/osint-extract-robustness`, off main after PR #38):**
- **Extraction-drop bug FIXED (commit 21859e0):** misses were TIMEOUTS not the model.
- timeout 60→180s; extract flags transient failures.

A later paragraph that is not part of the update.
```

`correction.md`:

```markdown
---
name: correction
description: A note whose theory was overturned by a measurement
metadata:
  type: project
  modified: 2026-06-28T10:00:00Z
---
The weak-value cache leaks on device, we believe.

**CORRECTION — measured on-device 2026-07-01 (VG's mem-probe `run-cache-split`).** The
weak-value-cache theory is OVERTURNED for on-device: after the dense query + drop + GC,
node-cache count = 0.
```

`stale.md`:

```markdown
---
name: stale
description: A note written when a host was production
metadata:
  type: project
  modified: 2026-07-05T10:00:00Z
---
⚠ **STALE ON HOSTS — written 2026-07-05, when odm WAS production and `ma.chatsubo.net`
pointed at it.** Host facts below are from that time. See [[hosts-now]].

Host facts.
```

`two.md` (an update, then an undated correction with a link):

```markdown
---
name: two
description: Two banners in one note
metadata:
  type: project
  modified: 2026-07-10T10:00:00Z
---
Stage 4 is done; Stage 5 is next.

**UPDATE 2026-07-12 — Stage 5 started.** Work began on the roadmap's next stage.

More text.

**CORRECTION to [[test-suite-roadmap]]: Stage 5 is NOT "next" — it is
blocked on Stage 4b.** The roadmap note has the order.
```

`plain.md` (a bold heading that is not a banner):

```markdown
---
name: plain
description: No banner here
metadata:
  type: project
  modified: 2026-07-01T10:00:00Z
---
**Standing rules**

1. Nothing here is a banner.
```

Also add a `MEMORY.md` index file (one line) so `%note-files`' exclusion
is exercised.

- [ ] **Step 2: Write the failing scanner tests**

`tests-memory/banner-tests.lisp`:

```lisp
;;;; tests-memory/banner-tests.lisp -- spec 2026-09-03 (banners) SS3:
;;;; the scanner on the real shapes; SS4: capture, listing, golden.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %banner-fixture-dir ()
  (asdf:system-relative-pathname
   :cl-llm "tests-memory/fixtures/banners/"))

(defun %fixture-body (name)
  (nth-value 1 (mem:read-frontmatter
                (merge-pathnames (format nil "~a.md" name)
                                 (%banner-fixture-dir)))))

(test scan-finds-the-superseded-blockquote
  (let ((bs (mem:scan-banners (%fixture-body "superseded"))))
    (is (= 1 (length bs)))
    (let ((b (first bs)))
      (is (eq :superseded (mem:banner-kind b)))
      (is (= 1 (mem:banner-position b)))
      (is (local-time:timestamp= (%ts "2026-07-22T00:00:00Z")
                                 (mem:banner-date b)))
      (is (string= "android-sqlite-peer" (mem:banner-link b)))
      (is (= 4 (count #\Newline (mem:banner-text b) :test #'char=))
          "four blockquote lines, joined by three newlines, plus none")
      (is (search "does not describe how the field app works today"
                  (mem:banner-text b)))
      (is (= 1 (mem:banner-line b))))))

(test scan-finds-a-dated-update-and-stops-at-the-blank-line
  (let ((bs (mem:scan-banners (%fixture-body "update"))))
    (is (= 1 (length bs)))
    (let ((b (first bs)))
      (is (eq :update (mem:banner-kind b)))
      (is (local-time:timestamp= (%ts "2026-07-09T00:00:00Z")
                                 (mem:banner-date b)))
      (is (null (mem:banner-link b)))
      (is (search "extract flags transient failures" (mem:banner-text b)))
      (is (not (search "later paragraph" (mem:banner-text b)))))))

(test scan-finds-a-correction-whose-date-is-inside-the-sentence
  (let ((b (first (mem:scan-banners (%fixture-body "correction")))))
    (is (eq :correction (mem:banner-kind b)))
    (is (local-time:timestamp= (%ts "2026-07-01T00:00:00Z")
                               (mem:banner-date b)))))

(test scan-finds-stale-on-hosts-with-its-link
  (let ((b (first (mem:scan-banners (%fixture-body "stale")))))
    (is (eq :stale (mem:banner-kind b)))
    (is (string= "hosts-now" (mem:banner-link b)))
    (is (local-time:timestamp= (%ts "2026-07-05T00:00:00Z")
                               (mem:banner-date b)))))

(test scan-numbers-two-banners-and-an-undated-one-has-no-date
  (let ((bs (mem:scan-banners (%fixture-body "two"))))
    (is (equal '(1 2) (mapcar #'mem:banner-position bs)))
    (is (equal '(:update :correction) (mapcar #'mem:banner-kind bs)))
    (is (null (mem:banner-date (second bs))))
    (is (string= "test-suite-roadmap" (mem:banner-link (second bs))))))

(test scan-ignores-a-bold-heading-that-is-not-a-banner
  (is (null (mem:scan-banners (%fixture-body "plain"))))
  (is (null (mem:scan-banners ""))
      "control: an empty body is no banners, not an error"))
```

- [ ] **Step 3: Add the components and run to see them fail**

Expected: `mem:scan-banners` unbound at read.

- [ ] **Step 4: Implement the scanner**

`memory/banners.lisp`:

```lisp
;;;; memory/banners.lisp -- the hand-written supersession banners, by
;;;; line shape.  Spec 2026-09-03 (banners) SS3; the listing SS4.

(in-package #:cl-llm.memory)

(defstruct banner
  "One banner found in a note body (SS3).  DATE is a TIMESTAMP at
00:00:00Z from the first YYYY-MM-DD on the heading line, or NIL; LINK
the first [[name]] in TEXT, or NIL; TEXT the banner's lines verbatim."
  kind position date link text line)

(defparameter +banner-words+
  '(("SUPERSEDED" . :superseded) ("UPDATE" . :update)
    ("CORRECTION" . :correction) ("STALE" . :stale)))

(defun %strip-prefix (line prefix)
  (if (and (>= (length line) (length prefix))
           (string= prefix line :end2 (length prefix)))
      (subseq line (length prefix))
      nil))

(defun %heading-kind (line)
  "The banner kind LINE opens, or NIL.  After an optional \"> \" and an
optional warning sign, the line must start with ** and a banner word."
  (let* ((s (or (%strip-prefix line "> ") line))
         (s (or (%strip-prefix s (format nil "~a " (code-char #x26a0))) s))
         (s (%strip-prefix s "**")))
    (and s
         (cdr (assoc-if (lambda (word) (%strip-prefix s word))
                        +banner-words+)))))

(defun %blockquote-p (line)
  (and (plusp (length line)) (char= #\> (char line 0))))

(defun %blank-p (line)
  (zerop (length (string-trim '(#\Space #\Tab #\Return) line))))

(defun %digit-run-p (s start n)
  (and (<= (+ start n) (length s))
       (every #'digit-char-p (subseq s start (+ start n)))))

(defun %first-date (line)
  "The first YYYY-MM-DD in LINE as a TIMESTAMP at midnight UTC, or NIL."
  (loop for i from 0 to (- (length line) 10)
        when (and (%digit-run-p line i 4)
                  (char= #\- (char line (+ i 4)))
                  (%digit-run-p line (+ i 5) 2)
                  (char= #\- (char line (+ i 7)))
                  (%digit-run-p line (+ i 8) 2))
          return (local-time:parse-timestring
                  (format nil "~aT00:00:00Z" (subseq line i (+ i 10))))))

(defun %first-link (text)
  "The name inside the first [[...]] in TEXT, or NIL."
  (let ((open (search "[[" text)))
    (when open
      (let ((close (search "]]" text :start2 (+ open 2))))
        (when close (subseq text (+ open 2) close))))))

(defun scan-banners (body)
  "The banners in BODY, in order, positions from 1 (SS3).  Parses line
shapes only: a heading line opens a banner; a blockquote banner runs
over the following > lines, any other over the following lines to the
next blank line."
  (let ((lines (uiop:split-string body :separator '(#\Newline)))
        (banners '()) (position 0) (i 0))
    (loop while (< i (length lines))
          do (let* ((line (nth i lines))
                    (kind (%heading-kind line)))
               (if (null kind)
                   (incf i)
                   (let ((quoted (%blockquote-p line))
                         (start i)
                         (collected (list line)))
                     (incf i)
                     (loop while (and (< i (length lines))
                                      (let ((l (nth i lines)))
                                        (if quoted
                                            (%blockquote-p l)
                                            (not (%blank-p l)))))
                           do (push (nth i lines) collected)
                              (incf i))
                     (let ((text (format nil "~{~a~^~%~}"
                                         (nreverse collected))))
                       (push (make-banner :kind kind
                                          :position (incf position)
                                          :date (%first-date line)
                                          :link (%first-link text)
                                          :text text
                                          :line (1+ start))
                             banners))))))
    (nreverse banners)))
```

Exports in `memory/packages.lisp`, new section:

```lisp
   ;; banners
   #:banner #:scan-banners #:banner-kind #:banner-position
   #:banner-date #:banner-link #:banner-text #:banner-line
```

- [ ] **Step 5: Run the memory suite until green**

If the newline count in the superseded test is off by one, check
whether `read-frontmatter` leaves a leading empty line before the
blockquote (it returns the lines after the closing fence joined) — the
scanner must still find the heading at line 1 of the body only if the
body starts with it; adjust the `banner-line` assertion to what the
body actually contains and say so in the report.

- [ ] **Step 6: Commit**

```bash
git add memory/banners.lisp memory/packages.lisp cl-llm.asd \
        tests-memory/fixtures/banners tests-memory/banner-tests.lisp
git commit -m "feat(memory): scan-banners -- the four banner shapes, by line (#14 unit 3)"
```

---

### Task 2: The record — banner nodes, annotates and superseded-by, the listing, the golden

**Files:**
- Modify: `memory/schema.lisp`, `memory/capture.lisp`, `memory/banners.lisp`, `memory/packages.lisp`
- Modify: `tests-memory/banner-tests.lisp` (append)
- Create: `tests-memory/golden/banners.sexp`
- Modify: `docs/superpowers/specs/2026-09-03-banner-round-trip-design.md` §4 (amendment)

**Interfaces:**
- Produces: source `memory-banner` with slots `banner-key banner-note
  banner-position banner-kind banner-date banner-dated-p banner-link
  banner-text`; `(capture-memory-dir graph dir &key producer (banners t))`;
  beliefs `(:banner . key) "annotates" (:memory-note . name)` with
  `method` = kind string, and `(:memory-note . name) "superseded-by"
  (:memory-note . link)` for `:superseded`/`:stale` with a link;
  `(banner-listing graph dir) => rows (note position kind date link
  text-digest dated-p)`.

- [ ] **Step 1: Amend the spec (§4)**

The belief series is single-valued per `(producer subject relation)`:
`record-belief` closes the predecessor when a different object arrives
(unit 1 §4). A note with two banners would have its first `carries`
superseded by the second. So the **banner is the subject**:

Replace the §4 table's first row with:

```
| `annotates` | subject `(:banner . "<note>#<n>")`, object `(:memory-note . name)`, `method` = kind | every banner |
```

and add one sentence after the table: "The banner is the subject
because a note may carry several banners and a belief series is
single-valued per subject and relation (unit 1 §4); a reader reaches a
note's banners through claims touching the note as object, which
`retrieve` and `claims-touching :role :either` do." Also in §5's prompt
replace "the record with relation `carries` is the banner" with "call
`retrieve` with endpoint `memory-note:<name>`; the item whose relation
is `annotates` is the banner, and its `cite` is your evidence".

- [ ] **Step 2: Write the failing tests**

Append to `tests-memory/banner-tests.lisp`:

```lisp
(defun %capture-banners-fixture (g)
  (mem:capture-memory-dir g (%banner-fixture-dir) :producer +p+))

(defun %annotations (g name)
  "The ANNOTATES beliefs touching NAME as object."
  (remove "annotates"
          (st:claims-touching g 'mem:belief :memory-note name :role :object)
          :key #'st:claim-relation :test-not #'string=))

(test capture-records-a-superseded-note-as-superseded-by-its-link
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((rs (mem:recall g '(:memory-note . "superseded")
                          :relation "superseded-by")))
      (is (= 1 (length rs)))
      (let ((r (first rs)))
        (is-true (mem:belief-record-current-p r))
        (is (eq :asserted (mem:belief-record-standing r)))
        (is (string= "android-sqlite-peer"
                     (st:claim-object-key (mem:belief-record-claim r))))
        (is (local-time:timestamp=
             (%ts "2026-07-22T00:00:00Z")
             (te:bound-earliest
              (te:extent-start (mem:belief-record-extent r)))))))
    (let ((as (%annotations g "superseded")))
      (is (= 1 (length as)))
      (is (string= "superseded#1" (st:claim-subject-key (first as))))
      (is (string= "superseded" (st:claim-method (first as)))))))

(test an-update-annotates-but-never-supersedes
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (is (= 1 (length (%annotations g "update"))))
    (is (null (mem:recall g '(:memory-note . "update")
                          :relation "superseded-by")))
    ;; a linking correction is still an addendum
    (is (= 2 (length (%annotations g "two"))))
    (is (null (mem:recall g '(:memory-note . "two")
                          :relation "superseded-by")))))

(test the-banner-node-holds-the-text-and-its-date
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((node (first (gdb:index-lookup g 'mem:memory-banner
                                         'mem:banner-key "two#2"))))
      (is (search "Stage 5 is NOT" (mem:banner-text node)))
      (is (string= "correction" (mem:banner-kind node)))
      (is (string= "test-suite-roadmap" (mem:banner-link node)))
      (is (null (mem:banner-dated-p node)))
      (is (string= "2026-07-10T10:00:00Z" (mem:banner-date node))
          "an undated banner starts at the note's MODIFIED"))
    (let ((node (first (gdb:index-lookup g 'mem:memory-banner
                                         'mem:banner-key "stale#1"))))
      (is-true (mem:banner-dated-p node))
      (is (string= "2026-07-05T00:00:00Z" (mem:banner-date node))))))

(test a-second-capture-writes-nothing-new
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((before (length (st:claims-by-producer g 'mem:belief +p+))))
      (%capture-banners-fixture g)
      (is (= before (length (st:claims-by-producer g 'mem:belief +p+))))
      (is (= 1 (length (%annotations g "superseded")))))))

(test banners-off-captures-as-unit-one-did
  (with-two-stores (g b)
    (declare (ignore b))
    (mem:capture-memory-dir g (%banner-fixture-dir) :producer +p+
                            :banners nil)
    (is (null (%annotations g "superseded")))
    (is (= 1 (length (mem:recall g '(:memory-note . "superseded")
                                 :relation "content")))
        "control: the content belief is there")))

(defun %banner-golden-path ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/golden/banners.sexp"))

(test banner-listing-matches-the-golden
  "Capture-and-diff (programme SS11): ordering is the contract."
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((rows (mem:banner-listing g (%banner-fixture-dir)))
          (golden (with-open-file (in (%banner-golden-path))
                    (let ((*read-eval* nil)) (read in)))))
      (is (equal golden rows)
          "diff: ~s" (set-exclusive-or golden rows :test #'equal)))))
```

- [ ] **Step 3: Run to see them fail**

Expected: `:banners` unknown keyword / no `memory-banner` class.

- [ ] **Step 4: Implement**

`memory/schema.lisp` — inside `define-memory-store`'s `progn`, after the
`memory-note` source:

```lisp
       (st:def-source memory-banner ,graph-name
           ((banner-key      :type string)
            (banner-note     :type string)
            (banner-position :type integer)
            (banner-kind     :type string)
            (banner-date     :type string)
            (banner-dated-p  :type boolean)
            (banner-link     :type string)
            (banner-text     :type string))
         :identity     (:namespace :banner :key-slot banner-key)
         :space        :none
         :time         (:extent-fn memory-banner-validity-extent)
         :attribution  :none
         :sensitivity  (:class :restricted)
         :registration :none
         :indexed-text (:text-fn banner-text))
```

and after `memory-note-validity-extent`:

```lisp
(defun memory-banner-validity-extent (banner)
  "Valid from the banner's date (or the note's stamp), open-ended."
  (te:make-interval
   (te:exact-bound (local-time:parse-timestring (banner-date banner)))
   (te:unknown-bound)
   :semantics :validity :standing :asserted))
```

Update the macro's docstring first line to "the belief and trace
families and the memory-note and memory-banner sources".

`memory/capture.lisp` — after `%capture-note`:

```lisp
(defun %iso-date (ts)
  (local-time:format-rfc3339-timestring nil ts
                                        :timezone local-time:+utc-zone+))

(defun %capture-banner (graph name banner modified producer)
  "One banner as a node and its beliefs (banners spec SS4)."
  (let* ((key (format nil "~a#~a" name (banner-position banner)))
         (dated (banner-date banner))
         (date (if dated (%iso-date dated) modified))
         (kind (string-downcase (symbol-name (banner-kind banner))))
         (old (first (gdb:index-lookup graph 'memory-banner
                                       'banner-key key))))
    (flet ((fill (b)
             (setf (banner-note b) name
                   (banner-position b) (banner-position banner)
                   (banner-kind b) kind
                   (banner-date b) date
                   (banner-dated-p b) (and dated t)
                   (banner-link b) (or (banner-link banner) "")
                   (banner-text b) (banner-text banner))
             b))
      (if old
          (gdb:save (fill (gdb:copy old)))
          (fill (make-memory-banner :graph graph :banner-key key))))
    (let ((extent (te:make-interval
                   (te:exact-bound (local-time:parse-timestring date))
                   (te:unknown-bound)
                   :semantics :validity :standing :asserted)))
      (record-belief graph (cons :banner key) "annotates"
                     (cons :memory-note name)
                     :producer producer :standing :asserted
                     :method kind :extent extent)
      (when (and (banner-link banner)
                 (member (banner-kind banner) '(:superseded :stale)))
        (record-belief graph (cons :memory-note name) "superseded-by"
                       (cons :memory-note (banner-link banner))
                       :producer producer :standing :asserted
                       :extent extent)))))
```

The struct accessors `banner-position` etc. name BOTH the scanner
struct's readers and the node's slot accessors — that collides. Rename
the node slots' accessors by giving the `def-source` slots distinct
names: `bn-key bn-note bn-position bn-kind bn-date bn-dated-p bn-link
bn-text` (the source's slot names are the accessors). Use those in
`%capture-banner`, the extent-fn, the tests (`mem:bn-text`,
`mem:bn-key` …) and the exports; keep the scanner struct's `banner-*`
names. Update the spec §4 declaration to the `bn-` names in the same
commit.

`make-memory-banner`'s `:graph` initarg plus slots as keywords: pass all
slots at construction instead of `fill` when creating, and use
`copy`/`setf`/`save` for the update, mirroring `%capture-note`.

In `%capture-note`, after `record-belief` of the content, when banners
are on:

```lisp
      (when banners
        (dolist (b (scan-banners body))
          (%capture-banner graph name b modified producer)))
```

so `%capture-note` gains a `banners` parameter and
`capture-memory-dir` gains `&key producer (banners t)` and passes it.

`memory/banners.lisp` — append:

```lisp
(defun banner-listing (graph dir)
  "The deterministic shape capture-and-diff compares (SS4): per note in
name order, per banner in position order, (NOTE POSITION KIND DATE
LINK TEXT-DIGEST DATED-P); DATE is NIL when the banner took the note's
stamp, as CAPTURE-LISTING does for an unstamped note."
  (loop for path in (%note-files dir)
        for fm = (read-frontmatter path)
        for name = (or (getf fm :name) (pathname-name path))
        append (loop for b in (scan-banners
                               (nth-value 1 (read-frontmatter path)))
                     for key = (format nil "~a#~a" name (banner-position b))
                     for node = (first (gdb:index-lookup
                                        graph 'memory-banner 'bn-key key))
                     collect (list name (banner-position b)
                                   (and node (bn-kind node))
                                   (and node (bn-dated-p node)
                                        (bn-date node))
                                   (and node (plusp (length (bn-link node)))
                                        (bn-link node))
                                   (and node (body-digest (bn-text node)))
                                   (and node (bn-dated-p node))))))
```

Exports: `#:memory-banner #:make-memory-banner #:bn-key #:bn-note
#:bn-position #:bn-kind #:bn-date #:bn-dated-p #:bn-link #:bn-text
#:banner-listing`. Adjust the tests above to the `bn-` accessors.

- [ ] **Step 5: Generate the golden, read it, run twice**

```bash
sbcl --dynamic-space-size 4096 --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" \
  --eval '(ql:quickload :cl-llm/memory/tests :silent t)' \
  --eval '(in-package :cl-llm.memory/tests)' \
  --eval '(with-two-stores (g b) (declare (ignore b))
            (%capture-banners-fixture g)
            (let ((*print-pretty* t) (*print-right-margin* 78))
              (with-open-file (out (%banner-golden-path) :direction :output
                                   :if-exists :supersede)
                (pprint (mem:banner-listing g (%banner-fixture-dir)) out)
                (terpri out))))'
```

Read every row against the fixture: `correction` dated 07-01 with no
link; `plain` contributes no row; `stale` links `hosts-now`;
`superseded` links `android-sqlite-peer`; `two#2` has `date` NIL and
`dated-p` NIL and links `test-suite-roadmap`; `update` no link. Then
the memory suite twice; `capture.sexp` and `trace.sexp` unchanged.

- [ ] **Step 6: Commit**

```bash
git add memory/ tests-memory/banner-tests.lisp tests-memory/golden/banners.sexp \
        docs/superpowers/specs/2026-09-03-banner-round-trip-design.md
git commit -m "feat(memory): banners as nodes and asserted beliefs; the listing and its golden (#14 unit 3)"
```

---

### Task 3: The model pass — `annotate-banners`

**Files:**
- Create: `agent/annotate.lisp`
- Modify: `agent/packages.lisp`, `cl-llm.asd` (`cl-llm/agent`: `(:file "annotate")` after `agent`; `cl-llm/agent/tests`: `(:file "annotate-tests")` after `loop-tests`)
- Create: `tests-agent/annotate-tests.lisp`
- Modify: spec §5 (the prompt names `retrieve`, per Task 2's amendment)

**Interfaces:**
- Produces: `(annotation-tools stores &key producer) => list of three tools`
  (`recall`, `retrieve`, `conclude`, in that order);
  `(annotate-banners stores dir &key provider producer (max-tool-turns 4)
  (model-name "unknown")) => list of (note-name . decision-id-or-nil)`;
  `*annotation-instructions*` the system prompt.

- [ ] **Step 1: Write the failing tests**

`tests-agent/annotate-tests.lisp`:

```lisp
;;;; tests-agent/annotate-tests.lisp -- the model pass, scripted.
;;;; Banners spec SS5, SS7.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %banner-dir ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/fixtures/banners/"))

(test annotation-tools-are-exactly-three
  (with-stores (w p)
    (is (equal '("recall" "retrieve" "conclude")
               (mapcar #'llm:tool-name
                       (agent:annotation-tools (list w p) :producer +p+))))))

(defun %annotates-cite (g name)
  "The cite of NAME's first ANNOTATES belief."
  (mem:claim-cite
   (first (remove "annotates"
                  (st:claims-touching g 'mem:belief :memory-note name
                                      :role :object)
                  :key #'st:claim-relation :test-not #'string=))))

(test annotate-banners-records-one-decision-per-prose-banner
  "SS7: the model is scripted to do what the prompt asks; the pass
wires the scope, the producer and the evidence."
  (with-stores (w p)
    (mem:capture-memory-dir w (%banner-dir) :producer "capture/test")
    (let* ((notes-seen '())
           (provider
             (llm:make-mock-provider
              :responder
              (lambda (c)
                (let* ((msgs (llm:conversation-messages c))
                       (last (car (last msgs)))
                       (result (find-if (lambda (x)
                                          (typep x 'llm:tool-result-part))
                                        (llm:message-content last))))
                  (if (null result)
                      ;; first turn: the prompt names the note; ask for it
                      (let* ((text (llm:part-text
                                    (first (llm:message-content last))))
                             (name (subseq text
                                           (+ 6 (search "note: " text))
                                           (position #\Newline text
                                                     :start (search "note: " text)))))
                        (push name notes-seen)
                        (%tool-use "t1" "retrieve" "query" name
                                   "endpoints" (vector (format nil "memory-note:~a" name))))
                      (let* ((r (json:parse (llm:part-content result)))
                             (ev (coerce (json:jget r "evidence") 'list))
                             (ann (find-if (lambda (e) (search "|annotates|"
                                                               (or (json:jget e "cite") "")))
                                           ev)))
                        (if (and ann (search "\"decisions\"" (llm:part-content result)))
                            "done"
                            (if (json:jget r "outcome")
                                "done"
                                (%tool-use "t2" "conclude"
                                           "subject-namespace" "memory-note"
                                           "subject-key" (first notes-seen)
                                           "relation" "overturns"
                                           "object-namespace" "proposition"
                                           "object-key" "the old theory"
                                           "rule" "read-banner"
                                           "rule-version" "mock"
                                           "evidence" (vector (json:jget ann "cite")))))))))))
           (results (agent:annotate-banners (list w p) (%banner-dir)
                                            :provider provider
                                            :producer "claude-code/agent"
                                            :model-name "mock")))
      ;; update, correction, stale, two -- not superseded, not plain
      (is (equal '("correction" "stale" "two" "update")
                 (sort (mapcar #'car results) #'string<)))
      (is (every #'cdr results) "every candidate got a decision")
      (let* ((id (cdr (assoc "correction" results :test #'string=)))
             (rec (mem:trace w id :scope (list w p))))
        (is (string= "claude-code/agent" (mem:decision-record-producer rec)))
        (is (string= "read-banner" (mem:decision-record-rule rec)))
        (is (string= "mock" (mem:decision-record-rule-version rec)))
        (is (string= (%annotates-cite w "correction")
                     (mem:cite-record-cite
                      (first (mem:decision-record-evidence rec)))))
        (is (eq :resolved (mem:cite-record-state
                           (first (mem:decision-record-evidence rec)))))))))

(test annotate-banners-reports-a-declined-note-as-nil
  (with-stores (w p)
    (mem:capture-memory-dir w (%banner-dir) :producer "capture/test")
    (let* ((provider (llm:make-mock-provider
                      :responder (lambda (c) (declare (ignore c)) "no")))
           (results (agent:annotate-banners (list w p) (%banner-dir)
                                            :provider provider
                                            :producer "claude-code/agent")))
      (is (= 4 (length results)))
      (is (every (lambda (r) (null (cdr r))) results))
      (is (null (st:claims-by-producer w 'mem:trace "claude-code/agent"))
          "control: nothing was written"))))
```

The scripted responder is deliberately simple: turn 1 retrieves the
note, turn 2 concludes citing the `annotates` item, turn 3 says done.
Simplify it while implementing if the conversation shape allows (e.g.
count turns instead of inspecting text) — what must hold is that the
`evidence` passed to `conclude` is the `annotates` cite read from the
`retrieve` result.

- [ ] **Step 2: Run to see them fail**

- [ ] **Step 3: Implement `agent/annotate.lisp`**

```lisp
;;;; agent/annotate.lisp -- the tool surface's first consumer: a model
;;;; reads a note's prose banner and records what it overturns.
;;;; Banners spec SS5.

(in-package #:cl-llm.agent)

(defparameter +annotation-tool-names+ '("recall" "retrieve" "conclude"))

(defun annotation-tools (stores &key producer)
  "The three tools ANNOTATE-BANNERS offers, over STORES as PRODUCER."
  (let ((all (make-agent-tools stores :producer producer)))
    (mapcar (lambda (name)
              (find name all :key #'llm:tool-name :test #'string=))
            +annotation-tool-names+)))

(defparameter *annotation-instructions*
  "You are annotating one note of an agent's memory. Call retrieve
with query the note's name and endpoints [\"memory-note:<name>\"]; the
item whose cite contains |annotates| is the banner, and its cite is
your evidence. Read the banner text in that item. Then call conclude
once: subject-namespace memory-note, subject-key <name>, relation
overturns, object-namespace proposition, object-key one sentence
stating what the banner overturns, standing inferred, rule
read-banner, rule-version <model>, evidence [that cite]. Then reply
done. If the banner overturns nothing you can state, reply no."
  "The system prompt; <name> and <model> are filled per note (SS5).")

(defun %prose-banner-p (banner)
  (member (mem:banner-kind banner) '(:update :correction :stale)))

(defun %candidate-notes (dir)
  "(name . banners) for every note in DIR with a prose-target banner."
  (loop for path in (uiop:directory-files dir "*.md")
        for name = (pathname-name path)
        unless (string= "MEMORY" name)
          append (multiple-value-bind (fm body) (mem:read-frontmatter path)
                   (let ((bs (remove-if-not #'%prose-banner-p
                                            (mem:scan-banners body))))
                     (and bs (list (cons (or (getf fm :name) name) bs)))))))

(defun %newest-decision-by (graph cite producer scope since)
  "The newest decision citing CITE that PRODUCER made at or after SINCE."
  (loop for id in (mem:decisions-citing graph cite :scope scope)
        for rec = (mem:trace graph id :scope scope)
        when (and (string= producer (mem:decision-record-producer rec))
                  (not (local-time:timestamp< (mem:decision-record-at rec)
                                              since)))
          return id))

(defun annotate-banners (stores dir &key provider producer
                                         (max-tool-turns 4)
                                         (model-name "unknown"))
  "One ASK per note in DIR with a prose-target banner, over STORES (the
first is the write store) as PRODUCER, with three tools; the model's
reading lands as a decision citing the banner (SS5).  Returns (name .
decision-id-or-NIL) per candidate, name order; NIL is a declined
annotation, not an error."
  (let ((write (first stores))
        (tools (annotation-tools stores :producer producer)))
    (loop for (name . banners) in (sort (%candidate-notes dir)
                                        #'string< :key #'car)
          collect
          (let* ((since (local-time:now))
                 (system (format nil "~a~%~%note: ~a~%model: ~a"
                                 *annotation-instructions* name model-name))
                 (cite (mem:claim-cite
                        (find "annotates"
                              (st:claims-touching write 'mem:belief
                                                  :memory-note name
                                                  :role :object)
                              :key #'st:claim-relation :test #'string=))))
            (llm:ask (format nil "note: ~a~%Annotate this note." name)
                     :provider provider :system system :tools tools
                     :max-tool-turns max-tool-turns)
            (cons name (%newest-decision-by write cite producer
                                            stores since))))))
```

`mem:claim-cite` on NIL (a note captured with `:banners nil`) signals;
guard with `(when ann ...)` and skip such notes with `(name . nil)`.
`st:claims-touching` returns retracted claims too; `find` the first
current one if you prefer, and say so.

Exports: `#:annotation-tools #:annotate-banners
#:*annotation-instructions*`.

- [ ] **Step 4: Run the agent suite until green; update spec §5's prompt wording**

- [ ] **Step 5: Commit**

```bash
git add agent/annotate.lisp agent/packages.lisp cl-llm.asd tests-agent/annotate-tests.lisp \
        docs/superpowers/specs/2026-09-03-banner-round-trip-design.md
git commit -m "feat(agent): annotate-banners -- a model reads a prose banner and concludes (#14 unit 3)"
```

---

### Task 4: The live suite, docs, the run

**Files:**
- Create: `live-agent/packages.lisp`, `live-agent/live.lisp`
- Modify: `cl-llm.asd` (`cl-llm/agent/live`)
- Modify: `docs/agent-memory.md`, `docs/agent-tools.md`, `README.md`, `docs/ci.md`

- [ ] **Step 1: The live suite**

```lisp
(defsystem "cl-llm/agent/live"
  :description "Live: annotate-banners against a real provider. Requires CL_LLM_LIVE=1."
  :license "MIT"
  :depends-on ("cl-llm/agent" "cl-llm/agent/tests" "fiveam")
  :serial t
  :pathname "live-agent/"
  :components ((:file "packages") (:file "live"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-agent-live)
               (error "cl-llm/agent/live suite failed."))))
```

`live-agent/packages.lisp`: package `cl-llm.agent.live`, `(:use #:cl
#:fiveam #:cl-llm.agent/tests)`, nicknames as `tests-agent-prolog`.

`live-agent/live.lisp`:

```lisp
;;;; live-agent/live.lisp -- annotate-banners against a real provider.
;;;; Gated exactly as cl-llm/live: skipped without CL_LLM_LIVE.

(in-package #:cl-llm.agent.live)

(def-suite :cl-llm-agent-live)
(in-suite :cl-llm-agent-live)

(defun live-enabled-p ()
  (let ((v (uiop:getenv "CL_LLM_LIVE")))
    (and v (string/= v "") (string/= v "0"))))

(test live-annotate-banners-records-decisions-with-the-banner-as-evidence
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (with-stores (w p)
        (mem:capture-memory-dir w (%banner-dir) :producer "capture/live")
        (let ((results (agent:annotate-banners
                        (list w p) (%banner-dir)
                        :provider llm:*provider*
                        :producer "claude-code/live"
                        :model-name (or (llm:provider-default-model
                                         llm:*provider*)
                                        "unknown"))))
          (is (some #'cdr results) "at least one decision")
          (loop for (nil . id) in results when id
                do (let ((rec (mem:trace w id :scope (list w p))))
                     (is (string= "read-banner" (mem:decision-record-rule rec)))
                     (is (plusp (length (mem:decision-record-rule-version rec))))
                     (is (eq :resolved
                             (mem:cite-record-state
                              (first (mem:decision-record-evidence rec)))))))))))
```

`%banner-dir` must be exported from `cl-llm.agent/tests`. If
`llm:provider-default-model` is not the exported name, use what
`src/protocol.lisp` exports, or pass `"live"`.

Run it once offline to see it skip cleanly (`Did 0 checks` is fine for
a skip; the suite must load). If `CL_LLM_LIVE=1` and a key are
available in your environment, run it once and record the outcome in
the report; do not block on it.

- [ ] **Step 2: Docs**

`docs/agent-memory.md`: a "Banners" section after "Several stores":
the four shapes (one line each), the `memory-banner` node, the
`annotates` and `superseded-by` beliefs and why the banner is the
subject, `capture-memory-dir :banners`, `banner-listing`, the golden.
Update "What this is not": banner parsing is now this module's, the
model half is `cl-llm/agent`'s.

`docs/agent-tools.md`: a section "The first consumer: annotate-banners"
— signature, the three tools, the prompt's contract, that a declined
note is NIL, the live suite and how to run it.

README: one line in the Agent tools section. `docs/ci.md`: the live
suite is not run in CI; how to run it by hand.

- [ ] **Step 3: Run everything, commit, stop**

Run the six offline suites (the command in
`docs/superpowers/plans/2026-09-03-agent-tools.md` "Running tests" plus
nothing new — the live suite is not in it). Expected: memory 199 +
this plan's checks, agent 119 + this plan's checks, the other four
unchanged. Commit:

```bash
git add live-agent cl-llm.asd tests-agent/packages.lisp docs/agent-memory.md docs/agent-tools.md README.md docs/ci.md
git commit -m "docs(memory,agent): banners, the annotation pass, and its live suite (#14 unit 3)"
```

Do not push.

---

## Self-review

**Spec coverage.** §3 scanner → Task 1 (struct, four shapes, positions,
date, link, text, the six fixture cases). §4 record → Task 2 (node with
all slots, extent-fn, `annotates` with `method` = kind, `superseded-by`
for superseded/stale with link only, idempotency test, `:banners`
switch, listing, golden), with the subject amendment recorded. §5 model
pass → Task 3 (three tools, one ask per candidate, prompt, producer,
`(name . id-or-nil)`, declined = NIL). §6 layering → no new dependency
anywhere; the live system depends on the agent tests for the harness.
§7 tests → scanner (T1), capture (T2), golden (T2), offline pass (T3),
live pass (T4). §8 docs → Task 4. §9 acceptance → T2's golden over the
real shapes; T3's decision citing the banner.

**Placeholder scan.** Task 2 names the accessor collision and its
resolution (`bn-` slots) explicitly; Task 3 names the two guards
(`claim-cite` on NIL, retracted claims) and says what to do. Task 4's
live test names its one uncertain symbol and the fallback. No TBD.

**Type consistency.** `banner-*` readers are the scanner struct's;
`bn-*` are the node's; `scan-banners`, `banner-listing`,
`annotation-tools`, `annotate-banners` named identically across tasks.
`capture-memory-dir`'s new keyword is `:banners` everywhere. The
`annotates` relation and `(:banner . "<note>#<n>")` subject are the
same in Task 2's writer, Task 2's tests, Task 3's prompt and test.
