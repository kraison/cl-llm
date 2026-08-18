# The retrieval planner — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A deterministic planner that bounds the region and window before
retrieval, so expansion is scoped rather than approximated by hop count.

**Architecture:** A `bounds` record in the graph-free `cl-llm/rag`, each half
carrying its own reason from the standing vocabulary. Two separately callable
bounders derive a window and a box from seed evidence; `plan-bounds` combines
them, with caller-supplied values winning. Sources honour a bound by
excluding only what is *known* to fall outside it, and populate evidence
facets from chunk metadata so the whole mechanism is exercisable today.

**Tech Stack:** Common Lisp (SBCL), ASDF, FiveAM, `cl-temporal-extent`.

**Spec:** `docs/superpowers/specs/2026-08-18-retrieval-planner-design.md`
(committed `17cbe77`). Executors read both.

## Global Constraints

- **80 columns, hard**, counted in **codepoints not bytes** — these files
  contain `—` and `⚠`. Spaces only, never tabs.
- **Comments terse**, pointing at a doc, a GH issue or a SHA. Docstrings say
  what it does, what it returns, and the one trap a caller must know.
- **`cl-llm/rag` must not gain a graph dependency.** It depends on `cl-llm`
  and `cl-temporal-extent`, and nothing else.
- **`hit`, `retrieve`, `store-search` and `rag-ask` are public API and do not
  change.**
- **A bound excludes only what is KNOWN to fall outside it.** Evidence whose
  facet is absent is never excluded. Getting this backwards empties a
  map-less corpus the moment any bound exists.
- Do not push. Do not bump any version.
- **Never run two SBCLs at once.** A `mine-action` server and a `cl-mcp` REPL
  are resident; they are not building, so they do not contend, but do not
  start a second build of your own.
- Run tests **detached to a log file and read it** — `nohup sbcl
  --non-interactive ... > /tmp/log 2>&1 &` plus an until-loop that also
  checks the process is alive. Never `timeout N sbcl ... | tail`.
- **Baselines:** `cl-llm/rag/tests` **240**, `cl-llm/eval/tests` **91**,
  `cl-llm/rag/eval/tests` **31**. The last two must not move.
- **A test whose whole value is that it would fail must be shown to fail.**

In these files `cl-temporal-extent`'s package is reached as
`temporal-extent:` — there is no local nickname for it in `cl-llm.rag`, and
this plan does not add one.

---

### Task 1: The `bounds` record, and a `box` on evidence

**Files:**
- Modify: `rag/bundle.lisp` (append the record; add one slot to `evidence`)
- Modify: `rag/packages.lisp` (exports)
- Modify: `tests-rag/bundle.lisp` (append)

**Interfaces:**
- Produces, relied on by Tasks 2-5:
  - `(make-bounds &key box box-standing window window-standing)` → `bounds`
  - readers `bounds-box` `bounds-box-standing` `bounds-window`
    `bounds-window-standing`
  - `evidence` gains slot `box`, reader `evidence-box`, default `NIL`

- [ ] **Step 1: Write the failing tests**

Append to `tests-rag/bundle.lisp`:

```lisp
(test a-bounds-record-defaults-both-halves-to-indeterminate
  "⚠ Each half carries its OWN reason: a document corpus has no space at
all while having perfectly good validity time, so one shared standing
would force a lie about one of them."
  (let ((b (rag:make-bounds)))
    (is (null (rag:bounds-box b)))
    (is (null (rag:bounds-window b)))
    (is (eq :indeterminate (rag:bounds-box-standing b)))
    (is (eq :indeterminate (rag:bounds-window-standing b)))))

(test the-two-halves-of-a-bound-carry-independent-reasons
  (let ((b (rag:make-bounds :box '(0 0 1 1) :box-standing :asserted
                            :window nil :window-standing :searched-empty)))
    (is (equal '(0 0 1 1) (rag:bounds-box b)))
    (is (eq :asserted (rag:bounds-box-standing b)))
    (is (eq :searched-empty (rag:bounds-window-standing b)))))

(test evidence-carries-a-box-beside-its-extent
  "Unit 3's claim source and unit 2's metadata plumbing both write here, so
a filter reads one place regardless of where the facet came from."
  (let ((e (rag:make-evidence :chunk (rag:make-chunk "t" :document-id "d")
                              :method :dense :box '(1 2 3 4))))
    (is (equal '(1 2 3 4) (rag:evidence-box e)))
    (is (null (rag:evidence-extent e)))))
```

