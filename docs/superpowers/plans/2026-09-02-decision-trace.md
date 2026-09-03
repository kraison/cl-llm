# Decision Trace (S6a unit 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record an agent's decisions as claims — what was concluded, from
which evidence, under which rule, or why it was refused — and read them
back as of the decision's instant, with what has moved since.

**Architecture:** A second claim family `trace` beside `belief` in
`cl-llm/memory`. A decision is an endpoint `(:decision . id)` carrying
`concluded` / `evidence` / `refused` claims whose objects are **cites**
(`"<family>|<identity-key>"`). `conclude` owns its transaction: stage the
proposal, `validate-writes` the transaction's own delta, commit or unwind
and record the refusal. `trace` resolves every cite with the engine's
`:as-of` and flags `changed-since`; `decisions-citing` is the reverse
lookup via the object-endpoint index.

**Tech Stack:** SBCL, ASDF, fiveam; vivace-graph `experiment` HEAD
(`graph-db/spacetime`, `validate-writes` in core), `cl-temporal-extent`,
ironclad (ids), local-time.

**Spec:** `docs/superpowers/specs/2026-09-02-decision-trace-design.md`
(read it first; §3–§5 are the contract every task below implements).
Companion: `docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md`
(the belief family this builds on) and `docs/agent-memory.md`.

## Global Constraints

- **Lisp style:** spaces only, never tabs; **hard 80-column limit** on
  code, comments, docstrings and strings. A 96-column line is a defect.
- **Comments are terse and point elsewhere** (spec section, issue number).
  No narrative in source.
- **Dependencies:** `cl-llm/memory` depends on `graph-db/spacetime`,
  `ironclad`, `babel` and nothing else. Never `cl-llm` core, never
  `cl-llm/rag`. No new dependency in this unit.
- **Engine:** vivace-graph `experiment` HEAD, unpinned. Locally
  `~/quicklisp/local-projects/graph-db.asd` symlinks to
  `~/work/vivace-graph-v3`; confirm `git -C ~/work/vivace-graph-v3
  rev-parse --short HEAD` is at or after `73ad4e2` before running tests.
  That checkout is shared with other sessions: **run suites in a
  subprocess, never in a shared REPL image**.
- **Order is the contract** (programme §11): every list a reader gets has
  a stated order; reordering is a regression.
- **Absence is not a value:** NIL from a read means "nothing recorded",
  never an absence standing, and tests assert the distinction.
- **Non-vacuity:** a negative test asserts the mechanism (the report's
  family) *and* the absence of the side effect (no belief written).
- **Docs travel with the code:** the pre-push hook refuses a source push
  without a doc change; this plan's last task is the doc pass, and each
  earlier commit touches only source + tests (no push until the end).
- **Internal engine symbols** are fenced in one function each, with the
  vivace-graph issue number beside them: `graph-db::writes`
  (kraison/vivace-graph#320) and the identity-key split
  (kraison/vivace-graph#321).

**Running tests.** Always as a subprocess, CI-style (`docs/ci.md`):

```bash
cd ~/work/cl-llm
sbcl --dynamic-space-size 4096 --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" \
  --eval '(ql:quickload :cl-llm/memory/tests :silent t)' \
  --eval '(asdf:test-system :cl-llm/memory)' 2>&1 | tail -40
```

A single test: replace the last `--eval` with
`--eval '(unless (fiveam:run! (quote cl-llm.memory/tests::TEST-NAME)) (sb-ext:exit :code 1))'`.
Green is `Did N checks. Pass: N (100%)`; the suite is 66 checks before
this plan. A run that prints no `Did N checks` line ran nothing
(`docs/ci.md`).

**Branch:** `feat/decision-trace` (exists; the spec is its first
commit). Commit after every task with the trailer:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016XhUGNmKWzsBV8PftSVfVo
```

---

## File structure

| File | Responsibility |
|---|---|
| `memory/schema.lisp` (modify) | adds the `trace` family beside `belief` |
| `memory/cite.lisp` (create) | a claim ↔ cite string, the identity-key split, `resolve-cite` (as-of + `changed-since`) |
| `memory/trace.lisp` (create) | `decision`, `conclude`, `decision-record`, `trace`, `decisions-citing`, `trace-listing` |
| `memory/packages.lisp` (modify) | exports |
| `cl-llm.asd` (modify) | `cite` and `trace` components; `cite-tests`, `trace-tests` |
| `tests-memory/cite-tests.lisp` (create) | spec §3 cite round-trip, §5 resolution states |
| `tests-memory/trace-tests.lisp` (create) | spec §4 write path, §5 read path, §7 tests |
| `tests-memory/golden/trace.sexp` (create) | capture-and-diff golden |
| `docs/agent-memory.md`, `README.md`, spec §3 (modify) | the user's view; one spec amendment |

Load order in the system: `packages`, `schema`, `write`, `recall`,
`capture`, **`cite`**, **`trace`** (cite uses `%open-p` from `write`;
trace uses everything).

---

### Task 1: The `trace` family, and the spec amendment for cite families

**Files:**
- Modify: `memory/schema.lisp` (after the `belief` declaration, line 9)
- Modify: `docs/superpowers/specs/2026-09-02-decision-trace-design.md` §3
- Modify: `memory/packages.lisp` (`:export`)
- Modify: `cl-llm.asd` (`cl-llm/memory/tests` components)
- Test: `tests-memory/schema-tests.lisp` (append)

**Interfaces:**
- Produces: classes `trace`, `trace-unary`, `trace-binary`; constructors
  `make-trace-unary`, `make-trace-binary` with the same initargs as the
  belief ones (`:graph :subject-namespace :subject-key :relation
  :object-namespace :object-key :producer :standing :extent :method
  :rule-version :confidence`).

- [ ] **Step 1: Amend spec §3 — a cite's family is package-qualified**

`st:claim-family` is keyed by the parent class **symbol**, so a bare
downcased name cannot be resolved back. In the spec's §3 paragraph
beginning "**A cite** is the string", replace

```
the parent claim class's name, downcased, then the engine's
```

with

```
the parent claim class's symbol, package-qualified and downcased
(`cl-llm.memory::belief`), then the engine's
```

- [ ] **Step 2: Write the failing schema test**

Append to `tests-memory/schema-tests.lisp`:

```lisp
(test the-trace-family-is-declared-beside-belief
  "Spec 2026-09-02 SS3: a second, non-temporal family in the same graph."
  (with-memory-graph (g)
    (let ((now (%ts "2026-09-02T12:00:00Z")))
      (gdb:with-transaction (:graph g)
        (mem:make-trace-binary
         :graph g
         :subject-namespace :decision :subject-key "d1"
         :relation "evidence"
         :object-namespace :claim :object-key "x|y|z"
         :producer +p+ :standing :observed
         :extent (te:make-instant (te:exact-bound now)
                                  :semantics :validity
                                  :standing :asserted)))
      (let ((cs (st:claims-touching g 'mem:trace :decision "d1"
                                    :role :subject)))
        (is (= 1 (length cs)))
        (is (typep (first cs) 'mem:trace-binary))
        (is (string= "x|y|z" (st:claim-object-key (first cs))))))))
```

- [ ] **Step 3: Run it to verify it fails**

Run the single-test command with `THE-TRACE-FAMILY-IS-DECLARED-BESIDE-BELIEF`.
Expected: a read error or `mem:make-trace-binary` unbound — the symbol
is not exported yet.

- [ ] **Step 4: Declare the family and export it**

In `memory/schema.lisp`, after the `belief` declaration:

```lisp
;; The decision trace (spec 2026-09-02 SS3): not temporal, so identity
;; is (producer subject object relation) and two cites of one claim
;; collapse to one EVIDENCE claim.
(st:def-claim-classes trace :cl-llm-memory)
```

In `memory/packages.lisp`, under `;; schema`, add:

```lisp
   #:trace #:trace-unary #:trace-binary
   #:make-trace-unary #:make-trace-binary
```

- [ ] **Step 5: Run the test to verify it passes, then the whole suite**

Expected: the new test passes; suite green, 66 + 3 checks.

- [ ] **Step 6: Commit**

```bash
git add memory/schema.lisp memory/packages.lisp tests-memory/schema-tests.lisp \
        docs/superpowers/specs/2026-09-02-decision-trace-design.md
git commit -m "feat(memory): the trace family beside belief (#14 unit 1)"
```

---

### Task 2: Cites — render, split, resolve as of an instant

**Files:**
- Create: `memory/cite.lisp`
- Modify: `memory/packages.lisp` (`:export`)
- Modify: `cl-llm.asd` (`cl-llm/memory` components: add `(:file "cite")`
  after `capture`; `cl-llm/memory/tests`: add `(:file "cite-tests")`
  after `capture-tests`)
- Create: `tests-memory/cite-tests.lisp`

**Interfaces:**
- Consumes: `%open-p` (`memory/write.lisp`), `st:claim-identity-key`,
  `st:claims-touching … :as-of`, `st:reaped-claim-p`,
  `st:reaped-claim-id`, `st:claim-version-stamp`, `st:claim-current-p`.
- Produces:
  - `(claim-cite claim) => string` — `"<pkg>::<parent>|<identity-key>"`.
  - `(cite-p x) => boolean`.
  - `(split-cite cite) => (values family-symbol subject-namespace
    subject-key identity-key)`; signals `belief-argument-error` on a
    malformed cite.
  - `(defstruct cite-record cite family state claim standing extent
    changed-since)` — `state` ∈ `:resolved :reaped :absent`.
  - `(resolve-cite graph cite at) => cite-record`.

- [ ] **Step 1: Write the failing cite tests**

`tests-memory/cite-tests.lisp`:

```lisp
;;;; tests-memory/cite-tests.lisp -- spec 2026-09-02 SS3 (cites) and
;;;; SS5 (resolution states, CHANGED-SINCE).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defparameter +cs+ '(:repo . "cl-llm"))

(defun %one-belief (g object &key (start "2026-09-01T08:00:00Z"))
  "Record and return one belief on +CS+ / ci-status."
  (gdb:with-transaction (:graph g)
    (mem:record-belief g +cs+ "ci-status" object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts start)))))

(test a-cite-names-the-family-and-the-identity-key
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite c)))
      (is (mem:cite-p cite))
      (is (string= (format nil "cl-llm.memory::belief|~a"
                           (st:claim-identity-key c))
                   cite))
      (multiple-value-bind (family ns key ikey) (mem:split-cite cite)
        (is (eq 'mem:belief family))
        (is (eq :repo ns))
        (is (string= "cl-llm" key))
        (is (string= (st:claim-identity-key c) ikey))))))

