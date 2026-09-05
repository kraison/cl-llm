# S6b Cross-Store Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cl-llm/memory` answers over a scope of stores in trust order: one series across stores with trust-ordered supersession, `conclude` refusing a higher-trust conflict, store-free cites resolved first-in-scope, decisions found and cited with their store, and every decision carrying its commit epoch.

**Architecture:** A new `memory/scope.lisp` holds the scope validator and the composed-snapshot helper; every reader and `conclude` gain `&key (scope (list graph))` and run their reads under one snapshot per store. The agent layer stops merging across stores itself and passes its scope down. Two stores in one image share one system clock, which the memory image and the test fixtures open before their stores.

**Tech Stack:** Common Lisp (SBCL), vivace-graph `graph-db/spacetime` at `feat/epoch-axis` (= `experiment` 3a8ca96 + #347), cl-temporal-extent 0.3.0, FiveAM.

**Spec:** `docs/superpowers/specs/2026-09-05-s6b-cross-store-memory-design.md` (amended 75463ff). Verified facts and the corrections the spec was amended for: `docs/superpowers/notes/2026-09-05-s6b-engine-api-facts.md` (§C, §S). Authority order: spec > this plan's rulings > the recon note > task text.

## Global Constraints

- Worktree: `/home/raison/work/cl-llm/.worktrees/s6b` (branch `feat/s6b-adversarial-pass`). The main checkout `/home/raison/work/cl-llm` and `/home/raison/work/vivace-graph-v3` are shared with other sessions: never build, edit or commit there, never `cd` into them. The engine is `/home/raison/work/vivace-graph-v3/.worktrees/epoch-axis` (read-only for you; it exports `graph-db:commit-epoch` and `graph-db.spacetime:claim-commit-epoch`, which `experiment` does not yet).
- Lisp: spaces only, never tabs; hard 80-column limit on every line of `.lisp` and `.asd` files, docstrings and comments included; terse comments pointing at the spec (`SS3`), the recon (`recon C9`), or an issue. Docstrings: what, returns, the one trap.
- Never run `pkill`, `pgrep -f`, or `kill`: other agents' SBCL images share this host. One SBCL build at a time in this worktree.
- Suites, foreground, one at a time. The memory suite:

  ```
  cd /home/raison/work/cl-llm/.worktrees/s6b
  sbcl --dynamic-space-size 4096 --non-interactive \
    --eval '(push #p"/home/raison/work/vivace-graph-v3/.worktrees/epoch-axis/" asdf:*central-registry*)' \
    --eval '(push #p"/home/raison/work/cl-llm/.worktrees/s6b/" asdf:*central-registry*)' \
    --eval '(ql:quickload :cl-llm/memory/tests :silent t)' \
    --eval '(asdf:test-system :cl-llm/memory)'
  ```

  The agent suite: the same with `:cl-llm/agent/tests` and `(asdf:test-system :cl-llm/agent)`. The claims suite: `:cl-llm/rag/claims/tests` and `(asdf:test-system :cl-llm/rag/claims)`. Read `Did N checks.` and the failure count from each run and put them in your report. No baseline is written down anywhere (recon E9): Task 1 records one before touching code. One test alone (each harness binds its own system directory, so a bare `run!` is fine here):

  ```
  sbcl --dynamic-space-size 4096 --non-interactive \
    --eval '(push #p"/home/raison/work/vivace-graph-v3/.worktrees/epoch-axis/" asdf:*central-registry*)' \
    --eval '(push #p"/home/raison/work/cl-llm/.worktrees/s6b/" asdf:*central-registry*)' \
    --eval '(ql:quickload :cl-llm/memory/tests :silent t)' \
    --eval '(fiveam:run! (quote cl-llm.memory/tests::TEST-NAME))'
  ```

  (`:cl-llm/agent/tests` and `cl-llm.agent/tests::TEST-NAME` for an agent test.)
- Test packages: `cl-llm.memory/tests` (nicknames `mem`, `st`, `gdb`, `te`; helpers `+p+`, `+ss+`, `%ts`, `%interval`, `%open-from`, `%belief`, `%belief-in`, `with-memory-graph`, `with-two-stores`) and `cl-llm.agent/tests` (`+p+`, `+subj+`, `%ts`, `%open-from`, `%belief`, `%belief-at`, `%tool`, `%args`, `%call`, `with-stores`). Engine internals are written with `graph-db::` (`transaction-id`, `graph-open-p`, `graph` the class) and a comment saying they are internal.
- Every negative test names its mechanism in its docstring and has a control in the same test. After every scripted edit to an existing test file, `git diff HEAD -- <file> | grep '^-[^-]'` shows only the lines the task says to change.
- Existing tests keep passing unless a task names the test and the reason it changes. The golden files `tests-memory/golden/capture.sexp` and `tests-memory/golden/trace.sexp` do not change.
- Docs travel with the code: Task 6 carries `docs/agent-memory.md` and `docs/agent-tools.md`; the push hook refuses source-only pushes. Nothing is pushed without Kevin. Commit trailers, both lines, on every commit:

  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
  ```

- The controller closes #46–#51 by hand with the merge SHA; a merge never auto-closes.

## Rulings taken while planning

1. `belief-record` gains two slots, `store` and `superseded-by-store`, both graphs: the JSON `"superseded-by"` object needs the successor's store and the record is the only carrier. Cost if wrong: one slot to remove.
2. `decision-record` gains `store` (the store-name string `trace` found the decision in) beside `epoch`, so the trace tool's `"store"` field survives the deletion of `%find-decision`. Cost: one slot.
3. `resolve-cite` takes no snapshot of its own; its callers (`trace`) do, and an enclosing snapshot of the same graph is inherited by the engine. Cost: an unsnapshotted `resolve-cite` when called bare, which is today's behaviour.
4. A higher-trust prior refuses even when the proposal names the same object; the boundary, not idempotence, is the point (spec §5). Cost: one refused duplicate that the model reads as a conflict.
5. `%recall-tool` calls `mem:recall` on the write store with the whole scope; the write store is always in the scope (`make-scope`). Cost: none.

## File Structure

| file | responsibility |
|---|---|
| `memory/scope.lisp` (new) | `scope-argument-error`, `%scope-error`, `%store-open-p`, `%scope-names`, `check-scope`, `call-with-scope-snapshots`, `with-scope-snapshots` |
| `memory/recall.lisp` | `%recall-in` (today's per-store selection), `%successor` with the trust rule, `recall` over the union, the two new `belief-record` slots |
| `memory/cite.lisp` | `resolve-cite &key scope`, first-in-scope, `store` filled on resolved and reaped records |
| `memory/trace.lisp` | `%governing-prior`, `%scope-conflict-report`, third branch of `%violation-families`, `conclude` pre-read and epoch, `%write-refusal` epoch, `%write-evidence` pair key, `decisions-citing` pairs, `trace` first-in-scope with `store` and `epoch`, `trace-listing` `:missing` |
| `memory/packages.lisp`, `cl-llm.asd` | exports; `scope` after `write`, before `recall` |
| `agent/scope.lisp` | `note-cite` first-wins; `make-scope` delegates the store-list checks to `mem:check-scope` |
| `agent/render.lisp` | `%record-json (record)`: store from the record, `"superseded-by"` an object |
| `agent/memory-tools.lisp` | one `mem:recall` with the scope; trace tool through `mem:trace`; `decisions-citing` pairs; `"epoch"` on decisions; conclude tools pass the scope; `%find-decision` deleted |
| `agent/annotate.lisp` | pairs, NIL-safe trace |
| `claims/source.lisp` | `%claim-doc-id source claim` with the graph name |
| `scripts/memory-image.lisp` | the clock: opened first, passed on every open, closed last |
| `tests-memory/store-tests.lisp`, `tests-agent/harness.lisp` | clocked two-store fixtures |
| `tests-memory/scope-tests.lisp` (new) | `check-scope`, snapshot discipline, trust rule, conclude with scope, cites, decisions, epoch |
| `docs/agent-memory.md`, `docs/agent-tools.md` | scope, trust rule, clock, JSON fields, refusal family, epoch |

---

### Task 1: Baselines, `memory/scope.lisp`, and the clocked fixtures

**Files:**
- Create: `memory/scope.lisp`
- Create: `tests-memory/scope-tests.lisp`
- Modify: `memory/packages.lisp` (export list), `cl-llm.asd` (`cl-llm/memory` and `cl-llm/memory/tests` components)
- Modify: `tests-memory/store-tests.lisp:12-33` (`%call-with-two-stores`)
- Modify: `tests-agent/harness.lisp:15-35` (`%call-with-stores`)

**Interfaces:**
- Consumes: `belief-argument-error` and its readers (`memory/write.lisp`), `store-name` (`memory/schema.lisp`), `gdb:graph-system-clock`, `gdb:call-with-read-snapshot`, `gdb:open-system-clock`, `gdb:close-system-clock`, `graph-db::graph-open-p` (internal), `graph-db::graph` (the class, internal).
- Produces: `mem:check-scope (scope &key write-store) => scope`, `mem:scope-argument-error`, `mem:call-with-scope-snapshots (thunk scope)`, `mem:with-scope-snapshots ((scope) &body)`, `mem::%scope-names`; clocked `with-two-stores ((a b) &body)` in `tests-memory` and `with-stores ((working private) &body)` in `tests-agent`, both asserting the shared clock inside the fixture.

- [ ] **Step 1: Record the baselines**

Run the memory suite, the agent suite and the claims suite (Global Constraints), one after another, on the untouched tree. Write the three `Did N checks.` lines and failure counts into your report under "Baseline". Expected: all three green.

- [ ] **Step 2: Write the failing tests**

Create `tests-memory/scope-tests.lisp`:

```lisp
;;;; tests-memory/scope-tests.lisp -- a scope of stores in trust order:
;;;; validation, snapshots, and the cross-store behaviour of every
;;;; reader.  Spec 2026-09-05 (S6b), cl-llm#24.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %clockless-pair (fn)
  "Two stores with NO clock, for the refusals a clocked fixture cannot
show.  *SYSTEM-CLOCK* is bound NIL explicitly so the premise does not
depend on run order."
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (gdb:*system-clock* nil)
         (gdb:*system-directory*
           (format nil "/tmp/cl-llm-scope-sys-~a/" stamp))
         (dirs (list (format nil "/tmp/cl-llm-scope-a-~a/" stamp)
                     (format nil "/tmp/cl-llm-scope-b-~a/" stamp)))
         (a (gdb:make-graph :cl-llm-memory (first dirs)
                            :buffer-pool-size 1000))
         (b (gdb:make-graph :memory-private (second dirs)
                            :buffer-pool-size 1000)))
    (unwind-protect (funcall fn a b)
      (ignore-errors (gdb:close-graph a))
      (ignore-errors (gdb:close-graph b))
      (dolist (d (cons gdb:*system-directory* dirs))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))

