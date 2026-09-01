# Agent-memory tenant (`cl-llm/memory`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land cl-llm#16 — a third `def-source` and a `:temporal t` claim
family in which an agent records beliefs and absences, recalls them
bounded by validity with supersession and retraction visible, and captures
its own memory corpus deterministically.

**Architecture:** One new ASDF system `cl-llm/memory` (package
`cl-llm.memory`, directory `memory/`) over `graph-db/spacetime` only.
Four files: `schema.lisp` (the claim family and the `memory-note` source),
`write.lisp` (`record-belief`, `record-absence`, `retract-belief`),
`recall.lisp` (`recall` and `belief-record`), `capture.lisp`
(`capture-memory-dir`). Tests in `tests-memory/` run on a real on-disk
graph exactly as `tests-claims/` does.

**Tech Stack:** SBCL, ASDF, FiveAM, vivace-graph `graph-db/spacetime` at
`experiment` HEAD (unpinned), `cl-temporal-extent`, `local-time`,
`ironclad` (sha256), `babel` (UTF-8 octets).

**Spec:** `docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md`

## Global Constraints

- Lisp: spaces only, **80 columns hard limit**, terse comments that point
  at the spec/issue (`~/.claude/CLAUDE.md`).
- `cl-llm/memory` depends on `graph-db/spacetime`, `ironclad`, `babel`
  and nothing else — never on `cl-llm` core or `cl-llm/rag` (spec §8).
- Relations and producers are canonical strings: `[a-z0-9-]`, producer
  also `/` (kraison/vivace-graph#160). Producer is required, never
  defaulted.
- Every write runs inside the caller's `graph-db:with-transaction`; the
  library never opens one (spec §5).
- Order is the contract (spec §6): validity start descending, then
  `recorded-at` descending, then object key ascending.
- Every test that proves a negative names the mechanism and has a
  control (memory `weak-assertions-pass-vacuously`).
- Run tests in the cl-mcp REPL (`lisp-repl` skill), never by shelling
  out to `sbcl`. Load with `(asdf:load-system :cl-llm/memory/tests)`,
  run with `(fiveam:run! :cl-llm-memory)` via `uiop:symbol-call`.
- Commit after every task on branch `feat/agent-memory-tenant`; docs
  travel with code (README + `docs/agent-memory.md` in Task 6).

---

## File structure

| File | Responsibility |
|---|---|
| `cl-llm.asd` | systems `cl-llm/memory` and `cl-llm/memory/tests`, with the `:in-order-to` test-op |
| `memory/packages.lisp` | package `cl-llm.memory`, exports |
| `memory/schema.lisp` | `def-claim-classes belief … :temporal t`; `def-source memory-note`; `+belief-graph+`-free: the graph name is the caller's |
| `memory/write.lisp` | argument checks, `record-belief`, `record-absence`, `retract-belief`, predecessor closing |
| `memory/recall.lisp` | `belief-record` struct, series lookup, `recall` with its order |
| `memory/capture.lisp` | frontmatter reader, sha256 digest, `capture-memory-dir` |
| `tests-memory/packages.lisp` | test package with nicknames |
| `tests-memory/harness.lisp` | `with-memory-graph`, `%ts`, `%interval`, suite definition |
| `tests-memory/write-tests.lisp` | Task 2 tests |
| `tests-memory/recall-tests.lisp` | Task 3 tests |
| `tests-memory/capture-tests.lisp` | Task 4 tests |
| `tests-memory/fixtures/memory/*.md` | a three-note fixture corpus |
| `tests-memory/golden/capture.sexp` | committed golden for capture-and-diff |
| `docs/agent-memory.md` | the tenant's user doc |
| `README.md` | a "Agent memory (`cl-llm/memory`)" section |
| `.github/workflows/test.yml` | load and test the new system |

A note on graph names: `def-claim-classes` and `def-source` take a graph
name at macroexpansion, and class names are global in graph-db. The
library declares its classes on graph `:cl-llm-memory`; tests open a
graph of that name in a temp dir, as `tests-claims` opens
`:cl-llm-claims-test`.

---

### Task 1: System skeleton, schema, harness

**Files:**
- Modify: `cl-llm.asd` (after the `cl-llm/rag/claims/tests` system, ~line 200)
- Create: `memory/packages.lisp`, `memory/schema.lisp`
- Create: `tests-memory/packages.lisp`, `tests-memory/harness.lisp`, `tests-memory/schema-tests.lisp`
- Modify: `.github/workflows/test.yml:55-60`

**Interfaces:**
- Produces: package `cl-llm.memory` (nickname use `mem:` in tests); claim
  family `belief` with constructors `make-belief-unary` /
  `make-belief-binary`; source class `memory-note` with slots
  `note-name`, `note-description`, `note-type`, `note-modified`,
  `note-body`; test macro `(with-memory-graph (g) …)`; helpers `(%ts
  "2026-01-01T00:00:00Z")` → timestamp, `(%interval y1 y2)` →
  validity interval, `(%open-from ts)` → `[ts, unknown)` validity.

- [ ] **Step 1: Add the systems to `cl-llm.asd`**

Insert after the `cl-llm/rag/claims/tests` defsystem:

```lisp
(defsystem "cl-llm/memory"
  :description "Tenant three: an agent's beliefs as claims (#16)."
  :license "MIT"
  ;; graph-db/spacetime only -- never cl-llm core or cl-llm/rag: this
  ;; tenant needs no LLM (spec 2026-09-01-agent-memory-tenant SS8).
  :depends-on ("graph-db/spacetime" "ironclad" "babel")
  :serial t
  :pathname "memory/"
  :components ((:file "packages")
               (:file "schema")
               (:file "write")
               (:file "recall")
               (:file "capture"))
  ;; The test-op link: without it TEST-SYSTEM is a silent no-op
  ;; (docs/ci.md, kraison/cl-llm#26).
  :in-order-to ((test-op (test-op "cl-llm/memory/tests"))))

(defsystem "cl-llm/memory/tests"
  :description "On-disk-graph tests for cl-llm/memory."
  :license "MIT"
  :depends-on ("cl-llm/memory" "fiveam")
  :serial t
  :pathname "tests-memory/"
  :components ((:file "packages")
               (:file "harness")
               (:file "schema-tests")
               (:file "write-tests")
               (:file "recall-tests")
               (:file "capture-tests"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-memory)
               (error "cl-llm/memory suite failed."))))
```

Until Tasks 2–4 create them, list only `"packages" "schema"` and
`"packages" "harness" "schema-tests"`; add the other files as their tasks
land.

- [ ] **Step 2: Write `memory/packages.lisp`**

```lisp
;;;; memory/packages.lisp

(defpackage #:cl-llm.memory
  (:use #:cl)
  (:local-nicknames (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent))
  (:export
   ;; schema
   #:belief #:belief-unary #:belief-binary
   #:make-belief-unary #:make-belief-binary
   #:memory-note #:note-name #:note-description #:note-type
   #:note-modified #:note-body
   ;; write
   #:record-belief #:record-absence #:retract-belief
   #:belief-argument-error #:belief-successor-before-predecessor
   ;; recall
   #:recall #:belief-record #:belief-record-claim
   #:belief-record-current-p #:belief-record-superseded-by
   #:belief-record-retracted-at #:belief-record-standing
   #:belief-record-extent
   ;; capture
   #:capture-memory-dir #:read-frontmatter #:body-digest))
```

- [ ] **Step 3: Write `memory/schema.lisp`**

```lisp
;;;; memory/schema.lisp -- the belief family and the memory-note source.
;;;; Spec: docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md

(in-package #:cl-llm.memory)

;; :TEMPORAL T: the validity start joins the identity tuple and live
;; claims on one base tuple must be disjoint in validity, so a belief
;; can hold, lapse and hold again (spec SS3; kraison/vivace-graph#296).
(st:def-claim-classes belief :cl-llm-memory :temporal t)

;; The dogfood source: one node per memory file.  Map-less, private,
;; text-indexed so the corpus can later be a RAG chunk source (spec SS7).
(st:def-source memory-note :cl-llm-memory
    ((note-name        :type string)
     (note-description :type string)
     (note-type        :type string)
     (note-modified    :type string)   ; RFC3339 UTC, as captured
     (note-body        :type string))
  :identity     (:namespace :memory-note :key-slot note-name)
  :space        :none
  :time         (:extent-fn memory-note-validity-extent)
  :attribution  :none
  ;; :NONE here would mean MOST restricted, not "n/a" (resolve.lisp).
  :sensitivity  (:class :restricted)
  :registration :none
  :indexed-text (:text-fn note-body))

(defun memory-note-validity-extent (note)
  "The :TIME facet's extent-fn: valid from the note's MODIFIED stamp,
open-ended -- supersession is a later capture's job (spec SS7)."
  (te:make-interval
   (te:exact-bound (local-time:parse-timestring (note-modified note)))
   (te:unknown-bound)
   :semantics :validity :standing :asserted))
```

- [ ] **Step 4: Write the test package and harness**

`tests-memory/packages.lisp`:

```lisp
;;;; tests-memory/packages.lisp

(defpackage #:cl-llm.memory/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:mem #:cl-llm.memory)
                    (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent)))
```

`tests-memory/harness.lisp`:

```lisp
;;;; tests-memory/harness.lisp -- a real on-disk graph per test, as
;;;; tests-claims does.

(in-package #:cl-llm.memory/tests)

(def-suite :cl-llm-memory
  :description "cl-llm/memory offline suite (on-disk graph).")
(in-suite :cl-llm-memory)

(defun %call-with-graph (fn)
  (let* ((dir (format nil "/tmp/cl-llm-memory-test-~a-~a/"
                      (get-internal-real-time) (random 1000000)))
         (gdb:*system-directory*
           (format nil "/tmp/cl-llm-memory-sys-~a-~a/"
                   (get-internal-real-time) (random 1000000)))
         (graph (gdb:make-graph :cl-llm-memory dir
                                :buffer-pool-size 1000)))
    (unwind-protect (funcall fn graph)
      (ignore-errors (gdb:close-graph graph))
      (ignore-errors (uiop:delete-directory-tree
                      (pathname dir) :validate t))
      (ignore-errors (uiop:delete-directory-tree
                      (pathname gdb:*system-directory*)
                      :validate t :if-does-not-exist :ignore)))))

(defmacro with-memory-graph ((g) &body body)
  `(%call-with-graph (lambda (,g) ,@body)))