(test split-cite-honours-the-escape-rule
  "A | or \\ inside a key is escaped by the engine; the split must not
break on it (kraison/vivace-graph#321)."
  (with-memory-graph (g)
    (let* ((c (gdb:with-transaction (:graph g)
                (mem:record-belief g '(:path . "a|b\\c") "content"
                                   '(:digest . "d") :producer +p+
                                   :standing :asserted
                                   :extent (%open-from
                                            (%ts "2026-09-01T08:00:00Z")))))
           (cite (mem:claim-cite c)))
      (multiple-value-bind (family ns key) (mem:split-cite cite)
        (declare (ignore family))
        (is (eq :path ns))
        (is (string= "a|b\\c" key))))))

(test a-malformed-cite-is-an-argument-error
  (signals mem:belief-argument-error (mem:split-cite "no-family-here"))
  (signals mem:belief-argument-error
    (mem:split-cite "no.such.package::belief|p|:ns|k|r")))

(test a-cite-resolves-to-the-version-believed-then
  "SS5: after the cited belief is superseded, resolution AS OF an earlier
instant returns the open version, flagged :SUPERSEDED."
  (with-memory-graph (g)
    (let* ((green (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite green))
           (at (local-time:now)))
      (sleep 0.01)
      (%one-belief g '(:verdict . "red") :start "2026-09-02T08:00:00Z")
      (let ((r (mem:resolve-cite g cite at)))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (te:bound-unknown-p
             (te:extent-end (st:claim-extent (mem:cite-record-claim r))))
            "the as-of version still has its open validity end")
        (is (eq :superseded (mem:cite-record-changed-since r)))
        (is (eq :observed (mem:cite-record-standing r)))))))

(test a-retracted-cite-reads-as-retracted-since
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite c))
           (at (local-time:now)))
      (sleep 0.01)
      (gdb:with-transaction (:graph g) (mem:retract-belief c))
      (let ((r (mem:resolve-cite g cite at)))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (eq :retracted (mem:cite-record-changed-since r)))))))

(test an-unchanged-cite-has-no-changed-since
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (r (mem:resolve-cite g (mem:claim-cite c) (local-time:now))))
      (is (eq :resolved (mem:cite-record-state r)))
      (is (null (mem:cite-record-changed-since r))))))

(test a-cite-created-after-the-instant-is-absent
  "A claim that did not exist at AT resolves :ABSENT, not to its
current version."
  (with-memory-graph (g)
    (let ((at (local-time:now)))
      (sleep 0.01)
      (let* ((c (%one-belief g '(:verdict . "green")))
             (r (mem:resolve-cite g (mem:claim-cite c) at)))
        (is (eq :absent (mem:cite-record-state r)))
        (is (null (mem:cite-record-claim r)))))))

(test a-swept-cite-is-absent
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite c))
           (at (local-time:now)))
      (sleep 0.01)
      (gdb:with-transaction (:graph g)
        (st:delete-claims-by-producer g 'mem:belief +p+))
      (is (eq :absent (mem:cite-record-state
                       (mem:resolve-cite g cite at)))))))
```

- [ ] **Step 2: Add the components to the ASDF systems and run to see it fail**

In `cl-llm.asd`, `cl-llm/memory` components become:

```lisp
  :components ((:file "packages")
               (:file "schema")
               (:file "write")
               (:file "recall")
               (:file "capture")
               (:file "cite")
               (:file "trace"))
```

and `cl-llm/memory/tests` components:

```lisp
  :components ((:file "packages")
               (:file "harness")
               (:file "schema-tests")
               (:file "write-tests")
               (:file "recall-tests")
               (:file "capture-tests")
               (:file "cite-tests")
               (:file "trace-tests"))
```

Create empty placeholders so the system loads:
`memory/cite.lisp`, `memory/trace.lisp`, `tests-memory/trace-tests.lisp`
each containing only `(in-package #:cl-llm.memory)` (tests file:
`(in-package #:cl-llm.memory/tests)`). Run the suite. Expected: the eight
new tests fail with unbound `mem:claim-cite` etc.