(defmacro with-clockless-pair ((a b) &body body)
  `(%clockless-pair (lambda (,a ,b) ,@body)))

(test check-scope-accepts-two-clocked-stores-and-one-clockless-store
  "SS3: the positive cases.  A multi-store scope on one clock passes;
a single store needs no clock."
  (with-two-stores (a b)
    (let ((s (list a b)) (r (list b a)))
      (is (eq s (mem:check-scope s)) "returns the very list")
      (is (eq r (mem:check-scope r :write-store a)))))
  (with-clockless-pair (a b)
    (declare (ignore b))
    (is (null (gdb:graph-system-clock a)) "control: no clock")
    (is (equal (list a) (mem:check-scope (list a))))))

(test check-scope-refuses-a-malformed-scope
  "SS3: empty, a repeated graph, a closed graph, a write store outside
the list -- each SCOPE-ARGUMENT-ERROR, a BELIEF-ARGUMENT-ERROR whose
message names the store."
  (with-two-stores (a b)
    (signals mem:scope-argument-error (mem:check-scope '()))
    (signals mem:scope-argument-error (mem:check-scope (list a a)))
    (signals mem:scope-argument-error
      (mem:check-scope (list a) :write-store b))
    (handler-case (mem:check-scope (list a a))
      (mem:scope-argument-error (c)
        (is (typep c 'mem:belief-argument-error))
        (is (search "cl-llm-memory" (princ-to-string c)))))
    (is (equal (list a b) (mem:check-scope (list a b))) "control")))

(test check-scope-refuses-a-closed-store
  "SS3: GRAPH-OPEN-P is the engine's own open flag (recon E8)."
  (with-clockless-pair (a b)
    (declare (ignore b))
    (is (equal (list a) (mem:check-scope (list a))) "control: open")
    (gdb:close-graph a)
    (signals mem:scope-argument-error (mem:check-scope (list a)))))

(test check-scope-refuses-two-stores-not-on-one-clock
  "SS3 one regime: two clockless stores, and one clocked with one not,
are refused; the message names the clockless store."
  (with-clockless-pair (a b)
    (signals mem:scope-argument-error (mem:check-scope (list a b)))
    (handler-case (mem:check-scope (list a b))
      (mem:scope-argument-error (c)
        (is (search "no system clock" (princ-to-string c)))))
    (is (equal (list a) (mem:check-scope (list a))) "control")))

(test check-scope-refuses-two-stores-on-two-clocks
  "SS3: attached, but to different clocks -- two counters, no shared
axis.  A second clock in its own directory is legal to open."
  (with-two-stores (a b)
    (declare (ignore b))
    (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                          (random 1000000)))
           (cdir (format nil "/tmp/cl-llm-scope-clock2-~a/" stamp))
           (dir (format nil "/tmp/cl-llm-scope-c-~a/" stamp))
           (clock (gdb:open-system-clock cdir))
           (c nil))
      (unwind-protect
           (progn
             (setf c (gdb:make-graph :memory-private dir
                                     :buffer-pool-size 1000
                                     :system-clock clock))
             (is (not (eq (gdb:graph-system-clock a)
                          (gdb:graph-system-clock c)))
                 "control: two clocks")
             (signals mem:scope-argument-error
               (mem:check-scope (list a c)))
             (handler-case (mem:check-scope (list a c))
               (mem:scope-argument-error (e)
                 (is (search "different clock" (princ-to-string e))))))
        (when c (ignore-errors (gdb:close-graph c)))
        (ignore-errors (gdb:close-system-clock clock))
        (dolist (d (list dir cdir))
          (ignore-errors (uiop:delete-directory-tree
                          (pathname d) :validate t
                          :if-does-not-exist :ignore)))))))

(test scope-snapshots-compose-and-refuse-inside-a-transaction
  "SS3 (recon C9): under WITH-SCOPE-SNAPSHOTS both stores answer and
*TRANSACTION* is NIL; inside an open transaction the read is refused
before any engine call -- for a two-store scope, where the engine would
have signalled CROSS-GRAPH-TRANSACTION-ERROR on the foreign half, and
for a one-store scope, where the engine would have ALLOWED the read and
shown uncommitted state.  The control is the engine's own refusal."
  (with-two-stores (a b)
    (%belief-in a "ci-status" '(:verdict . "green"))
    (%belief-in b "ci-status" '(:verdict . "red"))
    (mem:with-scope-snapshots ((list a b))
      (is (null gdb:*transaction*))
      (is (= 1 (length (mem:recall a +ss+))))
      (is (= 1 (length (mem:recall b +ss+)))))
    (gdb:with-transaction (:graph a)
      (signals mem:scope-argument-error
        (mem:with-scope-snapshots ((list a b)) (mem:recall b +ss+)))
      (signals mem:scope-argument-error
        (mem:with-scope-snapshots ((list a)) (mem:recall a +ss+)))
      ;; The controls go to the engine directly: RECALL itself is now
      ;; refused up front by the helper.
      (signals gdb:cross-graph-transaction-error
        (st:claims-touching b 'mem:belief :repo "cl-llm" :role :subject)
        "control: the engine refuses the foreign half only")
      (is (= 1 (length (st:claims-touching a 'mem:belief :repo "cl-llm"
                                           :role :subject)))
          "control: the engine allows the own-store half"))))
```

Register it: in `cl-llm.asd`, in `cl-llm/memory/tests`' components, add `(:file "scope-tests")` after `(:file "store-tests")` (it uses `with-two-stores`).

Clock the memory fixture. In `tests-memory/store-tests.lisp`, replace `%call-with-two-stores` (the whole `defun`, lines 12–33) with:

```lisp
(defun %call-with-two-stores (fn)
  "Two stores on ONE system clock (S6b SS3), each in scratch dirs.  The
clock closes in the outer UNWIND-PROTECT, after the stores: a leaked
clock refuses every later OPEN-SYSTEM-CLOCK in this image (recon C5).
The attach is asserted inside the fixture -- a store that silently
failed to attach would pass every epoch test for the wrong reason."
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (gdb:*system-directory*
           (format nil "/tmp/cl-llm-mem2-sys-~a/" stamp))
         (cdir (format nil "/tmp/cl-llm-mem2-clock-~a/" stamp))
         (dirs (list (format nil "/tmp/cl-llm-mem2-a-~a/" stamp)
                     (format nil "/tmp/cl-llm-mem2-b-~a/" stamp)))
         (clock (gdb:open-system-clock cdir)))
    (unwind-protect
         (let ((a (gdb:make-graph :cl-llm-memory (first dirs)
                                  :buffer-pool-size 1000
                                  :system-clock clock))
               (b (gdb:make-graph :memory-private (second dirs)
                                  :buffer-pool-size 1000
                                  :system-clock clock)))
           (unwind-protect
                (progn
                  (is (eq (gdb:graph-system-clock a)
                          (gdb:graph-system-clock b))
                      "fixture: both stores on one clock")
                  (funcall fn a b))
             (ignore-errors (gdb:close-graph a))
             (ignore-errors (gdb:close-graph b))))
      (ignore-errors (gdb:close-system-clock clock))
      (dolist (d (list* cdir gdb:*system-directory* dirs))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))
```

Clock the agent fixture. In `tests-agent/harness.lisp`, replace `%call-with-stores` (the whole `defun`, lines 15–35) with:

```lisp
(defun %call-with-stores (fn)
  "Working and private stores on ONE system clock (S6b SS3).  The clock
closes after the stores, in the outer UNWIND-PROTECT (a leaked clock
refuses every later open in this image); the attach is asserted inside
the fixture so a silently unattached store cannot pass vacuously."
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (dirs (list (format nil "/tmp/cl-llm-agent-w-~a/" stamp)
                     (format nil "/tmp/cl-llm-agent-p-~a/" stamp)))
         (cdir (format nil "/tmp/cl-llm-agent-clock-~a/" stamp))
         (gdb:*system-directory* (format nil "/tmp/cl-llm-agent-sys-~a/"
                                         stamp))
         (clock (gdb:open-system-clock cdir)))
    (unwind-protect
         (let ((working (gdb:make-graph :cl-llm-memory (first dirs)
                                        :buffer-pool-size 1000
                                        :system-clock clock))
               (private (gdb:make-graph :memory-private (second dirs)
                                        :buffer-pool-size 1000
                                        :system-clock clock)))
           (unwind-protect
                (progn
                  (is (eq (gdb:graph-system-clock working)
                          (gdb:graph-system-clock private))
                      "fixture: both stores on one clock")
                  (funcall fn working private))
             (ignore-errors (gdb:close-graph working))
             (ignore-errors (gdb:close-graph private))))
      (ignore-errors (gdb:close-system-clock clock))
      (dolist (d (list* cdir gdb:*system-directory* dirs))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run the one-test command for `check-scope-accepts-two-clocked-stores-and-one-clockless-store`.
Expected: FAIL with an undefined function or unknown symbol `MEM:CHECK-SCOPE` (the reader macro may signal at read time that the symbol is not external in `CL-LLM.MEMORY`; either is the expected red).

- [ ] **Step 4: Write `memory/scope.lisp` and register it**

Create `memory/scope.lisp`:

```lisp
;;;; memory/scope.lisp -- a scope: open stores in trust order, most
;;;; trusted first, read under one snapshot per store.  Spec 2026-09-05
;;;; (S6b) SS3.

(in-package #:cl-llm.memory)

(define-condition scope-argument-error (belief-argument-error) ()
  (:documentation "A scope CHECK-SCOPE refuses, or a scope read inside an
open write transaction (SS3).  VALUE is the list of store names, not the
graphs, so the message stays short.")
  (:report (lambda (c s)
             (format s "scope ~s: ~a"
                     (belief-argument-error-value c)
                     (belief-argument-error-reason c)))))

(defun %scope-names (scope)
  (if (listp scope)
      (mapcar (lambda (g)
                (if (typep g 'graph-db::graph) (store-name g) g))
              scope)
      scope))

(defun %scope-error (scope reason)
  (error 'scope-argument-error
         :argument :scope :value (%scope-names scope) :reason reason))

(defun %store-open-p (graph)
  ;; GRAPH-OPEN-P is internal to the engine; it is the slot the engine's
  ;; own registry guard consults (recon E8).
  (and (typep graph 'graph-db::graph) (graph-db::graph-open-p graph)))

(defun check-scope (scope &key write-store)
  "SCOPE itself when it is a non-empty list of distinct open stores with
distinct STORE-NAMEs, WRITE-STORE (when given) among them, and -- for
more than one store -- every store attached to ONE system clock (SS3,
one regime).  A single store needs no clock.  Signals
SCOPE-ARGUMENT-ERROR naming the offending store otherwise."
  (unless (consp scope)
    (%scope-error scope "must be a non-empty list of open stores"))
  (dolist (g scope)
    (unless (%store-open-p g)
      (%scope-error scope (format nil "~a is not an open store"
                                  (if (typep g 'graph-db::graph)
                                      (store-name g)
                                      g)))))
  (loop for (g . rest) on scope
        when (member g rest)
          do (%scope-error scope (format nil "~a appears twice"
                                         (store-name g))))
  (loop for (n . rest) on (%scope-names scope)
        when (member n rest :test #'string=)
          do (%scope-error scope (format nil "two stores are named ~a" n)))
  (when (and write-store (not (member write-store scope)))
    (%scope-error scope "the write store is not in the scope"))
  (when (rest scope)
    (let ((clock (gdb:graph-system-clock (first scope))))
      (dolist (g scope)
        (let ((c (gdb:graph-system-clock g)))
          (cond ((null c)
                 (%scope-error
                  scope (format nil "~a has no system clock; a ~
                                     multi-store scope needs one"
                                (store-name g))))
                ((not (eq c clock))
                 (%scope-error
                  scope (format nil "~a is on a different clock from ~a"
                                (store-name g)
                                (store-name (first scope))))))))))
  scope)

(defun call-with-scope-snapshots (thunk scope)
  "THUNK under one read snapshot per store of SCOPE, nested in scope
order; the engine composes them, with no single instant across stores
(GH #53).  Refused before any engine call inside an open write
transaction: the own-store half would show uncommitted state and the
foreign half would hit the engine's cross-graph refusal (recon C9)."
  (when gdb:*transaction*
    (%scope-error scope "a scope read inside an open transaction"))
  (labels ((nest (stores)
             (if (null stores)
                 (funcall thunk)
                 (gdb:call-with-read-snapshot
                  (lambda () (nest (rest stores)))
                  (first stores)))))
    (nest scope)))

(defmacro with-scope-snapshots ((scope) &body body)
  "BODY under CALL-WITH-SCOPE-SNAPSHOTS of SCOPE."
  `(call-with-scope-snapshots (lambda () ,@body) ,scope))
```

In `cl-llm.asd`, in `cl-llm/memory`'s components, insert `(:file "scope")` between `(:file "write")` and `(:file "recall")`.

In `memory/packages.lisp`, add after the `;; write` export lines:

```lisp
   ;; scope (S6b)
   #:check-scope #:scope-argument-error
   #:call-with-scope-snapshots #:with-scope-snapshots
```

- [ ] **Step 5: Run the new tests, then both suites**

Run the one-test command for each of the six new tests. Expected: each PASSES.
Then run the memory suite and the agent suite (the fixtures changed in both). Expected: both green; the check counts rise by the new tests only. Record the counts.

- [ ] **Step 6: Commit**

```bash
git add memory/scope.lisp memory/packages.lisp cl-llm.asd \
        tests-memory/scope-tests.lisp tests-memory/store-tests.lisp \
        tests-agent/harness.lisp
git commit -m "feat(memory): check-scope and composed scope snapshots; clocked two-store fixtures (#24)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 2: `recall` over a scope with trust-ordered supersession (#46)

**Files:**
- Modify: `memory/recall.lisp` (the `belief-record` defstruct, `%successor`, `recall`)
- Modify: `memory/packages.lisp` (exports)
- Modify: `agent/render.lisp:61-77` (`%record-json`)
- Modify: `agent/memory-tools.lisp:6-41` (`%recall-tool`)
- Modify: `tests-memory/scope-tests.lisp` (append), `tests-agent/memory-tools-tests.lisp` (one existing test extended)

**Interfaces:**
- Consumes: `check-scope`, `with-scope-snapshots` (Task 1); `%before-p`, `%series-key`, `%retracted-at`, `%open-p`, `%start-instant`.
- Produces: `recall (graph subject &key relation producer at include-retracted (scope (list graph)))`; `belief-record-store` and `belief-record-superseded-by-store` (graphs); `%record-json (record)`; the `"superseded-by"` JSON object `{"cite", "store"}`.

- [ ] **Step 1: Write the failing tests**

Append to `tests-memory/scope-tests.lisp`:

```lisp
(defun %row (records object-key)
  (find object-key records
        :key (lambda (r) (st:claim-object-key (mem:belief-record-claim r)))
        :test #'string=))

(test recall-supersedes-across-stores-from-equal-or-higher-trust-only
  "SS4 (#46): one series split across two stores.  Scope (P W), P more
trusted.  A newer belief in P supersedes W's older one: the W row is
not current and names P's claim and store.  A newer belief in W does
NOT supersede P's older one: both rows current, nothing superseded.
The reversed scope is the control that proves the rule reads the
order."
  (with-two-stores (w p)
    ;; W: green from 09-01; P: red from 09-02 -- P newer.
    (%belief-in w "ci-status" '(:verdict . "green"))
    (gdb:with-transaction (:graph p)
      (mem:record-belief p +ss+ "ci-status" '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (%open-from (%ts "2026-09-02T08:00:00Z"))))
    (let* ((rows (mem:recall p +ss+ :scope (list p w)))
           (green (%row rows "green"))
           (red (%row rows "red")))
      (is (= 2 (length rows)))
      (is (eq w (mem:belief-record-store green)))
      (is (eq p (mem:belief-record-store red)))
      (is (mem:belief-record-current-p red))
      (is (not (mem:belief-record-current-p green))
          "P is more trusted and newer: W's belief is superseded")
      (is (eq (mem:belief-record-claim red)
              (mem:belief-record-superseded-by green)))
      (is (eq p (mem:belief-record-superseded-by-store green))))
    ;; The reversed scope: W more trusted than P; P's newer belief may
    ;; not supersede W's.
    (let* ((rows (mem:recall w +ss+ :scope (list w p)))
           (green (%row rows "green"))
           (red (%row rows "red")))
      (is (mem:belief-record-current-p green) "control: reversed order")
      (is (mem:belief-record-current-p red))
      (is (null (mem:belief-record-superseded-by green)))
      (is (null (mem:belief-record-superseded-by red))))
    ;; Single-store reads are unchanged: each store sees only itself.
    (is (= 1 (length (mem:recall w +ss+))))
    (is (mem:belief-record-current-p (first (mem:recall w +ss+))))))

(test recall-keeps-filters-per-store-and-the-order-contract
  "SS4: :AT and :RELATION apply per store before the union; the union
keeps validity-start-descending order across stores."
  (with-two-stores (w p)
    (%belief-in w "ci-status" '(:verdict . "green"))
    (%belief-in w "owner" '(:person . "kevin"))
    (gdb:with-transaction (:graph p)
      (mem:record-belief p +ss+ "ci-status" '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (%open-from (%ts "2026-09-02T08:00:00Z"))))
    (let ((rows (mem:recall w +ss+ :relation "ci-status"
                                   :scope (list w p))))
      (is (= 2 (length rows)))
      (is (string= "red" (st:claim-object-key
                          (mem:belief-record-claim (first rows))))
          "newest validity first, across stores"))
    (is (= 2 (length (mem:recall w +ss+ :at (%ts "2026-09-01T12:00:00Z")
                                        :scope (list w p))))
        "at 09-01 noon: green and owner, not red")
    (is (= 3 (length (mem:recall w +ss+ :scope (list w p)))))))
```

In `tests-agent/memory-tools-tests.lisp` two existing tests change, each named here with its reason. JSON is read with `json:jget`; booleans decode to `t`/`nil`.

In `recall-filters-and-orders` (line 62), `"superseded-by"` becomes an object. Change

```lisp
        (is (mem:cite-p (json:jget old "superseded-by")))))
```

to

```lisp
        (is (mem:cite-p (json:jget old "superseded-by" "cite")))
        (is (string= "cl-llm-memory"
                     (json:jget old "superseded-by" "store")))))
```

In `recall-interleaves-cross-store-newest-first` (line 84), the scope `(list w p)` makes W more trusted than P, so P's newer belief no longer supersedes W's: both rows are current. Change its last form

```lisp
      (is (equal '("new" "old")
                 (map 'list (lambda (x) (json:jget x "object" "key"))
                      (json:jget r "records")))))))
```

to

```lisp
      (is (equal '("new" "old")
                 (map 'list (lambda (x) (json:jget x "object" "key"))
                      (json:jget r "records"))))
      ;; S6b (#46): W is more trusted than P here, so P's newer belief
      ;; does not supersede W's -- both current, nothing superseded.
      (let ((rows (coerce (json:jget r "records") 'list)))
        (is (every (lambda (x) (eq t (json:jget x "current"))) rows))
        (is (every (lambda (x) (null (json:jget x "superseded-by")))
                   rows))))))
```

Then append this new test to `tests-agent/memory-tools-tests.lisp`:

```lisp
(test recall-renders-a-cross-store-successor-with-its-store
  "S6b SS4 JSON: scope (P W) with W the write store; P more trusted and
newer: the W row is not current and its superseded-by is an object
naming P's cite and store."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief p "ci-status" '(:verdict . "red")
             :start "2026-09-02T08:00:00Z")
    (let* ((tools (agent:make-agent-tools (list p w) :write-store w
                                          :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm"))
           (rows (coerce (json:jget r "records") 'list))
           (green (find "cl-llm-memory" rows
                        :key (lambda (x) (json:jget x "store"))
                        :test #'string=)))
      (is (= 2 (length rows)))
      (is (eq nil (json:jget green "current")))
      (is (string= "memory-private"
                   (json:jget green "superseded-by" "store")))
      (is (mem:cite-p (json:jget green "superseded-by" "cite"))))))
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run the one-test command for `recall-supersedes-across-stores-from-equal-or-higher-trust-only`.
Expected: FAIL — `:SCOPE` is not a valid keyword argument to `RECALL`.

- [ ] **Step 3: Rewrite `recall`**

In `memory/recall.lisp`, replace the `belief-record` defstruct with:

```lisp
(defstruct belief-record
  "One recalled claim plus what a caller would otherwise recompute
wrongly.  SUPERSEDED-BY is COMPUTED -- the next current claim in the
same (producer subject relation) series by validity start, in a store
no later in scope order (SS4, the trust rule) -- never stored, so it
cannot go stale.  STORE is the graph the claim lives in;
SUPERSEDED-BY-STORE the successor's."
  claim
  (current-p nil)
  (superseded-by nil)
  (retracted-at nil)
  standing
  extent
  store
  (superseded-by-store nil))
```

Replace `%successor` with:

```lisp
(defun %successor (claim series owner)
  "The earliest-starting current claim in SERIES that starts after
CLAIM and lives in a store no later in scope order than CLAIM's, or
NIL.  OWNER maps each claim to its store's position in the scope (SS4:
a lower-trust store never supersedes a higher one)."
  (let ((start (%start-instant claim))
        (pos (gethash claim owner))
        (best nil))
    (dolist (c series best)
      (when (and (not (eq c claim))
                 (st:claim-current-p c)
                 (<= (gethash c owner) pos)
                 (local-time:timestamp< start (%start-instant c))
                 (or (null best)
                     (local-time:timestamp< (%start-instant c)
                                            (%start-instant best))))
        (setf best c)))))
```

Replace `recall` with:

```lisp
(defun %recall-in (graph subject relation producer at include-retracted)
  "Today's single-store selection for GRAPH: (values WANTED ALL).  The
:AT membership test is EQL on claim objects, sound only within one
store (recon E4), so it stays here, before the union."
  (let* ((all (st:claims-touching graph 'belief (car subject)
                                  (cdr subject) :role :subject))
         ;; The engine's :AT is the validity filter (cl-temporal-extent#2
         ;; fixed the open-ended case it used to get wrong).
         (at-window (and at (st:claims-touching
                             graph 'belief (car subject) (cdr subject)
                             :role :subject :at at)))
         (wanted (remove-if-not
                  (lambda (c)
                    (and (or (null relation)
                             (string= relation (st:claim-relation c)))
                         (or (null producer)
                             (string= producer (st:claim-producer c)))
                         (or include-retracted (st:claim-current-p c))
                         (or (null at) (member c at-window))))
                  all)))
    (values wanted all)))

(defun recall (graph subject &key relation producer at include-retracted
                                  (scope (list graph)))
  "BELIEF-RECORDs about SUBJECT over SCOPE, ordered newest validity
first (SS6; SS4 for the scope).  RELATION and PRODUCER narrow the
series; AT keeps only beliefs valid at that instant; retracted claims
are excluded unless INCLUDE-RETRACTED.  Each record names its store;
supersession is computed over the whole scope under the trust rule.
Nothing recorded returns NIL -- which is not an absence standing."
  (%check-endpoint :subject subject)
  (check-scope scope)
  (with-scope-snapshots (scope)
    (let ((series (make-hash-table :test 'equal))
          (owner (make-hash-table :test 'eq))
          (rows '()))
      ;; Store-major in scope order, then a stable sort: a genuine
      ;; cross-store tie breaks by scope order (agent SS6).
      (loop for g in scope
            for pos from 0
            do (multiple-value-bind (wanted all)
                   (%recall-in g subject relation producer at
                               include-retracted)
                 ;; Successors are found within the full series, so a
                 ;; claim outside the AT window can still be named as
                 ;; what superseded one inside.
                 (dolist (c all)
                   (setf (gethash c owner) pos)
                   (push c (gethash (%series-key c) series)))
                 (dolist (c (sort (copy-list wanted) #'%before-p))
                   (push (cons g c) rows))))
      (loop for (g . c) in (stable-sort (nreverse rows) #'%before-p
                                        :key #'cdr)
            for succ = (%successor c (gethash (%series-key c) series)
                                   owner)
            collect (make-belief-record
                     :claim c
                     :current-p (and (st:claim-current-p c) (%open-p c)
                                     (null succ))
                     :superseded-by succ
                     :superseded-by-store (and succ
                                               (nth (gethash succ owner)
                                                    scope))
                     :retracted-at (%retracted-at c)
                     :standing (st:claim-standing c)
                     :extent (st:claim-extent c)
                     :store g)))))
```

In `memory/packages.lisp`, add `#:belief-record-store #:belief-record-superseded-by-store` after `#:belief-record-extent`.

In `agent/render.lisp`, replace `%record-json` with:

```lisp
(defun %record-json (record)
  "One BELIEF-RECORD as the model reads it (SS6).  STORE is the record's
own; SUPERSEDED-BY names the successor's cite and store, which may be
another store in scope (S6b SS4)."
  (let* ((c (mem:belief-record-claim record))
         (s (mem:belief-record-superseded-by record))
         (e (mem:belief-record-extent record)))
    (json:jobject
     "store" (mem:store-name (mem:belief-record-store record))
     "cite" (mem:claim-cite c)
     "relation" (st:claim-relation c)
     "object" (and (typep c 'mem:belief-binary)
                   (%endpoint-json (st:claim-object-namespace c)
                                   (st:claim-object-key c)))
     "standing" (%standing (mem:belief-record-standing record))
     "valid-from" (%from e)
     "valid-to" (%to e)
     "current" (%bool (mem:belief-record-current-p record))
     "superseded-by"
     (and s (json:jobject
             "cite" (mem:claim-cite s)
             "store" (mem:store-name
                      (mem:belief-record-superseded-by-store record)))))))
```

In `agent/memory-tools.lisp`, replace the `let*` body of `%recall-tool`'s lambda (from `(rows '()))` through the `json:to-json` form) so the lambda reads:

```lisp
   (lambda (subject-namespace subject-key relation at)
     ;; An unknown namespace is never interned by %FIND-KEYWORD, so it
     ;; reads as "nothing recorded" -- an empty array -- not an error.
     (let* ((ns (%find-keyword subject-namespace))
            (subject (and ns (cons ns subject-key)))
            (instant (and at (%parse-iso at)))
            ;; One RECALL over the scope: the memory layer merges and
            ;; computes supersession under the trust rule (S6b SS4).
            (rows (and subject
                       (mem:recall (scope-write-store scope) subject
                                   :relation relation :at instant
                                   :scope (scope-stores scope)))))
       (dolist (r rows)
         (note-cite scope (mem:claim-cite (mem:belief-record-claim r))
                    (mem:belief-record-store r)))
       (let* ((cap (scope-max-rows scope))
              (shown (subseq rows 0 (min cap (length rows)))))
         (json:to-json
          (json:jobject
           "records" (map 'vector #'%record-json shown)
           "truncated" (%bool (> (length rows) cap)))))))
```

- [ ] **Step 4: Run the tests, then both suites**

Run the one-test command for `recall-supersedes-across-stores-from-equal-or-higher-trust-only`, `recall-keeps-filters-per-store-and-the-order-contract`, `recall-filters-and-orders`, `recall-interleaves-cross-store-newest-first`, `recall-breaks-a-genuine-cross-store-tie-by-scope-order`, `recall-renders-a-cross-store-successor-with-its-store`. Expected: each PASSES (the tie-break test is the regression guard for the store-major stable sort).
Run the memory and agent suites. Expected: green; `capture-listing`'s golden file unchanged (`git status` shows no change under `tests-memory/golden/`).

- [ ] **Step 5: Commit**

```bash
git add memory/recall.lisp memory/packages.lisp agent/render.lisp \
        agent/memory-tools.lisp tests-memory/scope-tests.lisp \
        tests-agent/memory-tools-tests.lisp
git commit -m "feat(memory): recall over a scope with trust-ordered supersession (#46, #24)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 3: Cites resolve first-in-scope; the cache never overwrites (#48)

**Files:**
- Modify: `memory/cite.lisp:98-128` (`resolve-cite`)
- Modify: `agent/scope.lisp:25-51` (`make-scope`, `note-cite`)
- Modify: `tests-memory/scope-tests.lisp` (append), `tests-agent/memory-tools-tests.lisp` (append)

**Interfaces:**
- Consumes: `check-scope` (Task 1), `%current-among`, `cite-record`, `scope-cites`, `cite-store`.
- Produces: `resolve-cite (graph cite at &key (scope (list graph)))` with `cite-record-store` filled on `:resolved` and `:reaped`; `note-cite` first-wins; `make-scope` signalling `scope-error` wrapping `mem:check-scope`'s message.

- [ ] **Step 1: Write the failing tests**

Append to `tests-memory/scope-tests.lisp`:

```lisp
(test resolve-cite-answers-from-the-first-store-in-scope
  "SS6 (#48): one cite, two stores holding the same identity; the
record names the first store in scope order, whichever order is
given.  A cite no store holds is :ABSENT with no store."
  (with-two-stores (w p)
    (let* ((cw (%belief-in w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite cw))
           (cp (%belief-in p "ci-status" '(:verdict . "green")))
           ;; AS-OF NOW must postdate both versions' stamps.
           (now (progn (sleep 0.01) (local-time:now))))
      (is (string= cite (mem:claim-cite cp))
          "control: both stores mint one cite for one fact")
      (let ((r (mem:resolve-cite w cite now :scope (list w p))))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (string= "cl-llm-memory" (mem:cite-record-store r))))
      (let ((r (mem:resolve-cite w cite now :scope (list p w))))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (string= "memory-private" (mem:cite-record-store r))))
      (let ((r (mem:resolve-cite w (mem:claim-cite
                                    (%belief-in w "owner"
                                                '(:person . "x")))
                                 (%ts "2020-01-01T00:00:00Z")
                                 :scope (list w p))))
        (is (eq :absent (mem:cite-record-state r)))
        (is (null (mem:cite-record-store r)))))))
```

Append to `tests-agent/memory-tools-tests.lisp`:

```lisp
(test recall-does-not-move-the-cite-cache-so-retract-still-works
  "S6b SS6 (#48): both stores hold one cite; scope (W P), write store
W.  After RECALL, which sees both copies, RETRACT on the cite acts on
W's copy -- NOTE-CITE is first-wins and CITE-STORE scans first-in-scope,
so the cache and the scan agree.  The control: retract in the reversed
scope (P W), write store W, is refused by name because P's copy resolves
first."
  (with-stores (w p)
    (let* ((cw (%belief w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite cw)))
      (%belief p "ci-status" '(:verdict . "green"))
      (let* ((scope (agent:make-scope (list w p) :write-store w
                                      :producer +p+))
             (tools (agent:make-memory-tools scope)))
        (%call tools "recall" "subject-namespace" "repo"
               "subject-key" "cl-llm")
        (is (eq w (agent:cite-store scope cite))
            "the cache names the first store after recall")
        (%call tools "retract" "cite" cite)
        (is (not (st:claim-current-p
                  (first (mem:recall w +subj+ :include-retracted t))))
            "W's copy is retracted")
        (is (st:claim-current-p (first (mem:recall p +subj+)))
            "P's copy is untouched"))
      (let* ((scope (agent:make-scope (list p w) :write-store w
                                      :producer +p+))
             (tools (agent:make-memory-tools scope)))
        (%call tools "recall" "subject-namespace" "repo"
               "subject-key" "cl-llm")
        (signals llm:llm-tool-error
          (%call tools "retract" "cite" cite)
          "control: P resolves first and is not writable")))))

(test make-scope-refuses-what-check-scope-refuses
  "S6b SS3: MAKE-SCOPE delegates the store-list checks; a repeated
store is a SCOPE-ERROR whose message names it."
  (with-stores (w p)
    (signals agent:scope-error
      (agent:make-scope (list w w) :producer +p+))
    (handler-case (agent:make-scope (list w w) :producer +p+)
      (agent:scope-error (c)
        (is (search "appears twice" (princ-to-string c)))))
    (is (agent:make-scope (list w p) :producer +p+) "control")))
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run the one-test command for `resolve-cite-answers-from-the-first-store-in-scope`. Expected: FAIL — `:SCOPE` is not a valid keyword to `RESOLVE-CITE`.

- [ ] **Step 3: Implement**

In `memory/cite.lisp`, replace `resolve-cite` with:

```lisp
(defun resolve-cite (graph cite at &key (scope (list graph)))
  "CITE as of AT (SS5), in the first store of SCOPE holding its identity
(S6b SS6): find the claim by identity among the subject's claims, then
ask that store for the version believed at AT.  Never substitutes the
current version -- it is consulted only for CHANGED-SINCE, which is
computed inside the resolving store.  STORE is filled on a resolved or
reaped record, NIL on an absent one.  A claim from a family with no
validity extent can only report CHANGED-SINCE :RETRACTED, :UPDATED or
NIL -- :SUPERSEDED needs %OPEN-P, which such a claim never satisfies.
Takes no snapshot of its own; TRACE, its caller, does."
  (check-scope scope)
  (multiple-value-bind (family ns key ikey) (split-cite cite)
    (let* ((current nil)
           (g (or (find-if (lambda (s)
                             (setf current
                                   (%current-among
                                    ikey (st:claims-touching s family ns key
                                                             :role :subject))))
                           scope)
                  graph))
           (id (and current (gdb:id current)))
           (then (and id
                      (find-if (lambda (c)
                                 (equalp id (if (st:reaped-claim-p c)
                                                (st:reaped-claim-id c)
                                                (gdb:id c))))
                               (st:claims-touching g family ns key
                                                   :role :subject
                                                   :as-of at)))))
      (cond ((null then)
             (make-cite-record :cite cite :family family :state :absent))
            ((st:reaped-claim-p then)
             (make-cite-record :cite cite :family family :state :reaped
                               :store (store-name g)))
            (t
             (make-cite-record :cite cite :family family :state :resolved
                               :claim then
                               :standing (st:claim-standing then)
                               :extent (st:claim-extent then)
                               :changed-since
                               (%changed-since then current)
                               :store (store-name g)))))))
```

In `agent/scope.lisp`, replace `note-cite` with:

```lisp
(defun note-cite (scope cite graph)
  "Remember GRAPH as the store CITE was returned from -- first wins, so
the cache agrees with CITE-STORE's first-in-scope scan whatever order
the tools ran in (S6b SS6, #48)."
  (unless (nth-value 1 (gethash cite (scope-cites scope)))
    (setf (gethash cite (scope-cites scope)) graph)))
```

and replace the first two checks of `make-scope` (the `unless ... %graph-p` form and the `let ((write ...)) (unless (member write stores) ...)` check) so the function reads:

```lisp
(defun make-scope (stores &key write-store producer sources
                                (k 5) (max-rows 50))
  (let ((write (or write-store (first (and (consp stores) stores)))))
    ;; The store-list checks live in the memory layer (S6b SS3); the
    ;; message is re-signalled as the model-readable SCOPE-ERROR.
    (handler-case (mem:check-scope stores :write-store write)
      (mem:scope-argument-error (c)
        (%scope-error "~a" (princ-to-string c))))
    (unless (st:canonical-producer-p producer)
      (%scope-error "PRODUCER is required: a canonical string ~
                     \"<agent>/<host>\""))
    (unless (and (integerp k) (plusp k))
      (%scope-error "K must be a positive integer, not ~s" k))
    (unless (and (integerp max-rows) (plusp max-rows))
      (%scope-error "MAX-ROWS must be a positive integer, not ~s"
                    max-rows))
    (%make-scope :stores stores :write-store write :producer producer
                 :sources sources :k k :max-rows max-rows)))
```

Delete `%graph-p` from `agent/scope.lisp` if nothing else in `agent/` uses it (`grep -n "%graph-p" agent/*.lisp`); keep it otherwise.

- [ ] **Step 4: Run the tests, then both suites**

Run the one-test command for the three new tests and for the existing `retract-acts-on-the-write-store-only` and `trace-names-the-store-the-decision-resolved-against`. Expected: all PASS. Run the memory and agent suites. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add memory/cite.lisp agent/scope.lisp tests-memory/scope-tests.lisp \
        tests-agent/memory-tools-tests.lisp
git commit -m "feat(memory): cites resolve first-in-scope; the agent cache never overwrites (#48, #24)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 4: Decisions across the scope, evidence pairs, retrieval ids, and the epoch (#47, #51, #49)

**Files:**
- Modify: `memory/trace.lisp` (`decision`, `decision-record`, `%write-evidence`, `%write-refusal`, `conclude`'s transaction return, `decisions-citing`, `trace`, `trace-listing`)
- Modify: `memory/packages.lisp` (exports)
- Modify: `agent/memory-tools.lisp` (`%find-decision` deleted; `%trace-tool`, `%decisions-citing-tool`, `%decision-json`)
- Modify: `agent/annotate.lisp:48-55` (`%newest-decision-by`)
- Modify: `claims/source.lisp:101,114-124,166` (`%claim-doc-id`)
- Modify: `tests-memory/store-tests.lisp:119-120`, `tests-memory/trace-tests.lisp:352-355`, `tests-agent/loop-tests.lisp:63-64` (the pairs return shape)
- Modify: `tests-memory/scope-tests.lisp`, `tests-agent/memory-tools-tests.lisp`, `tests-agent/annotate-tests.lisp`, `tests-claims/source-tests.lisp` (append)

**Interfaces:**
- Consumes: `check-scope`, `with-scope-snapshots`; `st:claim-commit-epoch` (engine #347); `graph-db::transaction-id` (internal).
- Produces: `decisions-citing => ((id . store-name) ...)`; `trace` finding the decision first-in-scope, `decision-record-store` (string) and `decision-record-epoch` (integer or NIL); `decision-epoch`; `trace-listing` emitting `(:missing nil nil nil nil)` for an unknown id; `%claim-doc-id (source claim)`; JSON `"epoch"` on `conclude` results and `"store"` on `decisions-citing` entries.

- [ ] **Step 1: Write the failing tests**

Append to `tests-memory/scope-tests.lisp`:

```lisp
(test decisions-citing-names-the-store-and-trace-finds-it-in-scope
  "SS7 (#47): a decision recorded in P is found through a scope whose
first store is W: DECISIONS-CITING returns (id . store-name) and TRACE
resolves it, naming its store; TRACE-LISTING gives a :MISSING row for an
id no store holds instead of signalling."
  (with-two-stores (w p)
    (let* ((e (%belief-in p "ci-status" '(:verdict . "green")))
           (d (mem:conclude p (list :belief +ss+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e) :rule "r"
                            :scope (list p))))
      (is (equal (list (cons (mem:decision-id d) "memory-private"))
                 (mem:decisions-citing w e :scope (list w p))))
      (let ((rec (mem:trace w (mem:decision-id d) :scope (list w p))))
        (is (not (null rec)))
        (is (string= "memory-private" (mem:decision-record-store rec)))
        (is (eq :concluded (mem:decision-record-outcome rec))))
      (is (null (mem:trace w (mem:decision-id d)))
          "control: W alone does not hold it")
      (is (equal '((:missing nil nil nil nil))
                 (mem:trace-listing w (list "no-such-id")
                                    :scope (list w p)))))))

(test write-evidence-keeps-one-cite-from-two-stores-as-two-rows
  "SS7 (#51): the same cite held by both stores, cited from both, gives
two evidence rows, each with its store as METHOD."
  (with-two-stores (w p)
    (let* ((cw (%belief-in w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite cw)))
      (%belief-in p "ci-status" '(:verdict . "green"))
      (let* ((d (mem:conclude w (list :belief +ss+ "releasable"
                                      '(:v . "yes") :standing :inferred)
                              :producer +p+
                              :evidence (list (cons cite "cl-llm-memory")
                                              (cons cite "memory-private"))
                              :rule "r" :scope (list w p)))
             (rec (mem:trace w (mem:decision-id d) :scope (list w p)))
             (ev (mem:decision-record-evidence rec)))
        (is (= 2 (length ev)))
        (is (equal '("cl-llm-memory" "memory-private")
                   (sort (mapcar #'mem:cite-record-store ev) #'string<)))
        (is (= 1 (length (mem:decision-record-evidence
                          (mem:trace w (mem:decision-id
                                        (mem:conclude
                                         w (list :belief +ss+ "other"
                                                 '(:v . "1")
                                                 :standing :inferred)
                                         :producer +p+
                                         :evidence (list cite cite)
                                         :rule "r"))))))
            "control: the same cite in the same store is still one row")))))

(test decisions-record-their-commit-epoch
  "SS7: two conclusions on two stores under one clock record integer
epochs in increasing order, and TRACE reads the same number back; a
refusal records one too."
  (with-two-stores (w p)
    (let* ((d1 (mem:conclude w (list :belief +ss+ "a" '(:v . "1")
                                     :standing :inferred
                                     :extent (%open-from
                                              (%ts "2026-09-01T08:00:00Z")))
                             :producer +p+ :rule "r"))
           (d2 (mem:conclude p (list :belief +ss+ "b" '(:v . "1")
                                     :standing :inferred)
                             :producer +p+ :rule "r"))
           ;; The validator path: retract, then re-assert the identical
           ;; fact at the same valid-from -- the unique family refuses
           ;; (as trace-tests' a-refused-proposal-is-recorded-and-writes-
           ;; no-belief does).
           (start (%open-from (%ts "2026-09-01T08:00:00Z")))
           (d3 (progn (mem:retract-belief (mem:decision-claim d1))
                      (mem:conclude w (list :belief +ss+ "a" '(:v . "1")
                                            :standing :inferred
                                            :extent start)
                                    :producer +p+ :rule "r"))))
      (is (integerp (mem:decision-epoch d1)))
      (is (< (mem:decision-epoch d1) (mem:decision-epoch d2)))
      (is (= (mem:decision-epoch d1)
             (mem:decision-record-epoch (mem:trace w (mem:decision-id d1)))))
      (is (= (mem:decision-epoch d2)
             (mem:decision-record-epoch
              (mem:trace w (mem:decision-id d2) :scope (list w p)))))
      (is (eq :refused (mem:decision-outcome d3)) "control: refused path")
      (is (integerp (mem:decision-epoch d3))))))
```

In `tests-memory/store-tests.lisp`, change line 119–120

```lisp
      (is (equal (list (mem:decision-id d))
                 (mem:decisions-citing b private :scope (list a b))))
```

to

```lisp
      (is (equal (list (cons (mem:decision-id d) "cl-llm-memory"))
                 (mem:decisions-citing b private :scope (list a b))))
```

In `tests-memory/trace-tests.lisp`, change lines 352–355

```lisp
      (is (equal (list (mem:decision-id d2) (mem:decision-id d1))
                 (mem:decisions-citing g e)))
      (is (equal (mem:decisions-citing g e)
                 (mem:decisions-citing g (mem:claim-cite e))))
```

to

```lisp
      (is (equal (list (mem:decision-id d2) (mem:decision-id d1))
                 (mapcar #'car (mem:decisions-citing g e))))
      (is (equal (mem:decisions-citing g e)
                 (mem:decisions-citing g (mem:claim-cite e))))
```

In `tests-agent/loop-tests.lisp`, change line 64 `(rec (mem:trace w (first ids) :scope (list w p))))` to `(rec (mem:trace w (car (first ids)) :scope (list w p))))`.

Append to `tests-agent/memory-tools-tests.lisp`:

```lisp
(test decisions-citing-tool-carries-the-store-and-trace-tool-finds-it
  "S6b SS7 (#47): a decision held only by P is listed with its store
and traced through the scope; the conclude result carries an epoch."
  (with-stores (w p)
    (let* ((e (%belief p "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite e))
           (d (mem:conclude p (list :belief +subj+ "releasable"
                                    '(:v . "yes") :standing :inferred)
                            :producer +p+ :evidence (list e) :rule "r"))
           (tools (agent:make-agent-tools (list w p) :producer +p+))
           (listed (coerce (json:jget (%call tools "decisions-citing"
                                             "cite" cite)
                                      "decisions")
                           'list))
           (traced (%call tools "trace" "decision-id" (mem:decision-id d))))
      (is (= 1 (length listed)))
      (is (string= "memory-private" (json:jget (first listed) "store")))
      (is (string= "memory-private" (json:jget traced "store")))
      (is (string= "concluded" (json:jget traced "outcome")))
      (is (integerp (json:jget traced "epoch")))
      (let ((out (%call tools "conclude"
                        "subject-namespace" "repo" "subject-key" "cl-llm"
                        "relation" "shippable" "object-namespace" "v"
                        "object-key" "yes" "rule" "r"
                        "evidence" (vector cite))))
        (is (integerp (json:jget out "epoch")))))))
```

Append to `tests-agent/annotate-tests.lisp`:

```lisp
(test annotate-banners-survives-a-decision-held-by-the-other-store
  "S6b (#47): the banner dir captured into BOTH stores mints one cite
per banner in each; a decision citing one lands in P.  A declining run
over (W P) then meets P's decision id through DECISIONS-CITING and must
return the declined shape, not signal on a TRACE that W cannot answer."
  (with-stores (w p)
    (mem:capture-memory-dir w (%banner-dir) :producer "capture/test")
    (mem:capture-memory-dir p (%banner-dir) :producer "capture/test")
    (let ((cite (%annotates-cite-for p "correction" 1)))
      (is (mem:cite-p cite) "control: P holds the banner's cite")
      (mem:conclude p (list :belief '(:memory-note . "correction")
                            "annotated" '(:verdict . "yes")
                            :standing :inferred)
                    :producer "claude-code/agent" :evidence (list cite)
                    :rule "annotate"))
    (let* ((provider (llm:make-mock-provider
                      :responder (lambda (c) (declare (ignore c)) "no")))
           (results (agent:annotate-banners (list w p) (%banner-dir)
                                            :provider provider
                                            :producer "claude-code/agent")))
      (is (= 5 (length results)))
      (is (every (lambda (r) (null (cdr r))) results)))))
```

(If `(%annotates-cite-for p "correction" 1)` returns NIL, the banner is not at position 1: look at the fixture file under `tests-memory/fixtures/banners/` for the first prose banner's name and position and use those.)

Append to `tests-claims/source-tests.lisp`, after the `probe-claim` declaration at the top add a second family on its own graph name:

```lisp
(st:def-claim-classes probe-claim-2 :cl-llm-claims-test-2)
```

and at the end of the file:

```lisp
(test copies-in-two-stores-carry-two-document-ids
  "S6b (#49): the claim document id carries the store, so one fact held
by two stores is two RRF identities, not one fused item.  The control:
the two items' TEXTs are equal, so only the id can separate them."
  (with-claims-graph (g)
    (let* ((dir (format nil "/tmp/cl-llm-claims-test2-~a-~a/"
                        (get-internal-real-time) (random 1000000)))
           (g2 (gdb:make-graph :cl-llm-claims-test-2 dir
                               :buffer-pool-size 1000)))
      (unwind-protect
           (progn
             (%seed g)
             (gdb:with-transaction ((graph-db::transaction-manager g2))
               (make-probe-claim-2-binary
                :graph g2
                :subject-namespace :device :subject-key "d42"
                :relation "feeds"
                :object-namespace :sensor :object-key "s1"
                :producer "rule-a" :standing :observed))
             (let* ((s1 (claims:make-claim-source
                         g 'probe-claim (%extract-devices "d42")))
                    (s2 (claims:make-claim-source
                         g2 'probe-claim-2 (%extract-devices "d42")))
                    (e1 (first (rag:collect-evidence s1 "d42")))
                    (e2 (first (rag:collect-evidence s2 "d42")))
                    (id1 (rag:chunk-document-id (rag:evidence-chunk e1)))
                    (id2 (rag:chunk-document-id (rag:evidence-chunk e2))))
               (is (string= (rag:chunk-text (rag:evidence-chunk e1))
                            (rag:chunk-text (rag:evidence-chunk e2)))
                   "control: same text")
               (is (not (string= id1 id2)))
               (is (eql 0 (search "claim:cl-llm-claims-test:" id1)))
               (is (eql 0 (search "claim:cl-llm-claims-test-2:" id2)))))
        (ignore-errors (gdb:close-graph g2))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname dir) :validate t
                        :if-does-not-exist :ignore))))))
```

(`chunk-document-id` is used unqualified in `rag/hybrid.lisp`; if it is not exported from `cl-llm.rag`, write `rag::chunk-document-id` and say so in your report.)

- [ ] **Step 2: Run one new test to verify it fails**

Run the one-test command for `decisions-citing-names-the-store-and-trace-finds-it-in-scope`. Expected: FAIL on the first `equal` (bare ids, not pairs) or on `:SCOPE` being rejected by `CONCLUDE`.

- [ ] **Step 3: Implement the memory layer**

In `memory/trace.lisp`:

Replace the `decision` defstruct with:

```lisp
(defstruct decision
  "What CONCLUDE returns (SS4).  OUTCOME is :CONCLUDED or :REFUSED; CLAIM
the belief or absence written (NIL when refused); REPORT the
VALIDATION-REPORT, the commit condition, or a (:SCOPE-CONFLICT cite
store) list (NIL when concluded); AT the outcome claim's RECORDED-AT;
EPOCH the committing transaction's id -- the shared clock's epoch when
the store is attached to one (S6b SS7)."
  id outcome claim report at epoch)
```

Replace the `decision-record` defstruct with:

```lisp
(defstruct decision-record
  "TRACE's answer (SS5).  CONCLUSION is a CITE-RECORD or NIL; EVIDENCE a
list of CITE-RECORDs in cite order then store; REFUSALS (family . text)
in family order.  STORE names the store the decision was found in;
EPOCH is the outcome claim's commit epoch, NIL for a claim written
before the engine stamped one (S6b SS7)."
  id producer at rule rule-version confidence outcome
  conclusion evidence refusals store epoch)
```

Replace `%write-evidence` with:

```lisp
(defun %write-evidence (graph id pairs producer)
  ;; The key is the whole (cite . store) pair: one cite held by two
  ;; stores is two evidence rows (S6b SS7, #51).  :FROM-END T keeps the
  ;; first of an exact repeat.
  (dolist (pair (remove-duplicates pairs :test #'equal :from-end t))
    (%trace-claim graph id "evidence" :claim (car pair) producer :observed
                  :method (cdr pair))))
```

Replace `%write-refusal` with:

```lisp
(defun %write-refusal (graph id report pairs producer rule rule-version)
  "A fresh transaction recording the refusal (SS4 step 2/3): one REFUSED
claim per violated family, and one ATTEMPTED claim naming the rule the
agent was applying, with CONCLUDED's slots, so a refused decision still
says under which rule (#35).  The transaction's id is the decision's
epoch (S6b SS7)."
  (let* ((outcome nil)
         (tx (gdb:with-transaction (:graph graph)
               (%trace-claim graph id "attempted" :rule rule producer
                             :observed :method rule
                             :rule-version rule-version)
               (dolist (row (%violation-families report))
                 (setf outcome
                       (%trace-claim graph id "refused" :violation (car row)
                                     producer :observed :method (cdr row))))
               (%write-evidence graph id pairs producer)
               gdb:*transaction*)))
    (make-decision :id id :outcome :refused :report report
                   :at (st:claim-recorded-at outcome)
                   ;; TRANSACTION-ID is internal to the engine (recon C10).
                   :epoch (graph-db::transaction-id tx))))
```

In `conclude`, change the `progn` of the `handler-case` so the transaction's value is kept:

```lisp
        (let ((tx (gdb:with-transaction (:graph graph)
                    (setf claim (%stage graph proposal producer rule
                                        rule-version confidence))
                    (let ((report (gdb:validate-transaction graph)))
                      (when (gdb:validation-report-violations report)
                        (error '%refused :report report)))
                    (setf outcome
                          (%trace-claim graph id "concluded" :claim
                                        (claim-cite claim) producer
                                        :inferred :method rule
                                        :rule-version rule-version
                                        :confidence confidence))
                    (%write-evidence graph id pairs producer)
                    gdb:*transaction*)))
          (make-decision :id id :outcome :concluded :claim claim
                         :at (st:claim-recorded-at outcome)
                         :epoch (graph-db::transaction-id tx)))
```

(`conclude`'s `:scope` keyword and pre-read are Task 5; this task only threads the epoch. If a test in this task passes `:scope` to `conclude` before Task 5 exists, add the keyword now as `(scope (list graph))` with a `(check-scope scope :write-store graph)` at the top and no other use; Task 5 fills it in.)

Replace `decisions-citing` with:

```lisp
(defun decisions-citing (graph claim-or-cite &key (scope (list graph)))
  "(id . store-name) per decision whose EVIDENCE cites CLAIM-OR-CITE,
RECORDED-AT descending then id (SS5), unioned over every store in SCOPE
under its snapshots (S6b SS7).  NIL means no decisions cite it."
  (check-scope scope)
  (let ((cite (%cite-of claim-or-cite)))
    (with-scope-snapshots (scope)
      (let ((rows (loop for g in scope
                        append (mapcar
                                (lambda (c)
                                  (list (%recorded-instant c)
                                        (st:claim-subject-key c)
                                        (store-name g)))
                                (st:claims-touching
                                 g 'trace :claim cite :role :object
                                 :relation "evidence")))))
        (mapcar (lambda (r) (cons (second r) (third r)))
                (sort rows
                      (lambda (a b)
                        (or (local-time:timestamp> (first a) (first b))
                            (and (local-time:timestamp= (first a)
                                                        (first b))
                                 (string< (second a) (second b)))))))))))
```

In `trace`, replace the opening `let*` binding of `claims` and the record construction so the function reads:

```lisp
(defun trace (graph decision-id &key (scope (list graph)))
  "The decision DECISION-ID reconstructed as of its own instant (SS5),
found in the first store of SCOPE holding it, or NIL when no store
does.  Each evidence cite resolves in the store it names, when that
store is in SCOPE (SS4.3).  Runs under the scope's snapshots (S6b)."
  (check-scope scope)
  (with-scope-snapshots (scope)
    (let* ((g (find-if (lambda (s) (%decision-claims s decision-id))
                       scope))
           (claims (and g (%decision-claims g decision-id)))
           (outcome (find-if (lambda (c)
                               (member (st:claim-relation c)
                                       '("concluded" "refused")
                                       :test #'string=))
                             claims)))
      (when outcome
        (let* (
```

and keep the rest of the existing body, with these three edits inside it: every `graph` in the `%resolve-in` calls becomes `g`; the `evidence` sort becomes `(sort ... (lambda (a b) (or (string< (car a) (car b)) (and (string= (car a) (car b)) (string< (or (cdr a) "") (or (cdr b) ""))))))` so one cite from two stores orders by store; and `make-decision-record` gains `:store (store-name g)` and `:epoch (st:claim-commit-epoch outcome)`. Close the extra `with-scope-snapshots` paren at the end.

Replace `trace-listing` with:

```lisp
(defun trace-listing (graph decision-ids &key (scope (list graph)))
  "The deterministic shape capture-and-diff compares (SS7): one row per
id, in the given order, with no id or timestamp in it.  SCOPE resolves
cross-store evidence as TRACE does (#34); an id no store in SCOPE holds
is a (:MISSING NIL NIL NIL NIL) row, never a signal (S6b, #47)."
  (loop for id in decision-ids
        for rec = (trace graph id :scope scope)
        collect (if (null rec)
                    (list :missing nil nil nil nil)
                    (list (decision-record-outcome rec)
                          (decision-record-rule rec)
                          (let ((c (decision-record-conclusion rec)))
                            (and c (cite-record-cite c)))
                          (mapcar (lambda (r)
                                    (list (cite-record-cite r)
                                          (cite-record-state r)
                                          (cite-record-changed-since r)))
                                  (decision-record-evidence rec))
                          (mapcar #'car (decision-record-refusals rec))))))
```

In `memory/packages.lisp`, add `#:decision-epoch` after `#:decision-at` and `#:decision-record-store #:decision-record-epoch` after `#:decision-record-refusals`.

- [ ] **Step 4: Implement the agent and claims layers**

In `agent/memory-tools.lisp`: delete `%find-decision`. Replace `%trace-tool`'s lambda body with:

```lisp
   (lambda (decision-id)
     ;; No NOTE-CITE here: each record already carries the store
     ;; MEM:TRACE resolved it against, and seeding the cache from a
     ;; trace would make a later CONCLUDE charge the evidence to
     ;; whichever store the cache saw (#14 unit 2 final review).
     (let ((rec (mem:trace (scope-write-store scope) decision-id
                           :scope (scope-stores scope))))
       (unless rec (error "no decision ~a in scope" decision-id))
       (json:to-json
        (json:jobject
         "id" decision-id
         "store" (mem:decision-record-store rec)
         "epoch" (mem:decision-record-epoch rec)
         "producer" (mem:decision-record-producer rec)
         "at" (%iso (mem:decision-record-at rec))
         "rule" (mem:decision-record-rule rec)
         "rule-version" (mem:decision-record-rule-version rec)
         "confidence" (mem:decision-record-confidence rec)
         "outcome" (%standing (mem:decision-record-outcome rec))
         "conclusion" (let ((c (mem:decision-record-conclusion rec)))
                        (and c (%cite-record-json c)))
         "evidence" (map 'vector #'%cite-record-json
                         (mem:decision-record-evidence rec))
         "refusals" (map 'vector
                         (lambda (f) (json:jobject "family" (car f)
                                                   "text" (cdr f)))
                         (mem:decision-record-refusals rec))))))
```

Replace `%decisions-citing-tool`'s lambda body with:

```lisp
   (lambda (cite)
     ;; MEM:DECISIONS-CITING unions SCOPE, orders newest first with an
     ;; id tiebreak (SS5), and names each decision's store (S6b SS7).
     (let ((pairs (mem:decisions-citing (scope-write-store scope) cite
                                        :scope (scope-stores scope))))
       (json:to-json
        (json:jobject
         "decisions"
         (map 'vector
              (lambda (pair)
                (json:jobject "id" (car pair) "store" (cdr pair)))
              pairs)))))
```

In `%decision-json`, add `"epoch" (mem:decision-epoch d)` after the `"store"` line.

In `agent/annotate.lisp`, replace `%newest-decision-by` with:

```lisp
(defun %newest-decision-by (graph cite producer scope since)
  "The newest decision citing CITE that PRODUCER made at or after SINCE,
in any store of SCOPE (S6b, #47)."
  (loop for (id . nil) in (mem:decisions-citing graph cite :scope scope)
        for rec = (mem:trace graph id :scope scope)
        when (and rec
                  (string= producer (mem:decision-record-producer rec))
                  (not (local-time:timestamp< (mem:decision-record-at rec)
                                              since)))
          return id))
```

In `claims/source.lisp`, replace `%claim-doc-id` with:

```lisp
(defun %claim-doc-id (source claim)
  "The fusion identity: RRF keys on (DOCUMENT-ID . TEXT), so one claim
reached through two queried endpoints must carry one id -- and copies
of one claim in two stores must carry two (S6b, #49).  The store is
the graph's name downcased, as %ABSENCE-EVIDENCE writes it; this system
cannot see the memory tenant's STORE-NAME (recon C7)."
  (format nil "claim:~(~a~):~a:~(~a~)~@[:~a~]:~(~a~)"
          (graph-db:graph-name (claim-source-graph source))
          (%endpoint (st:claim-subject-namespace claim)
                     (st:claim-subject-key claim))
          (st:claim-relation claim)
          (and (%binary-p claim)
               (%endpoint (st:claim-object-namespace claim)
                          (st:claim-object-key claim)))
          (st:claim-producer claim)))
```

and change both callers: `:document-id (%claim-doc-id claim)` to `:document-id (%claim-doc-id source claim)` and `(let ((id (%claim-doc-id claim)))` to `(let ((id (%claim-doc-id source claim)))`.

- [ ] **Step 5: Run the tests, then the three suites**

Run the one-test command for each new test and for the three edited existing tests: `trace-resolves-a-cross-store-cite-within-its-scope` (store-tests), `decisions-citing-finds-the-conclusions-resting-on-a-belief` (trace-tests), and the loop test in `tests-agent/loop-tests.lisp` whose body binds `seen-cite` (read its name). Expected: all PASS. Run the memory, agent and claims suites. Expected: green; `tests-memory/golden/trace.sexp` unchanged.

- [ ] **Step 6: Commit**

```bash
git add memory/trace.lisp memory/packages.lisp agent/memory-tools.lisp \
        agent/annotate.lisp claims/source.lisp tests-memory/scope-tests.lisp \
        tests-memory/store-tests.lisp tests-memory/trace-tests.lisp \
        tests-agent/loop-tests.lisp tests-agent/memory-tools-tests.lisp \
        tests-agent/annotate-tests.lisp tests-claims/source-tests.lisp
git commit -m "feat(memory): decisions found and cited with their store; evidence keyed by store; commit epoch recorded (#47, #51, #49, #24)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 5: `conclude` with a scope: the trust rule at the boundary (#50)

**Files:**
- Modify: `memory/trace.lisp` (`%violation-families`, new `%governing-prior` and `%scope-conflict-report`, `conclude`)
- Modify: `agent/memory-tools.lisp` (`%conclude-tool`, `%conclude-absence-tool`: pass the scope)
- Modify: `tests-memory/scope-tests.lisp`, `tests-agent/memory-tools-tests.lisp` (append)

**Interfaces:**
- Consumes: `check-scope`, `with-scope-snapshots`, `%series`, `%open-p`, `%start-instant`, `%write-refusal` (Task 4 shape), `%write-evidence`.
- Produces: `conclude (graph proposal &key producer evidence rule rule-version confidence (scope (list graph)))`; the refusal family `"scope-conflict"`; `decision-report` = `(:scope-conflict cite store-name)` on that path.

- [ ] **Step 1: Write the failing tests**

Append to `tests-memory/scope-tests.lisp`:

```lisp
(defun %families (g id)
  (mapcar #'car (mem:decision-record-refusals (mem:trace g id))))

(test conclude-refuses-a-belief-governed-by-a-higher-trust-store
  "SS5 (#50): scope (P W), write store W.  P holds the governing prior
of the proposal's series; the proposal is refused with the
SCOPE-CONFLICT family naming P's cite and store, nothing is written to
either store, and the decision's report is the (:SCOPE-CONFLICT ...)
list.  The control: the same proposal with P absent from the scope
concludes."
  (with-two-stores (w p)
    (let* ((prior (%belief-in p "ci-status" '(:verdict . "green")))
           (before-w (length (st:claims-by-producer w 'mem:belief +p+)))
           (before-p (length (st:claims-by-producer p 'mem:belief +p+)))
           (d (mem:conclude w (list :belief +ss+ "ci-status"
                                    '(:verdict . "red") :standing :inferred
                                    :extent (%open-from
                                             (%ts "2026-09-02T08:00:00Z")))
                            :producer +p+ :rule "r" :scope (list p w))))
      (is (eq :refused (mem:decision-outcome d)))
      (is (null (mem:decision-claim d)))
      (is (equal (list :scope-conflict (mem:claim-cite prior)
                       "memory-private")
                 (mem:decision-report d)))
      (is (equal '("scope-conflict") (%families w (mem:decision-id d))))
      (let ((text (cdr (first (mem:decision-record-refusals
                               (mem:trace w (mem:decision-id d)))))))
        (is (search (mem:claim-cite prior) text))
        (is (search "memory-private" text))
        (is (not (search "(:" text)) "prose, not a Lisp form"))
      (is (= before-w (length (st:claims-by-producer w 'mem:belief +p+))))
      (is (= before-p (length (st:claims-by-producer p 'mem:belief +p+))))
      (is (eq :concluded
              (mem:decision-outcome
               (mem:conclude w (list :belief +ss+ "ci-status"
                                     '(:verdict . "red")
                                     :standing :inferred
                                     :extent (%open-from
                                              (%ts "2026-09-02T08:00:00Z")))
                             :producer +p+ :rule "r" :scope (list w))))
          "control: without P in scope the write proceeds"))))

(test conclude-overrides-a-lower-trust-prior-and-records-it-as-evidence
  "SS5 (#50): scope (W P), write store W.  P holds the prior; W's newer
belief is concluded, supersedes P's at read time, and the trace carries
the overridden cite with P's name as its store.  A prior in the write
store itself still goes to the validator (the control)."
  (with-two-stores (w p)
    (let* ((prior (%belief-in p "ci-status" '(:verdict . "green")))
           (d (mem:conclude w (list :belief +ss+ "ci-status"
                                    '(:verdict . "red") :standing :inferred
                                    :extent (%open-from
                                             (%ts "2026-09-02T08:00:00Z")))
                            :producer +p+ :rule "r" :scope (list w p)))
           (rec (mem:trace w (mem:decision-id d) :scope (list w p)))
           (ev (mem:decision-record-evidence rec)))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (= 1 (length ev)))
      (is (string= (mem:claim-cite prior) (mem:cite-record-cite (first ev))))
      (is (string= "memory-private" (mem:cite-record-store (first ev))))
      (let ((rows (mem:recall w +ss+ :scope (list w p))))
        (is (not (mem:belief-record-current-p (%row rows "green"))))
        (is (mem:belief-record-current-p (%row rows "red"))))
      ;; Control: the validator path is untouched -- retract W's red,
      ;; re-assert the identical fact at the same valid-from, and the
      ;; unique family refuses, not scope-conflict.
      (mem:retract-belief (mem:decision-claim d))
      (let ((d2 (mem:conclude w (list :belief +ss+ "ci-status"
                                      '(:verdict . "red")
                                      :standing :inferred
                                      :extent (%open-from
                                               (%ts "2026-09-02T08:00:00Z")))
                              :producer +p+ :rule "r" :scope (list w p))))
        (is (eq :refused (mem:decision-outcome d2)))
        (is (not (member "scope-conflict"
                         (%families w (mem:decision-id d2))
                         :test #'string=)))))))

(test conclude-absence-takes-no-scope-pre-read
  "SS5 (recon C3): an absence has no series; the pre-read does not
apply and the write proceeds under any scope."
  (with-two-stores (w p)
    (%belief-in p "ci-status" '(:verdict . "green"))
    (let ((d (mem:conclude w (list :absence +ss+ "ci-status"
                                   :standing :searched-empty)
                           :producer +p+ :rule "r" :scope (list p w))))
      (is (eq :concluded (mem:decision-outcome d))))))
```

Append to `tests-agent/memory-tools-tests.lisp`:

```lisp
(test conclude-tool-refuses-a-higher-trust-conflict-by-name
  "S6b SS5 (#50): through the tool, scope (P W) write W, P's prior
governs: the result is a refusal whose refusals name the scope-conflict
family, the cite and the store."
  (with-stores (w p)
    (let* ((prior (%belief p "ci-status" '(:verdict . "green")))
           (tools (agent:make-agent-tools (list p w) :write-store w
                                          :producer +p+))
           (out (%call tools "conclude"
                       "subject-namespace" "repo" "subject-key" "cl-llm"
                       "relation" "ci-status" "object-namespace" "verdict"
                       "object-key" "red" "rule" "r"
                       "valid-from" "2026-09-02T08:00:00Z"))
           (refusals (coerce (json:jget out "refusals") 'list)))
      (is (string= "refused" (json:jget out "outcome")))
      (is (= 1 (length refusals)))
      (is (string= "scope-conflict" (json:jget (first refusals) "family")))
      (is (search (mem:claim-cite prior)
                  (json:jget (first refusals) "text")))
      (is (search "memory-private" (json:jget (first refusals) "text"))))))
```

- [ ] **Step 2: Run one new test to verify it fails**

Run the one-test command for `conclude-refuses-a-belief-governed-by-a-higher-trust-store`. Expected: FAIL — the decision is `:concluded`, or `:SCOPE` is rejected.

- [ ] **Step 3: Implement**

In `memory/trace.lisp`, replace `%violation-families` with:

```lisp
(defun %violation-families (report-or-condition)
  "(family . text) per violation, first per family, in family order.
A (:SCOPE-CONFLICT cite store) report is one SCOPE-CONFLICT row whose
text is prose, never a printed form (S6b SS5, recon C2)."
  (let ((rows (cond ((typep report-or-condition 'gdb:validation-report)
                     (loop for (family nil detail)
                             in (gdb:validation-report-violations
                                 report-or-condition)
                           collect (cons (string-downcase
                                          (symbol-name family))
                                         (princ-to-string detail))))
                    ((and (consp report-or-condition)
                          (eq :scope-conflict (first report-or-condition)))
                     (list (cons "scope-conflict"
                                 (format nil "~a in the higher-trust ~
                                              store ~a governs this ~
                                              series"
                                         (second report-or-condition)
                                         (third report-or-condition)))))
                    (t (list (cons "commit"
                                   (princ-to-string
                                    report-or-condition)))))))
    (sort (remove-duplicates rows :key #'car :test #'string= :from-end t)
          #'string< :key #'car)))
```

Add, before `conclude`:

```lisp
(defun %scope-conflict-report (cite store-name)
  (list :scope-conflict cite store-name))

(defun %proposal-start (more)
  "The validity start a (:BELIEF subject relation object . MORE) proposal
will be recorded with: its :EXTENT's, else now (RECORD-BELIEF's
default)."
  (let ((extent (getf (rest more) :extent)))
    (if extent
        (te:bound-earliest (te:extent-start extent))
        (local-time:now))))

(defun %governing-prior (proposal producer scope)
  "For a (:BELIEF ...) PROPOSAL, (values PRIOR STORE): the current open
binary claim of the same series, across SCOPE, whose validity start is
latest but not after the proposal's; the first store in scope order on
a tie.  NIL for an absence, which has no series (recon C3), and when no
prior governs.  Computed here, not by %CURRENT-PREDECESSOR, which is
unambiguous only inside one store.  Caller holds the snapshots."
  (destructuring-bind (kind subject relation &rest more) proposal
    (when (eq kind :belief)
      (let ((start (%proposal-start more))
            (best nil) (best-store nil))
        (dolist (g scope (values best best-store))
          (dolist (c (%series g producer subject relation))
            (when (and (typep c 'belief-binary)
                       (st:claim-current-p c)
                       (%open-p c)
                       (not (local-time:timestamp< start
                                                   (%start-instant c)))
                       (or (null best)
                           (local-time:timestamp< (%start-instant best)
                                                  (%start-instant c))))
              (setf best c best-store g))))))))
```

Replace `conclude` with:

```lisp
(defun conclude (graph proposal
                 &key producer evidence rule rule-version confidence
                      (scope (list graph)))
  "Decide PROPOSAL from EVIDENCE under RULE (SS4).  Owns its
transaction; signals BELIEF-ARGUMENT-ERROR when one is already open.
Returns a DECISION -- a refusal is RETURNED as one with :OUTCOME
:REFUSED and REPORT set, never signalled.  Under SCOPE (S6b SS5) a
belief governed by a prior in a higher-trust store is refused as
SCOPE-CONFLICT before the transaction opens; one in a lower-trust
store is overridden and recorded as evidence.  Advisory, like the
validation report: the commit is the enforcement."
  (when gdb:*transaction*
    (%arg-error :transaction gdb:*transaction*
                "CONCLUDE owns its transaction; call it outside one"))
  (check-scope scope :write-store graph)
  (%check-producer producer)
  (unless (stringp rule) (%arg-error :rule rule "a string naming the rule"))
  (%check-proposal proposal)
  (let ((id (%mint-id))
        (pairs (mapcar (lambda (e) (%evidence-of e (store-name graph)))
                       evidence))
        (claim nil) (outcome nil))
    (multiple-value-bind (prior store)
        (with-scope-snapshots (scope)
          (%governing-prior proposal producer scope))
      (when (and prior (not (eq store graph)))
        (if (< (position store scope) (position graph scope))
            (return-from conclude
              (%write-refusal graph id
                              (%scope-conflict-report (claim-cite prior)
                                                      (store-name store))
                              pairs producer rule rule-version))
            ;; Lower trust: overridden at read time (SS4); say so.
            (setf pairs (append pairs
                                (list (cons (claim-cite prior)
                                            (store-name store))))))))
    (handler-case
        (let ((tx (gdb:with-transaction (:graph graph)
                    (setf claim (%stage graph proposal producer rule
                                        rule-version confidence))
                    (let ((report (gdb:validate-transaction graph)))
                      (when (gdb:validation-report-violations report)
                        (error '%refused :report report)))
                    (setf outcome
                          (%trace-claim graph id "concluded" :claim
                                        (claim-cite claim) producer
                                        :inferred :method rule
                                        :rule-version rule-version
                                        :confidence confidence))
                    (%write-evidence graph id pairs producer)
                    gdb:*transaction*)))
          (make-decision :id id :outcome :concluded :claim claim
                         :at (st:claim-recorded-at outcome)
                         :epoch (graph-db::transaction-id tx)))
      (%refused (c)
        (%write-refusal graph id (%refused-report c) pairs producer
                        rule rule-version))
      (gdb:constraint-violation (c)
        ;; The report is advisory (SS2); the commit is the enforcement.
        (%write-refusal graph id c pairs producer rule rule-version)))))
```

In `agent/memory-tools.lisp`, in `%conclude-tool` and `%conclude-absence-tool`, add `:scope (scope-stores scope)` to their `mem:conclude` calls (read them; each calls `(mem:conclude (scope-write-store scope) ...)`).

- [ ] **Step 4: Run the tests, then both suites**

Run the one-test command for the four new tests and for the existing `retract-then-conclude-at-the-same-valid-from-is-refused` (memory suite; the validator-path control). Expected: all PASS. Run the memory and agent suites. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add memory/trace.lisp agent/memory-tools.lisp \
        tests-memory/scope-tests.lisp tests-agent/memory-tools-tests.lisp
git commit -m "feat(memory): conclude under a scope refuses a higher-trust conflict, overrides a lower one (#50, #24)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 6: The memory image's clock, the docs, and the suites

**Files:**
- Modify: `scripts/memory-image.lisp` (`start`, `stop`, the `*graph*` defvars)
- Modify: `docs/agent-memory.md`, `docs/agent-tools.md`

**Interfaces:**
- Consumes: `gdb:open-system-clock`, `gdb:close-system-clock`, `:system-clock` on `open-graph`/`make-graph`.
- Produces: an image whose store is always attached to one clock at `CL_LLM_MEMORY_CLOCK`.

- [ ] **Step 1: The image**

In `scripts/memory-image.lisp`, after the `*producer*` defvar add:

```lisp
(defvar *clock* nil
  "The image's system clock.  A property of the image, not of the store
on disk: a store reopened without it silently resumes its own counter
(S6b recon C1), so every open here passes it.")
```

In `start`, add a binding after `system`:

```lisp
         (clock-dir (%dir (%env "CL_LLM_MEMORY_CLOCK"
                                (%home ".cl-llm-memory/clock/"))))
```

and after `(setf gdb:*system-directory* system)` add `(setf *clock* (gdb:open-system-clock clock-dir))`; pass `:system-clock *clock*` to both the `open-graph` and the `make-graph` call; add `clock-dir` to the banner: `"~&memory image: ~(~S~) at ~A as ~A; clock ~A; swank 127.0.0.1:~D~%"` with `clock-dir` inserted before `port`.

Replace `stop` with:

```lisp
(defun stop ()
  "Close the store, then the clock; never signals.  Installed as an
exit hook because SBCL runs *EXIT-HOOKS* on SIGTERM (measured in sitrep
#25), so a stop from the shell or systemd leaves no .dirty marker."
  (when *graph*
    (ignore-errors (gdb:close-graph *graph*))
    (setf *graph* nil gdb:*graph* nil))
  (when *clock*
    (ignore-errors (gdb:close-system-clock *clock*))
    (setf *clock* nil)))
```

Verify the file still reads: run `sbcl --non-interactive --eval '(with-open-file (s "scripts/memory-image.lisp") (loop for form = (read s nil :eof) until (eq form :eof)))'` from the worktree (a read-only parse; the script must not be loaded, it starts a server). Expected: exits 0.

- [ ] **Step 2: The docs**

In `docs/agent-memory.md`, add a section `## Scopes` (after the section that describes stores, or at the end if none fits) with this content:

```markdown
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
`decision-record-store`.

**The clock belongs to the image.** A store attached to a system clock
draws its epochs from it; the attachment lives in memory and in the
clock's journal, not in the store, so a store reopened without the
clock silently resumes its own counter, continuing the same integers.
The memory image opens one clock (`CL_LLM_MEMORY_CLOCK`, default
`~/.cl-llm-memory/clock/`) before its stores, passes it on every open,
and closes it last. Every decision records its commit epoch
(`decision-epoch`, `decision-record-epoch`); the number is comparable
across stores only for decisions recorded under the shared clock. As-of
reads still use wall clock; they move to the epoch axis when
vivace-graph#347 is consumed.
```

In `docs/agent-tools.md`: where the `recall` result's fields are listed, change `"superseded-by"`'s description to "an object `{"cite", "store"}` naming the successor and the store it lives in, which may be another store in scope, or absent"; add that `"current"` is false when a claim is superseded anywhere in scope under the trust rule. Where `decisions-citing`'s result is described, add `"store"` on each entry. Where `trace`'s result is described, add `"epoch"` (integer, the commit epoch; null for a decision recorded before the engine stamped one). Where `conclude`'s result is described, add `"epoch"` and the `scope-conflict` refusal family with one sentence: "a belief governed by a prior in a higher-trust store is refused; the text names the cite and its store". In the limits list (around lines 496–498), replace the sentence that says cross-store recall is per store and merged with: "Recall, supersession and `current` are computed over the whole scope under the trust rule; as-of reads remain wall-clock until vivace-graph#347 is consumed."

- [ ] **Step 3: Run the three suites**

Memory, agent, claims, one at a time. Expected: green. Record the counts beside Task 1's baseline in your report.

- [ ] **Step 4: Commit**

```bash
git add scripts/memory-image.lisp docs/agent-memory.md docs/agent-tools.md
git commit -m "feat(image): one system clock for the memory image; document scopes, the trust rule and the epoch (#24)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

## After the tasks (controller)

1. Final whole-branch review on the most capable model; one fix wave; one scoped re-review.
2. Comment on cl-llm#24 with the delivery and the corrections; note on #46–#51 which commit fixes each. Kevin decides the push and the PR against `main`; the PR body says it needs vivace-graph `experiment` at or after the #347 merge.