(defun %ts (string)
  (local-time:parse-timestring string))

(defun %interval (y1 y2)
  "A :VALIDITY interval from Jan 1 Y1 to Jan 1 Y2."
  (te:make-interval
   (te:exact-bound (%ts (format nil "~d-01-01T00:00:00Z" y1)))
   (te:exact-bound (%ts (format nil "~d-01-01T00:00:00Z" y2)))
   :semantics :validity :standing :asserted))

(defun %open-from (ts)
  "[TS, unknown) -- a belief still held."
  (te:make-interval (te:exact-bound ts) (te:unknown-bound)
                    :semantics :validity :standing :asserted))

(defparameter +p+ "claude-code/test"
  "The producer every test writes under, canonical (vg#160).")
```

- [ ] **Step 5: Write the failing schema tests**

`tests-memory/schema-tests.lisp`:

```lisp
;;;; tests-memory/schema-tests.lisp

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(test the-belief-family-is-temporal
  "Spec SS3: identity includes the validity start, so re-entry works."
  (is-true (st:claim-family-temporal-p (st:claim-family 'mem:belief))))

(test memory-note-is-a-map-less-restricted-source
  "Spec SS7: the third source declares :SPACE :NONE explicitly and is
private.  SOURCE-CONTRACT signals NOT-A-SOURCE on a plain vertex, so
this cannot pass for a class that merely exists."
  (let ((c (st:source-contract 'mem:memory-note)))
    (is (eq :none (st:source-facets-space c)))
    (is (eq :none (st:source-facets-registration c)))
    (is (equal '(:class :restricted) (st:source-facets-sensitivity c)))
    (is (eq :memory-note
            (getf (st:source-facets-identity c) :namespace)))))

(test a-temporal-belief-requires-an-extent
  "The engine's own guard, exercised through OUR constructor name --
without it the write path's defaults would be doing the engine's job."
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (signals st:missing-claim-identity-component
        (mem:make-belief-binary
         :graph g
         :subject-namespace :repo :subject-key "cl-llm"
         :relation "ci-status"
         :object-namespace :verdict :object-key "green"
         :producer +p+ :standing :observed)))))
```

- [ ] **Step 6: Run to verify the suite fails to load, then passes**

In the REPL:

```lisp
(asdf:load-system :cl-llm/memory/tests)
(uiop:symbol-call :fiveam :run! :cl-llm-memory)
```

Expected before Step 3's file exists: a load error naming `memory/schema`.
After: 3 tests pass. If `a-temporal-belief-requires-an-extent` fails
because the engine signals a different condition, read
`spacetime/claim.lisp:196-244` and use the condition it names — do not
weaken the test to `signals error`.

- [ ] **Step 7: Wire CI**

In `.github/workflows/test.yml`, extend the quickload list with
`:cl-llm/memory/tests` and add a final
`--eval '(asdf:test-system :cl-llm/memory)'` line after the claims one.

- [ ] **Step 8: Commit**

```bash
git add cl-llm.asd memory/ tests-memory/ .github/workflows/test.yml
git commit -m "feat(memory): the belief family and the memory-note source (#16)"
```

---

### Task 2: The write path

**Files:**
- Create: `memory/write.lisp`
- Create: `tests-memory/write-tests.lisp`
- Modify: `cl-llm.asd` (add `"write"` and `"write-tests"` components)

**Interfaces:**
- Consumes: `make-belief-binary`, `make-belief-unary`, `+p+`,
  `with-memory-graph`, `%open-from`, `%interval`, `%ts` from Task 1.
- Produces:
  - `(record-belief graph subject relation object &key producer standing extent confidence method rule-version)` → the new `belief-binary`, or the existing current claim when the same object is already held (idempotent).
  - `(record-absence graph subject relation &key producer standing extent)` → the new `belief-unary`.
  - `(retract-belief claim &key (at (local-time:now)))` → the retracted copy; signals `belief-argument-error` if already retracted.
  - conditions `belief-argument-error` (slots `argument`, `value`, `reason`) and `belief-successor-before-predecessor`.
  - internal `(%series graph producer subject relation)` → every claim (both arities, retracted included) on that series, used by Task 3.
  - `subject`/`object` are `(namespace . key)` conses, namespace a keyword, key a string.

- [ ] **Step 1: Write the failing tests**

`tests-memory/write-tests.lisp`:

```lisp
;;;; tests-memory/write-tests.lisp -- spec SS4-5.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defparameter +subj+ '(:repo . "cl-llm"))

(defun %touching (g)
  (st:claims-touching g 'mem:belief :repo "cl-llm" :role :subject))

(test a-belief-reads-back-with-standing-and-validity
  (with-memory-graph (g)
    (let ((start (%ts "2026-09-01T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from start)))
      (let ((claims (%touching g)))
        (is (= 1 (length claims)))
        (let ((c (first claims)))
          (is (eq :observed (st:claim-standing c)))
          (is (string= "green" (st:claim-object-key c)))
          (is (te:bound-unknown-p (te:extent-end (st:claim-extent c))))
          (is (local-time:timestamp=
               start (te:bound-earliest
                      (te:extent-start (st:claim-extent c))))))))))

(test the-three-absences-are-distinct-writes-and-distinct-reads
  "Spec SS10: each absence standing reads back as itself, never NIL and
never as one of the others."
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-absence g +subj+ "looked-in-ci" :producer +p+
                          :standing :searched-empty)
      (mem:record-absence g +subj+ "asked-owner" :producer +p+
                          :standing :indeterminate)
      (mem:record-absence g +subj+ "checked-docs" :producer +p+
                          :standing :uncovered))
    (let ((by-relation (mapcar (lambda (c) (cons (st:claim-relation c)
                                                 (st:claim-standing c)))
                               (%touching g))))
      (is (eq :searched-empty (cdr (assoc "looked-in-ci" by-relation
                                          :test #'string=))))
      (is (eq :indeterminate (cdr (assoc "asked-owner" by-relation
                                         :test #'string=))))
      (is (eq :uncovered (cdr (assoc "checked-docs" by-relation
                                     :test #'string=))))
      (is (every (lambda (c) (typep c 'mem:belief-unary)) (%touching g))
          "an absence has no object"))))

(test a-presence-standing-is-refused-on-an-absence-and-vice-versa
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (signals mem:belief-argument-error
        (mem:record-absence g +subj+ "x" :producer +p+
                            :standing :observed))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "x" '(:v . "1") :producer +p+
                           :standing :searched-empty)))))

(test producer-and-relation-are-checked-before-the-write
  "The error names the argument (spec SS5), not the engine's slot."
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "ci-status" '(:v . "1")
                           :standing :observed))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "CI Status" '(:v . "1")
                           :producer +p+ :standing :observed))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "ci-status" '(:v . "1")
                           :producer :keyword :standing :observed)))))

(test a-successor-closes-the-predecessor-s-validity
  "Spec SS4: both claims remain; the old one's end is now just before
the new one's start, so the two never share an instant."
  (with-memory-graph (g)
    (let ((t1 (%ts "2026-09-01T08:00:00Z"))
          (t2 (%ts "2026-09-02T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t1)))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "red")
                           :producer +p+ :standing :observed
                           :extent (%open-from t2)))
      (let* ((claims (%touching g))
             (green (find "green" claims :key #'st:claim-object-key
                                         :test #'string=))
             (red (find "red" claims :key #'st:claim-object-key
                                     :test #'string=)))
        (is (= 2 (length claims)) "supersession keeps both")
        (is (local-time:timestamp<
             (te:bound-latest (te:extent-end (st:claim-extent green)))
             t2))
        (is (te:bound-unknown-p (te:extent-end (st:claim-extent red))))
        (is-true (st:extents-disjoint-p (st:claim-extent green)
                                        (st:claim-extent red)))))))

(test re-asserting-the-held-value-is-idempotent
  (with-memory-graph (g)
    (let ((t1 (%ts "2026-09-01T08:00:00Z"))
          (t2 (%ts "2026-09-02T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t1)))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t2)))
      (is (= 1 (length (%touching g))))
      (is (te:bound-unknown-p
           (te:extent-end (st:claim-extent (first (%touching g)))))
          "the held belief is neither closed nor duplicated"))))

(test a-successor-starting-at-or-before-its-predecessor-is-refused
  (with-memory-graph (g)
    (let ((t1 (%ts "2026-09-02T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t1)))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (signals mem:belief-successor-before-predecessor
          (mem:record-belief g +subj+ "ci-status" '(:verdict . "red")
                             :producer +p+ :standing :observed
                             :extent (%open-from t1)))))))

(test retraction-closes-transaction-time-and-leaves-validity-alone
  "Spec SS4: wrong, not outdated.  Control: before retraction the claim
is current."
  (with-memory-graph (g)
    (let (c)
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (setf c (mem:record-belief g +subj+ "ci-status"
                                   '(:verdict . "green")
                                   :producer +p+ :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-09-01T08:00:00Z")))))
      (is-true (st:claim-current-p c) "control")
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:retract-belief c :at (%ts "2026-09-03T00:00:00Z")))
      (let ((c2 (first (%touching g))))
        (is-false (st:claim-current-p c2))
        (is (te:bound-unknown-p (te:extent-end (st:claim-extent c2)))
            "validity untouched")
        (gdb:with-transaction ((graph-db::transaction-manager g))
          (signals mem:belief-argument-error
            (mem:retract-belief c2)))))))
```

- [ ] **Step 2: Run to verify they fail**

Add `"write-tests"` to the tests system's components and `"write"` to
the library's (create an empty `memory/write.lisp` with only the
`in-package` form so the system loads). Run:

```lisp
(asdf:load-system :cl-llm/memory/tests)
(uiop:symbol-call :fiveam :run! :cl-llm-memory)
```

Expected: each new test fails with `undefined function
CL-LLM.MEMORY:RECORD-BELIEF` (or `RECORD-ABSENCE` / `RETRACT-BELIEF`) or
an unknown condition type. Not a load error.

- [ ] **Step 3: Implement `memory/write.lisp`**

```lisp
;;;; memory/write.lisp -- record, record an absence, retract.
;;;; Spec SS4-5: supersession closes validity; correction closes
;;;; transaction time; RECORD-BELIEF never retracts.

(in-package #:cl-llm.memory)

(define-condition belief-argument-error (error)
  ((argument :initarg :argument :reader belief-argument-error-argument)
   (value :initarg :value :reader belief-argument-error-value)
   (reason :initarg :reason :reader belief-argument-error-reason))
  (:report (lambda (c s)
             (format s "~a ~s: ~a"
                     (belief-argument-error-argument c)
                     (belief-argument-error-value c)
                     (belief-argument-error-reason c)))))

(define-condition belief-successor-before-predecessor (error)
  ((predecessor :initarg :predecessor
                :reader bsbp-predecessor)
   (start :initarg :start :reader bsbp-start))
  (:report (lambda (c s)
             (format s "a successor must start after its predecessor ~
                        (~a); to say the predecessor was wrong, ~
                        RETRACT-BELIEF it" (bsbp-start c)))))

(defun %arg-error (argument value reason)
  (error 'belief-argument-error
         :argument argument :value value :reason reason))

(defun %check-endpoint (argument pair)
  (unless (and (consp pair) (keywordp (car pair)) (stringp (cdr pair)))
    (%arg-error argument pair "must be (namespace-keyword . key-string)")))

(defun %check-producer (producer)
  (unless (st:canonical-producer-p producer)
    (%arg-error :producer producer
                "required; a canonical string [a-z0-9-/]")))

(defun %check-relation (relation)
  (unless (st:canonical-relation-p relation)
    (%arg-error :relation relation "a canonical string [a-z0-9-]")))

(defun %default-extent ()
  (te:make-interval (te:exact-bound (local-time:now))
                    (te:unknown-bound)
                    :semantics :validity :standing :asserted))

(defun %start-instant (claim)
  (te:bound-earliest (te:extent-start (st:claim-extent claim))))

(defun %open-p (claim)
  "Validity end unknown or unbounded -- the belief is still held."
  (let ((end (te:extent-end (st:claim-extent claim))))
    (or (te:bound-unknown-p end)
        (eq :unbounded (te:bound-latest end)))))

(defun %series (graph producer subject relation)
  "Every claim -- both arities, retracted included -- one PRODUCER holds
on (SUBJECT, RELATION).  The engine indexes subject and producer, not
relation, so the relation filter is ours (survey SS6)."
  (remove-if-not
   (lambda (c) (and (string= relation (st:claim-relation c))
                    (string= producer (st:claim-producer c))))
   (st:claims-touching graph 'belief (car subject) (cdr subject)
                       :role :subject)))

(defun %current-predecessor (graph producer subject relation)
  "The one open, current binary belief on the series, or NIL."
  (find-if (lambda (c) (and (typep c 'belief-binary)
                            (st:claim-current-p c)
                            (%open-p c)))
           (%series graph producer subject relation)))

(defun %close-validity (claim before)
  "Close CLAIM's validity 1 ns before BEFORE.  Intervals are closed and
:MEETS is not disjoint (manual ch. 18), so the end must precede the
successor's start strictly."
  (let* ((c (gdb:copy claim))
         (e (st:claim-extent c))
         (end (local-time:timestamp- before 1 :nsec)))
    (setf (st:claim-extent c)
          (te:make-interval (te:extent-start e) (te:exact-bound end)
                            :precision (te:extent-precision e)
                            :semantics :validity
                            :standing (te:extent-standing e)))
    (gdb:save c)
    c))

(defun record-belief (graph subject relation object
                      &key producer standing (extent (%default-extent))
                           confidence method rule-version)
  "Record that PRODUCER holds SUBJECT RELATION OBJECT, valid over
EXTENT (default [now, unknown)).  Returns the new BELIEF-BINARY -- or
the existing one when the same OBJECT is already held (idempotent).  A
different OBJECT currently held is SUPERSEDED: its validity closes just
before EXTENT's start, and both claims remain.  Never retracts.
Must run inside the caller's WITH-TRANSACTION."
  (%check-endpoint :subject subject)
  (%check-endpoint :object object)
  (%check-relation relation)
  (%check-producer producer)
  (unless (te:standing-present-p standing)
    (%arg-error :standing standing
                "a presence standing; absences go through RECORD-ABSENCE"))
  (let ((start (te:bound-earliest (te:extent-start extent)))
        (pred (%current-predecessor graph producer subject relation)))
    (when pred
      (cond ((and (string= (cdr object) (st:claim-object-key pred))
                  (eq (car object) (st:claim-object-namespace pred)))
             (return-from record-belief pred))
            ((not (local-time:timestamp< (%start-instant pred) start))
             (error 'belief-successor-before-predecessor
                    :predecessor pred :start start))
            (t (%close-validity pred start))))
    (make-belief-binary
     :graph graph
     :subject-namespace (car subject) :subject-key (cdr subject)
     :relation relation
     :object-namespace (car object) :object-key (cdr object)
     :producer producer :standing standing :extent extent
     :confidence confidence :method method :rule-version rule-version)))

(defun record-absence (graph subject relation
                       &key producer standing
                            (extent (te:make-instant
                                     (te:exact-bound (local-time:now))
                                     :semantics :validity
                                     :standing :asserted)))
  "Record that PRODUCER looked for SUBJECT RELATION and STANDING says
what happened: :SEARCHED-EMPTY, :INDETERMINATE or :UNCOVERED.  EXTENT is
the search itself, an instant by default.  Returns the BELIEF-UNARY."
  (%check-endpoint :subject subject)
  (%check-relation relation)
  (%check-producer producer)
  (unless (member standing '(:searched-empty :indeterminate :uncovered))
    (%arg-error :standing standing
                "one of :searched-empty :indeterminate :uncovered"))
  (make-belief-unary
   :graph graph
   :subject-namespace (car subject) :subject-key (cdr subject)
   :relation relation
   :producer producer :standing standing :extent extent))

(defun retract-belief (claim &key (at (local-time:now)))
  "CLAIM was wrong: close its transaction period at AT and leave its
validity as recorded.  Signals BELIEF-ARGUMENT-ERROR on a claim already
retracted, because RETRACT-CLAIM would silently do nothing."
  (unless (st:claim-current-p claim)
    (%arg-error :claim claim "already retracted"))
  (st:retract-claim claim :at at))
```

- [ ] **Step 4: Run to verify they pass**

Same REPL forms. Expected: all Task 1 and Task 2 tests pass. If
`a-successor-closes-the-predecessor-s-validity` fails with
`COPYING-UNCOMMITTED-NODE`, the predecessor was created in the same
transaction — the test uses two transactions deliberately; check the
harness, not the implementation.

- [ ] **Step 5: Commit**

```bash
git add cl-llm.asd memory/write.lisp tests-memory/write-tests.lisp
git commit -m "feat(memory): record-belief, record-absence, retract-belief (#16)"
```

---

### Task 3: The read path

**Files:**
- Create: `memory/recall.lisp`
- Create: `tests-memory/recall-tests.lisp`
- Modify: `cl-llm.asd` (add `"recall"`, `"recall-tests"`)

**Interfaces:**
- Consumes: `%series`, `%start-instant`, `%open-p` from Task 2 (same package, no export needed); `record-belief`, `record-absence`, `retract-belief`.
- Produces:
  - struct `belief-record` with readers `belief-record-claim`, `-current-p`, `-superseded-by` (a claim or NIL), `-retracted-at` (timestamp or NIL), `-standing`, `-extent`.
  - `(recall graph subject &key relation producer at include-retracted)` → list of `belief-record`, ordered.

- [ ] **Step 1: Write the failing tests**

`tests-memory/recall-tests.lisp`:

```lisp
;;;; tests-memory/recall-tests.lisp -- spec SS6.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %seed-series (g)
  "green from 09-01, red from 09-02, green again from 09-03; and an
absence on another relation.  Returns nothing; RECALL is the reader."
  (flet ((at (s) (%open-from (%ts s))))
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                         :producer +p+ :standing :observed
                         :extent (at "2026-09-01T08:00:00Z")))
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-belief g +subj+ "ci-status" '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (at "2026-09-02T08:00:00Z")))
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                         :producer +p+ :standing :observed
                         :extent (at "2026-09-03T08:00:00Z"))
      (mem:record-absence g +subj+ "release-date" :producer +p+
                          :standing :searched-empty))))

(defun %objects (records)
  (mapcar (lambda (r)
            (let ((c (mem:belief-record-claim r)))
              (if (typep c 'mem:belief-binary)
                  (st:claim-object-key c)
                  (st:claim-standing c))))
          records))

(test recall-orders-newest-validity-first-and-marks-the-current-one
  "Spec SS6: order is the contract."
  (with-memory-graph (g)
    (%seed-series g)
    (let ((rs (mem:recall g +subj+ :relation "ci-status")))
      (is (equal '("green" "red" "green") (%objects rs)))
      (is (equal '(t nil nil)
                 (mapcar #'mem:belief-record-current-p rs))))))

(test a-superseded-belief-names-its-successor-and-is-never-current
  (with-memory-graph (g)
    (%seed-series g)
    (let* ((rs (mem:recall g +subj+ :relation "ci-status"))
           (red (second rs))
           (first-green (third rs)))
      (is (string= "green" (st:claim-object-key
                            (mem:belief-record-superseded-by red))))
      (is (string= "red" (st:claim-object-key
                          (mem:belief-record-superseded-by
                           first-green))))
      (is (null (mem:belief-record-superseded-by (first rs))))
      (is-false (mem:belief-record-current-p red)))))

(test recall-at-an-instant-returns-what-held-then
  (with-memory-graph (g)
    (%seed-series g)
    (let ((rs (mem:recall g +subj+ :relation "ci-status"
                          :at (%ts "2026-09-02T12:00:00Z"))))
      (is (equal '("red") (%objects rs)))
      (is-false (mem:belief-record-current-p (first rs))
                "held THEN, superseded since -- not current"))))

(test an-absence-is-recalled-as-itself-and-a-nil-read-is-not-one
  "Spec SS10: distinguishable in both directions.  The control asks for
a relation nobody wrote: NIL, which is not :UNCOVERED and not
:SEARCHED-EMPTY."
  (with-memory-graph (g)
    (%seed-series g)
    (is (equal '(:searched-empty)
               (%objects (mem:recall g +subj+ :relation "release-date"))))
    (is (null (mem:recall g +subj+ :relation "never-written"))
        "control: nothing recorded reads as nothing, not as an absence")))

(test a-retracted-belief-is-hidden-unless-asked-for-and-then-dated
  (with-memory-graph (g)
    (%seed-series g)
    (let* ((current (first (mem:recall g +subj+ :relation "ci-status")))
           (when-wrong (%ts "2026-09-04T00:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:retract-belief (mem:belief-record-claim current)
                            :at when-wrong))
      (is (equal '("red" "green")
                 (%objects (mem:recall g +subj+ :relation "ci-status"))))
      (let ((all (mem:recall g +subj+ :relation "ci-status"
                             :include-retracted t)))
        (is (equal '("green" "red" "green") (%objects all)))
        (is (local-time:timestamp= when-wrong
                                   (mem:belief-record-retracted-at
                                    (first all))))
        (is-false (mem:belief-record-current-p (first all)))))))

(test recall-without-a-relation-spans-every-series-of-the-subject
  (with-memory-graph (g)
    (%seed-series g)
    (is (= 4 (length (mem:recall g +subj+))))
    (is (= 0 (length (mem:recall g +subj+ :producer "someone/else"))))))
```

- [ ] **Step 2: Run to verify they fail**

Add the components, create `memory/recall.lisp` with only `in-package`,
load, run. Expected: `undefined function CL-LLM.MEMORY:RECALL`.

- [ ] **Step 3: Implement `memory/recall.lisp`**

```lisp
;;;; memory/recall.lisp -- read back by subject, bounded by validity,
;;;; with supersession and retraction visible.  Spec SS6.

(in-package #:cl-llm.memory)

(defstruct belief-record
  "One recalled claim plus what a caller would otherwise recompute
wrongly.  SUPERSEDED-BY is COMPUTED -- the next claim in the same
(producer subject relation) series by validity start -- never stored,
so it cannot go stale (spec SS4)."
  claim
  (current-p nil)
  (superseded-by nil)
  (retracted-at nil)
  standing
  extent)

(defun %retracted-at (claim)
  (let ((e (st:claim-transaction-extent claim)))
    (and e
         (not (st:claim-current-p claim))
         (let ((end (te:bound-latest (te:extent-end e))))
           (and (typep end 'local-time:timestamp) end)))))

(defun %recorded-at (claim)
  "A timestamp for ordering; a pre-axis claim sorts last."
  (let ((at (st:claim-recorded-at claim)))
    (if (typep at 'local-time:timestamp)
        at
        (local-time:unix-to-timestamp 0))))

(defun %series-key (claim)
  (list (st:claim-producer claim)
        (st:claim-subject-namespace claim)
        (st:claim-subject-key claim)
        (st:claim-relation claim)))

(defun %successor (claim series)
  "The earliest-starting current claim in SERIES that starts after
CLAIM, or NIL."
  (let ((start (%start-instant claim))
        (best nil))
    (dolist (c series best)
      (when (and (not (eq c claim))
                 (st:claim-current-p c)
                 (local-time:timestamp< start (%start-instant c))
                 (or (null best)
                     (local-time:timestamp< (%start-instant c)
                                            (%start-instant best))))
        (setf best c)))))

(defun %object-key-for-order (claim)
  (if (typep claim 'belief-binary) (st:claim-object-key claim) ""))

(defun %before-p (a b)
  "The order contract: validity start descending, RECORDED-AT descending,
object key ascending."
  (let ((sa (%start-instant a)) (sb (%start-instant b)))
    (cond ((local-time:timestamp> sa sb) t)
          ((local-time:timestamp< sa sb) nil)
          (t (let ((ra (%recorded-at a)) (rb (%recorded-at b)))
               (cond ((local-time:timestamp> ra rb) t)
                     ((local-time:timestamp< ra rb) nil)
                     (t (string< (%object-key-for-order a)
                                 (%object-key-for-order b)))))))))

(defun recall (graph subject &key relation producer at include-retracted)
  "BELIEF-RECORDs about SUBJECT, ordered newest validity first (SS6).
RELATION and PRODUCER narrow the series; AT keeps only beliefs valid at
that instant; retracted claims are excluded unless INCLUDE-RETRACTED.
Nothing recorded returns NIL -- which is not an absence standing."
  (%check-endpoint :subject subject)
  (let* ((all (st:claims-touching graph 'belief (car subject)
                                  (cdr subject) :role :subject))
         (wanted (remove-if-not
                  (lambda (c)
                    (and (or (null relation)
                             (string= relation (st:claim-relation c)))
                         (or (null producer)
                             (string= producer (st:claim-producer c)))))
                  all))
         (series (make-hash-table :test 'equal)))
    ;; Successors are found within the full series, so a claim outside
    ;; the AT window can still be named as what superseded one inside.
    (dolist (c all) (push c (gethash (%series-key c) series)))
    (let ((records
            (loop for c in (sort (copy-list wanted) #'%before-p)
                  for current = (st:claim-current-p c)
                  when (or include-retracted current)
                    when (or (null at)
                             (member c (st:claims-touching
                                        graph 'belief (car subject)
                                        (cdr subject) :role :subject
                                        :at at)))
                      collect (make-belief-record
                               :claim c
                               :current-p (and current (%open-p c))
                               :superseded-by
                               (%successor c (gethash (%series-key c)
                                                      series))
                               :retracted-at (%retracted-at c)
                               :standing (st:claim-standing c)
                               :extent (st:claim-extent c)))))
      records)))
```

Note for the implementer: `current-p` is `(and current (%open-p c))` —
a belief valid *then* and superseded since is not current (spec §6), and
`recall-at-an-instant-returns-what-held-then` pins that.

- [ ] **Step 4: Run to verify they pass**

Expected: whole suite green. If the `:at` test returns two claims, the
predecessor's validity was not closed strictly before the successor —
check `%close-validity`, not the test.

- [ ] **Step 5: Commit**

```bash
git add cl-llm.asd memory/recall.lisp tests-memory/recall-tests.lisp
git commit -m "feat(memory): recall -- supersession computed, retraction visible (#16)"
```

---

### Task 4: Capture the memory corpus, and capture-and-diff

**Files:**
- Create: `memory/capture.lisp`
- Create: `tests-memory/capture-tests.lisp`
- Create: `tests-memory/fixtures/memory/alpha.md`, `beta.md`, `gamma.md`, `MEMORY.md`
- Create: `tests-memory/golden/capture.sexp`
- Modify: `cl-llm.asd` (add `"capture"`, `"capture-tests"`)

**Interfaces:**
- Consumes: `record-belief`, `recall`, `memory-note` and its constructor `make-memory-note` (generated by `def-vertex`; initargs `:note-name` …, `:graph`), `belief-record-*`.
- Produces:
  - `(read-frontmatter path)` → `(values plist body)` with keys `:name :description :type :modified` (strings; missing → NIL).
  - `(body-digest string)` → lowercase sha256 hex of the UTF-8 body.
  - `(capture-memory-dir graph dir &key producer)` → number of notes captured. One transaction per note. Skips `MEMORY.md`.
  - `(capture-listing graph dir)` → the deterministic sexp the golden is compared against.

- [ ] **Step 1: Write the fixture corpus**

`tests-memory/fixtures/memory/alpha.md`:

```markdown
---
name: alpha
description: The alpha note, unchanged across captures
metadata:
  type: project
  modified: 2026-08-01T10:00:00Z
---

Alpha body. Links to [[beta]].
```

`tests-memory/fixtures/memory/beta.md`:

```markdown
---
name: beta
description: The beta note, edited in place between captures
metadata:
  type: feedback
  modified: 2026-08-02T10:00:00Z
---

Suite is 486 pass / 1 fail / 3 uncollectable.
```

`tests-memory/fixtures/memory/gamma.md`:

```markdown
---
name: gamma
description: A reference with no modified stamp
metadata:
  type: reference
---

https://example.invalid/dashboard
```

`tests-memory/fixtures/memory/MEMORY.md`:

```markdown
# Memory index

- [alpha](alpha.md) — unchanged
- [beta](beta.md) — edited
- [gamma](gamma.md) — no stamp
```

- [ ] **Step 2: Write the failing tests**

`tests-memory/capture-tests.lisp`:

```lisp
;;;; tests-memory/capture-tests.lisp -- spec SS7, capture-and-diff.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %fixture-dir ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/fixtures/memory/"))

(defun %golden-path ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/golden/capture.sexp"))

(defun %copy-fixture-to-temp ()
  (let ((dir (format nil "/tmp/cl-llm-memory-corpus-~a-~a/"
                     (get-internal-real-time) (random 1000000))))
    (ensure-directories-exist dir)
    (dolist (f (uiop:directory-files (%fixture-dir) "*.md"))
      (uiop:copy-file f (merge-pathnames (file-namestring f) dir)))
    dir))

(defun %rewrite-beta (dir)
  (with-open-file (out (merge-pathnames "beta.md" dir)
                       :direction :output :if-exists :supersede
                       :external-format :utf-8)
    (format out "---~%name: beta~%description: edited~%metadata:~%~
  type: feedback~%  modified: 2026-08-20T10:00:00Z~%---~%~%~
Suite is 500 pass / 0 fail.~%")))

(test frontmatter-reads-name-type-and-modified
  (multiple-value-bind (fm body)
      (mem:read-frontmatter (merge-pathnames "beta.md" (%fixture-dir)))
    (is (string= "beta" (getf fm :name)))
    (is (string= "feedback" (getf fm :type)))
    (is (string= "2026-08-02T10:00:00Z" (getf fm :modified)))
    (is (search "486 pass" body))
    (is (not (search "---" body)) "the fence is not part of the body")))

(test a-note-without-a-modified-stamp-reads-nil-not-a-guess
  (is (null (getf (mem:read-frontmatter
                   (merge-pathnames "gamma.md" (%fixture-dir)))
                  :modified))))

(test the-digest-is-stable-and-utf-8
  (is (string= (mem:body-digest "héllo") (mem:body-digest "héllo")))
  (is (string/= (mem:body-digest "a") (mem:body-digest "b")))
  (is (= 64 (length (mem:body-digest "")))))

(test capture-makes-one-note-and-one-content-belief-per-file
  (with-memory-graph (g)
    (is (= 3 (mem:capture-memory-dir g (%fixture-dir) :producer +p+)))
    (let ((rs (mem:recall g '(:memory-note . "beta") :relation "content")))
      (is (= 1 (length rs)))
      (is (eq :digest (st:claim-object-namespace
                       (mem:belief-record-claim (first rs)))))
      (is-true (mem:belief-record-current-p (first rs))))))

(test a-second-capture-after-an-edit-supersedes-rather-than-overwrites
  "The #16 case: the old content claim survives, closed and naming the
new one.  Control: an unedited note gains no second claim."
  (let ((dir (%copy-fixture-to-temp)))
    (unwind-protect
         (with-memory-graph (g)
           (mem:capture-memory-dir g dir :producer +p+)
           (%rewrite-beta dir)
           (mem:capture-memory-dir g dir :producer +p+)
           (let ((beta (mem:recall g '(:memory-note . "beta")
                                   :relation "content"))
                 (alpha (mem:recall g '(:memory-note . "alpha")
                                    :relation "content")))
             (is (= 2 (length beta)))
             (is-true (mem:belief-record-current-p (first beta)))
             (is-false (mem:belief-record-current-p (second beta)))
             (is (eq (mem:belief-record-claim (first beta))
                     (mem:belief-record-superseded-by (second beta))))
             (is (= 1 (length alpha)) "control")))
      (uiop:delete-directory-tree (pathname dir) :validate t))))

(test capture-and-diff-matches-the-committed-golden
  "Ordering as the contract: the listing is compared whole, so a
reordering or a changed digest is a diff, not a pass."
  (let ((dir (%copy-fixture-to-temp)))
    (unwind-protect
         (with-memory-graph (g)
           (mem:capture-memory-dir g dir :producer +p+)
           (%rewrite-beta dir)
           (mem:capture-memory-dir g dir :producer +p+)
           (let ((got (mem:capture-listing g dir))
                 (want (with-open-file (in (%golden-path))
                         (let ((*read-eval* nil)) (read in)))))
             (is (equal want got)
                 "regenerate the golden ONLY for an intended change: ~
                  (mem:capture-listing g dir) -> ~a" (%golden-path))))
      (uiop:delete-directory-tree (pathname dir) :validate t))))
```

- [ ] **Step 3: Run to verify they fail**

Add components, empty `memory/capture.lisp`, load, run. Expected:
undefined functions `READ-FRONTMATTER`, `BODY-DIGEST`,
`CAPTURE-MEMORY-DIR`, `CAPTURE-LISTING`. The golden test fails on the
missing file; that is expected until Step 5.

- [ ] **Step 4: Implement `memory/capture.lisp`**

```lisp
;;;; memory/capture.lisp -- the memory corpus as the dogfood tenant.
;;;; Deterministic: frontmatter + digest, no prose parsing (spec SS7).

(in-package #:cl-llm.memory)

(defun %read-file (path)
  (with-open-file (in path :external-format :utf-8)
    (let ((s (make-string (file-length in))))
      (subseq s 0 (read-sequence s in)))))

(defun %trim (s) (string-trim '(#\Space #\Tab #\Return) s))

(defun read-frontmatter (path)
  "Two values: a plist (:NAME :DESCRIPTION :TYPE :MODIFIED), each a
string or NIL, and the body after the closing fence.  Reads only the
line shapes the memory files use -- `key: value` at the top level and
under `metadata:` -- and is not a YAML parser."
  (let* ((text (%read-file path))
         (lines (uiop:split-string text :separator '(#\Newline))))
    (unless (and lines (string= "---" (%trim (first lines))))
      (return-from read-frontmatter (values nil text)))
    (let ((plist '()) (i 1))
      (loop while (and (< i (length lines))
                       (string/= "---" (%trim (nth i lines))))
            do (let* ((line (nth i lines))
                      (colon (position #\: line)))
                 (when colon
                   (let ((key (%trim (subseq line 0 colon)))
                         (val (%trim (subseq line (1+ colon)))))
                     (when (plusp (length val))
                       (cond ((string= key "name")
                              (setf (getf plist :name) val))
                             ((string= key "description")
                              (setf (getf plist :description) val))
                             ((string= key "type")
                              (setf (getf plist :type) val))
                             ((string= key "modified")
                              (setf (getf plist :modified) val)))))))
               (incf i))
      (values plist
              (format nil "~{~a~^~%~}" (nthcdr (1+ i) lines))))))

(defun body-digest (string)
  "Lowercase sha256 hex of STRING's UTF-8 octets."
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    :sha256 (babel:string-to-octets string :encoding :utf-8))))

(defun %note-modified (fm path)
  "The MODIFIED stamp, RFC3339 UTC; the file's write date when the note
carries none -- and then the capture is only as reproducible as the
filesystem."
  (or (getf fm :modified)
      (local-time:format-rfc3339-timestring
       nil (local-time:universal-to-timestamp (file-write-date path))
       :timezone local-time:+utc-zone+)))

(defun %existing-note (graph name)
  (first (gdb:index-lookup graph 'memory-note 'note-name name)))

(defun %capture-note (graph path producer)
  (multiple-value-bind (fm body) (read-frontmatter path)
    (let* ((name (or (getf fm :name)
                     (pathname-name path)))
           (modified (%note-modified fm path))
           (start (local-time:parse-timestring modified))
           (old (%existing-note graph name)))
      (if old
          (let ((c (gdb:copy old)))
            (setf (note-description c) (or (getf fm :description) "")
                  (note-type c) (or (getf fm :type) "")
                  (note-modified c) modified
                  (note-body c) body)
            (gdb:save c))
          (make-memory-note :graph graph
                            :note-name name
                            :note-description (or (getf fm :description) "")
                            :note-type (or (getf fm :type) "")
                            :note-modified modified
                            :note-body body))
      (record-belief graph (cons :memory-note name) "content"
                     (cons :digest (body-digest body))
                     :producer producer :standing :asserted
                     :extent (te:make-interval
                              (te:exact-bound start) (te:unknown-bound)
                              :semantics :validity :standing :asserted)))))

(defun %note-files (dir)
  (sort (remove "MEMORY" (uiop:directory-files dir "*.md")
                :key #'pathname-name :test #'string=)
        #'string< :key #'pathname-name))

(defun capture-memory-dir (graph dir &key producer)
  "One MEMORY-NOTE per *.md in DIR (MEMORY.md, the index, excluded) and
one content belief per note under PRODUCER.  A note whose body changed
since the last capture gets a new content claim that SUPERSEDES the old
one; an unchanged note is idempotent.  One transaction per note.
Returns the number of notes captured."
  (%check-producer producer)
  (let ((n 0))
    (dolist (path (%note-files dir) n)
      (gdb:with-transaction (:graph graph)
        (%capture-note graph path producer))
      (incf n))))

(defun capture-listing (graph dir)
  "The deterministic shape capture-and-diff compares: per note, its
recall of the content series, newest first -- (NAME DIGEST START
CURRENT-P SUPERSEDED-BY-DIGEST) rows."
  (loop for path in (%note-files dir)
        for fm = (read-frontmatter path)
        for name = (or (getf fm :name) (pathname-name path))
        ;; A note with no MODIFIED stamp starts at the file's write
        ;; date, which no two checkouts share -- so the listing omits
        ;; the start for it rather than making the golden host-bound.
        for stamped = (and (getf fm :modified) t)
        append (loop for r in (recall graph (cons :memory-note name)
                                      :relation "content")
                     for c = (belief-record-claim r)
                     for s = (belief-record-superseded-by r)
                     collect (list name
                                   (st:claim-object-key c)
                                   (and stamped
                                        (local-time:format-rfc3339-timestring
                                         nil (%start-instant c)
                                         :timezone local-time:+utc-zone+))
                                   (belief-record-current-p r)
                                   (and s (st:claim-object-key s))))))
```

`gdb:with-transaction (:graph graph)` is the `(:graph G)` routing form
(kraison/vivace-graph#175); the tests use the transaction-manager form —
both are valid, this one keeps the library from reaching into
`graph-db::transaction-manager`.

- [ ] **Step 5: Generate the golden, review it by eye, commit it**

In the REPL, after the suite loads, run the body of
`capture-and-diff-matches-the-committed-golden` up to `got` and write
it:

```lisp
(with-open-file (out (asdf:system-relative-pathname
                      :cl-llm "tests-memory/golden/capture.sexp")
                     :direction :output :if-exists :supersede)
  (let ((*print-case* :downcase))
    (pprint got out)))
```

Expected shape (digests are the real sha256 of the fixture bodies —
check `alpha` has one row, `beta` two with the newer first and the older
naming the newer, `gamma` one):

```lisp
(("alpha" "<sha>" "2026-08-01T10:00:00.000000Z" t nil)
 ("beta" "<sha-new>" "2026-08-20T10:00:00.000000Z" t nil)
 ("beta" "<sha-old>" "2026-08-02T10:00:00.000000Z" nil "<sha-new>")
 ("gamma" "<sha>" nil t nil))
```

`gamma` carries no `modified`, so its start is the file's write date;
`capture-listing` emits NIL in that position for an unstamped note so
the golden is not host-bound (the code above already does this). Its
row therefore reads `("gamma" "<sha>" nil t nil)`.

- [ ] **Step 6: Run to verify the whole suite passes, three times**

The claims suite once flaked on iteration order; run
`(uiop:symbol-call :fiveam :run! :cl-llm-memory)` three times.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd memory/capture.lisp tests-memory/
git commit -m "feat(memory): capture the memory corpus by digest; capture-and-diff golden (#16)"
```

---

### Task 5: Docs, CI verification, PR

**Files:**
- Create: `docs/agent-memory.md`
- Modify: `README.md` (new `### Agent memory (`cl-llm/memory`)` section after "Claim traversal", ~line 205; add the suite to "## Testing")
- Modify: `docs/ci.md` (one line: the memory suite is in the run)
- Modify: `docs/superpowers/specs/2026-08-09-spatiotemporal-substrate-programme-design.md` §8 table row for tenant three? **No** — the programme doc lists units, not tenants' internals; leave it.

- [ ] **Step 1: Write `docs/agent-memory.md`**

Sections, each a few paragraphs, citing the spec rather than repeating
it: *What a belief is* (the record table from spec §3); *Outdated vs.
wrong* (spec §4, with the two three-line code examples: record then
record, record then retract); *Recall and its order* (spec §6);
*Capturing a memory directory* (spec §7, the one-call example and what
a second capture shows); *What this is not* (spec §1 last paragraph +
§8). Under 150 lines.

- [ ] **Step 2: README section**

```markdown
### Agent memory (`cl-llm/memory`)

`cl-llm/memory` is the third tenant of `graph-db/spacetime`: an agent's
**beliefs** as claims, with a standing and a validity extent
(kraison/cl-llm#16). "I looked and there was nothing" is a write, not a
missing row; a belief that stopped being true is recalled *as
superseded*, naming its successor; a belief that was wrong is retracted
and stays readable as "believed from t1 to t2".

```lisp
;; mem = cl-llm.memory
(gdb:with-transaction (:graph g)
  (mem:record-belief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green")
                     :producer "claude-code/odm" :standing :observed))
(mem:recall g '(:repo . "cl-llm") :relation "ci-status")
;; => (#S(belief-record :current-p t :superseded-by nil ...))
```

`capture-memory-dir` turns a directory of memory notes into one source
node and one content belief per note; a second capture after an edit
supersedes rather than overwrites. See `docs/agent-memory.md`.
```

- [ ] **Step 3: Push, watch CI, read the log**

```bash
git push -u origin feat/agent-memory-tenant
gh pr create --title "feat(memory): tenant three -- an agent's beliefs as claims (#16)" --body "..."
gh pr checks --watch
gh run view --job <id> --log | grep -E "Running test suite|Did [0-9]+ checks"
```

The log **must** show `CL-LLM-MEMORY` with its check count (`docs/ci.md`).

- [ ] **Step 4: Commit docs; update #16 and the tracker**

Comment on #16 with what landed and what it does not prove (spec §1);
the PR closes it. Update the sitrep plan if the target slips.

---

## Self-review

**Spec coverage.** §3 record → Task 1 schema + Task 2 constructors;
§4 two axes → Task 2 (`%close-validity`, `retract-belief`) and Task 3
(`superseded-by`, `retracted-at`); §5 write path → Task 2; §6 read path
and order → Task 3; §7 capture and capture-and-diff → Task 4; §8
layering → Task 1 asd (`depends-on`), CI wiring with `:in-order-to`; §9
findings → Task 5's #16 comment; §10 acceptance → each bullet has a
named test (absences both ways: `the-three-absences-…` and
`an-absence-is-recalled-as-itself-…`; superseded never current:
`a-superseded-belief-names-its-successor-…`; corrected on request:
`a-retracted-belief-is-hidden-…`; capture-and-diff:
`capture-and-diff-matches-the-committed-golden`).

**Placeholder scan.** Task 5 Step 1 describes the doc by sections rather
than full text — acceptable for prose the executor writes from the spec;
everything code-shaped is present. Task 4 Step 5 contains an inline
correction (gamma's non-deterministic start); it is applied as part of
the step, not deferred.

**Type consistency.** `belief-record-*` readers match between Task 3's
struct and Task 4's `capture-listing`; `%series`, `%start-instant`,
`%open-p`, `%check-producer`, `%check-endpoint` are defined in Task 2
and used in Tasks 3–4 within the same package; subject/object are
`(keyword . string)` throughout; `+p+` is defined in the harness.