- [ ] **Step 3: Implement `memory/cite.lisp`**

```lisp
;;;; memory/cite.lisp -- a claim as a string that survives regeneration,
;;;; and its resolution as of an instant.  Spec 2026-09-02 SS3, SS5.

(in-package #:cl-llm.memory)

(defun %family-parent-of (claim)
  "The registered parent class of CLAIM's family.  CLAIM-FAMILY is keyed
by the parent symbol only, so walk the precedence list until one
answers (an engine-side CLAIM-FAMILY-OF is asked for on
kraison/vivace-graph#321)."
  (dolist (class (sb-mop:class-precedence-list (class-of claim))
                 (%arg-error :claim claim "not a member of a claim family"))
    (let ((name (class-name class)))
      (when (and name (ignore-errors (st:claim-family name)))
        (return name)))))

(defun %render-family (symbol)
  (format nil "~(~a::~a~)"
          (package-name (symbol-package symbol)) (symbol-name symbol)))

(defun claim-cite (claim)
  "CLAIM as a cite: \"<pkg>::<parent>|<identity-key>\" (SS3)."
  (format nil "~a|~a" (%render-family (%family-parent-of claim))
          (st:claim-identity-key claim)))

(defun cite-p (x)
  (and (stringp x) (search "::" x) (position #\| x) t))

(defun %split-escaped (string)
  "STRING's |-separated fields, honouring \\ escapes -- the inverse of the
engine's rendering, kept here until kraison/vivace-graph#321 lands."
  (let ((fields '()) (buf (make-string-output-stream)) (esc nil))
    (loop for ch across string
          do (cond (esc (write-char ch buf) (setf esc nil))
                   ((char= ch #\\) (setf esc t))
                   ((char= ch #\|)
                    (push (get-output-stream-string buf) fields))
                   (t (write-char ch buf))))
    (push (get-output-stream-string buf) fields)
    (nreverse fields)))

(defun %parse-family (string)
  (let ((sep (search "::" string)))
    (unless sep (%arg-error :cite string "no package-qualified family"))
    (let* ((pkg (find-package (string-upcase (subseq string 0 sep))))
           (sym (and pkg (find-symbol (string-upcase
                                       (subseq string (+ sep 2)))
                                      pkg))))
      (unless (and sym (ignore-errors (st:claim-family sym)))
        (%arg-error :cite string "names no registered claim family"))
      sym)))

(defun split-cite (cite)
  "Four values: the family's parent symbol, the subject namespace
keyword, the subject key, and the identity key.  A cite the engine did
not render is a BELIEF-ARGUMENT-ERROR."
  (unless (cite-p cite) (%arg-error :cite cite "not a cite"))
  (let* ((bar (position #\| cite))
         (family (%parse-family (subseq cite 0 bar)))
         (ikey (subseq cite (1+ bar)))
         (fields (%split-escaped ikey)))
    (unless (>= (length fields) 4)
      (%arg-error :cite cite "identity key has fewer than four fields"))
    (let ((ns (second fields)))
      (unless (and (plusp (length ns)) (char= #\: (char ns 0)))
        (%arg-error :cite cite "subject namespace is not a keyword"))
      (values family
              (intern (string-upcase (subseq ns 1)) :keyword)
              (third fields)
              ikey))))

(defstruct cite-record
  "One cite resolved AS OF an instant (SS5).  STATE is :RESOLVED, :REAPED
or :ABSENT; CLAIM is the version believed then when :RESOLVED.
CHANGED-SINCE is :RETRACTED, :SUPERSEDED, :UPDATED or NIL."
  cite family (state :absent) claim standing extent changed-since)

(defun %changed-since (as-of-version current)
  (cond ((and (st:claim-current-p as-of-version)
              (not (st:claim-current-p current)))
         :retracted)
        ((and (%open-p as-of-version) (not (%open-p current)))
         :superseded)
        ((not (equal (st:claim-version-stamp as-of-version)
                     (st:claim-version-stamp current)))
         :updated)
        (t nil)))

(defun resolve-cite (graph cite at)
  "CITE as of AT (SS5): find the claim by identity among the subject's
claims, then ask the engine for the version believed at AT.  Never
substitutes the current version -- it is consulted only for
CHANGED-SINCE."
  (multiple-value-bind (family ns key ikey) (split-cite cite)
    (let* ((current (find ikey (st:claims-touching graph family ns key
                                                   :role :subject)
                          :key #'st:claim-identity-key :test #'string=))
           (id (and current (gdb:id current)))
           (then (and id
                      (find-if (lambda (c)
                                 (equalp id (if (st:reaped-claim-p c)
                                                (st:reaped-claim-id c)
                                                (gdb:id c))))
                               (st:claims-touching graph family ns key
                                                   :role :subject
                                                   :as-of at)))))
      (cond ((null then)
             (make-cite-record :cite cite :family family :state :absent))
            ((st:reaped-claim-p then)
             (make-cite-record :cite cite :family family :state :reaped))
            (t
             (make-cite-record :cite cite :family family :state :resolved
                               :claim then
                               :standing (st:claim-standing then)
                               :extent (st:claim-extent then)
                               :changed-since
                               (%changed-since then current)))))))
```

Export from `memory/packages.lisp`, new section:

```lisp
   ;; cite
   #:claim-cite #:cite-p #:split-cite #:resolve-cite
   #:cite-record #:cite-record-cite #:cite-record-family
   #:cite-record-state #:cite-record-claim #:cite-record-standing
   #:cite-record-extent #:cite-record-changed-since
```

- [ ] **Step 4: Run the cite tests; iterate until green**

Two things likely to need adjustment, in this order:

1. If `st:delete-claims-by-producer` is not the exported name, check
   `~/work/vivace-graph-v3/spacetime/package.lisp` for the sweep
   function and use it.
2. If the `:as-of` walk returns the *closed* version for the
   supersession test, the `at` captured before the supersession is not
   earlier than the close's stamp: raise the `sleep` to `0.05` and, if
   still red, print both stamps — `(st:claim-version-stamp c)` — to see
   whether the engine's `%st-now` and `local-time:now` disagree. Record
   what you find in the test's docstring.

Expected: suite green, 66 + 3 + 17 checks (count may differ by one or
two; what matters is `100%`).

- [ ] **Step 5: Commit**

```bash
git add memory/cite.lisp memory/trace.lisp memory/packages.lisp cl-llm.asd \
        tests-memory/cite-tests.lisp tests-memory/trace-tests.lisp
git commit -m "feat(memory): cites -- a claim by identity, resolved as of an instant (#14 unit 1)"
```

---

### Task 3: `conclude` — the concluded path

**Files:**
- Modify: `memory/trace.lisp`
- Modify: `memory/packages.lisp`
- Modify: `tests-memory/trace-tests.lisp`

**Interfaces:**
- Consumes: `record-belief`, `record-absence` (`memory/write.lisp`),
  `claim-cite` (Task 2), `make-trace-binary` (Task 1),
  `gdb:with-transaction`, `gdb:*transaction*`, `graph-db::writes`,
  `gdb:validate-writes`, `gdb:validation-report-violations`.