- [ ] **Step 2: Run the suite and confirm RED** (`MAKE-BOUNDS` undefined)

```bash
cd /home/raison/work/cl-llm
nohup sbcl --non-interactive \
  --eval '(ql:register-local-projects)' \
  --eval '(ql:quickload :cl-llm/rag/tests)' \
  --eval '(fiveam:run! (quote cl-llm.rag.test::cl-llm-rag-suite))' \
  > /tmp/planner-t1-red.log 2>&1 &
```

Record what you actually saw.

- [ ] **Step 3: Add the `box` slot**

In `rag/bundle.lisp`'s `evidence` defstruct, immediately after `precision`:

```lisp
  (box nil)           ; (min-lon min-lat max-lon max-lat), or NIL
```

- [ ] **Step 4: Add the record**

Append to `rag/bundle.lisp`:

```lisp
(defstruct bounds
  "The scope retrieval runs inside: a region and a window, each with its own
reason.  A bound EXCLUDES ONLY WHAT IS KNOWN TO FALL OUTSIDE IT -- evidence
whose facet is absent is never excluded, or a corpus with no geometry would
empty the moment a region existed (design, cl-llm#13 unit 2)."
  (box nil)                      ; (min-lon min-lat max-lon max-lat), or NIL
  (box-standing :indeterminate)
  (window nil)                   ; a TEMPORAL-EXTENT, or NIL
  (window-standing :indeterminate))
```

- [ ] **Step 5: Export the names**

In `rag/packages.lisp`, beside the bundle exports:

```lisp
   #:bounds #:make-bounds #:bounds-box #:bounds-box-standing
   #:bounds-window #:bounds-window-standing #:evidence-box
```

- [ ] **Step 6: Run the suite and confirm GREEN.** Expected 240 + 9; report
      the number you measured and decompose it per test.

- [ ] **Step 7: Commit**

```bash
git add rag/bundle.lisp rag/packages.lisp tests-rag/bundle.lisp
git commit -m "feat(rag): the bounds record, and a box on evidence (#13)

Each half of a bound carries its own reason: a document corpus has no
spatial facet while having perfectly good validity time.  [skip-docs]"
```

---

### Task 2: The two bounders

**Files:**
- Modify: `rag/bundle.lisp` (append)
- Modify: `rag/packages.lisp` (exports)
- Modify: `tests-rag/bundle.lisp` (append)

**Interfaces:**
- Consumes: Task 1's records; `evidence-extent`, `evidence-box`.
- Produces, relied on by Task 3:
  - `(temporal-bound evidence)` → `(values <temporal-extent or NIL> <standing>)`
  - `(spatial-bound evidence)` → `(values <box or NIL> <standing>)`

- [ ] **Step 1: Write the failing tests**

Append to `tests-rag/bundle.lisp`:

```lisp
(defun %ev-at (doc-id &key extent box)
  (rag:make-evidence :chunk (rag:make-chunk (format nil "t-~a" doc-id)
                                            :document-id doc-id)
                     :method :dense :extent extent :box box))

(defun %interval (y1 y2)
  (temporal-extent:make-interval
   (temporal-extent:exact-bound
    (local-time:parse-timestring (format nil "~a-01-01T00:00:00Z" y1)))
   (temporal-extent:exact-bound
    (local-time:parse-timestring (format nil "~a-01-01T00:00:00Z" y2)))
   :semantics :validity))

(test temporal-bound-reports-indeterminate-when-there-is-nothing-to-look-at
  "⚠ :INDETERMINATE and :SEARCHED-EMPTY are the pair most easily conflated,
and conflating them is the failure this vocabulary exists to prevent."
  (multiple-value-bind (w standing) (rag:temporal-bound '())
    (is (null w))
    (is (eq :indeterminate standing))))

(test temporal-bound-reports-searched-empty-when-no-seed-carries-an-extent
  (multiple-value-bind (w standing)
      (rag:temporal-bound (list (%ev-at "a") (%ev-at "b")))
    (is (null w))
    (is (eq :searched-empty standing))))

(test a-derived-window-encloses-every-seed-extent-and-is-inferred
  (multiple-value-bind (w standing)
      (rag:temporal-bound (list (%ev-at "a" :extent (%interval 2001 2002))
                                (%ev-at "b" :extent (%interval 2005 2006))
                                (%ev-at "c")))
    (is (eq :inferred standing)
        "a derived bound is INFERRED -- it was not observed")
    (is (local-time:timestamp=
         (local-time:parse-timestring "2001-01-01T00:00:00Z")
         (temporal-extent:bound-earliest (temporal-extent:extent-start w))))
    (is (local-time:timestamp=
         (local-time:parse-timestring "2006-01-01T00:00:00Z")
         (temporal-extent:bound-latest (temporal-extent:extent-end w))))))

(test a-window-derived-from-one-instant-is-an-instant-not-an-interval
  "⚠ MAKE-INTERVAL signals when its two bounds are exact and equal, so a
union over extents that share one moment MUST build an instant."
  (let* ((ts (local-time:parse-timestring "2003-03-03T00:00:00Z"))
         (inst (temporal-extent:make-instant (temporal-extent:exact-bound ts)
                                             :semantics :validity)))
    (multiple-value-bind (w standing)
        (rag:temporal-bound (list (%ev-at "a" :extent inst)
                                  (%ev-at "b" :extent inst)))
      (is (eq :inferred standing))
      (is (temporal-extent:extent-instant-p w)))))

(test spatial-bound-mirrors-the-temporal-one
  (multiple-value-bind (b standing) (rag:spatial-bound '())
    (is (null b))
    (is (eq :indeterminate standing)))
  (multiple-value-bind (b standing)
      (rag:spatial-bound (list (%ev-at "a") (%ev-at "b")))
    (is (null b))
    (is (eq :searched-empty standing)))
  (multiple-value-bind (b standing)
      (rag:spatial-bound (list (%ev-at "a" :box '(0 0 2 2))
                               (%ev-at "b" :box '(1 -1 3 1))
                               (%ev-at "c")))
    (is (eq :inferred standing))
    (is (equal '(0 -1 3 2) b) "the enclosing box, not the first one")))
```

- [ ] **Step 2: Run and confirm RED** (`TEMPORAL-BOUND` undefined)

- [ ] **Step 3: Write the bounders**

Append to `rag/bundle.lisp`:

```lisp
(defun %extent-earliest (e)
  (temporal-extent:bound-earliest (temporal-extent:extent-start e)))

(defun %extent-latest (e)
  (temporal-extent:bound-latest (temporal-extent:extent-end e)))

(defun %union-extents (extents)
  "The enclosing extent of EXTENTS.  An :UNBOUNDED edge swallows everything
past it.  ⚠ Builds an INSTANT when the two edges coincide exactly --
MAKE-INTERVAL signals on equal exact bounds."
  (let* ((lo (if (some (lambda (e) (eq :unbounded (%extent-earliest e)))
                       extents)
                 :unbounded
                 (reduce (lambda (a b) (if (local-time:timestamp< a b) a b))
                         (mapcar #'%extent-earliest extents))))
         (hi (if (some (lambda (e) (eq :unbounded (%extent-latest e)))
                       extents)
                 :unbounded
                 (reduce (lambda (a b) (if (local-time:timestamp< a b) b a))
                         (mapcar #'%extent-latest extents))))
         (start (temporal-extent:make-bound lo lo))
         (end (temporal-extent:make-bound hi hi)))
    (if (eq := (temporal-extent:bound-compare start end))
        (temporal-extent:make-instant start :semantics :validity
                                            :standing :inferred)
        (temporal-extent:make-interval start end :semantics :validity
                                                 :standing :inferred))))

(defun temporal-bound (evidence)
  "Two values: the enclosing TEMPORAL-EXTENT of EVIDENCE's extents, and the
standing saying how it was arrived at -- :INFERRED when derived,
:SEARCHED-EMPTY when nothing carried one, :INDETERMINATE when there was
nothing to look at (design, cl-llm#13 unit 2)."
  (let ((extents (remove nil (mapcar #'evidence-extent evidence))))
    (cond ((null evidence) (values nil :indeterminate))
          ((null extents) (values nil :searched-empty))
          (t (values (%union-extents extents) :inferred)))))

(defun %union-boxes (boxes)
  "The enclosing (MIN-LON MIN-LAT MAX-LON MAX-LAT) of BOXES."
  (list (reduce #'min (mapcar #'first boxes))
        (reduce #'min (mapcar #'second boxes))
        (reduce #'max (mapcar #'third boxes))
        (reduce #'max (mapcar #'fourth boxes))))

(defun spatial-bound (evidence)
  "Two values: the enclosing box of EVIDENCE's boxes, and the standing
saying how it was arrived at.  Same vocabulary as TEMPORAL-BOUND."
  (let ((boxes (remove nil (mapcar #'evidence-box evidence))))
    (cond ((null evidence) (values nil :indeterminate))
          ((null boxes) (values nil :searched-empty))
          (t (values (%union-boxes boxes) :inferred)))))
```

