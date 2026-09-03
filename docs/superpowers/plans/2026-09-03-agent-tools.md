# Agent Tool Surface (S6a unit 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a language model a bounded, scoped tool surface over the
agent memory: recall, trace and decisions-citing across a scope of
stores; conclude, conclude-absence and retract into one writable store;
retrieve and plan-bounds over the planner; and a guarded free-text
Prolog query.

**Architecture:** `cl-llm/agent` builds closure tools from a `scope`
(readable stores, one write store, producer, caps) with a new core
`make-tool`; every result is a JSON string; every write goes through
unit 1's `conclude`; every error reaches the model through the existing
tool loop. `cl-llm/agent/prolog` is a separate optional system on
`graph-db/gui` with all internal engine symbols fenced in one function.
Three small amendments to `cl-llm/memory` (`define-memory-store`,
evidence records its store, `trace`/`decisions-citing` take a scope)
and one to `cl-llm/rag/claims` (the claim's identity key in chunk
metadata) come first.

**Tech Stack:** SBCL, ASDF, fiveam; cl-llm core (`deftool`, `call-tool`,
`make-mock-provider`, `cl-llm.json`), `cl-llm/memory`, `cl-llm/rag`,
`cl-llm/rag/claims`; vivace-graph `experiment` HEAD (`graph-db/core`,
`graph-db/spacetime`, and `graph-db/gui` for the query tool only);
local-time, cl-temporal-extent.

**Spec:** `docs/superpowers/specs/2026-09-03-agent-tools-design.md`
(§2 the scope model, §4 the amendments, §5–§9 the contract). Companion:
`docs/superpowers/specs/2026-09-02-decision-trace-design.md` (unit 1),
`docs/agent-memory.md`, `docs/evidence-bundle.md` §9–§10.

## Global Constraints

- **Lisp style:** spaces only, never tabs; **hard 80-column limit** on
  code, comments, docstrings and strings. A longer line is a defect.
  Comments are terse and point at the spec section or issue.
- **Dependencies:** `cl-llm/memory` stays on graph-db/spacetime,
  ironclad, babel. `cl-llm/agent` depends on `cl-llm`, `cl-llm/memory`,
  `cl-llm/rag/claims` and nothing else — **no web stack**.
  `cl-llm/agent/prolog` alone depends on `graph-db/gui`.
- **Internal engine symbols** are fenced in one function each, with the
  issue number beside them: `graph-db::resolve-node-graph` in
  `%claim-store` (memory); the GUI guard pipeline and
  `graph-db::run-query-goals` in `%guarded-rows` (agent/prolog,
  kraison/vivace-graph#322).
- **Engine:** vivace-graph `experiment` HEAD, unpinned. Locally
  `~/quicklisp/local-projects/graph-db.asd` symlinks to
  `~/work/vivace-graph-v3` (at or after `73ad4e2`; do not modify it).
  Run suites in a subprocess, never in a shared REPL image.
- **Every tool returns a JSON string** built with `json:jobject` /
  `json:jarray` / `json:to-json`. Booleans are `:true`/`:false`;
  timestamps are RFC 3339 UTC strings; standings are keyword names
  without the colon; store names are the graph name downcased.
- **Every bound and the scope are the operator's at construction.** A
  model argument above a cap is clamped and the result says
  `truncated`.
- **A refused decision is data** (`outcome` `"refused"`); every other
  failure signals and the tool loop turns it into an error result. Tool
  bodies catch nothing.
- **Order is the contract**; **absence is not a value**; negative tests
  carry a control assertion; every scripted-loop test asserts on the
  request body the model would have received.
- **Docs travel with the code:** the last task is the doc pass; no push
  before it. Commit trailer on every commit:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016XhUGNmKWzsBV8PftSVfVo
```

**Running tests.** Always as a subprocess. The full offline set, as CI
runs it:

```bash
cd ~/work/cl-llm
sbcl --dynamic-space-size 4096 --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" \
  --eval '(ql:quickload (list :cl-llm/tests :cl-llm/rag/tests :cl-llm/rag/claims/tests :cl-llm/memory/tests :cl-llm/agent/tests :cl-llm/agent/prolog/tests) :silent t)' \
  --eval '(asdf:test-system :cl-llm)' \
  --eval '(asdf:test-system :cl-llm/rag)' \
  --eval '(asdf:test-system :cl-llm/rag/claims)' \
  --eval '(asdf:test-system :cl-llm/memory)' \
  --eval '(asdf:test-system :cl-llm/agent)' \
  --eval '(asdf:test-system :cl-llm/agent/prolog)' 2>&1 | grep -E 'Did [0-9]+ checks|Pass:|Fail:'
```

One system: keep only its quickload and its `test-system`. One test:
`--eval '(unless (fiveam:run! (quote PACKAGE::TEST-NAME)) (sb-ext:exit :code 1))'`.
Baselines before this plan: core 408, rag 319, claims 18, memory 174.
A run that prints no `Did N checks` line ran nothing (`docs/ci.md`).

**Branch:** `feat/agent-tools` (exists; the spec is on it).

---

## File structure

| File | Responsibility |
|---|---|
| `src/tools.lisp` (modify) | `make-tool`; `deftool` expands to it |
| `rag/answer.lisp` (modify) | `make-retrieval-tool` on `make-tool` |
| `memory/schema.lisp` (modify) | `define-memory-store` macro; `:cl-llm-memory` declared through it |
| `memory/trace.lisp` (modify) | evidence records its store; `%claim-store`; `trace`/`decisions-citing` scope |
| `memory/recall.lisp` (modify) | export `claim-before-p` (the order rule) |
| `claims/source.lisp` (modify) | `:claim-key` in chunk metadata |
| `agent/packages.lisp` (create) | package, nicknames, exports |
| `agent/scope.lisp` (create) | `scope` struct, store naming and lookup, caps, the cite→store map |
| `agent/render.lisp` (create) | timestamps, standings, records and cite-records as JSON |
| `agent/memory-tools.lisp` (create) | recall, trace, decisions-citing, conclude, conclude-absence, retract |
| `agent/planner-tools.lisp` (create) | retrieve, plan-bounds |
| `agent/agent.lisp` (create) | `make-agent-tools` |
| `agent/prolog/packages.lisp`, `agent/prolog/query.lisp` (create) | `%guarded-rows`, `make-query-tool` |
| `cl-llm.asd` (modify) | four new systems |
| `tests/tools.lisp` (modify) | `make-tool` tests |
| `tests-memory/store-tests.lisp` (create) | unit 1 amendments |
| `tests-claims/source-tests.lisp` (modify) | `:claim-key` |
| `tests-agent/{packages,harness,memory-tools-tests,planner-tools-tests,loop-tests}.lisp` (create) | agent suite |
| `tests-agent-prolog/{packages,query-tests}.lisp` (create) | prolog suite |
| `docs/agent-tools.md` (create), `docs/agent-memory.md`, `README.md`, `docs/ci.md`, `.github/workflows/test.yml` (modify) | docs and CI |

---

### Task 1: `make-tool` in core

**Files:**
- Modify: `src/tools.lisp` (after `deftool`)
- Modify: `src/packages.lisp` (export `#:make-tool`)
- Modify: `rag/answer.lisp:35-45`
- Test: `tests/tools.lisp` (append)

**Interfaces:**
- Produces: `(make-tool name description parameters function) => tool`.
  `name` a string or symbol (downcased); `parameters` a `deftool`
  lambda list; `function` takes the parameters positionally in
  declaration order. Not registered in `*tools-registry*`.

- [ ] **Step 1: Write the failing test**

Append to `tests/tools.lisp`:

```lisp
(test make-tool-builds-a-closure-tool-with-a-derived-schema
  "A tool need not be a DEFUN: MAKE-TOOL takes a lambda list and a
function and derives the same schema DEFTOOL would."
  (let* ((seen nil)
         (tool (llm:make-tool "greet" "Greet someone."
                              '(name (times :type integer :default 1))
                              (lambda (name times)
                                (setf seen (list name times))
                                (format nil "~a x~a" name times)))))
    (is (string= "greet" (llm:tool-name tool)))
    (is (string= "string"
                 (json:jget (llm:tool-schema tool) "properties" "name" "type")))
    (is (equalp #("name") (json:jget (llm:tool-schema tool) "required")))
    (let ((args (make-hash-table :test 'equal)))
      (setf (gethash "name" args) "ada")
      (is (string= "ada x1" (llm:call-tool tool args)))
      (is (equal '("ada" 1) seen)))
    (is (null (gethash "greet" cl-llm::*tools-registry*))
        "MAKE-TOOL does not register")))
```

- [ ] **Step 2: Run it to verify it fails**

Run the single-test form with `cl-llm.test::MAKE-TOOL-BUILDS-A-CLOSURE-TOOL-WITH-A-DERIVED-SCHEMA`
after quickloading `:cl-llm/tests`. Expected: read error, `llm:make-tool`
not external.

- [ ] **Step 3: Implement**

In `src/tools.lisp`, after `parameter-names` and before `deftool`:

```lisp
(defun make-tool (name description parameters function)
  "A TOOL from a DEFTOOL lambda list and a FUNCTION of those parameters
in declaration order.  Not registered: closure tools are built per
graph or per scope, not per image (agent-tools design SS4)."
  (check-type description string)
  (make-instance 'tool
                 :name (string-downcase (string name))
                 :description description
                 :schema (derive-schema parameters)
                 :function function
                 :parameter-names (parameter-names parameters)
                 :parameter-specs (mapcar #'parameter-spec-of
                                          (remove '&optional parameters))))
```

Rewrite `deftool`'s expansion to use it:

```lisp
       (register-tool
        (make-tool ',name ,docstring ',parameters #',name))
```

replacing the `make-instance 'tool ...` form. Export `#:make-tool` from
the `cl-llm` package in `src/packages.lisp` beside `#:deftool`.

In `rag/answer.lisp`, `make-retrieval-tool` becomes:

```lisp
(defun make-retrieval-tool (index &key (k 5))
  "Build a cl-llm tool that retrieves cited context from INDEX, for the
agentic path where the model decides whether to retrieve."
  (llm:make-tool "retrieve-context"
                 "Retrieve relevant, cited passages from the knowledge base for a query."
                 '((query :type string))
                 (lambda (query)
                   (assemble-context (retrieve index query :k k)))))
```

- [ ] **Step 4: Run the core and rag suites**

Expected: core 408 + 6 checks, rag 319, all green.

- [ ] **Step 5: Commit**

```bash
git add src/tools.lisp src/packages.lisp rag/answer.lisp tests/tools.lisp
git commit -m "feat(core): make-tool -- closure tools with a derived schema (#14 unit 2)"
```

---

### Task 2: Unit 1 amendments in `cl-llm/memory`

**Files:**
- Modify: `memory/schema.lisp`, `memory/trace.lisp`, `memory/recall.lisp`, `memory/packages.lisp`
- Modify: `cl-llm.asd` (`cl-llm/memory/tests` components: add `(:file "store-tests")` after `trace-tests`)
- Create: `tests-memory/store-tests.lisp`

**Interfaces:**
- Produces:
  - `(define-memory-store graph-name)` macro.
  - `(store-name graph) => string` (downcased graph name).
  - `conclude` `:evidence` items: a cite string, `(cite . store-name)`,
    or a claim. Evidence claims carry the store name in `method`.
  - `(trace graph id &key (scope (list graph)))`,
    `(decisions-citing graph claim-or-cite &key (scope (list graph)))`.
  - `(claim-before-p a b)` exported: unit 1's order rule.
  - `(find-store scope name)` is NOT here — the agent owns it.

- [ ] **Step 1: Write the failing tests**

`tests-memory/store-tests.lisp`:

```lisp
;;;; tests-memory/store-tests.lisp -- the unit-2 amendments to unit 1:
;;;; a second store, evidence naming its store, TRACE with a scope.
;;;; Spec 2026-09-03 SS4.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

;; The second store's families, declared once at load (spec SS2: the
;; indexes and constraints are per graph name).
(mem:define-memory-store :memory-private)

(defun %call-with-two-stores (fn)
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (gdb:*system-directory* (format nil "/tmp/cl-llm-mem2-sys-~a/" stamp))
         (a (gdb:make-graph :cl-llm-memory
                            (format nil "/tmp/cl-llm-mem2-a-~a/" stamp)
                            :buffer-pool-size 1000))
         (b (gdb:make-graph :memory-private
                            (format nil "/tmp/cl-llm-mem2-b-~a/" stamp)
                            :buffer-pool-size 1000)))
    (unwind-protect (funcall fn a b)
      (ignore-errors (gdb:close-graph a))
      (ignore-errors (gdb:close-graph b))
      (dolist (d (list (format nil "/tmp/cl-llm-mem2-a-~a/" stamp)
                       (format nil "/tmp/cl-llm-mem2-b-~a/" stamp)
                       gdb:*system-directory*))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))

(defmacro with-two-stores ((a b) &body body)
  `(%call-with-two-stores (lambda (,a ,b) ,@body)))