- Produces:
  - `(defstruct decision id outcome claim report at)`.
  - `(conclude graph proposal &key producer evidence rule rule-version
    confidence) => decision`.
  - `(decision-cites graph id) => trace claims on (:decision . id)`
    (internal helper `%decision-claims`, used by Task 5).

- [ ] **Step 1: Write the failing tests**

Replace `tests-memory/trace-tests.lisp` with:

```lisp
;;;; tests-memory/trace-tests.lisp -- spec 2026-09-02 SS4 (conclude),
;;;; SS5 (trace, decisions-citing), SS7.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defparameter +ts+ '(:repo . "cl-llm"))

(defun %belief (g relation object &key (start "2026-09-01T08:00:00Z"))
  (gdb:with-transaction (:graph g)
    (mem:record-belief g +ts+ relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts start)))))

(defun %trace-claims (g id)
  (st:claims-touching g 'mem:trace :decision id :role :subject))

(defun %relations (claims)
  (sort (mapcar #'st:claim-relation claims) #'string<))

(test conclude-writes-the-belief-and-its-trace
  "SS4: outcome :CONCLUDED; the belief is recorded with the rule; the
trace has one CONCLUDED and one EVIDENCE claim per cite."
  (with-memory-graph (g)
    (let* ((e1 (%belief g "ci-status" '(:verdict . "green")))
           (e2 (%belief g "last-push" '(:sha . "abc")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e1 e2)
                            :rule "green-and-pushed" :rule-version "1"
                            :confidence 0.9)))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (typep (mem:decision-claim d) 'mem:belief-binary))
      (is (string= "green-and-pushed"
                   (st:claim-method (mem:decision-claim d))))
      (is (string= "1" (st:claim-rule-version (mem:decision-claim d))))
      (is (typep (mem:decision-at d) 'local-time:timestamp))
      (let ((claims (%trace-claims g (mem:decision-id d))))
        (is (equal '("concluded" "evidence" "evidence")
                   (%relations claims)))
        (let ((concluded (find "concluded" claims
                               :key #'st:claim-relation :test #'string=)))
          (is (string= (mem:claim-cite (mem:decision-claim d))
                       (st:claim-object-key concluded)))
          (is (eq :inferred (st:claim-standing concluded)))
          (is (string= "green-and-pushed" (st:claim-method concluded))))
        (is (every (lambda (c) (eq :observed (st:claim-standing c)))
                   (remove "concluded" claims
                           :key #'st:claim-relation :test #'string=)))
        ;; SS6: the recalled belief carries the rule too
        (let ((r (first (mem:recall g +ts+ :relation "releasable"))))
          (is (string= "green-and-pushed"
                       (st:claim-method (mem:belief-record-claim r)))))))))

(test conclude-an-absence
  (with-memory-graph (g)
    (let ((d (mem:conclude g (list :absence +ts+ "release-date"
                                   :standing :searched-empty)
                           :producer +p+ :rule "looked-in-changelog")))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (typep (mem:decision-claim d) 'mem:belief-unary))
      (is (equal '("concluded") (%relations
                                 (%trace-claims g (mem:decision-id d))))))))

(test evidence-may-be-cites-and-duplicates-collapse
  (with-memory-graph (g)
    (let* ((e (%belief g "ci-status" '(:verdict . "green")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+
                            :evidence (list e (mem:claim-cite e))
                            :rule "r")))
      (is (equal '("concluded" "evidence")
                 (%relations (%trace-claims g (mem:decision-id d))))))))

(test concluding-the-object-already-held-is-a-new-decision
  "SS4: RECORD-BELIEF's idempotent path -- CONCLUDED cites the existing
belief, and the trace is new."
  (with-memory-graph (g)
    (let* ((held (%belief g "releasable" '(:verdict . "yes")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :rule "r")))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (equalp (gdb:id held) (gdb:id (mem:decision-claim d))))
      (is (= 1 (length (mem:recall g +ts+ :relation "releasable"))))
      (is (= 1 (length (%trace-claims g (mem:decision-id d))))))))

(test conclude-refuses-to-nest-in-a-callers-transaction
  (with-memory-graph (g)
    (gdb:with-transaction (:graph g)
      (signals mem:belief-argument-error
        (mem:conclude g (list :belief +ts+ "x" '(:v . "1")
                              :standing :inferred)
                      :producer +p+ :rule "r")))
    (is (null (mem:recall g +ts+)) "nothing was written")))

(test a-malformed-proposal-records-no-decision
  (with-memory-graph (g)
    (signals mem:belief-argument-error
      (mem:conclude g (list :belief +ts+ :not-a-string '(:v . "1")
                            :standing :inferred)
                    :producer +p+ :rule "r"))
    (signals mem:belief-argument-error
      (mem:conclude g (list :wish +ts+ "x") :producer +p+ :rule "r"))
    (is (null (st:claims-by-producer g 'mem:trace +p+))
        "no trace claims either")))
```

- [ ] **Step 2: Run to verify they fail**

Expected: `mem:conclude` unbound.

- [ ] **Step 3: Implement the concluded path in `memory/trace.lisp`**

```lisp
;;;; memory/trace.lisp -- decisions as claims: CONCLUDE, TRACE,
;;;; DECISIONS-CITING.  Spec 2026-09-02 SS3-SS5.

(in-package #:cl-llm.memory)

(defstruct decision
  "What CONCLUDE returns (SS4).  OUTCOME is :CONCLUDED or :REFUSED; CLAIM
the belief or absence written (NIL when refused); REPORT the
VALIDATION-REPORT or the commit condition (NIL when concluded); AT the
outcome claim's RECORDED-AT."
  id outcome claim report at)

(defun %mint-id ()
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))

(defun %instant-now ()
  (te:make-instant (te:exact-bound (local-time:now))
                   :semantics :validity :standing :asserted))

(defun %cite-of (x)
  (cond ((cite-p x) x)
        ((typep x 'st::claim) (claim-cite x))
        (t (%arg-error :evidence x "a claim or a cite string"))))

(defun %check-proposal (proposal)
  "Argument errors surface before any transaction opens (SS4 step 1)."
  (unless (and (consp proposal) (member (first proposal) '(:belief :absence)))
    (%arg-error :proposal proposal "(:belief ...) or (:absence ...)"))
  (destructuring-bind (kind subject relation &rest more) proposal
    (%check-endpoint :subject subject)
    (%check-relation relation)
    (when (eq kind :belief)
      (%check-endpoint :object (first more)))))

(defun %stage (graph proposal producer rule rule-version confidence)
  "Run the tenant writer for PROPOSAL inside the open transaction."
  (destructuring-bind (kind subject relation &rest more) proposal
    (ecase kind
      (:belief
       (destructuring-bind (object &key (standing :inferred) extent) more
         (apply #'record-belief graph subject relation object
                :producer producer :standing standing
                :method rule :rule-version rule-version
                :confidence confidence
                (and extent (list :extent extent)))))
      (:absence
       (destructuring-bind (&key (standing :searched-empty) extent) more
         (apply #'record-absence graph subject relation
                :producer producer :standing standing
                (and extent (list :extent extent))))))))

(defun %trace-claim (graph id relation ns key producer standing
                     &key method rule-version confidence)
  (make-trace-binary
   :graph graph
   :subject-namespace :decision :subject-key id
   :relation relation
   :object-namespace ns :object-key key
   :producer producer :standing standing :extent (%instant-now)
   :method method :rule-version rule-version :confidence confidence))

(defun %write-evidence (graph id cites producer)
  (dolist (cite (remove-duplicates cites :test #'string=))
    (%trace-claim graph id "evidence" :claim cite producer :observed)))

(defun conclude (graph proposal
                 &key producer evidence rule rule-version confidence)
  "Decide PROPOSAL from EVIDENCE under RULE (SS4).  Owns its
transaction; signals BELIEF-ARGUMENT-ERROR when one is already open.
Returns a DECISION."
  (when gdb:*transaction*
    (%arg-error :transaction gdb:*transaction*
                "CONCLUDE owns its transaction; call it outside one"))
  (%check-producer producer)
  (unless (stringp rule) (%arg-error :rule rule "a string naming the rule"))
  (%check-proposal proposal)
  (let ((id (%mint-id))
        (cites (mapcar #'%cite-of evidence))
        (claim nil) (outcome nil))
    (gdb:with-transaction (:graph graph)
      (setf claim (%stage graph proposal producer rule rule-version
                          confidence))
      (setf outcome
            (%trace-claim graph id "concluded" :claim (claim-cite claim)
                          producer :inferred
                          :method rule :rule-version rule-version
                          :confidence confidence))
      (%write-evidence graph id cites producer))
    (make-decision :id id :outcome :concluded :claim claim
                   :at (st:claim-recorded-at outcome))))
```