- [ ] **Step 4: Export**

```lisp
   #:temporal-bound #:spatial-bound
```

- [ ] **Step 5: Run and confirm GREEN.** Report the count and decompose it.

- [ ] **Step 6: Prove the standing distinction is load-bearing**

Make `temporal-bound` return `:searched-empty` for the empty-evidence case
too — collapsing the two reasons, which is the tidy-up someone would make.
`temporal-bound-reports-indeterminate-when-there-is-nothing-to-look-at` MUST
go red. Restore, reconfirm, `git status` clean. Report the observed red.

- [ ] **Step 7: Commit**

```bash
git add rag/bundle.lisp rag/packages.lisp tests-rag/bundle.lisp
git commit -m "feat(rag): derive a window and a box from the seeds (#13)

Four standings, each meaning something true: INFERRED derived,
SEARCHED-EMPTY looked and found none, INDETERMINATE nothing to look at.
[skip-docs]"
```

---

### Task 3: Combining, with precedence

**Files:**
- Modify: `rag/bundle.lisp` (append)
- Modify: `rag/packages.lisp` (exports)
- Modify: `tests-rag/bundle.lisp` (append)

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces, relied on by Task 5:
  `(plan-bounds evidence &key box window)` → `bounds`

- [ ] **Step 1: Write the failing tests**

```lisp
(test supplied-bounds-win-and-are-asserted
  (let ((b (rag:plan-bounds (list (%ev-at "a" :extent (%interval 2001 2002)))
                            :box '(9 9 10 10))))
    (is (equal '(9 9 10 10) (rag:bounds-box b)))
    (is (eq :asserted (rag:bounds-box-standing b))
        "the caller asserts the scope; it was not derived")))

(test the-two-halves-resolve-independently
  "⚠ The reason the bounders are separate operations: an agent pins the
window it cares about and lets the region follow from the evidence."
  (let* ((seeds (list (%ev-at "a" :extent (%interval 2001 2002)
                                  :box '(0 0 1 1))))
         (b (rag:plan-bounds seeds :window (%interval 1990 1991))))
    (is (eq :asserted (rag:bounds-window-standing b)))
    (is (eq :inferred (rag:bounds-box-standing b)))
    (is (equal '(0 0 1 1) (rag:bounds-box b)))))

(test planning-over-nothing-is-indeterminate-on-both-halves
  (let ((b (rag:plan-bounds '())))
    (is (eq :indeterminate (rag:bounds-box-standing b)))
    (is (eq :indeterminate (rag:bounds-window-standing b)))))
```

- [ ] **Step 2: Run and confirm RED**

- [ ] **Step 3: Write it**

```lisp
(defun plan-bounds (evidence &key box window)
  "The scope to retrieve inside: BOX and WINDOW when supplied, otherwise
derived from EVIDENCE.  Each half resolves independently, so a caller may
pin one and let the other follow.  A supplied value is :ASSERTED."
  (multiple-value-bind (derived-box box-standing) (spatial-bound evidence)
    (multiple-value-bind (derived-window window-standing)
        (temporal-bound evidence)
      (make-bounds :box (or box derived-box)
                   :box-standing (if box :asserted box-standing)
                   :window (or window derived-window)
                   :window-standing (if window :asserted window-standing)))))
```

- [ ] **Step 4: Export `#:plan-bounds`**

- [ ] **Step 5: Run and confirm GREEN.** Report the count.

- [ ] **Step 6: Commit**

```bash
git add rag/bundle.lisp rag/packages.lisp tests-rag/bundle.lisp
git commit -m "feat(rag): plan-bounds, supplied winning over derived (#13)

[skip-docs]"
```