(defparameter +ss+ '(:repo . "cl-llm"))

(defun %belief-in (g relation object)
  (gdb:with-transaction (:graph g)
    (mem:record-belief g +ss+ relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts "2026-09-01T08:00:00Z")))))

(test a-second-store-is-queryable-and-separate
  "SS2: DEFINE-MEMORY-STORE under the second name makes RECALL, CONCLUDE
and the validators live there; the first store sees nothing of it."
  (with-two-stores (a b)
    (%belief-in b "ci-status" '(:verdict . "green"))
    (is (= 1 (length (mem:recall b +ss+))))
    (is (null (mem:recall a +ss+)) "control: the first store is untouched")
    (let ((d (mem:conclude b (list :belief +ss+ "ci-status"
                                   '(:verdict . "green")
                                   :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-09-01T08:00:00Z")))
                           :producer +p+ :rule "dup")))
      ;; same object, same start: RECORD-BELIEF's idempotent path
      (is (eq :concluded (mem:decision-outcome d))))
    (is (string= "memory-private" (mem:store-name b)))))

(test evidence-records-the-store-it-was-found-in
  "SS4.2: a decision in store A resting on a claim from store B says so
on the evidence claim's METHOD slot."
  (with-two-stores (a b)
    (let* ((private (%belief-in b "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite private))
           (d (mem:conclude a (list :belief +ss+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+
                            :evidence (list (cons cite "memory-private"))
                            :rule "r"))
           (ev (find "evidence"
                     (st:claims-touching a 'mem:trace :decision
                                         (mem:decision-id d) :role :subject)
                     :key #'st:claim-relation :test #'string=)))
      (is (string= "memory-private" (st:claim-method ev)))
      ;; a claim object records its own store
      (let* ((d2 (mem:conclude a (list :belief +ss+ "deployable" '(:v . "yes")
                                       :standing :inferred)
                               :producer +p+ :evidence (list private)
                               :rule "r"))
             (ev2 (find "evidence"
                        (st:claims-touching a 'mem:trace :decision
                                            (mem:decision-id d2)
                                            :role :subject)
                        :key #'st:claim-relation :test #'string=)))
        (is (string= "memory-private" (st:claim-method ev2))))
      ;; a bare cite records the write store
      (let* ((own (%belief-in a "last-push" '(:sha . "abc")))
             (d3 (mem:conclude a (list :belief +ss+ "x" '(:v . "1")
                                       :standing :inferred)
                               :producer +p+
                               :evidence (list (mem:claim-cite own))
                               :rule "r"))
             (ev3 (find "evidence"
                        (st:claims-touching a 'mem:trace :decision
                                            (mem:decision-id d3)
                                            :role :subject)
                        :key #'st:claim-relation :test #'string=)))
        (is (string= "cl-llm-memory" (st:claim-method ev3)))))))

(test trace-resolves-a-cross-store-cite-within-its-scope
  "SS4.3: with B in scope the cite resolves; without it, :ABSENT --
never silently resolved in the wrong store."
  (with-two-stores (a b)
    (let* ((private (%belief-in b "ci-status" '(:verdict . "green")))
           (d (mem:conclude a (list :belief +ss+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+
                            :evidence (list private) :rule "r"))
           (in (mem:trace a (mem:decision-id d) :scope (list a b)))
           (out (mem:trace a (mem:decision-id d))))
      (is (eq :resolved (mem:cite-record-state
                         (first (mem:decision-record-evidence in)))))
      (is (eq :absent (mem:cite-record-state
                       (first (mem:decision-record-evidence out)))))
      (is (equal (list (mem:decision-id d))
                 (mem:decisions-citing b private :scope (list a b))))
      (is (null (mem:decisions-citing b private))
          "control: B alone holds no decision"))))

(test claim-before-p-is-the-recall-order
  (with-two-stores (a b)
    (declare (ignore b))
    (let ((old (%belief-in a "ci-status" '(:verdict . "green")))
          (new (gdb:with-transaction (:graph a)
                 (mem:record-belief a +ss+ "ci-status" '(:verdict . "red")
                                    :producer +p+ :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-09-02T08:00:00Z"))))))
      (is-true (mem:claim-before-p new old))
      (is-false (mem:claim-before-p old new)))))
```

- [ ] **Step 2: Add the component and run to see it fail**

Expected: `mem:define-memory-store` unbound at read.

- [ ] **Step 3: Implement**

`memory/schema.lisp` — replace the three declarations with the macro
and one use:

```lisp
(defmacro define-memory-store (graph-name)
  "Declare the belief and trace families and the memory-note source in
GRAPH-NAME.  A family's indexes and constraints are per graph name
(spec 2026-09-03 SS2), so every store an agent scope may read needs
this once; the class names are shared, which is the engine's model
(kraison/vivace-graph#167, #196)."
  `(progn
     (st:def-claim-classes belief ,graph-name :temporal t)
     (st:def-claim-classes trace ,graph-name)
     (st:def-source memory-note ,graph-name
         ((note-name        :type string)
          (note-description :type string)
          (note-type        :type string)
          (note-modified    :type string)
          (note-body        :type string))
       :identity     (:namespace :memory-note :key-slot note-name)
       :space        :none
       :time         (:extent-fn memory-note-validity-extent)
       :attribution  :none
       :sensitivity  (:class :restricted)
       :registration :none
       :indexed-text (:text-fn note-body))
     ',graph-name))

(define-memory-store :cl-llm-memory)

(defun store-name (graph)
  "GRAPH's name as the string a model sees: downcased (SS5)."
  (string-downcase (symbol-name (gdb:graph-name graph))))
```

Keep `memory-note-validity-extent` as is (it must be defined before the
macro is used; move it above if needed — the `:extent-fn` names it, it
need not be defined at expansion time, but keep the order the file has).
Keep the existing comments above the declarations, moved into the
macro's docstring where they still apply.

`memory/trace.lisp`:

```lisp
(defun %claim-store (claim)
  "The name of the store holding CLAIM, or NIL.  RESOLVE-NODE-GRAPH is
the engine's only route from a node to its store and is internal
(noted on kraison/vivace-graph#322)."
  (let ((g (graph-db::resolve-node-graph (gdb:id claim))))
    (and g (store-name g))))

(defun %evidence-of (x write-store)
  "(cite . store-name) for one EVIDENCE item (SS4.2): a cite string
means WRITE-STORE; a (cite . store) pair passes through; a claim
resolves its own store, falling back to WRITE-STORE."
  (cond ((cite-p x) (cons (progn (split-cite x) x) write-store))
        ((and (consp x) (cite-p (car x)) (stringp (cdr x)))
         (split-cite (car x))
         x)
        ((ignore-errors (%family-parent-of x))
         (cons (claim-cite x) (or (%claim-store x) write-store)))
        (t (%arg-error :evidence x
                       "a claim, a cite string, or (cite . store)"))))
```

`%write-evidence` takes `(graph id pairs producer)` and writes one
claim per distinct cite, `:method (cdr pair)`:

```lisp
(defun %write-evidence (graph id pairs producer)
  (dolist (pair (remove-duplicates pairs :key #'car :test #'string=))
    (%trace-claim graph id "evidence" :claim (car pair) producer :observed
                  :method (cdr pair))))
```

In `conclude`, replace `(cites (mapcar #'%cite-of evidence))` with
`(pairs (mapcar (lambda (e) (%evidence-of e (store-name graph))) evidence))`
and pass `pairs` where `cites` was passed (both `%write-evidence` calls
and `%write-refusal`'s parameter). `%cite-of` stays for
`decisions-citing`.

`trace` gains `&key (scope (list graph))`. Where it resolves the
conclusion and each evidence cite, resolve in the right store:

```lisp
(defun %store-in-scope (name scope)
  (find name scope :key #'store-name :test #'string=))

(defun %resolve-in (cite store-name graph scope at)
  "CITE resolved in the store its evidence claim named, when that store
is in SCOPE; unit-1 evidence (no store) resolves in GRAPH; a store out
of scope is :ABSENT (SS4.3)."
  (let ((g (if store-name (%store-in-scope store-name scope) graph)))
    (if g
        (resolve-cite g cite at)
        (make-cite-record :cite cite :state :absent))))
```

Evidence claims are collected as `(cite . method)` pairs sorted by
cite; each becomes `(%resolve-in cite method graph scope at)`. The
conclusion resolves in `graph` (it was written there).

`decisions-citing` gains `&key (scope (list graph))` and unions
`claims-touching` over every store in scope, sorted as before.

`memory/recall.lisp`: add `(defun claim-before-p (a b) (%before-p a b))`
with a one-line docstring naming the order rule. Exports in
`memory/packages.lisp`: `#:define-memory-store #:store-name
#:claim-before-p`.

- [ ] **Step 4: Run the memory suite until green; then the golden must be unchanged**

`tests-memory/golden/trace.sexp` must not change (the listing carries
no store). Expected: memory 174 + new checks, all green; run twice.

- [ ] **Step 5: Commit**

```bash
git add memory/ tests-memory/store-tests.lisp cl-llm.asd
git commit -m "feat(memory): define-memory-store; evidence names its store; trace scope (#14 unit 2)"
```

---

### Task 3: The claim's identity key in the claim source's evidence

**Files:**
- Modify: `claims/source.lisp:79-97` (`%claim-evidence`)
- Modify: `tests-claims/source-tests.lisp` (append)

**Interfaces:**
- Produces: a claim evidence item's chunk metadata plist gains
  `:claim-key <identity-key string>` beside `:extent`.

- [ ] **Step 1: Write the failing test**

Append to `tests-claims/source-tests.lisp`, using that file's existing
fixture helpers (read the file first; it opens a real claim store and
has a `%seed`):

```lisp
(test claim-evidence-carries-the-identity-key
  "Agent-tools SS7: a consumer renders a cite from evidence, so the
identity key rides in the chunk metadata beside :EXTENT."
  (with-claim-store (g)
    (%seed g)
    (let* ((source (claims:make-claim-source
                    g 'test-claim (lambda (q) (declare (ignore q))
                                    (list (cons :device . "d1")))))
           (ev (first (rag:collect-evidence source "anything"))))
      (is (stringp (getf (rag:chunk-metadata (rag:evidence-chunk ev))
                         :claim-key)))
      (is (search "|" (getf (rag:chunk-metadata (rag:evidence-chunk ev))
                            :claim-key))))))
```

Adjust the fixture names (`with-claim-store`, `%seed`, the parent
class `test-claim`, the endpoint) to what `tests-claims/source-tests.lisp`
actually defines; the assertion is what matters.

- [ ] **Step 2: Run it to verify it fails**

Expected: `:claim-key` is NIL.

- [ ] **Step 3: Implement**

In `%claim-evidence`, the chunk's `:metadata` becomes

```lisp
             :metadata (append
                        (and extent
                             (list :extent (temporal-extent:extent->sexp
                                            extent)))
                        (list :claim-key (st:claim-identity-key claim)))
```

and the docstring gains one line: "`:CLAIM-KEY` is the identity key, so
a consumer can cite the claim (agent-tools design SS7)."

- [ ] **Step 4: Run the claims suite**

Expected: 18 + 2 checks green.

- [ ] **Step 5: Commit**

```bash
git add claims/source.lisp tests-claims/source-tests.lisp
git commit -m "feat(rag/claims): evidence carries the claim's identity key (#14 unit 2)"
```

---

### Task 4: The agent system — scope, rendering, and the read tools

**Files:**
- Create: `agent/packages.lisp`, `agent/scope.lisp`, `agent/render.lisp`, `agent/memory-tools.lisp`, `agent/agent.lisp`
- Create: `tests-agent/packages.lisp`, `tests-agent/harness.lisp`, `tests-agent/memory-tools-tests.lisp`
- Modify: `cl-llm.asd` (two systems)

**Interfaces:**
- Produces:
  - `(make-scope stores &key write-store producer sources k max-rows) => scope`;
    accessors `scope-stores scope-write-store scope-producer
    scope-sources scope-k scope-max-rows scope-cites`.
  - `(find-store scope name) => graph` or signals.
  - `(note-cite scope cite graph)`, `(cite-store scope cite) => graph or NIL`.
  - `(make-agent-tools stores &key write-store producer sources (k 5) (max-rows 50)) => list of tools`
    (Task 4 delivers recall, trace, decisions-citing; Tasks 5–6 add the rest).
  - `(tool-result tool &rest args) => parsed JSON` test helper in the harness.
  - Render helpers: `%iso (timestamp-or-nil)`, `%parse-iso (string)`,
    `%from/%to (extent)`, `%standing (keyword) => string`,
    `%keyword (string) => keyword`, `%record-json`, `%cite-record-json`.

- [ ] **Step 1: Systems**

In `cl-llm.asd`, after `cl-llm/memory/tests`:

```lisp
(defsystem "cl-llm/agent"
  :description "The agent tool surface over cl-llm/memory and the
retrieval planner (#14 unit 2)."
  :license "MIT"
  ;; No web stack: the guarded query tool lives in cl-llm/agent/prolog.
  :depends-on ("cl-llm" "cl-llm/memory" "cl-llm/rag/claims")
  :serial t
  :pathname "agent/"
  :components ((:file "packages")
               (:file "scope")
               (:file "render")
               (:file "memory-tools")
               (:file "planner-tools")
               (:file "agent"))
  :in-order-to ((test-op (test-op "cl-llm/agent/tests"))))

(defsystem "cl-llm/agent/tests"
  :description "On-disk, two-store, scripted-model tests for cl-llm/agent."
  :license "MIT"
  :depends-on ("cl-llm/agent" "fiveam")
  :serial t
  :pathname "tests-agent/"
  :components ((:file "packages")
               (:file "harness")
               (:file "memory-tools-tests")
               (:file "planner-tools-tests")
               (:file "loop-tests"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-agent)
               (error "cl-llm/agent suite failed."))))
```

Create `agent/planner-tools.lisp`, `tests-agent/planner-tools-tests.lisp`
and `tests-agent/loop-tests.lisp` as placeholders holding only their
`in-package` form (Tasks 6–7 fill them).

- [ ] **Step 2: Packages**

`agent/packages.lisp`:

```lisp
;;;; agent/packages.lisp

(defpackage #:cl-llm.agent
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:json #:cl-llm.json)
                    (#:mem #:cl-llm.memory)
                    (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent)
                    (#:rag #:cl-llm.rag)
                    (#:claims #:cl-llm.rag.claims))
  (:export
   ;; scope
   #:scope #:make-scope #:scope-stores #:scope-write-store
   #:scope-producer #:scope-sources #:scope-k #:scope-max-rows
   #:find-store #:note-cite #:cite-store #:scope-error
   ;; tools
   #:make-agent-tools #:make-memory-tools #:make-planner-tools))
```

`tests-agent/packages.lisp`:

```lisp
;;;; tests-agent/packages.lisp

(defpackage #:cl-llm.agent/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:agent #:cl-llm.agent)
                    (#:llm #:cl-llm)
                    (#:json #:cl-llm.json)
                    (#:mem #:cl-llm.memory)
                    (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent)
                    (#:rag #:cl-llm.rag)))
```

- [ ] **Step 3: Write the failing tests**

`tests-agent/harness.lisp`:

```lisp
;;;; tests-agent/harness.lisp -- two on-disk stores per test, and a
;;;; way to call a tool as the model would.

(in-package #:cl-llm.agent/tests)

(def-suite :cl-llm-agent
  :description "cl-llm/agent offline suite (two on-disk stores).")
(in-suite :cl-llm-agent)

;; The second store's families (spec SS2).  :MEMORY-PRIVATE is also
;; declared by tests-memory; a second declaration is the engine's
;; supported idempotent case (kraison/vivace-graph#196).
(mem:define-memory-store :memory-private)

(defun %call-with-stores (fn)
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (dirs (list (format nil "/tmp/cl-llm-agent-w-~a/" stamp)
                     (format nil "/tmp/cl-llm-agent-p-~a/" stamp)))
         (gdb:*system-directory* (format nil "/tmp/cl-llm-agent-sys-~a/" stamp))
         (working (gdb:make-graph :cl-llm-memory (first dirs)
                                  :buffer-pool-size 1000))
         (private (gdb:make-graph :memory-private (second dirs)
                                  :buffer-pool-size 1000)))
    (unwind-protect (funcall fn working private)
      (ignore-errors (gdb:close-graph working))
      (ignore-errors (gdb:close-graph private))
      (dolist (d (cons gdb:*system-directory* dirs))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))

(defmacro with-stores ((working private) &body body)
  `(%call-with-stores (lambda (,working ,private) ,@body)))

(defparameter +p+ "claude-code/test")
(defparameter +subj+ '(:repo . "cl-llm"))

(defun %ts (s) (local-time:parse-timestring s))

(defun %open-from (s)
  (te:make-interval (te:exact-bound (%ts s)) (te:unknown-bound)
                    :semantics :validity :standing :asserted))

(defun %belief (g relation object &key (start "2026-09-01T08:00:00Z")
                                       (subject +subj+))
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from start))))

(defun %tool (tools name)
  (or (find name tools :key #'llm:tool-name :test #'string=)
      (error "no tool ~a" name)))

(defun %args (&rest plist)
  "A hash-table of decoded-JSON arguments, as the model sends them."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr do (setf (gethash k h) v))
    h))

(defun %call (tools name &rest plist)
  "Call tool NAME as the model would and parse its JSON result."
  (json:parse (llm:call-tool (%tool tools name) (apply #'%args plist))))
```

`tests-agent/memory-tools-tests.lisp`:

```lisp
;;;; tests-agent/memory-tools-tests.lisp -- spec SS5, SS6: the read
;;;; tools across a scope.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(test make-agent-tools-needs-a-producer-and-a-write-store-in-scope
  (with-stores (w p)
    (signals error (agent:make-agent-tools (list w p)))
    (signals error (agent:make-agent-tools (list w) :write-store p
                                                    :producer +p+))
    (is (= 8 (length (agent:make-agent-tools (list w p) :producer +p+))))))

(test recall-spans-the-scope-and-names-the-store
  "SS6: reads run over every store in scope; each record says where it
came from; the private store is invisible when out of scope."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief p "owner" '(:person . "kevin"))
    (let* ((both (agent:make-agent-tools (list w p) :producer +p+))
           (only (agent:make-agent-tools (list w) :producer +p+))
           (r (%call both "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm"))
           (records (json:jget r "records")))
      (is (= 2 (length records)))
      (is (equal '("cl-llm-memory" "memory-private")
                 (sort (map 'list (lambda (x) (json:jget x "store")) records)
                       #'string<)))
      (let ((green (find "ci-status" records
                         :key (lambda (x) (json:jget x "relation"))
                         :test #'string=)))
        (is (string= "green" (json:jget green "object" "key")))
        (is (string= "verdict" (json:jget green "object" "namespace")))
        (is (string= "observed" (json:jget green "standing")))
        (is (string= "2026-09-01T08:00:00.000000Z"
                     (json:jget green "valid-from")))
        (is (null (json:jget green "valid-to")))
        (is (eq t (json:jget green "current")))
        (is (mem:cite-p (json:jget green "cite"))))
      (is (eq nil (json:jget r "truncated")))
      (let ((r2 (%call only "recall" "subject-namespace" "repo"
                       "subject-key" "cl-llm")))
        (is (= 1 (length (json:jget r2 "records")))
            "the private store is not in scope")))))

(test recall-clamps-to-max-rows-and-says-so
  (with-stores (w p)
    (dotimes (i 3)
      (%belief w (format nil "rel-~a" i) '(:v . "1")))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+
                                          :max-rows 2))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm")))
      (is (= 2 (length (json:jget r "records"))))
      (is (eq t (json:jget r "truncated"))))))

(test recall-filters-and-orders
  "Order is unit 1's: validity start descending."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "ci-status" '(:verdict . "red") :start "2026-09-02T08:00:00Z")
    (%belief w "last-push" '(:sha . "abc"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm" "relation" "ci-status")))
      (is (equal '("red" "green")
                 (map 'list (lambda (x) (json:jget x "object" "key"))
                      (json:jget r "records"))))
      (let ((old (second (coerce (json:jget r "records") 'list))))
        (is (eq nil (json:jget old "current")))
        (is (mem:cite-p (json:jget old "superseded-by")))))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm" "relation" "ci-status"
                     "at" "2026-09-01T12:00:00Z")))
      (is (= 1 (length (json:jget r "records")))))))

(test recall-of-nothing-is-an-empty-array-not-an-absence
  (with-stores (w p)
    (gdb:with-transaction (:graph w)
      (mem:record-absence w +subj+ "release-date" :producer +p+
                          :standing :searched-empty))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm"))
           (rec (first (coerce (json:jget r "records") 'list))))
      (is (null (json:jget rec "object")))
      (is (string= "searched-empty" (json:jget rec "standing")))
      (let ((none (%call tools "recall" "subject-namespace" "repo"
                         "subject-key" "nothing-here")))
        (is (= 0 (length (json:jget none "records"))))))))

(test trace-and-decisions-citing-across-the-scope
  (with-stores (w p)
    (let* ((private (%belief p "owner" '(:person . "kevin")))
           (d (mem:conclude w (list :belief +subj+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list private)
                            :rule "r" :rule-version "1"))
           (tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "trace" "decision-id" (mem:decision-id d))))
      (is (string= "concluded" (json:jget r "outcome")))
      (is (string= "cl-llm-memory" (json:jget r "store")))
      (is (string= "r" (json:jget r "rule")))
      (let ((ev (first (coerce (json:jget r "evidence") 'list))))
        (is (string= "memory-private" (json:jget ev "store")))
        (is (string= "resolved" (json:jget ev "state")))
        (is (null (json:jget ev "changed-since"))))
      (let ((c (%call tools "decisions-citing"
                      "cite" (mem:claim-cite private))))
        (is (string= (mem:decision-id d)
                     (json:jget (first (coerce (json:jget c "decisions")
                                               'list))
                                "id")))))))

(test trace-of-an-unknown-id-signals
  (with-stores (w p)
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "trace")
                       (%args "decision-id" "nope"))))))
```

`llm:llm-tool-error` is `cl-llm.conditions:llm-tool-error`; check how
`tests/tool-loop.lisp` refers to it (`c:llm-tool-error` there) and use
the exported name from `cl-llm`.

- [ ] **Step 4: Run to see them fail**

Expected: `agent:make-agent-tools` unbound.

- [ ] **Step 5: Implement `agent/scope.lisp`**

```lisp
;;;; agent/scope.lisp -- what a tool set may see and write, and the
;;;; caps.  Spec 2026-09-03 SS2, SS5.

(in-package #:cl-llm.agent)

(define-condition scope-error (error)
  ((reason :initarg :reason :reader scope-error-reason))
  (:report (lambda (c s) (format s "~a" (scope-error-reason c)))))

(defun %scope-error (fmt &rest args)
  (error 'scope-error :reason (apply #'format nil fmt args)))

(defstruct (scope (:constructor %make-scope))
  "STORES readable in order; WRITE-STORE one of them; PRODUCER the
canonical agent name; SOURCES extra COLLECT-EVIDENCE sources; K and
MAX-ROWS the caps; CITES the cite -> store map of results already
returned (SS6)."
  stores write-store producer sources k max-rows
  (cites (make-hash-table :test 'equal)))

(defun make-scope (stores &key write-store producer sources
                                (k 5) (max-rows 50))
  (unless (and (consp stores) (every #'gdb:graph-p stores))
    (%scope-error "STORES must be a non-empty list of open graphs"))
  (let ((write (or write-store (first stores))))
    (unless (member write stores)
      (%scope-error "the write store must be one of the readable stores"))
    (unless (st:canonical-producer-p producer)
      (%scope-error "PRODUCER is required: a canonical string ~
                     \"<agent>/<host>\""))
    (%make-scope :stores stores :write-store write :producer producer
                 :sources sources :k k :max-rows max-rows)))

(defun find-store (scope name)
  "The graph NAME (a store-name string) denotes in SCOPE, or a
SCOPE-ERROR the model can read."
  (or (find name (scope-stores scope) :key #'mem:store-name
            :test #'string=)
      (%scope-error "store ~s is not in this scope" name)))

(defun note-cite (scope cite graph)
  (setf (gethash cite (scope-cites scope)) graph))

(defun cite-store (scope cite)
  "The store CITE was returned from, else the first store in scope
holding it, else NIL (SS6)."
  (or (gethash cite (scope-cites scope))
      (multiple-value-bind (family ns key) (mem:split-cite cite)
        (dolist (g (scope-stores scope) nil)
          (when (find cite (st:claims-touching g family ns key
                                               :role :subject)
                      :key #'mem:claim-cite :test #'string=)
            (note-cite scope cite g)
            (return g))))))

(defun clamp (n cap)
  "N clamped to CAP; NIL or non-positive means CAP."
  (if (and (integerp n) (plusp n)) (min n cap) cap))
```

`gdb:graph-p` — check the export; if absent use `(typep x 'gdb:graph)`.

- [ ] **Step 6: Implement `agent/render.lisp`**

```lisp
;;;; agent/render.lisp -- values as the model reads them.  Spec SS5.

(in-package #:cl-llm.agent)

(defun %iso (ts)
  (and (typep ts 'local-time:timestamp)
       (local-time:format-rfc3339-timestring
        nil ts :timezone local-time:+utc-zone+)))

(defun %parse-iso (string)
  "A TIMESTAMP from an RFC 3339 STRING; a malformed one signals, and
the tool loop shows the model the message."
  (local-time:parse-timestring string))

(defun %from (extent)
  (and extent (%iso (te:bound-earliest (te:extent-start extent)))))

(defun %to (extent)
  (and extent
       (let ((end (te:extent-end extent)))
         (and (not (te:bound-unknown-p end))
              (not (eq :unbounded (te:bound-latest end)))
              (%iso (te:bound-latest end))))))

(defun %standing (keyword)
  (and keyword (string-downcase (symbol-name keyword))))

(defun %keyword (string)
  (intern (string-upcase string) :keyword))

(defun %bool (x) (if x :true :false))

(defun %endpoint-json (ns key)
  (json:jobject :namespace (%standing ns) :key key))

(defun %record-json (store record)
  "One BELIEF-RECORD as the model reads it (SS6)."
  (let* ((c (mem:belief-record-claim record))
         (s (mem:belief-record-superseded-by record))
         (e (mem:belief-record-extent record)))
    (json:jobject
     :store (mem:store-name store)
     :cite (mem:claim-cite c)
     :relation (st:claim-relation c)
     :object (and (typep c 'mem:belief-binary)
                  (%endpoint-json (st:claim-object-namespace c)
                                  (st:claim-object-key c)))
     :standing (%standing (mem:belief-record-standing record))
     :valid-from (%from e)
     :valid-to (%to e)
     :current (%bool (mem:belief-record-current-p record))
     :superseded-by (and s (mem:claim-cite s)))))

(defun %cite-record-json (store-name record)
  (json:jobject
   :store store-name
   :cite (mem:cite-record-cite record)
   :state (%standing (mem:cite-record-state record))
   :changed-since (%standing (mem:cite-record-changed-since record))
   :standing (%standing (mem:cite-record-standing record))
   :valid-from (%from (mem:cite-record-extent record))
   :valid-to (%to (mem:cite-record-extent record))))
```

`json:jobject` omits NIL values; `%bool` makes false explicit where a
boolean is promised. Note `jkey` turns hyphens into underscores —
check `cl-llm.json::jkey`; if it does, pass string keys
(`"valid-from"`) so the wire spelling matches the spec.

- [ ] **Step 7: Implement `agent/memory-tools.lisp` (reads) and `agent/agent.lisp`**

```lisp
;;;; agent/memory-tools.lisp -- recall, trace, decisions-citing,
;;;; conclude, conclude-absence, retract.  Spec SS6.

(in-package #:cl-llm.agent)

(defun %recall-tool (scope)
  (llm:make-tool
   "recall"
   "Recall what is believed about a subject: every belief on
(subject-namespace, subject-key) across the memory in scope, newest
validity first, each with its cite, standing, validity window, whether
it is current, and what superseded it.  Optional relation narrows to
one predicate; optional at (RFC 3339) keeps only beliefs valid then."
   '((subject-namespace :type string) (subject-key :type string)
     (relation :type string :optional t) (at :type string :optional t))
   (lambda (subject-namespace subject-key relation at)
     (let* ((subject (cons (%keyword subject-namespace) subject-key))
            (instant (and at (%parse-iso at)))
            (rows '()))
       (dolist (g (scope-stores scope))
         (dolist (r (mem:recall g subject :relation relation :at instant))
           (note-cite scope (mem:claim-cite (mem:belief-record-claim r)) g)
           (push (cons g r) rows)))
       (setf rows (stable-sort (nreverse rows)
                               (lambda (a b)
                                 (mem:claim-before-p
                                  (mem:belief-record-claim (cdr a))
                                  (mem:belief-record-claim (cdr b))))))
       (let* ((cap (scope-max-rows scope))
              (shown (subseq rows 0 (min cap (length rows)))))
         (json:to-json
          (json:jobject
           "records" (map 'vector (lambda (x) (%record-json (car x) (cdr x)))
                          shown)
           "truncated" (%bool (> (length rows) cap)))))))))

(defun %find-decision (scope id)
  "The store holding decision ID, or NIL."
  (find-if (lambda (g) (st:claims-touching g 'mem:trace :decision id
                                          :role :subject :limit 1))
           (scope-stores scope)))

(defun %trace-tool (scope)
  (llm:make-tool
   "trace"
   "Reconstruct a decision as of the instant it was made: its rule,
outcome, the conclusion, every evidence cite resolved to the version
believed then with what has changed since, and any refusals."
   '((decision-id :type string))
   (lambda (decision-id)
     (let ((g (%find-decision scope decision-id)))
       (unless g (error "no decision ~a in scope" decision-id))
       (let ((rec (mem:trace g decision-id :scope (scope-stores scope))))
         (dolist (r (mem:decision-record-evidence rec))
           (note-cite scope (mem:cite-record-cite r)
                      (or (cite-store scope (mem:cite-record-cite r)) g)))
         (json:to-json
          (json:jobject
           "id" decision-id
           "store" (mem:store-name g)
           "producer" (mem:decision-record-producer rec)
           "at" (%iso (mem:decision-record-at rec))
           "rule" (mem:decision-record-rule rec)
           "rule-version" (mem:decision-record-rule-version rec)
           "confidence" (mem:decision-record-confidence rec)
           "outcome" (%standing (mem:decision-record-outcome rec))
           "conclusion" (let ((c (mem:decision-record-conclusion rec)))
                          (and c (%cite-record-json (mem:store-name g) c)))
           "evidence" (map 'vector
                           (lambda (r)
                             (%cite-record-json
                              (let ((s (cite-store scope
                                                   (mem:cite-record-cite r))))
                                (and s (mem:store-name s)))
                              r))
                           (mem:decision-record-evidence rec))
           "refusals" (map 'vector
                           (lambda (f) (json:jobject "family" (car f)
                                                     "text" (cdr f)))
                           (mem:decision-record-refusals rec)))))))))

(defun %decisions-citing-tool (scope)
  (llm:make-tool
   "decisions-citing"
   "The decisions whose evidence cites a claim, newest first: which
conclusions rest on this belief."
   '((cite :type string))
   (lambda (cite)
     (let ((rows '()))
       (dolist (g (scope-stores scope))
         (dolist (id (mem:decisions-citing g cite :scope (list g)))
           (push (json:jobject "id" id "store" (mem:store-name g)) rows)))
       (json:to-json (json:jobject "decisions" (coerce (nreverse rows)
                                                       'vector)))))))
```

`decisions-citing`'s cross-store order: the memory function sorts per
store; the tool concatenates in scope order. Pin it that way in a test
if the spec's "newest first" across stores matters — it does: sort the
rows by the decision's `recorded-at` instead. Do that: collect
`(at . json)` using `(mem:decision-record-at (mem:trace g id))` and sort
`local-time:timestamp>` before rendering.

`agent/agent.lisp`:

```lisp
;;;; agent/agent.lisp -- the tool set.  Spec SS5.

(in-package #:cl-llm.agent)

(defun make-memory-tools (scope)
  (list (%recall-tool scope) (%trace-tool scope)
        (%decisions-citing-tool scope)
        (%conclude-tool scope) (%conclude-absence-tool scope)
        (%retract-tool scope)))

(defun make-planner-tools (scope)
  (list (%retrieve-tool scope) (%plan-bounds-tool scope)))

(defun make-agent-tools (stores &key write-store producer sources
                                     (k 5) (max-rows 50))
  "The agent's tools over STORES (readable, in scope order) writing to
WRITE-STORE (default the first), as PRODUCER, with SOURCES added to the
planner and K / MAX-ROWS as the caps.  Every bound is fixed here; the
model chooses arguments only (SS5)."
  (let ((scope (make-scope stores :write-store write-store
                                  :producer producer :sources sources
                                  :k k :max-rows max-rows)))
    (append (make-memory-tools scope) (make-planner-tools scope))))
```

For this task, define `%conclude-tool`, `%conclude-absence-tool`,
`%retract-tool`, `%retrieve-tool` and `%plan-bounds-tool` as stubs
returning a tool whose function signals `"not implemented"`, each with
its real name and an empty parameter list, so the count test passes
and Tasks 5–6 replace them.

- [ ] **Step 8: Run the agent suite until green**

Expected: all Task 4 tests green; note the check count.

- [ ] **Step 9: Commit**

```bash
git add cl-llm.asd agent/ tests-agent/
git commit -m "feat(agent): scope, rendering, and the read tools (#14 unit 2)"
```

---

### Task 5: The write tools — conclude, conclude-absence, retract

**Files:**
- Modify: `agent/memory-tools.lisp`
- Modify: `tests-agent/memory-tools-tests.lisp` (append)

**Interfaces:**
- Consumes: `mem:conclude` with `(cite . store)` evidence (Task 2),
  `cite-store`, `mem:retract-belief`, `mem:split-cite`.
- Produces: the three tools with the spec's parameters and result shape.

- [ ] **Step 1: Write the failing tests**

```lisp
(test conclude-writes-a-decision-into-the-write-store-citing-what-it-read
  (with-stores (w p)
    (%belief p "owner" '(:person . "kevin"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "recall" "subject-namespace" "repo"
                     "subject-key" "cl-llm"))
           (cite (json:jget (first (coerce (json:jget r "records") 'list))
                            "cite"))
           (c (%call tools "conclude"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "releasable"
                     "object-namespace" "verdict" "object-key" "yes"
                     "rule" "owner-says" "rule-version" "1"
                     "evidence" (vector cite) "confidence" 0.8)))
      (is (string= "concluded" (json:jget c "outcome")))
      (is (string= "cl-llm-memory" (json:jget c "store")))
      (is (mem:cite-p (json:jget c "claim-cite")))
      (is (= 0 (length (json:jget c "refusals"))))
      (let ((t2 (%call tools "trace" "decision-id" (json:jget c "id"))))
        (is (string= "owner-says" (json:jget t2 "rule")))
        (is (string= cite (json:jget (first (coerce (json:jget t2 "evidence")
                                                   'list))
                                     "cite")))
        (is (string= "memory-private"
                     (json:jget (first (coerce (json:jget t2 "evidence")
                                               'list))
                                "store"))))
      (is (= 1 (length (mem:recall w +subj+ :relation "releasable"))))
      (is (null (mem:recall p +subj+ :relation "releasable"))
          "control: the private store gained nothing"))))

(test conclude-standing-defaults-to-inferred-and-is-checked
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (c (%call tools "conclude"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "x" "object-namespace" "v" "object-key" "1"
                     "rule" "r")))
      (is (string= "concluded" (json:jget c "outcome")))
      (is (eq :inferred (st:claim-standing
                         (mem:belief-record-claim
                          (first (mem:recall w +subj+ :relation "x"))))))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "conclude")
                       (%args "subject-namespace" "repo" "subject-key" "cl-llm"
                              "relation" "y" "object-namespace" "v"
                              "object-key" "1" "rule" "r"
                              "standing" "searched-empty"))))))

(test a-refused-conclude-is-a-result-the-model-can-read
  "SS6: refusal is data.  A lapsed belief re-asserted inside its own
window trips the validator; no belief is written."
  (with-stores (w p)
    (gdb:with-transaction (:graph w)
      (mem:record-belief w +subj+ "ci-status" '(:verdict . "green")
                         :producer +p+ :standing :observed
                         :extent (te:make-interval
                                  (te:exact-bound (%ts "2026-01-01T00:00:00Z"))
                                  (te:exact-bound (%ts "2026-03-01T00:00:00Z"))
                                  :semantics :validity :standing :asserted)))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (c (%call tools "conclude"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "ci-status" "object-namespace" "verdict"
                     "object-key" "green" "rule" "r" "standing" "observed"
                     "valid-from" "2026-02-01T00:00:00Z")))
      (is (string= "refused" (json:jget c "outcome")))
      (is (null (json:jget c "claim-cite")))
      (is (string= "subsystem"
                   (json:jget (first (coerce (json:jget c "refusals") 'list))
                              "family")))
      (is (= 1 (length (mem:recall w +subj+ :relation "ci-status"
                                   :include-retracted t)))
          "nothing new was written"))))

(test conclude-absence-writes-a-unary-decision
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (c (%call tools "conclude-absence"
                     "subject-namespace" "repo" "subject-key" "cl-llm"
                     "relation" "release-date" "rule" "looked"
                     "standing" "searched-empty")))
      (is (string= "concluded" (json:jget c "outcome")))
      (let ((r (first (mem:recall w +subj+ :relation "release-date"))))
        (is (typep (mem:belief-record-claim r) 'mem:belief-unary))
        (is (eq :searched-empty (mem:belief-record-standing r)))))))

(test retract-acts-on-the-write-store-only
  (with-stores (w p)
    (let* ((own (%belief w "ci-status" '(:verdict . "green")))
           (theirs (%belief p "owner" '(:person . "kevin")))
           (tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retract" "cite" (mem:claim-cite own))))
      (is (string= (mem:claim-cite own) (json:jget r "cite")))
      (is (stringp (json:jget r "retracted-at")))
      (is (null (mem:recall w +subj+ :relation "ci-status")))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "retract")
                       (%args "cite" (mem:claim-cite theirs))))
      (is (= 1 (length (mem:recall p +subj+ :relation "owner")))
          "control: the private belief stands")
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "retract")
                       (%args "cite" (mem:claim-cite own)))
        "already retracted"))))
```

- [ ] **Step 2: Run to see them fail**

Expected: the stubs signal "not implemented".

- [ ] **Step 3: Implement**

Replace the three stubs in `agent/memory-tools.lisp`:

```lisp
(defparameter +presence-standings+ '("inferred" "observed" "asserted"))
(defparameter +absence-standings+
  '("searched-empty" "indeterminate" "uncovered"))

(defun %check-standing (string allowed)
  (unless (member string allowed :test #'string=)
    (error "standing must be one of ~{~a~^, ~}" allowed))
  (%keyword string))

(defun %evidence-pairs (scope evidence)
  "(cite . store-name) per cite the model passed, from the store it
was returned from or found in (SS6)."
  (loop for cite across (or evidence #())
        for g = (cite-store scope cite)
        collect (cons cite (mem:store-name (or g (scope-write-store scope))))))

(defun %decision-json (scope d)
  (json:to-json
   (json:jobject
    "id" (mem:decision-id d)
    "store" (mem:store-name (scope-write-store scope))
    "outcome" (%standing (mem:decision-outcome d))
    "claim-cite" (let ((c (mem:decision-claim d)))
                   (and c (progn (note-cite scope (mem:claim-cite c)
                                            (scope-write-store scope))
                                 (mem:claim-cite c))))
    "refusals" (map 'vector
                    (lambda (f) (json:jobject "family" (car f)
                                              "text" (cdr f)))
                    (mem:decision-record-refusals
                     (mem:trace (scope-write-store scope)
                                (mem:decision-id d)))))))

(defun %conclude-tool (scope)
  (llm:make-tool
   "conclude"
   "Record a belief as a decision: subject relation object, under a
named rule, citing the evidence (cites from earlier results).  The
write is validated before it commits; a refusal comes back as outcome
\"refused\" with the constraint families, and writes nothing.
standing: inferred (default), observed or asserted.  valid-from: when
the belief starts to hold (RFC 3339; default now)."
   '((subject-namespace :type string) (subject-key :type string)
     (relation :type string)
     (object-namespace :type string) (object-key :type string)
     (rule :type string)
     (evidence :type (list string) :optional t)
     (standing :type string :default "inferred")
     (confidence :type number :optional t)
     (rule-version :type string :optional t)
     (valid-from :type string :optional t))
   (lambda (subject-namespace subject-key relation object-namespace
            object-key rule evidence standing confidence rule-version
            valid-from)
     (let* ((st (%check-standing standing +presence-standings+))
            (extent (and valid-from
                         (te:make-interval
                          (te:exact-bound (%parse-iso valid-from))
                          (te:unknown-bound)
                          :semantics :validity :standing :asserted)))
            (d (mem:conclude
                (scope-write-store scope)
                (append (list :belief
                              (cons (%keyword subject-namespace) subject-key)
                              relation
                              (cons (%keyword object-namespace) object-key)
                              :standing st)
                        (and extent (list :extent extent)))
                :producer (scope-producer scope)
                :evidence (%evidence-pairs scope evidence)
                :rule rule :rule-version rule-version
                :confidence confidence)))
       (%decision-json scope d)))))

(defun %conclude-absence-tool (scope)
  (llm:make-tool
   "conclude-absence"
   "Record that you looked and found nothing, as a decision: standing
searched-empty (looked in a nameable place, nothing there),
indeterminate (could not find out) or uncovered (nothing has looked).
Validated and traced like conclude."
   '((subject-namespace :type string) (subject-key :type string)
     (relation :type string) (rule :type string)
     (standing :type string)
     (evidence :type (list string) :optional t)
     (rule-version :type string :optional t))
   (lambda (subject-namespace subject-key relation rule standing
            evidence rule-version)
     (let ((d (mem:conclude
               (scope-write-store scope)
               (list :absence (cons (%keyword subject-namespace) subject-key)
                     relation
                     :standing (%check-standing standing +absence-standings+))
               :producer (scope-producer scope)
               :evidence (%evidence-pairs scope evidence)
               :rule rule :rule-version rule-version)))
       (%decision-json scope d)))))

(defun %retract-tool (scope)
  (llm:make-tool
   "retract"
   "Say a belief was wrong: close its transaction period, leaving its
validity as recorded.  Only beliefs in the writable store; a cite from
a read-only store is an error."
   '((cite :type string))
   (lambda (cite)
     (let ((g (cite-store scope cite)))
       (unless g (error "no claim for cite ~a in scope" cite))
       (unless (eq g (scope-write-store scope))
         (error "store ~a is not writable in this scope" (mem:store-name g)))
       (multiple-value-bind (family ns key) (mem:split-cite cite)
         (let ((claim (find cite (st:claims-touching g family ns key
                                                     :role :subject)
                            :key #'mem:claim-cite :test #'string=)))
           (unless claim (error "no claim for cite ~a" cite))
           (let ((retracted (gdb:with-transaction (:graph g)
                              (mem:retract-belief claim))))
             (json:to-json
              (json:jobject
               "cite" cite
               "store" (mem:store-name g)
               "retracted-at" (%iso (te:bound-latest
                                     (te:extent-end
                                      (st:claim-transaction-extent
                                       retracted)))))))))))))
```

`retract-belief` signals `belief-argument-error` on an already-retracted
claim; that propagates to the tool loop as intended.

- [ ] **Step 4: Run the agent suite until green**

- [ ] **Step 5: Commit**

```bash
git add agent/memory-tools.lisp tests-agent/memory-tools-tests.lisp
git commit -m "feat(agent): conclude, conclude-absence, retract -- every write a decision (#14 unit 2)"
```

---

### Task 6: The planner tools — retrieve and plan-bounds

**Files:**
- Modify: `agent/planner-tools.lisp`
- Modify: `tests-agent/planner-tools-tests.lisp`

**Interfaces:**
- Consumes: `rag:fuse`, `rag:plan-bounds`, `rag:make-bounds`,
  `rag:bundle-evidence`, `rag:bundle-modes`, `rag:evidence-*`,
  `rag:chunk-text`, `rag:chunk-metadata` (`:claim-key`, Task 3),
  `claims:make-claim-source`, `mem:store-name`.
- Produces: `%retrieve-tool`, `%plan-bounds-tool`.

- [ ] **Step 1: Write the failing tests**

```lisp
;;;; tests-agent/planner-tools-tests.lisp -- spec SS7.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %seed-two-stores (w p)
  (%belief w "ci-status" '(:verdict . "green"))
  (%belief w "ci-status" '(:verdict . "red") :start "2026-09-02T08:00:00Z")
  (%belief p "owner" '(:person . "kevin")))

(test retrieve-fuses-the-scopes-claim-sources-and-cites-each-claim
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "anything"
                     "endpoints" (vector "repo:cl-llm")))
           (ev (coerce (json:jget r "evidence") 'list)))
      (is (equal '("claim") (coerce (json:jget r "modes") 'list)))
      (is (= 3 (length ev)))
      (is (every (lambda (e) (mem:cite-p (json:jget e "cite"))) ev))
      (is (equal '("cl-llm-memory" "memory-private")
                 (sort (remove-duplicates
                        (mapcar (lambda (e) (json:jget e "store")) ev)
                        :test #'string=)
                       #'string<)))
      (is (every (lambda (e) (stringp (json:jget e "text"))) ev))
      (is (stringp (json:jget r "bounds" "window" "from")))
      (is (string= "inferred" (json:jget r "bounds" "window" "standing"))))))

(test retrieve-applies-a-supplied-window-and-reports-it-asserted
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm")
                     "from" "2026-09-02T00:00:00Z" "to" "2026-09-03T00:00:00Z"))
           (keys (mapcar (lambda (e) (json:jget e "cite"))
                         (coerce (json:jget r "evidence") 'list))))
      (is (string= "asserted" (json:jget r "bounds" "window" "standing")))
      ;; green [09-01, 09-02) is known to be outside; red and the open
      ;; owner belief survive (absence is never exclusion)
      (is (= 2 (length keys))))))

(test retrieve-clamps-k-and-a-recognised-endpoint-with-nothing-is-searched-empty
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+ :k 1))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm") "k" 50)))
      (is (= 1 (length (json:jget r "evidence"))))
      (is (eq t (json:jget r "truncated"))))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:nothing-here")))
           (ev (coerce (json:jget r "evidence") 'list)))
      (is (every (lambda (e) (string= "searched-empty" (json:jget e "standing")))
                 ev))
      (is (every (lambda (e) (null (json:jget e "cite"))) ev)))))

(test plan-bounds-derives-a-window-from-the-seed
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "plan-bounds" "query" "q"
                     "endpoints" (vector "repo:cl-llm"))))
      (is (string= "2026-09-01T08:00:00.000000Z"
                   (json:jget r "window" "from")))
      (is (string= "inferred" (json:jget r "window" "standing")))
      (is (null (json:jget r "box")))
      (is (string= "searched-empty" (json:jget r "box-standing"))))))
```

`plan-bounds` in the spec takes `query` and `k`; the seed needs
endpoints to find claims, so both tools take `endpoints`. Amend the spec's
§7 sentence for `plan-bounds` to "(`query`; optional `endpoints`, `k`)"
in this task.

- [ ] **Step 2: Run to see them fail**

- [ ] **Step 3: Implement `agent/planner-tools.lisp`**

```lisp
;;;; agent/planner-tools.lisp -- retrieve and plan-bounds over the
;;;; planner.  Spec SS7.

(in-package #:cl-llm.agent)

(defun %endpoints (strings)
  "\"namespace:key\" strings as (namespace . key), split at the first
colon (namespaces are canonical [a-z0-9-])."
  (loop for s across (or strings #())
        for i = (position #\: s)
        unless i do (error "endpoint ~s is not namespace:key" s)
        collect (cons (%keyword (subseq s 0 i)) (subseq s (1+ i)))))

(defun %claim-sources (scope endpoints)
  "One claim source per store in scope, each recognising exactly
ENDPOINTS; the store rides on the source object for rendering."
  (mapcar (lambda (g)
            (claims:make-claim-source
             g 'mem:belief (lambda (q) (declare (ignore q)) endpoints)))
          (scope-stores scope)))

(defun %source-store (scope evidence)
  "The store an evidence item came from: the claim source it was
collected by, else NIL for the operator's sources."
  (let ((src (rag:evidence-source evidence)))
    (and (typep src 'claims:claim-source)
         (find (claims:claim-source-graph src) (scope-stores scope)))))

(defun %evidence-cite (evidence)
  (let ((key (getf (rag:chunk-metadata (rag:evidence-chunk evidence))
                   :claim-key)))
    (and key (format nil "cl-llm.memory::belief|~a" key))))

(defun %evidence-json (scope e)
  (let* ((store (%source-store scope e))
         (cite (%evidence-cite e)))
    (when (and cite store) (note-cite scope cite store))
    (json:jobject
     "method" (%standing (rag:evidence-method e))
     "source" (let ((s (rag:evidence-source e)))
                (and s (not (typep s 'claims:claim-source))
                     (princ-to-string s)))
     "store" (and store (mem:store-name store))
     "text" (rag:chunk-text (rag:evidence-chunk e))
     "cite" cite
     "standing" (%standing (rag:evidence-standing e))
     "confidence" (rag:evidence-confidence e)
     "valid-from" (%from (rag:evidence-extent e))
     "valid-to" (%to (rag:evidence-extent e)))))

(defun %bounds-json (b)
  (json:jobject
   "window" (let ((w (rag:bounds-window b)))
              (json:jobject "from" (%from w) "to" (%to w)
                            "standing" (%standing
                                        (rag:bounds-window-standing b))))
   "box" (let ((box (rag:bounds-box b)))
           (and box (coerce box 'vector)))
   "box-standing" (%standing (rag:bounds-box-standing b))))

(defun %window (from to)
  (and (or from to)
       (te:make-interval
        (if from (te:exact-bound (%parse-iso from)) (te:unknown-bound))
        (if to (te:exact-bound (%parse-iso to)) (te:unknown-bound))
        :semantics :validity :standing :asserted)))

(defun %seed (scope query endpoints k)
  "A first fusion with no bounds: the seed PLAN-BOUNDS derives from."
  (rag:fuse (append (%claim-sources scope endpoints) (scope-sources scope))
            query :k k))

(defun %retrieve-tool (scope)
  (llm:make-tool
   "retrieve"
   "Retrieve evidence for a query across the memory in scope: claims
touching the named endpoints (\"namespace:key\"), plus any other
sources configured, fused into one ranked list.  from/to (RFC 3339)
scope retrieval to a validity window; otherwise a window is derived
from what the query first finds and applied.  Each claim item carries
its cite for use as evidence in conclude."
   '((query :type string)
     (endpoints :type (list string) :optional t)
     (from :type string :optional t) (to :type string :optional t)
     (k :type integer :optional t))
   (lambda (query endpoints from to k)
     (let* ((k (clamp k (scope-k scope)))
            (eps (%endpoints endpoints))
            (sources (append (%claim-sources scope eps)
                             (scope-sources scope)))
            (seed (%seed scope query eps k))
            (bounds (rag:plan-bounds (rag:bundle-evidence seed)
                                     :window (%window from to)))
            (bundle (rag:fuse sources query :k k :bounds bounds))
            (evidence (rag:bundle-evidence bundle)))
       (json:to-json
        (json:jobject
         "query" query
         "modes" (map 'vector #'%standing (rag:bundle-modes bundle))
         "bounds" (%bounds-json bounds)
         "evidence" (map 'vector (lambda (e) (%evidence-json scope e))
                         evidence)
         "truncated" (%bool
                      (> (length (rag:bundle-evidence
                                  (rag:fuse sources query :k (1+ k)
                                            :bounds bounds)))
                         k))))))))

(defun %plan-bounds-tool (scope)
  (llm:make-tool
   "plan-bounds"
   "Derive the validity window and region the evidence for a query
implies, without retrieving inside it: the planner's bound as a
callable, each half with its own standing."
   '((query :type string)
     (endpoints :type (list string) :optional t)
     (k :type integer :optional t))
   (lambda (query endpoints k)
     (let* ((k (clamp k (scope-k scope)))
            (seed (%seed scope query (%endpoints endpoints) k)))
       (json:to-json (%bounds-json
                      (rag:plan-bounds (rag:bundle-evidence seed))))))))
```

Two things to verify while implementing, and to fix in place:

1. Whether `fuse` sets `evidence-source` to the source object; if it does
   not (read `rag/bundle.lisp`'s `fuse`), the claim source needs to set
   `:source source` in `%claim-evidence` (`claims/source.lisp`) — a
   one-line addition to Task 3's change, made here, with a test in
   `tests-claims`.
2. The `truncated` probe re-fuses with `k+1`; if that is too costly,
   compare `(length evidence)` to `k` and accept that an exactly-full
   page reads as truncated, and say so in the docstring.

- [ ] **Step 4: Run the agent suite until green; update spec §7 for `plan-bounds`' endpoints**

- [ ] **Step 5: Commit**

```bash
git add agent/planner-tools.lisp tests-agent/planner-tools-tests.lisp \
        docs/superpowers/specs/2026-09-03-agent-tools-design.md \
        claims/source.lisp tests-claims/source-tests.lisp
git commit -m "feat(agent): retrieve and plan-bounds over the planner (#14 unit 2)"
```

---

### Task 7: The scripted loop, errors reaching the model, and the count

**Files:**
- Modify: `tests-agent/loop-tests.lisp`

**Interfaces:**
- Consumes: `llm:make-mock-provider`, `llm:make-tool-use-part`,
  `llm:response`, `llm:ask`, `llm:conversation-messages`.

- [ ] **Step 1: Write the tests**

```lisp
;;;; tests-agent/loop-tests.lisp -- the model scripted through the
;;;; mock provider: a whole loop with no network.  Spec SS10.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %tool-use (id name &rest plist)
  (make-instance 'llm:response
                 :content (list (llm:make-tool-use-part
                                 id name (apply #'%args plist)))
                 :stop-reason :tool-use))

(defun %scripted (turns)
  "A provider that answers TURNS in order: each a function of the
conversation returning a RESPONSE or a string."
  (let ((remaining turns))
    (llm:make-mock-provider
     :responder (lambda (conversation)
                  (funcall (pop remaining) conversation)))))

(defun %last-tool-result (conversation)
  "The content of the last tool-result part the model was sent."
  (let* ((msgs (llm:conversation-messages conversation))
         (parts (llm:message-content (car (last msgs 2)))))
    (find-if (lambda (p) (typep p 'llm:tool-result-part)) parts)))

(test a-scripted-loop-recalls-then-concludes-citing-what-it-read
  (with-stores (w p)
    (%belief p "owner" '(:person . "kevin"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (seen-cite nil)
           (provider
             (%scripted
              (list
               (lambda (c) (declare (ignore c))
                 (%tool-use "t1" "recall" "subject-namespace" "repo"
                            "subject-key" "cl-llm"))
               (lambda (c)
                 (let* ((result (%last-tool-result c))
                        (r (json:parse (llm:part-content result)))
                        (cite (json:jget (first (coerce (json:jget r "records")
                                                        'list))
                                         "cite")))
                   (setf seen-cite cite)
                   (%tool-use "t2" "conclude"
                              "subject-namespace" "repo" "subject-key" "cl-llm"
                              "relation" "releasable"
                              "object-namespace" "verdict" "object-key" "yes"
                              "rule" "owner-says"
                              "evidence" (vector cite))))
               (lambda (c) (declare (ignore c)) "Done."))))
           (text (llm:ask "is it releasable?" :provider provider
                                              :tools tools)))
      (is (string= "Done." text))
      (let* ((ids (mem:decisions-citing w seen-cite :scope (list w p)))
             (rec (mem:trace w (first ids) :scope (list w p))))
        (is (= 1 (length ids)))
        (is (string= seen-cite
                     (mem:cite-record-cite
                      (first (mem:decision-record-evidence rec)))))
        (is (eq :resolved (mem:cite-record-state
                           (first (mem:decision-record-evidence rec)))))))))

(test a-tool-error-reaches-the-model-as-an-error-result
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (seen nil)
           (provider
             (%scripted
              (list
               (lambda (c) (declare (ignore c))
                 (%tool-use "t1" "recall" "subject-namespace" "repo"
                            "subject-key" "cl-llm" "at" "not-a-date"))
               (lambda (c)
                 (setf seen (%last-tool-result c))
                 "ok")))))
      (is (string= "ok" (llm:ask "?" :provider provider :tools tools)))
      (is-true (llm:part-error-p seen))
      (is (stringp (llm:part-content seen))))))

(test the-loop-is-bounded-by-max-tool-turns
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (provider (llm:make-mock-provider
                      :responder (lambda (c) (declare (ignore c))
                                   (%tool-use "t" "recall"
                                              "subject-namespace" "repo"
                                              "subject-key" "cl-llm")))))
      (signals llm:llm-tool-error
        (llm:ask "loop" :provider provider :tools tools
                        :max-tool-turns 3)))))
```

Check the exported names: `llm:message-content`, `llm:part-content`,
`llm:part-error-p`, `llm:tool-result-part`, `llm:conversation-messages`
(`src/packages.lisp`); use what is exported.

- [ ] **Step 2: Run the agent suite until green**

- [ ] **Step 3: Commit**

```bash
git add tests-agent/loop-tests.lisp
git commit -m "test(agent): a scripted loop, errors as results, the turn bound (#14 unit 2)"
```

---

### Task 8: The guarded query tool — `cl-llm/agent/prolog`

**Files:**
- Create: `agent/prolog/packages.lisp`, `agent/prolog/query.lisp`
- Create: `tests-agent-prolog/packages.lisp`, `tests-agent-prolog/query-tests.lisp`
- Modify: `cl-llm.asd`

**Interfaces:**
- Produces: `(make-query-tool stores &key (max-rows 50) (max-inferences 100000) (timeout 5)) => tool`.
- Consumes (internal, fenced): `graph-db.gui::%make-scratch-package`,
  `::%guard-context`, `::%read-guarded-forms`, `::%schema-package`,
  `graph-db::run-query-goals`, `graph-db::*query-default-max-inferences*`,
  `graph-db::*query-default-timeout*`, `graph-db::*query-default-limit*`,
  `graph-db::%query-var-field`.

- [ ] **Step 1: Systems and packages**

```lisp
(defsystem "cl-llm/agent/prolog"
  :description "A guarded free-text Prolog tool for the agent (#14 unit 2)."
  :license "MIT"
  ;; graph-db/gui carries the #279 guard and the web stack with it;
  ;; kraison/vivace-graph#322 asks for a web-free home.
  :depends-on ("cl-llm/agent" "graph-db/gui")
  :serial t
  :pathname "agent/prolog/"
  :components ((:file "packages") (:file "query"))
  :in-order-to ((test-op (test-op "cl-llm/agent/prolog/tests"))))

(defsystem "cl-llm/agent/prolog/tests"
  :description "Tests for the guarded query tool."
  :license "MIT"
  :depends-on ("cl-llm/agent/prolog" "cl-llm/agent/tests" "fiveam")
  :serial t
  :pathname "tests-agent-prolog/"
  :components ((:file "packages") (:file "query-tests"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-agent-prolog)
               (error "cl-llm/agent/prolog suite failed."))))
```

`agent/prolog/packages.lisp`:

```lisp
(defpackage #:cl-llm.agent.prolog
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm) (#:json #:cl-llm.json)
                    (#:agent #:cl-llm.agent) (#:mem #:cl-llm.memory)
                    (#:gdb #:graph-db))
  (:export #:make-query-tool))
```

`tests-agent-prolog/packages.lisp`:

```lisp
(defpackage #:cl-llm.agent.prolog/tests
  (:use #:cl #:fiveam #:cl-llm.agent/tests)
  (:local-nicknames (#:prolog #:cl-llm.agent.prolog) (#:agent #:cl-llm.agent)
                    (#:llm #:cl-llm) (#:json #:cl-llm.json)
                    (#:mem #:cl-llm.memory) (#:gdb #:graph-db)))
```

`cl-llm.agent/tests` must export `with-stores`, `%belief`, `%tool`,
`%args`, `%call`, `+p+`, `+subj+` for this — add the exports to
`tests-agent/packages.lisp` (and rename the `%`-prefixed ones without
the prefix if exporting them reads wrong: `call-tool-json`, `belief-in`,
`tool-named`, `tool-args`).

- [ ] **Step 2: Write the failing tests**

```lisp
;;;; tests-agent-prolog/query-tests.lisp -- spec SS8: the guard, the
;;;; budgets, the row cap, the scope.

(in-package #:cl-llm.agent.prolog/tests)

(def-suite :cl-llm-agent-prolog)
(in-suite :cl-llm-agent-prolog)

(test a-guarded-query-over-beliefs-returns-rows
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "last-push" '(:sha . "abc"))
    (let* ((tool (prolog:make-query-tool (list w p)))
           (r (json:parse (llm:call-tool tool
                            (%args "text" "(is-a ?c belief-binary) (node-slot-value ?c relation ?r)")))))
      (is (string= "cl-llm-memory" (json:jget r "store")))
      (is (equalp #("c" "r") (json:jget r "columns")))
      (is (= 2 (length (json:jget r "rows"))))
      (is (eq nil (json:jget r "truncated"))))))

(test query-names-a-store-in-scope
  (with-stores (w p)
    (%belief p "owner" '(:person . "kevin"))
    (let ((tool (prolog:make-query-tool (list w p))))
      (is (= 1 (length (json:jget
                        (json:parse (llm:call-tool tool
                                     (%args "text" "(is-a ?c belief-binary)"
                                            "store" "memory-private")))
                        "rows"))))
      (signals llm:llm-tool-error
        (llm:call-tool tool (%args "text" "(is-a ?c belief-binary)"
                                   "store" "elsewhere"))))))

(test the-guard-refuses-reader-syntax-with-its-own-reason
  (with-stores (w p)
    (let ((tool (prolog:make-query-tool (list w p))))
      (handler-case
          (progn (llm:call-tool tool (%args "text" "(is-a ?c #.(quit))"))
                 (fail "a #. query must be refused"))
        (llm:llm-tool-error (e)
          (is (search "#" (princ-to-string (llm:llm-error-underlying e)))))))))

(test an-excluded-or-effectful-predicate-is-refused
  (with-stores (w p)
    (let ((tool (prolog:make-query-tool (list w p))))
      (signals llm:llm-tool-error
        (llm:call-tool tool (%args "text" "(lisp ?x (+ 1 2))"))))))

(test the-inference-budget-is-the-operators
  (with-stores (w p)
    (dotimes (i 5) (%belief w (format nil "r~a" i) '(:v . "1")))
    (let ((tool (prolog:make-query-tool (list w p) :max-inferences 1)))
      (handler-case
          (progn (llm:call-tool tool
                   (%args "text" "(is-a ?a belief-binary) (is-a ?b belief-binary)"))
                 (fail "the budget must trip"))
        (llm:llm-tool-error (e)
          (is (search "inference" (string-downcase
                                   (princ-to-string
                                    (llm:llm-error-underlying e))))))))))

(test the-row-cap-is-the-operators
  (with-stores (w p)
    (dotimes (i 5) (%belief w (format nil "r~a" i) '(:v . "1")))
    (let* ((tool (prolog:make-query-tool (list w p) :max-rows 2))
           (r (json:parse (llm:call-tool tool
                            (%args "text" "(is-a ?c belief-binary)"
                                   "limit" 100)))))
      (is (= 2 (length (json:jget r "rows"))))
      (is (eq t (json:jget r "truncated"))))))
```

The `is-a` / `node-slot-value` spellings and the class name the
whitelist expects (`belief-binary` as the schema type name, maybe
kebab-cased from the class) must be checked against
`~/work/vivace-graph-v3/gui/prolog.lisp`'s `%schema-name-table` and the
engine's Prolog docs; adjust the query text, not the assertions.

- [ ] **Step 3: Implement `agent/prolog/query.lisp`**

```lisp
;;;; agent/prolog/query.lisp -- free-text Prolog through the engine's
;;;; guard, effects off, the operator's budgets.  Spec SS8.

(in-package #:cl-llm.agent.prolog)

(defun %guarded-rows (graph text limit max-inferences timeout)
  "Read, guard and run TEXT against GRAPH; (values columns rows
truncated-p).  Every symbol below is the GUI's #279 pipeline and the
DSL runner, all internal: kraison/vivace-graph#322 asks for an
exported RUN-GUARDED-PROLOG in a web-free subsystem, at which point
this body becomes one call."
  (let ((scratch (graph-db.gui::%make-scratch-package)))
    (unwind-protect
         (multiple-value-bind (vars goals)
             (graph-db.gui::%read-guarded-forms
              text scratch (graph-db.gui::%guard-context graph scratch))
           (let* ((cap (min limit graph-db::*query-default-limit*))
                  (probe (if (< cap graph-db::*query-default-limit*)
                             (1+ cap) cap))
                  (json-string
                    (let ((graph-db::*query-default-max-inferences*
                            max-inferences)
                          (graph-db::*query-default-timeout* timeout))
                      (graph-db::run-query-goals
                       vars goals graph
                       :package (graph-db.gui::%schema-package graph)
                       :limit probe :format :json)))
                  (columns (mapcar #'graph-db::%query-var-field vars))
                  (rows (coerce (json:parse json-string) 'list))
                  (truncated (if (> probe cap) (> (length rows) cap)
                                 (>= (length rows) cap))))
             (values columns
                     (subseq rows 0 (min cap (length rows)))
                     truncated)))
      (delete-package scratch))))

(defun make-query-tool (stores &key (max-rows 50) (max-inferences 100000)
                                    (timeout 5))
  "The QUERY tool over STORES (names a model may pass as store; the
first is the default).  Effects off, one snapshot, MAX-INFERENCES and
TIMEOUT (seconds) and MAX-ROWS are the operator's (SS8)."
  (llm:make-tool
   "query"
   "Run a read-only Prolog query against one memory store and get rows
back.  Goals are parenthesised forms over the store's own vertex
types and slots, e.g. (is-a ?c belief-binary) (node-slot-value ?c
relation ?r); ?variables become columns.  No side effects; bounded in
inferences, time and rows.  store names which store (default the
first); limit caps rows."
   '((text :type string)
     (store :type string :optional t)
     (limit :type integer :optional t))
   (lambda (text store limit)
     (let ((graph (if store
                      (or (find store stores :key #'mem:store-name
                                :test #'string=)
                          (error "store ~s is not in this scope" store))
                      (first stores))))
       (multiple-value-bind (columns rows truncated)
           (%guarded-rows graph text (agent::clamp limit max-rows)
                          max-inferences timeout)
         (json:to-json
          (json:jobject
           "store" (mem:store-name graph)
           "columns" (coerce columns 'vector)
           "rows" (map 'vector
                       (lambda (row)
                         (map 'vector (lambda (c) (gethash c row)) columns))
                       rows)
           "truncated" (agent::%bool truncated))))))))
```

Export `clamp` and `%bool` from `cl-llm.agent` (as `clamp` and
`json-bool`) rather than reaching for them with `::`.

- [ ] **Step 4: Run the prolog suite until green**

Load with `(ql:quickload :cl-llm/agent/prolog/tests)`; the first load
pulls ningle/clack/cl-json from Quicklisp — that is expected and is the
reason this system is separate.

- [ ] **Step 5: Commit**

```bash
git add cl-llm.asd agent/prolog/ tests-agent-prolog/ agent/packages.lisp tests-agent/packages.lisp
git commit -m "feat(agent/prolog): a guarded, budgeted free-text query tool (#14 unit 2)"
```

---

### Task 9: Docs, CI wiring, the run

**Files:**
- Create: `docs/agent-tools.md`
- Modify: `docs/agent-memory.md`, `README.md`, `docs/ci.md`, `.github/workflows/test.yml`

- [ ] **Step 1: `docs/agent-tools.md`**

Write the user's view, in the voice of `docs/agent-memory.md`, with
these sections: **One memory, partitioned by trust** (spec §2 in a
paragraph: topic is the namespace, the store is the trust boundary, the
scope is the operator's); **Declaring a store** (`define-memory-store`);
**Building the tools** (`make-agent-tools`, `make-query-tool`, every
keyword); **The tools** — one subsection per tool with its parameters
and a result example copied from a test run; **A scripted example**
(the loop from `tests-agent/loop-tests.lisp`, abridged); **What this is
not** (no cross-store consistent instant — S6b; no banner round-trip —
unit 3; the query tool loads the web stack until
kraison/vivace-graph#322).

- [ ] **Step 2: `docs/agent-memory.md`**

Add a short section **Several stores** after "Decisions and their
trace": `define-memory-store`, that an evidence claim names its store
in `method`, that `trace` and `decisions-citing` take `:scope`, with a
pointer to `docs/agent-tools.md`. In "What this is not", replace "No
tool surface, no bounded traversal," with "The tool surface is
`docs/agent-tools.md` (kraison/cl-llm#14 unit 2); no".

- [ ] **Step 3: README**

After the "Agent memory" section, before "Graph-backed stores":

```markdown
### Agent tools (`cl-llm/agent`)

`make-agent-tools` builds the tools a model uses to read and write the
agent memory: `recall`, `trace` and `decisions-citing` across a scope
of stores; `conclude`, `conclude-absence` and `retract` into one
writable store — every write a validated decision; `retrieve` and
`plan-bounds` over the retrieval planner. The scope and every bound are
the operator's at construction; the model names subjects, never
stores. `cl-llm/agent/prolog` adds `query`, guarded free-text Prolog
with effects off and budgets (it loads `graph-db/gui` until
kraison/vivace-graph#322). Guide: [`docs/agent-tools.md`](docs/agent-tools.md).
```

- [ ] **Step 4: CI**

`.github/workflows/test.yml`: extend the quickload list with
`:cl-llm/agent/tests :cl-llm/agent/prolog/tests` and add

```yaml
            --eval '(asdf:test-system :cl-llm/agent)' \
            --eval '(asdf:test-system :cl-llm/agent/prolog)'
```

after the memory line. `docs/ci.md`: the list of suites gains agent and
agent/prolog, with one sentence that the latter loads `graph-db/gui`
and its web dependencies from Quicklisp on the runner.

- [ ] **Step 5: Run everything, commit, and stop before pushing**

Run the full command from "Running tests". Expected: six `Did N checks`
lines, all 100%. Commit:

```bash
git add docs/agent-tools.md docs/agent-memory.md README.md docs/ci.md .github/workflows/test.yml
git commit -m "docs(agent): the agent tool surface; CI runs both agent suites (#14 unit 2)"
```

Do not push: the push and the PR are the repo owner's call.

---

## Self-review

**Spec coverage.** §2 → Task 2 (`define-memory-store`, second store
test), Task 4 (scope, visibility test). §4 amendments → Task 2 (all
three) and Task 3 (`:claim-key`). §5 construction → Task 4 (`make-scope`,
`make-agent-tools`, caps, store naming). §6 memory tools → Tasks 4–5,
including refusal-as-data, retract read-only error, absence rendering,
order. §7 planner → Task 6 (amended to take `endpoints`). §8 query →
Task 8 (guard, store, budgets, row cap, fence with #322). §9 bounds and
errors → Tasks 4–8 tests; errors-reach-the-model in Task 7. §10 tests →
each bullet has a test above. §11 docs → Task 9. §12 acceptance → Tasks
5, 7, 8.

**Placeholder scan.** Task 3's test fixture names and Task 8's query
spellings are flagged as "adjust to the actual names", with the
assertions fixed; Task 6 names two things to verify in place. No TBD.

**Type consistency.** `scope` accessors, `note-cite`/`cite-store`,
`clamp`, `%bool`, `%iso`/`%from`/`%to`, `%standing`/`%keyword`,
`%record-json`, `%cite-record-json`, `%decision-json` are named the
same in Tasks 4–8. `mem:conclude` evidence pairs `(cite . store-name)`
match Task 2's `%evidence-of`. `trace`'s `:scope` and
`decisions-citing`'s `:scope` are used identically in Tasks 4, 5 and 7.
`make-query-tool` takes the same `stores` list shape as
`make-agent-tools`.