Exports (`memory/packages.lisp`, new section):

```lisp
   ;; trace
   #:conclude #:decision #:decision-id #:decision-outcome
   #:decision-claim #:decision-report #:decision-at
```

- [ ] **Step 4: Run the tests until green**

Watch for: `claim-cite` on the freshly staged, uncommitted `claim` —
`claim-identity-key` reads slots only, so it works before commit. If
`st::claim` is not the parent class name, find it with
`(st:claim-family-parent (st:claim-family 'belief))` and use `typep`
against that instead.

- [ ] **Step 5: Commit**

```bash
git add memory/trace.lisp memory/packages.lisp tests-memory/trace-tests.lisp
git commit -m "feat(memory): conclude -- a decision as trace claims (#14 unit 1)"
```

---

### Task 4: `conclude` — the refused path

**Files:**
- Modify: `memory/trace.lisp`
- Modify: `tests-memory/trace-tests.lisp` (append)

**Interfaces:**
- Consumes: `gdb:validate-writes`, `gdb:validation-report-violations`
  (each `(family write detail)`), `gdb:constraint-violation`,
  `graph-db::writes`.
- Produces: `conclude` returning `:refused` decisions; internal condition
  `%refused`.

- [ ] **Step 1: Write the failing tests**

Append to `tests-memory/trace-tests.lisp`:

```lisp
(defun %lapsed-belief (g &key (subject +ts+))
  "A belief on SUBJECT / ci-status held over [2026-01-01, 2026-03-01],
written closed: no current predecessor, so a re-assertion stages a
fresh claim (SS7).  Written closed in one go -- RECORD-BELIEF would
otherwise take its idempotent path against an open green belief on the
same subject and hand back THAT one."
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject "ci-status" '(:verdict . "green")
                       :producer +p+ :standing :observed
                       :extent (te:make-interval
                                (te:exact-bound (%ts "2026-01-01T00:00:00Z"))
                                (te:exact-bound (%ts "2026-03-01T00:00:00Z"))
                                :semantics :validity :standing :asserted))))

(defun %refused-families (g id)
  (sort (mapcar #'st:claim-object-key
                (remove "refused" (%trace-claims g id)
                        :key #'st:claim-relation :test-not #'string=))
        #'string<))

(test a-refused-proposal-is-recorded-and-writes-no-belief
  "SS4 step 2 / SS7: the extent-disjointness validator refuses the
overlap; the trace says so; RECALL shows no new belief."
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let ((d (mem:conclude g (list :belief +ts+ "ci-status"
                                   '(:verdict . "green")
                                   :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-02-01T00:00:00Z")))
                           :producer +p+ :rule "r")))
      (is (eq :refused (mem:decision-outcome d)))
      (is (null (mem:decision-claim d)))
      (is (typep (mem:decision-report d) 'gdb:validation-report))
      (is (equal '("subsystem") (%refused-families g (mem:decision-id d))))
      (is (= 1 (length (mem:recall g +ts+ :relation "ci-status"
                                   :include-retracted t)))
          "the lapsed belief is the only one; nothing new was written"))))

(test a-repeated-identity-is-refused-by-the-unique-family
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let ((d (mem:conclude g (list :belief +ts+ "ci-status"
                                   '(:verdict . "green")
                                   :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-01-01T00:00:00Z")))
                           :producer +p+ :rule "r")))
      (is (eq :refused (mem:decision-outcome d)))
      (is (member "unique" (%refused-families g (mem:decision-id d))
                  :test #'string=)))))

(test a-refused-decision-still-records-its-evidence
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let* ((e (%belief g "last-push" '(:sha . "abc")))
           (d (mem:conclude g (list :belief +ts+ "ci-status"
                                    '(:verdict . "green")
                                    :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-02-01T00:00:00Z")))
                            :producer +p+ :evidence (list e) :rule "r")))
      (is (equal '("evidence" "refused")
                 (%relations (%trace-claims g (mem:decision-id d)))))
      (is (typep (mem:decision-at d) 'local-time:timestamp)))))
```

Tests in this task call `%lapsed-belief` on the default subject, with
no open belief on it beforehand, so the closed claim is the only one in
the series.

- [ ] **Step 2: Run to verify they fail**

Expected: the first two fail at commit with a `constraint-violation`
escaping `conclude` (no refusal path yet).

- [ ] **Step 3: Implement the refused path**

In `memory/trace.lisp`, before `conclude`:

```lisp
(define-condition %refused (error)
  ((report :initarg :report :reader %refused-report))
  (:documentation "Unwinds CONCLUDE's transaction without committing
(SS4 step 2); never escapes CONCLUDE."))

(defun %staged-writes ()
  "The open transaction's delta, for VALIDATE-WRITES.  Internal reader;
export asked on kraison/vivace-graph#320."
  (graph-db::writes gdb:*transaction*))

(defun %violation-families (report-or-condition)
  "(family . text) per violation, first per family, in family order."
  (let ((rows (if (typep report-or-condition 'gdb:validation-report)
                  (loop for (family nil detail)
                          in (gdb:validation-report-violations
                              report-or-condition)
                        collect (cons (string-downcase (symbol-name family))
                                      (princ-to-string detail)))
                  (list (cons "commit"
                              (princ-to-string report-or-condition))))))
    (sort (remove-duplicates rows :key #'car :test #'string= :from-end t)
          #'string< :key #'car)))

(defun %write-refusal (graph id report cites producer)
  "A fresh transaction recording the refusal (SS4 step 2/3)."
  (let ((outcome nil))
    (gdb:with-transaction (:graph graph)
      (dolist (row (%violation-families report))
        (setf outcome
              (%trace-claim graph id "refused" :violation (car row)
                            producer :observed :method (cdr row))))
      (%write-evidence graph id cites producer))
    (make-decision :id id :outcome :refused :report report
                   :at (st:claim-recorded-at outcome))))
```

Replace the body of `conclude` after the `let` bindings with:

```lisp
    (handler-case
        (progn
          (gdb:with-transaction (:graph graph)
            (setf claim (%stage graph proposal producer rule rule-version
                                confidence))
            (let ((report (gdb:validate-writes graph (%staged-writes))))
              (when (gdb:validation-report-violations report)
                (error '%refused :report report)))
            (setf outcome
                  (%trace-claim graph id "concluded" :claim
                                (claim-cite claim) producer :inferred
                                :method rule :rule-version rule-version
                                :confidence confidence))
            (%write-evidence graph id cites producer))
          (make-decision :id id :outcome :concluded :claim claim
                         :at (st:claim-recorded-at outcome)))
      (%refused (c)
        (%write-refusal graph id (%refused-report c) cites producer))
      (gdb:constraint-violation (c)
        ;; The report is advisory (SS2); the commit is the enforcement.
        (%write-refusal graph id c cites producer)))
```

Why a condition and not `rollback`: a non-local exit out of
`with-transaction`'s body leaves it uncommitted and cleaned up
(`call-with-transaction`, `completed` stays NIL), and the engine's own
evaluator tests wrap `rollback` in a handler for the same reason.

- [ ] **Step 4: Run the whole suite until green**

If `validate-writes` reports the overlap under a family other than
`:subsystem`, read `validation-report-family-counts` in the REPL
subprocess and fix the test's expected string — the spec names the
mechanism (extent disjointness), not the keyword.

If the `:unique` test reports `:subsystem` instead (both refuse), accept
either with `member`; the assertion that matters is the second one,
"nothing new was written".

- [ ] **Step 5: Commit**

```bash
git add memory/trace.lisp tests-memory/trace-tests.lisp
git commit -m "feat(memory): conclude validates its delta first; a refusal is trace claims (#14 unit 1)"
```

---

### Task 5: `trace` and `decisions-citing`

**Files:**
- Modify: `memory/trace.lisp`
- Modify: `memory/packages.lisp`
- Modify: `tests-memory/trace-tests.lisp` (append)

**Interfaces:**
- Consumes: `resolve-cite`, `cite-record` (Task 2); trace claims
  (Tasks 3–4).
- Produces:
  - `(defstruct decision-record id producer at rule rule-version
    confidence outcome conclusion evidence refusals)`.
  - `(trace graph decision-id) => decision-record | NIL`.
  - `(decisions-citing graph claim-or-cite) => list of ids`.

- [ ] **Step 1: Write the failing tests**

Append:

```lisp
(test trace-reconstructs-a-decision
  (with-memory-graph (g)
    (let* ((e1 (%belief g "ci-status" '(:verdict . "green")))
           (e2 (%belief g "last-push" '(:sha . "abc")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e2 e1)
                            :rule "r" :rule-version "2" :confidence 0.5))
           (rec (mem:trace g (mem:decision-id d))))
      (is (string= (mem:decision-id d) (mem:decision-record-id rec)))
      (is (string= +p+ (mem:decision-record-producer rec)))
      (is (eq :concluded (mem:decision-record-outcome rec)))
      (is (string= "r" (mem:decision-record-rule rec)))
      (is (string= "2" (mem:decision-record-rule-version rec)))
      (is (= 0.5 (mem:decision-record-confidence rec)))
      (is (local-time:timestamp= (mem:decision-at d)
                                 (mem:decision-record-at rec)))
      (let ((c (mem:decision-record-conclusion rec)))
        (is (eq :resolved (mem:cite-record-state c)))
        (is (string= "yes" (st:claim-object-key
                            (mem:cite-record-claim c)))))
      ;; SS5 order: evidence in cite-string order, whatever was passed
      (let ((ev (mem:decision-record-evidence rec)))
        (is (= 2 (length ev)))
        (is (equal (sort (mapcar #'mem:claim-cite (list e1 e2)) #'string<)
                   (mapcar #'mem:cite-record-cite ev)))
        (is (every (lambda (r) (eq :resolved (mem:cite-record-state r)))
                   ev))
        (is (every (lambda (r) (null (mem:cite-record-changed-since r)))
                   ev)))
      (is (null (mem:decision-record-refusals rec))))))

(test trace-of-an-unknown-id-is-nil
  (with-memory-graph (g)
    (is (null (mem:trace g "no-such-decision")))))

(test trace-returns-the-evidence-as-believed-then
  "SS5 / #14 acceptance: the ground moved after the decision; the trace
still returns the version believed then, flagged."
  (with-memory-graph (g)
    (let* ((e (%belief g "ci-status" '(:verdict . "green")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e) :rule "r")))
      (sleep 0.01)
      (%belief g "ci-status" '(:verdict . "red")
               :start "2026-09-02T08:00:00Z")
      (let* ((rec (mem:trace g (mem:decision-id d)))
             (r (first (mem:decision-record-evidence rec))))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (string= "green" (st:claim-object-key
                              (mem:cite-record-claim r))))
        (is (te:bound-unknown-p
             (te:extent-end (st:claim-extent (mem:cite-record-claim r)))))
        (is (eq :superseded (mem:cite-record-changed-since r)))))))

(test trace-of-a-refusal
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let* ((d (mem:conclude g (list :belief +ts+ "ci-status"
                                    '(:verdict . "green")
                                    :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-02-01T00:00:00Z")))
                            :producer +p+ :rule "r"))
           (rec (mem:trace g (mem:decision-id d))))
      (is (eq :refused (mem:decision-record-outcome rec)))
      (is (null (mem:decision-record-conclusion rec)))
      (is (equal '("subsystem")
                 (mapcar #'car (mem:decision-record-refusals rec))))
      (is (stringp (cdr (first (mem:decision-record-refusals rec))))))))

(test decisions-citing-finds-the-conclusions-resting-on-a-belief
  "SS5: the reverse direction, newest first; an uncited belief yields
NIL, which is 'no decisions', not an absence."
  (with-memory-graph (g)
    (let* ((e (%belief g "ci-status" '(:verdict . "green")))
           (other (%belief g "last-push" '(:sha . "abc")))
           (d1 (mem:conclude g (list :belief +ts+ "a" '(:v . "1")
                                     :standing :inferred)
                             :producer +p+ :evidence (list e) :rule "r"))
           (d2 (progn (sleep 0.01)
                      (mem:conclude g (list :belief +ts+ "b" '(:v . "1")
                                            :standing :inferred)
                                    :producer +p+ :evidence (list e)
                                    :rule "r"))))
      (is (equal (list (mem:decision-id d2) (mem:decision-id d1))
                 (mem:decisions-citing g e)))
      (is (equal (mem:decisions-citing g e)
                 (mem:decisions-citing g (mem:claim-cite e))))
      (is (null (mem:decisions-citing g other))))))
```

- [ ] **Step 2: Run to verify they fail**

Expected: `mem:trace` unbound.

- [ ] **Step 3: Implement**

Append to `memory/trace.lisp`:

```lisp
(defstruct decision-record
  "TRACE's answer (SS5).  CONCLUSION is a CITE-RECORD or NIL; EVIDENCE a
list of CITE-RECORDs in cite order; REFUSALS (family . text) in family
order."
  id producer at rule rule-version confidence outcome
  conclusion evidence refusals)

(defun %decision-claims (graph id)
  (st:claims-touching graph 'trace :decision id :role :subject))

(defun %recorded-instant (claim)
  "RECORDED-AT as a TIMESTAMP; a trace claim always has one."
  (let ((at (st:claim-recorded-at claim)))
    (unless (typep at 'local-time:timestamp)
      (%arg-error :claim claim "a trace claim with no recorded-at"))
    at))

(defun trace (graph decision-id)
  "The decision DECISION-ID reconstructed as of its own instant (SS5),
or NIL when no such decision was recorded."
  (let* ((claims (%decision-claims graph decision-id))
         (outcome (find-if (lambda (c)
                             (member (st:claim-relation c)
                                     '("concluded" "refused")
                                     :test #'string=))
                           claims)))
    (when outcome
      (let* ((at (%recorded-instant outcome))
             (concluded (and (string= "concluded" (st:claim-relation outcome))
                             outcome))
             (evidence (sort (mapcar #'st:claim-object-key
                                     (remove "evidence" claims
                                             :key #'st:claim-relation
                                             :test-not #'string=))
                             #'string<))
             (refusals (sort (loop for c in claims
                                   when (string= "refused"
                                                 (st:claim-relation c))
                                     collect (cons (st:claim-object-key c)
                                                   (st:claim-method c)))
                             #'string< :key #'car)))
        (make-decision-record
         :id decision-id
         :producer (st:claim-producer outcome)
         :at at
         ;; NIL on the refused path: the rule is not recorded there.
         :rule (and concluded (st:claim-method concluded))
         :rule-version (and concluded (st:claim-rule-version concluded))
         :confidence (and concluded (st:claim-confidence concluded))
         :outcome (if concluded :concluded :refused)
         :conclusion (and concluded
                          (resolve-cite graph (st:claim-object-key concluded)
                                        at))
         :evidence (mapcar (lambda (cite) (resolve-cite graph cite at))
                           evidence)
         :refusals refusals)))))

(defun decisions-citing (graph claim-or-cite)
  "Ids of the decisions whose EVIDENCE cites CLAIM-OR-CITE, RECORDED-AT
descending then id (SS5).  NIL means no decisions cite it."
  (let* ((cite (%cite-of claim-or-cite))
         (claims (st:claims-touching graph 'trace :claim cite
                                     :role :object :relation "evidence")))
    (mapcar #'cdr
            (sort (mapcar (lambda (c) (cons (%recorded-instant c)
                                            (st:claim-subject-key c)))
                          claims)
                  (lambda (a b)
                    (or (local-time:timestamp> (car a) (car b))
                        (and (local-time:timestamp= (car a) (car b))
                             (string< (cdr a) (cdr b)))))))))
```

Exports, appended to the `;; trace` section:

```lisp
   #:trace #:decisions-citing
   #:decision-record #:decision-record-id #:decision-record-producer
   #:decision-record-at #:decision-record-rule
   #:decision-record-rule-version #:decision-record-confidence
   #:decision-record-outcome #:decision-record-conclusion
   #:decision-record-evidence #:decision-record-refusals
```

`trace` shadows nothing in CL (`cl:trace` is a macro): add
`(:shadow #:trace)` to the `cl-llm.memory` defpackage so the function is
this package's own symbol, and export it from there.

- [ ] **Step 4: Run the suite until green**

If `trace-returns-the-evidence-as-believed-then` resolves the closed
version, the same stamp question as Task 2 step 4 applies — the
decision's `at` must be later than the evidence's stamp and earlier than
the close's; the `sleep` guards the second.

- [ ] **Step 5: Commit**

```bash
git add memory/trace.lisp memory/packages.lisp tests-memory/trace-tests.lisp
git commit -m "feat(memory): trace -- a decision as of its instant; decisions-citing (#14 unit 1)"
```

---

### Task 6: Capture-and-diff golden for a trace listing

**Files:**
- Modify: `memory/trace.lisp` (`trace-listing`)
- Modify: `memory/packages.lisp`
- Modify: `tests-memory/trace-tests.lisp` (append)
- Create: `tests-memory/golden/trace.sexp`

**Interfaces:**
- Produces: `(trace-listing graph decision-ids) => rows` — per decision,
  in the given order: `(outcome rule conclusion-key-or-nil
  ((cite state changed-since) …) (family …))`. No ids, no timestamps:
  both are host-bound; identity keys are not, because the fixture uses
  fixed validity starts.

- [ ] **Step 1: Write the failing test**

```lisp
(defun %golden-trace-path ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/golden/trace.sexp"))

(defparameter +other+ '(:repo . "other")
  "The refused decision's subject: its lapsed belief must not share a
series with +TS+'s open ci-status, or RECORD-BELIEF's idempotent path
turns the refusal into a conclusion.")

(defun %trace-fixture (g)
  "Three decisions: one concluded, one refused, one whose ground moves.
Returns their ids in that order."
  (let* ((e1 (%belief g "ci-status" '(:verdict . "green")))
         (e2 (%belief g "last-push" '(:sha . "abc")))
         (d1 (mem:conclude g (list :belief +ts+ "releasable"
                                   '(:verdict . "yes") :standing :inferred
                                   :extent (%open-from
                                            (%ts "2026-09-01T09:00:00Z")))
                           :producer +p+ :evidence (list e1 e2)
                           :rule "green-and-pushed" :rule-version "1")))
    (%lapsed-belief g :subject +other+)
    (let ((d2 (mem:conclude g (list :belief +other+ "ci-status"
                                    '(:verdict . "green")
                                    :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-02-01T00:00:00Z")))
                            :producer +p+ :evidence (list e2)
                            :rule "re-assert")))
      (sleep 0.01)
      (let ((d3 (mem:conclude g (list :belief +ts+ "deployable"
                                      '(:verdict . "yes")
                                      :standing :inferred
                                      :extent (%open-from
                                               (%ts "2026-09-01T10:00:00Z")))
                              :producer +p+ :evidence (list e1)
                              :rule "green" :rule-version "1")))
        (sleep 0.01)
        (%belief g "ci-status" '(:verdict . "red")
                 :start "2026-09-02T08:00:00Z")
        (list (mem:decision-id d1) (mem:decision-id d2)
              (mem:decision-id d3))))))

(test trace-listing-matches-the-golden
  "Capture-and-diff (programme SS11): ordering is the contract."
  (with-memory-graph (g)
    (let* ((ids (%trace-fixture g))
           (rows (mem:trace-listing g ids))
           (golden (with-open-file (in (%golden-trace-path))
                     (let ((*package* (find-package :keyword)))
                       (read in)))))
      (is (equal golden rows)
          "diff: ~s" (set-exclusive-or golden rows :test #'equal)))))
```

`%lapsed-belief` writes on `+other+`, so `e1`'s series on `+ts+` is
untouched and `d2` stages a fresh, overlapping claim that the validator
refuses.

- [ ] **Step 2: Implement `trace-listing`**

```lisp
(defun trace-listing (graph decision-ids)
  "The deterministic shape capture-and-diff compares (SS7): one row per
id, in the given order, with no id or timestamp in it."
  (loop for id in decision-ids
        for rec = (trace graph id)
        collect (list (decision-record-outcome rec)
                      (decision-record-rule rec)
                      (let ((c (decision-record-conclusion rec)))
                        (and c (cite-record-cite c)))
                      (mapcar (lambda (r) (list (cite-record-cite r)
                                                (cite-record-state r)
                                                (cite-record-changed-since r)))
                              (decision-record-evidence rec))
                      (mapcar #'car (decision-record-refusals rec)))))
```