---

### Task 4: Facets from chunk metadata

**Files:**
- Modify: `rag/bundle.lisp` (`%hit->evidence`)
- Modify: `tests-rag/bundle.lisp` (append)

**Interfaces:**
- Consumes: Task 1's `box` slot.
- Produces: `dense-source` and `sparse-source` evidence carrying `extent`
  and `box` when the chunk's metadata declares them.

**Why this task exists:** without it the planner is a mechanism nothing
exercises — every source produces `NIL` facets, so derivation always reports
`:searched-empty` and filtering always excludes nothing. That is the shape of
the defect that survived four reviews in unit 1.

- [ ] **Step 1: Write the failing tests**

```lisp
(test a-source-reads-facets-from-chunk-metadata
  "Metadata carries the extent as its SEXP -- plain data, so it survives
persistence through any store -- and the box as four numbers."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store))
         (extent (%interval 2001 2002)))
    (rag:store-add
     store (list (rag:make-chunk "anti-tank mine" :document-id "d1"
                                 :metadata (list :extent
                                                 (temporal-extent:extent->sexp
                                                  extent)
                                                 :box '(0 0 1 1))
                                 :embedding (rag:embed embedder "anti-tank"))))
    (let ((ev (rag:collect-evidence (rag:make-dense-source embedder store)
                                    "anti-tank" :k 1)))
      (is (temporal-extent:temporal-extent-p (rag:evidence-extent (first ev))))
      (is (equal '(0 0 1 1) (rag:evidence-box (first ev)))))))

(test a-chunk-without-facet-metadata-yields-nil-facets
  "The map-less tenant's normal case: no keys, no facets, no error."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store)))
    (rag:store-add store
                   (list (rag:make-chunk "plain" :document-id "d1"
                                         :embedding (rag:embed embedder "plain"))))
    (let ((ev (rag:collect-evidence (rag:make-dense-source embedder store)
                                    "plain" :k 1)))
      (is (null (rag:evidence-extent (first ev))))
      (is (null (rag:evidence-box (first ev)))))))

(test a-malformed-extent-sexp-in-metadata-signals
  "⚠ A corrupt facet is a definition mistake, not an absence.  Silently
reading it as NIL would make a broken corpus look like a map-less one."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store)))
    (rag:store-add
     store (list (rag:make-chunk "bad" :document-id "d1"
                                 :metadata '(:extent (:not-an-extent 9))
                                 :embedding (rag:embed embedder "bad"))))
    (signals temporal-extent:invalid-extent
      (rag:collect-evidence (rag:make-dense-source embedder store)
                            "bad" :k 1))))
```

- [ ] **Step 2: Run and confirm RED**

- [ ] **Step 3: Read the facets in `%hit->evidence`**

Replace `%hit->evidence` in `rag/bundle.lisp`:

```lisp
(defun %chunk-facets (chunk)
  "Two values: the TEMPORAL-EXTENT and box CHUNK's metadata declares, or NIL
for each.  :EXTENT holds the extent SEXP -- plain data, so it survives any
store -- and SEXP->EXTENT signals on a malformed one rather than reading it
as an absence."
  (let ((md (chunk-metadata chunk)))
    (values (let ((s (getf md :extent)))
              (and s (temporal-extent:sexp->extent s)))
            (getf md :box))))

(defun %hit->evidence (hit method)
  "Wrap HIT as EVIDENCE attributed to METHOD.  STANDING is :INDETERMINATE:
no claim has been consulted, which is not the same as having consulted one
and found nothing (that is :SEARCHED-EMPTY, cl-llm#13 unit 3)."
  (multiple-value-bind (extent box) (%chunk-facets (hit-chunk hit))
    (make-evidence :chunk (hit-chunk hit)
                   :score (hit-score hit)
                   :method method
                   :extent extent
                   :box box
                   :standing :indeterminate)))
```

- [ ] **Step 4: Run and confirm GREEN.** Report the count.

⚠ **`fuse` WILL drop the new slot unless you add it — verified, not
suspected.** Its reconstruction lists all eight fields explicitly
(`:chunk :score :method :source :confidence :precision :extent :standing`)
and `box` is not among them, so a fused bundle would silently lose the facet
and Task 5's filter would see nothing while every test still passed. Add
`:box (evidence-box e)` to that form, and add a test asserting a fused
bundle retains the box.

- [ ] **Step 5: Commit**

```bash
git add rag/bundle.lisp tests-rag/bundle.lisp
git commit -m "feat(rag): sources read facets from chunk metadata (#13)

Without this the planner is a mechanism nothing exercises.  [skip-docs]"
```

---

### Task 5: Applying a bound

**Files:**
- Modify: `rag/bundle.lisp` (the two `collect-evidence` methods)
- Modify: `rag/packages.lisp` (exports)
- Modify: `tests-rag/bundle.lisp` (append)

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: `(bounded-evidence evidence bounds)` → filtered list; both
  sources honour `:bounds`.

- [ ] **Step 1: Write the failing tests**

```lisp
(test a-bound-excludes-what-is-known-to-fall-outside-it
  "Otherwise the filter does nothing and the absence test below passes
vacuously."
  (let ((inside (%ev-at "in" :extent (%interval 2005 2006)))
        (outside (%ev-at "out" :extent (%interval 1990 1991)))
        (b (rag:make-bounds :window (%interval 2004 2007)
                            :window-standing :asserted)))
    (let ((kept (rag:bounded-evidence (list inside outside) b)))
      (is (= 1 (length kept)))
      (is (string= "in" (rag:chunk-document-id
                         (rag:evidence-chunk (first kept))))))))

(test absence-is-never-exclusion
  "⚠ THE map-less tenant's guarantee.  If a bound rejected unknowns, the
first spatial bound would empty a corpus with no geometry -- and the tenant
that exists to prove the spatial facets are optional is the one it would
break."
  (let ((no-facet (%ev-at "plain"))
        (b (rag:make-bounds :window (%interval 2004 2007)
                            :window-standing :asserted
                            :box '(0 0 1 1) :box-standing :asserted)))
    (is (= 1 (length (rag:bounded-evidence (list no-facet) b))))))

(test a-bound-with-no-halves-keeps-everything
  (let ((evs (list (%ev-at "a" :extent (%interval 1990 1991))
                   (%ev-at "b"))))
    (is (= 2 (length (rag:bounded-evidence evs (rag:make-bounds)))))))

(test a-source-honours-a-bound-it-is-given
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store))
         (old (temporal-extent:extent->sexp (%interval 1990 1991))))
    (rag:store-add
     store (list (rag:make-chunk "old mine" :document-id "d1"
                                 :metadata (list :extent old)
                                 :embedding (rag:embed embedder "old"))))
    (is (null (rag:collect-evidence
               (rag:make-dense-source embedder store) "old" :k 5
               :bounds (rag:make-bounds :window (%interval 2004 2007)
                                        :window-standing :asserted))))))
```

- [ ] **Step 2: Run and confirm RED**

- [ ] **Step 3: Write the filter**

Append to `rag/bundle.lisp`:

```lisp
(defun %outside-window-p (evidence window)
  "True only when EVIDENCE's extent is KNOWN and lies wholly outside WINDOW."
  (let ((e (evidence-extent evidence)))
    (and window e
         (or (temporal-extent:extent-before-p e window)
             (temporal-extent:extent-after-p e window)))))

(defun %outside-box-p (evidence box)
  "True only when EVIDENCE's box is KNOWN and does not overlap BOX."
  (let ((b (evidence-box evidence)))
    (and box b
         (or (< (third b) (first box)) (> (first b) (third box))
             (< (fourth b) (second box)) (> (second b) (fourth box))))))

(defun bounded-evidence (evidence bounds)
  "EVIDENCE minus what BOUNDS is KNOWN to exclude.  ⚠ Absence is never
exclusion: an item whose facet is NIL always survives, or a corpus with no
geometry would empty the moment a region existed (design, cl-llm#13 unit 2)."
  (if (null bounds)
      evidence
      (remove-if (lambda (e)
                   (or (%outside-window-p e (bounds-window bounds))
                       (%outside-box-p e (bounds-box bounds))))
                 evidence)))
```

Then in both `collect-evidence` methods, replace `(declare (ignore bounds))`
and wrap the result:

```lisp
(defmethod collect-evidence ((source dense-source) query &key (k 5) bounds)
  (bounded-evidence
   (mapcar (lambda (h) (%hit->evidence h :dense))
           (store-search (dense-source-store source)
                         (embed (dense-source-embedder source) query)
                         k))
   bounds))
```