Export `#:trace-listing`.

- [ ] **Step 3: Generate the golden once, read it, commit it**

Run in a subprocess:

```bash
sbcl --dynamic-space-size 4096 --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" \
  --eval '(ql:quickload :cl-llm/memory/tests :silent t)' \
  --eval '(in-package :cl-llm.memory/tests)' \
  --eval '(with-memory-graph (g)
            (let ((*package* (find-package :keyword))
                  (*print-pretty* t) (*print-right-margin* 78))
              (with-open-file (out (%golden-trace-path) :direction :output
                                   :if-exists :supersede)
                (pprint (mem:trace-listing g (%trace-fixture g)) out)
                (terpri out))))'
```

Open `tests-memory/golden/trace.sexp` and check it **by reading**, row
by row, against the fixture: row 1 `:concluded`, two evidence cites both
`:resolved`, the `ci-status` one `:superseded` (the red belief landed
after); row 2 `:refused` with `("subsystem")`; row 3 `:concluded`, its
one cite `:resolved :superseded`. A golden that does not say what the
fixture means is wrong even if the test passes.

- [ ] **Step 4: Run the suite; it must be green twice in a row**

Two runs, because a host-bound value in the listing would pass once and
fail on the next process. Expected: green both times.

- [ ] **Step 5: Commit**

```bash
git add memory/trace.lisp memory/packages.lisp tests-memory/trace-tests.lisp \
        tests-memory/golden/trace.sexp
git commit -m "test(memory): capture-and-diff golden for the decision trace (#14 unit 1)"
```

---

### Task 7: Docs, CI check, and the issue

**Files:**
- Modify: `docs/agent-memory.md` (new section before "What this is not")
- Modify: `README.md` (§ Agent memory, after the `capture-memory-dir`
  paragraph, line ~224)
- Modify: `docs/agent-memory.md` "What this is not" paragraph
- No change to `docs/ci.md` — the memory suite is already wired and
  `test.yml` already runs `asdf:test-system :cl-llm/memory`.

- [ ] **Step 1: Add the section to `docs/agent-memory.md`**

Insert before `## What this is not`:

```markdown
## Decisions and their trace

A **decision** is what `conclude` records: a belief or an absence written
from evidence under a named rule — or a refusal, and why (design:
`docs/superpowers/specs/2026-09-02-decision-trace-design.md`,
kraison/cl-llm#14 unit 1). The trace is claims in a second family,
`trace`, on the endpoint `(:decision . id)`, so the reverse question —
which decisions rest on this belief — is an index lookup.

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
you get; the current one only sets the flag.

```lisp
(mem:trace g (mem:decision-id d))
;; => #S(decision-record :outcome :concluded :rule "green-and-pushed"
;;       :evidence (#S(cite-record :state :resolved :changed-since :superseded ...)
;;                  #S(cite-record :state :resolved :changed-since nil ...)) ...)
(mem:decisions-citing g ci-belief)   ; => decision ids, newest first
```

**Order is the contract:** evidence in cite-string order, refusals in
family order, `decisions-citing` by `recorded-at` descending then id.
`trace-listing` renders decisions as rows for capture-and-diff
(`tests-memory/golden/trace.sexp`).
```

Then edit "What this is not": replace `No traversal, no tool surface,
no planner, no LLM, no cross-namespace recall — those are
kraison/cl-llm#14 and #24.` with `No tool surface, no bounded
traversal, no LLM, no banner parsing (kraison/cl-llm#14 units 2 and
3) and no cross-namespace recall (#24).`

- [ ] **Step 2: Add the README paragraph**

After the `capture-memory-dir` paragraph in `README.md`'s "Agent memory"
section:

```markdown
`conclude` records a **decision** — a belief written from cited evidence
under a named rule, or a structurally recorded refusal — and `trace`
reads it back as of its own instant, each cite resolved to the version
believed then and flagged if it has moved since (kraison/cl-llm#14 unit
1; `docs/agent-memory.md`).
```

- [ ] **Step 3: Run the suite one more time, then push and read CI**

```bash
git add docs/agent-memory.md README.md
git commit -m "docs(memory): decisions and their trace (#14 unit 1)"
git push -u origin feat/decision-trace
gh pr create --title "feat(memory): the decision trace (#14 unit 1)" --body-file - <<'EOF'
S6a unit 1: decisions as trace claims. Spec: docs/superpowers/specs/2026-09-02-decision-trace-design.md.

- `trace` family beside `belief`; cites by claim identity (vg#303)
- `conclude` owns its transaction, validates the delta (vg#301) and records a refusal structurally
- `trace` resolves every cite `:as-of` the decision (vg#300) with `changed-since`; `decisions-citing` is the reverse lookup
- capture-and-diff golden; docs/agent-memory.md and README

Engine asks, non-blocking: kraison/vivace-graph#320, #321.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_016XhUGNmKWzsBV8PftSVfVo
EOF
gh run watch --exit-status
gh run view --log | grep -E 'Did [0-9]+ checks|vivace-graph @'
```

Expected: four `Did N checks` lines; the memory one is 66 + this plan's
checks. If the `vivace-graph @` sha is older than `73ad4e2`, the runner's
clone did not refresh — re-run the job before reading anything into a red.

- [ ] **Step 4: Update the issue**

Comment on kraison/cl-llm#14: unit 1 landed as PR `<n>` — the family,
`conclude`, `trace`, `decisions-citing`, the golden; the check counts
from CI; the two engine asks still open; unit 2 (tool surface) is next
and gets its own spec.

---

## Self-review

**Spec coverage.** §3 record → Tasks 1, 3, 4 (family, the three
relations, standings, slots, cite format incl. the amendment). §4 write
path → Tasks 3 (steps 1 and 3, idempotent path, nesting refusal,
argument errors before any write) and 4 (validate, unwind, refusal
transaction, commit-race catch, evidence on both outcomes). §5 read
path → Tasks 2 (three states, `changed-since`) and 5 (`trace`,
`decisions-citing`, order). §6 layering → no new dependency (Task 2
uses ironclad, already present; `sb-mop` is SBCL's own); internal
symbols fenced in `%staged-writes` and `%split-escaped`. §7 tests → all
seven bullets have a test: round-trip (T3, T5), refusal non-vacuous (T4,
both families), as-of (T2, T5), reverse (T5), idempotent (T3),
capture-and-diff (T6), nested call (T3). §8 acceptance → T5's
as-believed-then test and T4's no-belief-written assertion. §9 → issues
already filed; referenced in code comments.

**Placeholder scan.** None; every step carries its code. The one
"adjust if" in Task 2 step 4 and Task 4 step 4 names the exact symbol
to check and what to change.

**Type consistency.** `cite-record` fields (`cite family state claim
standing extent changed-since`) match between Task 2's struct, Task 5's
`trace` and Task 6's listing. `decision` (`id outcome claim report at`)
matches Tasks 3, 4 and the tests. `%trace-claim` signature `(graph id
relation ns key producer standing &key method rule-version confidence)`
is used identically in Tasks 3 and 4. `%cite-of` is defined in Task 3
and used by Task 5's `decisions-citing`. `trace` is shadowed from CL in
the package (Task 5 step 3).