and the same shape for `sparse-source` with `:sparse` and `sparse-search`.

- [ ] **Step 4: Export `#:bounded-evidence`**

- [ ] **Step 5: Run and confirm GREEN.** Report the count.

- [ ] **Step 6: Prove the exclusion rule is load-bearing**

Change `%outside-window-p` to treat a `NIL` extent as outside — the
plausible "a bound should exclude what it cannot verify" reading.
`absence-is-never-exclusion` MUST go red. Restore, reconfirm, `git status`
clean. Report the observed red; this is the guarantee the map-less tenant
rests on, so it must be demonstrated rather than assumed.

- [ ] **Step 7: Commit**

```bash
git add rag/bundle.lisp rag/packages.lisp tests-rag/bundle.lisp
git commit -m "feat(rag): sources honour a bound, absence never excluded (#13)

A bound excludes only what is KNOWN to fall outside it.  [skip-docs]"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/evidence-bundle.md`
- Modify: `README.md`

**This is the commit that carries the unit's documentation** — every prior
task used `[skip-docs]`.

- [ ] **Step 1: Extend `docs/evidence-bundle.md`**

Read it first and match its structure and register. Add a section covering:

- What the planner is for: it produces a **scope**, not a ranking. Weighting
  within the scope is unit 3.
- The `bounds` record, and why each half carries its own reason — a document
  corpus has no spatial facet while having perfectly good validity time.
- `temporal-bound` and `spatial-bound` as separately callable operations,
  with the four-standing table and what each member means.
- `plan-bounds` and supplied-wins precedence, and that the halves resolve
  independently so a caller can pin one.
- **The exclusion rule**, stated plainly: a bound excludes only what is
  *known* to fall outside it, and why the map-less tenant depends on that.
- The metadata contract: `:extent` as the extent **sexp**, `:box` as four
  numbers, and that a malformed sexp signals rather than reading as absence.
- That the region is a **box, not a polygon** — precise containment needs
  the engine and belongs with unit 3's traversal.
- Update §4's account of `collect-evidence` — `bounds` is no longer
  accepted-and-ignored.

- [ ] **Step 2: Note it in the README**

Extend the bundle section: the planner scopes retrieval before it runs, and
lives in `cl-llm/rag` with no graph dependency. Match the surrounding prose.

- [ ] **Step 3: Run all three suites**, fresh detached processes, one at a
      time. Documentation-only, so `cl-llm/rag/tests` must equal Task 5's
      figure, `cl-llm/eval/tests` **91**, `cl-llm/rag/eval/tests` **31**. If
      one moves, stop and report.

- [ ] **Step 4: Commit**

```bash
git add docs/evidence-bundle.md README.md
git commit -m "docs: the retrieval planner (#13 unit 2)"
```

- [ ] **Step 5: Do not push. Report and stop.**

Report the three counts and stop. Pushing needs Kevin's approval; issue
updates happen after that.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| The `bounds` record, per-half reasons | 1 |
| `box` on evidence | 1 |
| Two bounders, four standings | 2 |
| Temporal union, instant edge case | 2 |
| Spatial union | 2 |
| `plan-bounds`, supplied wins, halves independent | 3 |
| Metadata contract, malformed sexp signals | 4 |
| Exclusion rule — absence never excludes | 5 (ablated in Step 6) |
| Sources honour a bound | 5 |
| No ranking, no polygon, no query parsing | 6 |
| `cl-llm/rag` gains no graph dependency | none — no task adds one; the system definition is untouched throughout |

**Placeholder scan:** none. Every code step carries the code; the docs step
enumerates required content.

**Type consistency:** `bounds-box`, `bounds-box-standing`, `bounds-window`,
`bounds-window-standing`, `evidence-box`, `temporal-bound`, `spatial-bound`,
`plan-bounds`, `bounded-evidence`, `%chunk-facets`, `%union-extents`,
`%union-boxes`, `%outside-window-p`, `%outside-box-p` — spelled identically
in every task that names them.

**One risk verified while writing this plan, not left as an instruction to
check:** `fuse` reconstructs evidence by listing all eight fields
explicitly, so the `box` slot Task 1 adds would be silently dropped there.
Task 4 Step 4 states that as a fact and requires a test. A plan that says
"go and confirm X" has not finished thinking; this one confirmed it.
