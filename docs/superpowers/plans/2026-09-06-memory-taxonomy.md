# Memory Taxonomy and a Live Retrieve Query — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent can discover what a memory store holds (`list-taxonomy`), `retrieve` finds endpoints from its query string, and a retrieve that would consult nothing says so instead of returning an empty bundle (cl-llm#64).

**Architecture:** One walk of a store's belief vertices (`memory/vocabulary.lisp`) feeds both a new read tool (`agent/taxonomy-tool.lisp`) and a lexical key extractor (`agent/extract.lisp`) that the belief claim source now uses in `retrieve`/`plan-bounds` (`agent/planner-tools.lisp`). Task 5 lands after the engine unit (vivace-graph#351) merges and adds the query-tool tests and docs for the three engine behaviours.

**Tech Stack:** SBCL, FiveAM, vivace-graph `experiment`, cl-llm memory/agent/rag layers.

**Spec:** `docs/superpowers/specs/2026-09-06-memory-taxonomy-design.md`. Engine facts: `docs/superpowers/notes/2026-09-06-memory-taxonomy-engine-api-facts.md` (read it; every signature below is verified there).

## Global Constraints

- Lisp: spaces only, hard 80 columns, terse comments pointing at #64 or the spec section.
- Worktree `/home/raison/work/cl-llm/.worktrees/taxonomy`, branch `feat/memory-taxonomy` from main 6302511. Never build, edit or commit in `/home/raison/work/cl-llm` or `/home/raison/work/vivace-graph-v3`.
- Never run `pkill`, `pgrep -f`, or `kill`. One SBCL build at a time in this worktree.
- Every name a tool emits for a namespace or relation is the canonical lowercase spelling (`%standing` of the keyword); an uncanonical namespace argument is `%keyword`'s error (#63).
- Absent fields are omitted, never null; `truncated` follows the one-past-the-cap rule.
- Docs travel with the code: each task names its doc edit.
- Commit trailer on every commit:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
  ```

## Running the suites

Registry file `/tmp/claude-1000/-home-raison-work-cl-llm/8235f26d-9ab1-4573-b1ef-c3408365e71c/scratchpad/registry-64.lisp`:

```lisp
(asdf:initialize-source-registry
 '(:source-registry
   (:tree "/home/raison/work/cl-llm/.worktrees/taxonomy/")
   (:directory "/tmp/claude-1000/-home-raison-work-cl-llm/8235f26d-9ab1-4573-b1ef-c3408365e71c/scratchpad/vg-experiment/")
   (:directory "/home/raison/work/cl-mcp/")
   :inherit-configuration))
```

One suite (`SYS` is `memory`, `agent`, `agent/prolog` or `agent/mcp`):

```bash
S=/tmp/claude-1000/-home-raison-work-cl-llm/8235f26d-9ab1-4573-b1ef-c3408365e71c/scratchpad
cd /home/raison/work/cl-llm/.worktrees/taxonomy
sbcl --dynamic-space-size 4096 --non-interactive --load "$HOME/quicklisp/setup.lisp" \
  --load "$S/registry-64.lisp" \
  --eval "(ql:quickload :cl-llm/SYS/tests :silent t)" \
  --eval "(asdf:test-system :cl-llm/SYS)" > "$S/suite-64-SYS.log" 2>&1; echo "exit=$?"
grep -E "^ *Did [0-9]+ checks|^ *Fail:" "$S/suite-64-SYS.log"
```

Baselines at 6302511: memory 453, agent 278, prolog 40, agent/mcp 136. Record every run's count; a count that drops is a deleted test.

---

### Task 1: The vocabulary walk

**Files:**
- Create: `memory/vocabulary.lisp`
- Modify: `memory/packages.lisp` (export list), `cl-llm.asd` (`cl-llm/memory` components, after `"recall"`; `cl-llm/memory/tests` components, after `"recall-tests"`), `docs/agent-memory.md` (new section after "Recall, and its order")
- Test: `tests-memory/vocabulary-tests.lisp`

**Interfaces:**
- Produces (all exported from `cl-llm.memory`): `(vocabulary graph &key include-retracted)` → `vocabulary` struct; readers `vocabulary-store`, `vocabulary-namespaces` (hash: name-string → `namespace-entry`), `vocabulary-relations` (hash: name-string → count), `vocabulary-endpoints` (list of `(namespace-keyword . key-string)`, distinct); `namespace-entry-name`, `-subjects`, `-objects`, `-keys` (hash: key-string → count); `(namespace-keys vocabulary name)` → list of `(key . count)`; `make-vocabulary &key store namespaces relations endpoints` (for tests and vivace-graph#350).

- [ ] **Step 1: Write the failing tests**

Create `tests-memory/vocabulary-tests.lisp`:

```lisp
;;;; tests-memory/vocabulary-tests.lisp -- what a store's beliefs name
;;;; (#64, spec SS2).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %vbelief (g subject relation object)
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts "2026-09-01T08:00:00Z")))))

(test vocabulary-counts-namespaces-relations-and-keys
  (with-memory-graph (g)
    (%vbelief g '(:incident . "a") "outage-root-cause" '(:cause . "x"))
    (%vbelief g '(:incident . "b") "outage-root-cause" '(:cause . "y"))
    (%vbelief g '(:project . "p") "superseded-by-project" '(:project . "q"))
    (gdb:with-transaction (:graph g)
      (mem:record-absence g '(:incident . "c") "postmortem"
                          :producer +p+ :standing :searched-empty))
    (mem:with-scope-snapshots ((list g))
      (let* ((v (mem:vocabulary g))
             (ns (mem:vocabulary-namespaces v))
             (inc (gethash "incident" ns))
             (proj (gethash "project" ns))
             (cause (gethash "cause" ns)))
        (is (eq g (mem:vocabulary-store v)))
        (is (= 3 (hash-table-count ns)))
        (is (= 3 (mem:namespace-entry-subjects inc)))
        (is (= 0 (mem:namespace-entry-objects inc)))
        (is (= 3 (hash-table-count (mem:namespace-entry-keys inc))))
        (is (= 1 (gethash "a" (mem:namespace-entry-keys inc))))
        (is (= 1 (mem:namespace-entry-subjects proj)))
        (is (= 1 (mem:namespace-entry-objects proj)))
        (is (= 2 (mem:namespace-entry-objects cause)))
        (is (= 2 (gethash "outage-root-cause" (mem:vocabulary-relations v))))
        (is (= 1 (gethash "postmortem" (mem:vocabulary-relations v))))
        (is (= 7 (length (mem:vocabulary-endpoints v))))
        (is (member '(:cause . "y") (mem:vocabulary-endpoints v)
                    :test #'equal))
        (is (equal '(("a" . 1) ("b" . 1) ("c" . 1))
                   (sort (mem:namespace-keys v "incident") #'string<
                         :key #'car)))
        (is (null (mem:namespace-keys v "nothing")))))))

(test vocabulary-counts-every-claim-on-a-key
  "Supersession keeps both claims current on the transaction axis, so
a key written twice counts twice; the walk counts claims, not values."
  (with-memory-graph (g)
    (%vbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (gdb:with-transaction (:graph g)
      (mem:record-belief g '(:repo . "cl-llm") "ci-status"
                         '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (%open-from (%ts "2026-09-02T08:00:00Z"))))
    (mem:with-scope-snapshots ((list g))
      (let* ((v (mem:vocabulary g))
             (repo (gethash "repo" (mem:vocabulary-namespaces v))))
        (is (= 2 (mem:namespace-entry-subjects repo)))
        (is (= 2 (gethash "cl-llm" (mem:namespace-entry-keys repo))))
        (is (= 2 (gethash "ci-status" (mem:vocabulary-relations v))))
        (is (= 3 (length (mem:vocabulary-endpoints v))))))))

(test vocabulary-skips-a-retracted-belief-unless-asked
  (with-memory-graph (g)
    (let ((c (%vbelief g '(:incident . "a") "outage-root-cause"
                       '(:cause . "x"))))
      (gdb:with-transaction (:graph g) (mem:retract-belief c))
      (mem:with-scope-snapshots ((list g))
        (is (= 0 (hash-table-count
                  (mem:vocabulary-namespaces (mem:vocabulary g)))))
        (is (null (mem:vocabulary-endpoints (mem:vocabulary g))))
        (let ((v (mem:vocabulary g :include-retracted t)))
          (is (= 1 (mem:namespace-entry-subjects
                    (gethash "incident" (mem:vocabulary-namespaces v))))))))))

(test make-vocabulary-builds-one-by-hand
  "The keyword constructor is the seam vivace-graph#350 and the
extractor tests use."
  (let ((v (mem:make-vocabulary :endpoints '((:a . "k")))))
    (is (equal '((:a . "k")) (mem:vocabulary-endpoints v)))
    (is (= 0 (hash-table-count (mem:vocabulary-namespaces v))))))
```

Add `(:file "vocabulary-tests")` after `(:file "recall-tests")` in the `cl-llm/memory/tests` components of `cl-llm.asd`.

- [ ] **Step 2: Run the memory suite; expect a load failure naming `mem:vocabulary`**

Run the suite for `memory`. Expected: the reader fails on `mem:vocabulary` (symbol not exported) — a failure, which is the point.

- [ ] **Step 3: Write the walk**

Create `memory/vocabulary.lisp`:

```lisp
;;;; memory/vocabulary.lisp -- what a store's beliefs name: namespaces,
;;;; relations, keys and endpoints, from one walk per call (#64 SS2).
;;;; kraison/vivace-graph#350 is the engine index that replaces the
;;;; walk behind VOCABULARY's signature.

(in-package #:cl-llm.memory)

(defstruct (namespace-entry (:constructor %make-namespace-entry (name)))
  "One namespace as the beliefs use it: claim counts by role, and the
distinct keys with a claim count each."
  name
  (subjects 0)
  (objects 0)
  (keys (make-hash-table :test 'equal)))

(defstruct (vocabulary
            (:constructor %make-vocabulary
                (store &aux (namespaces (make-hash-table :test 'equal))
                            (relations (make-hash-table :test 'equal))))
            (:constructor make-vocabulary
                (&key store
                      (namespaces (make-hash-table :test 'equal))
                      (relations (make-hash-table :test 'equal))
                      endpoints)))
  "What STORE's beliefs name.  NAMESPACES and RELATIONS map a canonical
lowercase name to a NAMESPACE-ENTRY and to a claim count; ENDPOINTS is
every distinct (namespace-keyword . key) in either role."
  store
  namespaces
  relations
  endpoints)

(defun %note-endpoint (v namespace key role seen)
  (let* ((name (string-downcase (symbol-name namespace)))
         (entry (or (gethash name (vocabulary-namespaces v))
                    (setf (gethash name (vocabulary-namespaces v))
                          (%make-namespace-entry name)))))
    (if (eq role :subject)
        (incf (namespace-entry-subjects entry))
        (incf (namespace-entry-objects entry)))
    (incf (gethash key (namespace-entry-keys entry) 0))
    (let ((pair (cons namespace key)))
      (unless (gethash pair seen)
        (setf (gethash pair seen) t)
        (push pair (vocabulary-endpoints v))))))

(defun vocabulary (graph &key include-retracted)
  "One walk of GRAPH's belief vertices, both arities, under the
caller's read snapshot.  Retracted claims are skipped unless
INCLUDE-RETRACTED (RECALL's default).  Linear in the store's beliefs;
nothing is cached.  Returns a VOCABULARY."
  (let ((v (%make-vocabulary graph))
        (seen (make-hash-table :test 'equal)))
    (dolist (class '(belief-unary belief-binary))
      (gdb:map-vertices
       (lambda (c)
         (when (or include-retracted (st:claim-current-p c))
           (%note-endpoint v (st:claim-subject-namespace c)
                           (st:claim-subject-key c) :subject seen)
           (incf (gethash (st:claim-relation c) (vocabulary-relations v) 0))
           (when (typep c 'belief-binary)
             (%note-endpoint v (st:claim-object-namespace c)
                             (st:claim-object-key c) :object seen))))
       graph :vertex-type class))
    (setf (vocabulary-endpoints v) (nreverse (vocabulary-endpoints v)))
    v))

(defun namespace-keys (vocabulary name)
  "The keys under canonical NAME as (key . count) conses, unordered;
NIL when nothing is filed there."
  (let ((entry (gethash name (vocabulary-namespaces vocabulary)))
        (pairs '()))
    (when entry
      (maphash (lambda (k n) (push (cons k n) pairs))
               (namespace-entry-keys entry)))
    pairs))
```

Add to `memory/packages.lisp` exports, after the `;; recall` block:

```lisp
   ;; vocabulary (#64)
   #:vocabulary #:make-vocabulary #:vocabulary-store
   #:vocabulary-namespaces #:vocabulary-relations #:vocabulary-endpoints
   #:namespace-entry #:namespace-entry-name #:namespace-entry-subjects
   #:namespace-entry-objects #:namespace-entry-keys #:namespace-keys
```

Add `(:file "vocabulary")` after `(:file "recall")` in the `cl-llm/memory` components of `cl-llm.asd`.

- [ ] **Step 4: Run the memory suite; expect green**

Expected: `Did 469 checks` (453 + 16), `Fail: 0`. If `gdb:map-vertices` refuses the class name, the type is registered under its package-qualified name; pass `'cl-llm.memory::belief-binary` explicitly (it already is, since this file is in that package) and read `resolve-node-type-ids` in the engine's `vertex.lisp` before changing anything else.

- [ ] **Step 5: Docs**

In `docs/agent-memory.md`, after the "Recall, and its order" section (before "## Capturing a memory directory"), add:

```markdown
## What a store names

```lisp
(mem:with-scope-snapshots ((list g))
  (mem:vocabulary g))
;; => #S(vocabulary :namespaces #<hash "repo" "verdict" ...>
;;                  :relations #<hash "ci-status" ...>
;;                  :endpoints ((:repo . "cl-llm") (:verdict . "green")))
```

`vocabulary` is one walk of a store's belief vertices under the
caller's snapshot: every namespace with its subject and object claim
counts and the keys filed under it, every relation with its count,
and every distinct endpoint. Retracted claims are skipped unless
`:include-retracted`. It is linear in the store's beliefs and caches
nothing, which is the right trade at hundreds to low thousands of
beliefs; the engine-side index that replaces the walk behind the same
function is kraison/vivace-graph#350. The agent's `list-taxonomy` and
the key extractor behind `retrieve` are its two consumers (#64).
```

- [ ] **Step 6: Commit**

```bash
git add memory/vocabulary.lisp memory/packages.lisp cl-llm.asd tests-memory/vocabulary-tests.lisp docs/agent-memory.md
git commit -F - <<'EOF'
feat(memory): vocabulary, one walk of what a store's beliefs name (#64)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
EOF
```

---

### Task 2: The `list-taxonomy` tool

**Files:**
- Create: `agent/taxonomy-tool.lisp`
- Modify: `agent/agent.lisp:5-9` (`make-memory-tools`), `cl-llm.asd` (`cl-llm/agent` components: `(:file "taxonomy-tool")` after `"memory-tools"`; `cl-llm/agent/tests`: `(:file "taxonomy-tool-tests")` after `"memory-tools-tests"`), `tests-agent-mcp/adapter-tests.lisp:26-27`, `docs/agent-tools.md` ("Building the tools" comment; new `### list-taxonomy` section before `### retrieve`)
- Test: `tests-agent/taxonomy-tool-tests.lisp`

**Interfaces:**
- Consumes: Task 1's `mem:vocabulary`, `mem:namespace-keys`, `mem:namespace-entry-*`, `mem:vocabulary-*`; `find-store`, `scope-stores`, `scope-max-rows`, `clamp` (NIL → cap), `%keyword`, `%standing`, `%bool`, `mem:store-name`.
- Produces: `(%taxonomy-tool scope)` — a tool named `"list-taxonomy"`; `make-agent-tools` now returns 9 tools.

- [ ] **Step 1: Write the failing tests**

Create `tests-agent/taxonomy-tool-tests.lisp`:

```lisp
;;;; tests-agent/taxonomy-tool-tests.lisp -- list-taxonomy (#64 SS3).

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %seed-taxonomy (w p)
  (%belief w "ci-status" '(:verdict . "green"))
  (%belief w "ci-status" '(:verdict . "red") :start "2026-09-02T08:00:00Z")
  (%belief w "outage-root-cause" '(:cause . "quill")
           :subject '(:incident . "ledger-freeze-2026-05-22"))
  (%belief w "outage-root-cause" '(:cause . "sigil")
           :subject '(:incident . "drift-b8dc70-2026"))
  (%belief p "owner" '(:person . "kevin")))

(defun %named (entries name)
  (find name (coerce entries 'list)
        :key (lambda (e) (json:jget e "name")) :test #'string=))

(defun %names (entries)
  (mapcar (lambda (e) (json:jget e "name")) (coerce entries 'list)))

(test list-taxonomy-describes-every-store-in-scope
  (with-stores (w p)
    (%seed-taxonomy w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "list-taxonomy"))
           (stores (coerce (json:jget r "stores") 'list))
           (first-store (first stores))
           (ns (json:jget first-store "namespaces"))
           (incident (%named ns "incident"))
           (repo (%named ns "repo"))
           (rel (json:jget first-store "relations")))
      (is (= 2 (length stores)))
      (is (string= "cl-llm-memory" (json:jget first-store "store")))
      (is (string= "memory-private" (json:jget (second stores) "store")))
      ;; every namespace totals 2 claims: ties break by name
      (is (equal '("cause" "incident" "repo" "verdict") (%names ns)))
      (is (= 2 (json:jget incident "subjects")))
      (is (= 0 (json:jget incident "objects")))
      (is (= 2 (json:jget incident "keys")))
      (is (equal '("drift-b8dc70-2026" "ledger-freeze-2026-05-22")
                 (coerce (json:jget incident "sample") 'list)))
      (is (= 2 (json:jget repo "subjects")))
      (is (= 1 (json:jget repo "keys")))
      (is (equal '("ci-status" "outage-root-cause") (%names rel)))
      (is (= 2 (json:jget (elt rel 0) "claims")))
      (is (equal '("person" "repo")
                 (%names (json:jget (second stores) "namespaces")))))))

(test list-taxonomy-caps-samples-and-keys-by-max-rows
  (with-stores (w p)
    (%seed-taxonomy w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+
                                                     :max-rows 1))
           (r (%call tools "list-taxonomy" "store" "cl-llm-memory"))
           (stores (coerce (json:jget r "stores") 'list))
           (incident (%named (json:jget (first stores) "namespaces")
                             "incident")))
      (is (= 1 (length stores)))
      (is (= 1 (length (json:jget incident "sample"))))
      (is (= 2 (json:jget incident "keys")) "the count is the full count")
      (let ((k (%call tools "list-taxonomy" "namespace" "incident"
                      "limit" 50)))
        (is (= 1 (length (json:jget k "keys"))))
        (is (json:jget k "truncated"))))))

(test list-taxonomy-lists-keys-under-a-namespace-across-the-scope
  (with-stores (w p)
    (%seed-taxonomy w p)
    (%belief p "owner" '(:person . "kevin")
             :subject '(:repo . "vivace-graph"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "list-taxonomy" "namespace" "repo"))
           (keys (coerce (json:jget r "keys") 'list)))
      (is (string= "repo" (json:jget r "namespace")))
      ;; claims descending, then key, then scope order
      (is (equal '(("cl-llm" "cl-llm-memory" 2)
                   ("cl-llm" "memory-private" 1)
                   ("vivace-graph" "memory-private" 1))
                 (mapcar (lambda (k) (list (json:jget k "key")
                                           (json:jget k "store")
                                           (json:jget k "claims")))
                         keys)))
      (is (eq nil (json:jget r "truncated"))))))

(test list-taxonomy-refuses-an-uncanonical-namespace-and-an-unknown-store
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (%call tools "list-taxonomy" "namespace" "INCIDENT"))
      (signals llm:llm-tool-error
        (%call tools "list-taxonomy" "store" "elsewhere"))
      (is (= 0 (length (json:jget (%call tools "list-taxonomy"
                                         "namespace" "incident")
                                  "keys")))
          "a canonical namespace nothing holds is the store's answer"))))
```

In `tests-agent-mcp/adapter-tests.lisp`, change `(is (= 8 (length names)))` to `(is (= 9 (length names)))` and add `"list-taxonomy"` to the `dolist` name list.

Add the test file to `cl-llm.asd` as listed under Files.

- [ ] **Step 2: Run the agent suite; expect failures on the four new tests**

Expected: `Fail:` > 0, each new test failing on "no tool list-taxonomy".

- [ ] **Step 3: Write the tool**

Create `agent/taxonomy-tool.lisp`:

```lisp
;;;; agent/taxonomy-tool.lisp -- list-taxonomy: what the memory in
;;;; scope names, so a read starts from a spelling the store holds,
;;;; not a guess (#64 SS3).

(in-package #:cl-llm.agent)

(defun %scope-vocabularies (scope store)
  "(graph . vocabulary) per store in scope order -- or for STORE (a
store name) alone -- under the scope snapshot."
  (let ((stores (if store
                    (list (find-store scope store))
                    (scope-stores scope))))
    (mem:with-scope-snapshots ((scope-stores scope))
      (mapcar (lambda (g) (cons g (mem:vocabulary g))) stores))))

(defun %namespace-total (entry)
  (+ (mem:namespace-entry-subjects entry)
     (mem:namespace-entry-objects entry)))

(defun %namespace-json (entry cap)
  (let ((keys (sort (loop for k being the hash-keys
                            of (mem:namespace-entry-keys entry)
                          collect k)
                    #'string<)))
    (json:jobject
     "name" (mem:namespace-entry-name entry)
     "subjects" (mem:namespace-entry-subjects entry)
     "objects" (mem:namespace-entry-objects entry)
     "keys" (length keys)
     "sample" (coerce (subseq keys 0 (min cap (length keys))) 'vector))))

(defun %count-desc-then-name (count name)
  "A predicate over (COUNT . NAME)-shaped pairs: count descending, then
name ascending."
  (lambda (a b)
    (let ((ca (funcall count a)) (cb (funcall count b)))
      (or (> ca cb)
          (and (= ca cb) (string< (funcall name a) (funcall name b)))))))

(defun %store-taxonomy-json (graph vocabulary cap)
  (let ((entries (loop for e being the hash-values
                         of (mem:vocabulary-namespaces vocabulary)
                       collect e))
        (relations (loop for name being the hash-keys
                           of (mem:vocabulary-relations vocabulary)
                             using (hash-value n)
                         collect (cons name n))))
    (json:jobject
     "store" (mem:store-name graph)
     "namespaces" (map 'vector (lambda (e) (%namespace-json e cap))
                       (sort entries
                             (%count-desc-then-name
                              #'%namespace-total
                              #'mem:namespace-entry-name)))
     "relations" (map 'vector
                      (lambda (r) (json:jobject "name" (car r)
                                                "claims" (cdr r)))
                      (sort relations
                            (%count-desc-then-name #'cdr #'car))))))

(defun %namespace-keys-json (scope namespace store limit)
  "The keys under NAMESPACE across the scope, each naming its store:
claims descending, then key, then scope order (SS3)."
  (let* ((name (%standing (%keyword namespace)))
         (cap (clamp limit (scope-max-rows scope)))
         (rows '()))
    (loop for (g . v) in (%scope-vocabularies scope store)
          for pos from 0
          do (loop for (key . n) in (mem:namespace-keys v name)
                   do (push (list key n g pos) rows)))
    (setf rows (sort rows
                     (lambda (a b)
                       (destructuring-bind (ka na ga pa) a
                         (declare (ignore ga))
                         (destructuring-bind (kb nb gb pb) b
                           (declare (ignore gb))
                           (or (> na nb)
                               (and (= na nb)
                                    (or (string< ka kb)
                                        (and (string= ka kb)
                                             (< pa pb))))))))))
    (let ((shown (subseq rows 0 (min cap (length rows)))))
      (json:to-json
       (json:jobject
        "namespace" name
        "keys" (map 'vector
                    (lambda (r)
                      (json:jobject "key" (first r)
                                    "store" (mem:store-name (third r))
                                    "claims" (second r)))
                    shown)
        "truncated" (%bool (> (length rows) cap)))))))

(defun %taxonomy-tool (scope)
  (llm:make-tool
   "list-taxonomy"
   "Discover what this memory holds before an exact read.  Without
namespace: every store's namespaces (subject and object claim counts,
distinct key count, a sample of keys) and relations (with counts).
With namespace: the keys under it across the memory in scope, each
naming its store, most-cited first.  Every name is the canonical
lowercase spelling recall and retrieve take.  Never conclude absence
from a guessed key: look here first.  store restricts to one store;
limit caps keys (clamped to the operator's max-rows; truncated says
more existed)."
   '((namespace :type string :optional t)
     (store :type string :optional t)
     (limit :type integer :optional t))
   (lambda (namespace store limit)
     (if namespace
         (%namespace-keys-json scope namespace store limit)
         (json:to-json
          (json:jobject
           "stores" (map 'vector
                         (lambda (pair)
                           (%store-taxonomy-json (car pair) (cdr pair)
                                                 (scope-max-rows scope)))
                         (%scope-vocabularies scope store))))))))
```

In `agent/agent.lisp`, `make-memory-tools` becomes:

```lisp
(defun make-memory-tools (scope)
  (list (%recall-tool scope) (%trace-tool scope)
        (%decisions-citing-tool scope)
        (%conclude-tool scope) (%conclude-absence-tool scope)
        (%retract-tool scope) (%taxonomy-tool scope)))
```

Add `(:file "taxonomy-tool")` after `(:file "memory-tools")` in `cl-llm/agent`'s components.

- [ ] **Step 4: Run the agent and agent/mcp suites; expect green**

Expected: agent `Did 304 checks` (278 + 26) `Fail: 0`; agent/mcp `Did 137 checks` (136 + 1) `Fail: 0`. If a sort order differs from the test, the test is the spec: fix the code.

- [ ] **Step 5: Docs**

In `docs/agent-tools.md`, "Building the tools": change the comment to

```lisp
;; => 9 tools: recall trace decisions-citing conclude
;;    conclude-absence retract list-taxonomy retrieve plan-bounds
```

Insert before `### \`retrieve\``:

```markdown
### `list-taxonomy`

Parameters: optional `namespace`, `store`, `limit`.

Without `namespace`, what every store in scope names, in scope order:

```json
{"stores": [
  {"store": "cl-llm-memory",
   "namespaces": [
     {"name": "incident", "subjects": 5, "objects": 0, "keys": 5,
      "sample": ["drift-b8dc70-2026", "ledger-freeze-2026-05-22"]}],
   "relations": [{"name": "outage-root-cause", "claims": 5}]}]}
```

Namespaces sort by subject plus object claims descending, then name;
relations by claims descending, then name. `sample` is the first keys
alphabetically, at most `max-rows`; `keys` is the full distinct count.

With `namespace`, the keys filed under it across the scope, each
naming its store, claims descending, then key, then scope order:

```json
{"namespace": "incident",
 "keys": [{"key": "ledger-freeze-2026-05-22", "store": "cl-llm-memory",
           "claims": 1}],
 "truncated": false}
```

`limit` clamps to `max-rows`; `truncated` follows `recall`'s rule. An
uncanonical `namespace` is the #63 error; a canonical one no store
holds returns an empty `keys` array, the store's own answer. `store`
restricts either shape to one store; an out-of-scope name is an error.

Every name here is the spelling `recall` and `retrieve` take, which
is the point: discover the address, then read it. The walk behind
this tool is `mem:vocabulary` (`docs/agent-memory.md`), linear in the
store's beliefs per call (#64).
```

- [ ] **Step 6: Commit**

```bash
git add agent/taxonomy-tool.lisp agent/agent.lisp cl-llm.asd tests-agent/taxonomy-tool-tests.lisp tests-agent-mcp/adapter-tests.lisp docs/agent-tools.md
git commit -F - <<'EOF'
feat(agent): list-taxonomy, what the memory in scope names (#64)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
EOF
```

---

### Task 3: The lexical key extractor

**Files:**
- Create: `agent/extract.lisp`
- Modify: `agent/packages.lisp` (export `#:make-key-extractor` under `;; tools`), `cl-llm.asd` (`cl-llm/agent`: `(:file "extract")` after `"render"`; `cl-llm/agent/tests`: `(:file "extract-tests")` after `"taxonomy-tool-tests"`)
- Test: `tests-agent/extract-tests.lisp`

**Interfaces:**
- Consumes: `mem:vocabulary-endpoints`, `mem:make-vocabulary`, `%standing`.
- Produces: `(make-key-extractor vocabulary &key (cap 10))` → a function of a query string returning up to CAP `(namespace-keyword . key-string)` conses, best first.

- [ ] **Step 1: Write the failing tests**

Create `tests-agent/extract-tests.lisp`:

```lisp
;;;; tests-agent/extract-tests.lisp -- the key extractor (#64 SS4.1).

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %vocab (&rest endpoints)
  (mem:make-vocabulary :endpoints endpoints))

(test the-extractor-tokenises-lowercase-runs-of-three-or-more
  (is (equal '("ledger" "freeze" "2026")
             (agent::%tokens "Ledger-Freeze 2026/05 r2 a")))
  (is (equal '("ledger") (agent::%tokens "ledger, LEDGER, ledger"))
      "distinct, first occurrence kept")
  (is (null (agent::%tokens "?? !!"))))

(test the-extractor-scores-endpoints-by-key-tokens
  (let* ((v (%vocab '(:decision . "drop-nightly-reindex")
                    '(:project . "harbor-ledger")
                    '(:incident . "ledger-freeze-2026-05-22-r2")
                    '(:incident . "ledger-freeze-2026-05-22")))
         (x (agent:make-key-extractor v)))
    ;; two tokens beat one; equal scores: the shorter key first
    (is (equal '((:incident . "ledger-freeze-2026-05-22")
                 (:incident . "ledger-freeze-2026-05-22-r2")
                 (:project . "harbor-ledger"))
               (funcall x "Why did the ledger freeze back in May?")))
    (is (equal '((:decision . "drop-nightly-reindex"))
               (funcall x "do we still run the nightly reindex")))
    (is (null (funcall x "anything at all")))
    (is (null (funcall x "incident")) "a namespace name alone selects nothing")
    (is (equal '((:project . "harbor-ledger"))
               (funcall x "harbor-ledger"))
        "the whole key matches as one token")))

(test the-extractor-prefers-a-named-namespace-and-caps
  (let* ((v (%vocab '(:person . "ledger") '(:project . "ledger")))
         (x (agent:make-key-extractor v :cap 1)))
    (is (equal '((:project . "ledger")) (funcall x "the project ledger")))
    (is (equal '((:person . "ledger")) (funcall x "ledger"))
        "no namespace hit: alphabetical on namespace:key")
    (is (= 2 (length (funcall (agent:make-key-extractor v) "ledger"))))))
```

Add the test file to `cl-llm.asd` as listed.

- [ ] **Step 2: Run the agent suite; expect the three tests to fail**

Expected: failures naming `agent:make-key-extractor` / `agent::%tokens`.

- [ ] **Step 3: Write the extractor**

Create `agent/extract.lisp`:

```lisp
;;;; agent/extract.lisp -- the belief claim source's key extractor:
;;;; the endpoints a query names, by key token, from a store's
;;;; vocabulary (#64 SS4.1).

(in-package #:cl-llm.agent)

(defun %tokens (string)
  "The lowercase runs of [a-z0-9] in STRING of length >= 3, distinct,
in first-occurrence order."
  (let ((tokens '()) (run '()))
    (flet ((flush ()
             (when run
               (let ((tok (coerce (reverse run) 'string)))
                 (when (and (>= (length tok) 3)
                            (not (member tok tokens :test #'string=)))
                   (push tok tokens))))
             (setf run '())))
      (loop for ch across (string-downcase string)
            do (if (or (char<= #\a ch #\z) (char<= #\0 ch #\9))
                   (push ch run)
                   (flush)))
      (flush))
    (nreverse tokens)))

(defun %key-tokens (key)
  "KEY lowercased, split on #\\-, plus the whole key."
  (let ((key (string-downcase key)) (parts '()) (start 0))
    (loop for i = (position #\- key :start start)
          do (push (subseq key start i) parts)
          while i do (setf start (1+ i)))
    (cons key (remove "" parts :test #'string=))))

(defun %endpoint-match (tokens endpoint)
  "(values SCORE NAMESPACE-HIT-P) for ENDPOINT against query TOKENS:
SCORE counts distinct tokens equal to a key token or the whole key."
  (let ((key-tokens (%key-tokens (cdr endpoint))))
    (values (count-if (lambda (tok) (member tok key-tokens :test #'string=))
                      tokens)
            (and (member (%standing (car endpoint)) tokens :test #'string=)
                 t))))

(defun %endpoint-name (endpoint)
  (format nil "~a:~a" (%standing (car endpoint)) (cdr endpoint)))

(defun %better-match-p (a b)
  "Over (SCORE HIT ENDPOINT) triples: score descending, a namespace
hit first, shorter key, then namespace:key alphabetically."
  (destructuring-bind (sa ha ea) a
    (destructuring-bind (sb hb eb) b
      (cond ((/= sa sb) (> sa sb))
            ((not (eq ha hb)) ha)
            ((/= (length (cdr ea)) (length (cdr eb)))
             (< (length (cdr ea)) (length (cdr eb))))
            (t (string< (%endpoint-name ea) (%endpoint-name eb)))))))

(defun make-key-extractor (vocabulary &key (cap 10))
  "A function of a query string returning up to CAP endpoints of
VOCABULARY as (namespace-keyword . key), best match first.  A token
equal to a namespace name selects nothing by itself; it breaks ties."
  (lambda (query)
    (let ((tokens (%tokens query)) (scored '()))
      (dolist (ep (mem:vocabulary-endpoints vocabulary))
        (multiple-value-bind (score hit) (%endpoint-match tokens ep)
          (when (plusp score)
            (push (list score hit ep) scored))))
      (let ((sorted (sort scored #'%better-match-p)))
        (mapcar #'third (subseq sorted 0 (min cap (length sorted))))))))
```

Export `#:make-key-extractor` from `cl-llm.agent` (under `;; tools`). Add `(:file "extract")` after `(:file "render")` in `cl-llm/agent`'s components.

- [ ] **Step 4: Run the agent suite; expect green**

Expected: `Did 316 checks` (304 + 12) `Fail: 0`.

- [ ] **Step 5: Commit**

```bash
git add agent/extract.lisp agent/packages.lisp cl-llm.asd tests-agent/extract-tests.lisp
git commit -F - <<'EOF'
feat(agent): a lexical key extractor over a store's vocabulary (#64)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
EOF
```

---

### Task 4: The query string participates in `retrieve`

**Files:**
- Modify: `agent/planner-tools.lisp` (`%claim-sources`, `%seed`, `%bounds-json`, `%retrieve-tool`, `%plan-bounds-tool`), `docs/agent-tools.md` (`retrieve` and `plan-bounds` sections)
- Test: `tests-agent/planner-tools-tests.lisp` (append)

**Interfaces:**
- Consumes: Task 3's `make-key-extractor`; Task 1's `mem:vocabulary`; `claims:claim-source-key-extractor`; `scope-sources`, `scope-k`, `%endpoints`, `%keyword`.
- Produces: `retrieve` and `plan-bounds` results carry `"endpoints"` (a vector of `"namespace:key"` strings consulted, consultation order, deduplicated across stores); both signal an error when nothing would be consulted.

- [ ] **Step 1: Write the failing tests**

Append to `tests-agent/planner-tools-tests.lisp`:

```lisp
;;; #64 SS4.2: the query string finds endpoints.

(test retrieve-finds-endpoints-in-the-query-string
  (with-stores (w p)
    (%belief w "outage-root-cause" '(:cause . "quill")
             :subject '(:incident . "ledger-freeze-2026-05-22"))
    (%belief p "owner" '(:person . "kevin"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve"
                     "query" "why did the ledger freeze in May"))
           (ev (coerce (json:jget r "evidence") 'list)))
      (is (equal '("incident:ledger-freeze-2026-05-22")
                 (coerce (json:jget r "endpoints") 'list)))
      (is (= 1 (length ev)))
      (is (search "ledger-freeze-2026-05-22" (json:jget (first ev) "text")))
      (is (mem:cite-p (json:jget (first ev) "cite")))
      (is (string= "cl-llm-memory" (json:jget (first ev) "store"))))))

(test explicit-endpoints-come-first-and-are-never-displaced
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "outage-root-cause" '(:cause . "quill")
             :subject '(:incident . "ledger-freeze-2026-05-22"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+ :k 1))
           (r (%call tools "retrieve" "query" "ledger freeze"
                     "endpoints" (vector "repo:cl-llm"))))
      ;; the union is capped at 2k = 2: the explicit one, then the best
      ;; extracted one; the explicit one is consulted in both stores
      ;; and listed once
      (is (equal '("repo:cl-llm" "incident:ledger-freeze-2026-05-22")
                 (coerce (json:jget r "endpoints") 'list)))
      (is (= 1 (length (json:jget r "evidence"))))
      (is (json:jget r "truncated")))))

(test retrieve-refuses-when-nothing-would-be-consulted
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (handler-case
          (progn (%call tools "retrieve"
                        "query" "completely unrelated banana helicopter")
                 (fail "an unconsulted retrieve must be refused"))
        (llm:llm-tool-error (e)
          (let ((text (princ-to-string (llm:llm-error-underlying e))))
            (is (search "no endpoint recognised" text))
            (is (search "banana helicopter" text))
            (is (search "list-taxonomy" text)))))
      (signals llm:llm-tool-error
        (%call tools "plan-bounds" "query" "banana helicopter")))))

(defclass %stub-source () ())

(defmethod rag:collect-evidence ((s %stub-source) query &key k bounds)
  (declare (ignore query k bounds))
  (list (rag:make-evidence
         :chunk (rag:make-chunk "stub text" :document-id "stub:1")
         :score 1d0 :method :dense :source s :standing :observed)))

(test retrieve-runs-over-an-operator-source-with-no-endpoints
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools
                   (list w p) :producer +p+
                   :sources (list (make-instance '%stub-source))))
           (r (%call tools "retrieve" "query" "banana helicopter"))
           (ev (json:jget r "evidence")))
      (is (= 0 (length (json:jget r "endpoints"))))
      (is (= 1 (length ev)))
      (is (string= "stub text" (json:jget (elt ev 0) "text")))
      (is (= 0 (length (json:jget (%call tools "plan-bounds"
                                         "query" "banana helicopter")
                                  "endpoints")))))))
```

- [ ] **Step 2: Run the agent suite; expect the four new tests to fail**

Expected: `Fail: 4` (or more, within those tests); the existing retrieve tests pass.

- [ ] **Step 3: Wire the extractor in**

In `agent/planner-tools.lisp` replace `%claim-sources` and `%seed`, and add `%consulted` / `%check-consulted`:

```lisp
(defun %claim-sources (scope endpoints)
  "One claim source per store in scope.  Each recognises ENDPOINTS
first, never displaced, then what its own vocabulary finds in the
query, the union capped at twice the scope's k (SS4.2, #64).  The
vocabularies are walked once here, under the scope snapshot; the
store rides on the source object for rendering."
  (let* ((cap (* 2 (scope-k scope)))
         (stores (scope-stores scope))
         (extractors (mem:with-scope-snapshots (stores)
                       (mapcar (lambda (g)
                                 (make-key-extractor (mem:vocabulary g)
                                                     :cap cap))
                               stores))))
    (mapcar (lambda (g extract)
              (claims:make-claim-source
               g 'mem:belief
               (lambda (query)
                 (let ((all (remove-duplicates
                             (append endpoints (funcall extract query))
                             :test #'equal :from-end t)))
                   (subseq all 0 (min cap (length all)))))))
            stores extractors)))

(defun %consulted (claim-sources query)
  "The \"namespace:key\" strings CLAIM-SOURCES will consult for QUERY,
in consultation order, each once."
  (let ((seen '()))
    (dolist (src claim-sources (nreverse seen))
      (dolist (ep (funcall (claims:claim-source-key-extractor src) query))
        (let ((name (%endpoint-name ep)))
          (unless (member name seen :test #'string=)
            (push name seen)))))))

(defun %check-consulted (scope consulted query)
  "Nothing consulted and no operator source is a refusal, never an
empty bundle a caller could read as nothing recorded (SS4.2, R3)."
  (when (and (null consulted) (null (scope-sources scope)))
    (error "no endpoint recognised in ~s: name endpoints, or call ~
list-taxonomy to see what this memory holds" query)))

(defun %seed (sources query k)
  "A first fusion with no bounds: the seed PLAN-BOUNDS derives from."
  (rag:fuse sources query :k k))
```

`%bounds-json` takes an optional endpoints vector and includes it when given (`json:jobject` is a plist function that omits NIL values; an empty vector is not NIL, so an empty `endpoints` survives):

```lisp
(defun %bounds-json (b &optional (endpoints nil endpoints-p))
  "The bounds object; with ENDPOINTS (a vector, possibly empty) the
consulted endpoints ride along -- PLAN-BOUNDS's own result (SS4.2)."
  (apply #'json:jobject
         "window" (let ((w (rag:bounds-window b)))
                    (json:jobject "from" (%from w) "to" (%to w)
                                  "standing" (%standing
                                              (rag:bounds-window-standing b))))
         "box" (let ((box (rag:bounds-box b)))
                 (and box (coerce box 'vector)))
         "box-standing" (%standing (rag:bounds-box-standing b))
         (and endpoints-p (list "endpoints" endpoints))))
```

`%retrieve-tool`'s lambda becomes:

```lisp
   (lambda (query endpoints from to k)
     (let* ((k (clamp k (scope-k scope)))
            (eps (%endpoints endpoints))
            (claim-sources (%claim-sources scope eps))
            (consulted (%consulted claim-sources query))
            (sources (append claim-sources (scope-sources scope))))
       (%check-consulted scope consulted query)
       (let* ((seed (%seed sources query k))
              (bounds (rag:plan-bounds (rag:bundle-evidence seed)
                                       :window (%window from to)))
              ;; Fuse one past the cap and cut, so TRUNCATED means more
              ;; existed -- RECALL's rule (spec SS5, #14 unit 2 final
              ;; review); an exactly-full page is not truncated.
              (bundle (rag:fuse sources query :k (1+ k) :bounds bounds))
              (fused (rag:bundle-evidence bundle))
              (evidence (subseq fused 0 (min k (length fused)))))
         ;; Seed the cache in SCOPE order, not ranking order: first-wins
         ;; must mean first-in-scope (S6b SS6, #48).
         (dolist (g (scope-stores scope))
           (dolist (e evidence)
             (let ((cite (%evidence-cite e)))
               (when (and cite (eq g (%source-store scope e)))
                 (note-cite scope cite g)))))
         (json:to-json
          (json:jobject
           "query" query
           "endpoints" (coerce consulted 'vector)
           "modes" (map 'vector #'%standing (rag:bundle-modes bundle))
           "bounds" (%bounds-json bounds)
           "evidence" (map 'vector (lambda (e) (%evidence-json scope e))
                           evidence)
           "truncated" (%bool (> (length fused) k)))))))
```

`%plan-bounds-tool`'s lambda becomes:

```lisp
   (lambda (query endpoints k)
     (let* ((k (clamp k (scope-k scope)))
            (claim-sources (%claim-sources scope (%endpoints endpoints)))
            (consulted (%consulted claim-sources query))
            (sources (append claim-sources (scope-sources scope))))
       (%check-consulted scope consulted query)
       (json:to-json
        (%bounds-json (rag:plan-bounds
                       (rag:bundle-evidence (%seed sources query k)))
                      (coerce consulted 'vector)))))
```

Update the two tool descriptions. `retrieve`:

```
"Retrieve evidence for a query across the memory in scope: claims
touching the endpoints the query names -- by key token, from what the
stores hold -- plus any \"namespace:key\" endpoints given, plus any
other sources configured, fused into one ranked list.  endpoints in
the result lists what was consulted; a query that names nothing and
lists nothing is an error, and list-taxonomy shows what to name.
from/to (RFC 3339) scope retrieval to a validity window; otherwise a
window is derived from what the query first finds and applied.  Each
claim item carries its cite for use as evidence in conclude.
truncated is true when more evidence existed past k, as in recall."
```

`plan-bounds`:

```
"Derive the validity window and region the evidence for a query
implies, without retrieving inside it: the planner's bound as a
callable, each half with its own standing.  Endpoints come from the
query as in retrieve, and endpoints in the result lists them."
```

- [ ] **Step 4: Run the agent suite; expect green**

Expected: `Did 336 checks` (316 + 20) `Fail: 0`. The annotate tests (`tests-agent/annotate-tests.lisp`) pass endpoints explicitly and must still pass; `retrieve-clamps-k-and-a-recognised-endpoint-with-nothing-is-searched-empty` must still report `searched-empty` for its explicit endpoint.

- [ ] **Step 5: Docs**

In `docs/agent-tools.md`, `### retrieve`: change the first paragraph to

```markdown
Parameters: `query`; optional `endpoints` (a list of
`"namespace:key"` strings, split at the first colon — the one place
that encoding appears, because namespaces are canonical
`[a-z0-9-]`), `from`, `to` (RFC 3339), `k`.

The query string finds endpoints on its own: it is lowercased and
split into runs of `[a-z0-9]` of three characters or more, each
store's keys are split on `-`, and an endpoint whose key shares a
token with the query (or equals it whole) is consulted, scored by the
number of matching tokens, ties broken by a namespace the query
names, then the shorter key, then `namespace:key` alphabetically.
Explicit `endpoints` come first and are never displaced; the union is
capped at twice `k` per store. So "why did the ledger freeze in May"
consults `incident:ledger-freeze-2026-05-22` with no endpoints given.
The vocabulary behind this is `mem:vocabulary`, walked once per call
(#64).
```

Add `"endpoints": ["incident:ledger-freeze-2026-05-22"],` to the JSON example after `"query"`, and after the example add:

```markdown
`endpoints` is always present: the `"namespace:key"` strings actually
consulted, in consultation order, each once across stores. A call
that would consult nothing — no endpoint named, none found, and no
operator `sources` — is an error naming the query and pointing at
`list-taxonomy`, not an empty bundle: an empty result must mean
"looked, found nothing", never "did not look" (#64). With operator
sources present the fusion runs over them alone and `endpoints` is
empty.
```

In `### plan-bounds`, append: "Endpoints come from the query as in `retrieve`; the result carries the same `endpoints` array, and the same nothing-consulted error applies."

- [ ] **Step 6: Commit**

```bash
git add agent/planner-tools.lisp tests-agent/planner-tools-tests.lisp docs/agent-tools.md
git commit -F - <<'EOF'
feat(agent): retrieve finds endpoints in its query and refuses to consult nothing (#64)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
EOF
```

---

### Task 5: The query tool after vivace-graph#351 (gated)

**Gate:** vivace-graph#351 merged to `experiment`, and the engine clone at `scratchpad/vg-experiment` fast-forwarded to that merge (`git -C <clone> pull --ff-only origin experiment`). Do not start before.

**Files:**
- Modify: `docs/agent-tools.md` (`### query` section)
- Test: `tests-agent-prolog/query-tests.lisp` (append)

- [ ] **Step 1: Write the tests**

Append to `tests-agent-prolog/query-tests.lisp`:

```lisp
;;; kraison/vivace-graph#351 (cl-llm#64): the three query-language gaps.

(test a-namespace-is-filtered-by-a-string
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "owner" '(:person . "kevin"))
    (let* ((tool (prolog:make-query-tool (list w p)))
           (rows (json:jget
                  (json:parse
                   (llm:call-tool
                    tool (%args "text"
                                (concatenate
                                 'string "(is-a ?c belief-binary) "
                                 "(node-slot-value ?c object-namespace "
                                 "\"verdict\") "
                                 "(node-slot-value ?c object-key ?k)"))))
                  "rows")))
      (is (= 1 (length rows)))
      (is (string= "green" (elt (elt rows 0) 1))))))

(test a-lookup-by-slot-needs-no-is-a
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let* ((tool (prolog:make-query-tool (list w p)))
           (rows (json:jget
                  (json:parse
                   (llm:call-tool
                    tool (%args "text"
                                (concatenate
                                 'string
                                 "(node-slot-value ?c relation \"ci-status\") "
                                 "(node-slot-value ?c object-key ?k)"))))
                  "rows")))
      (is (= 1 (length rows)))
      (is (string= "green" (elt (elt rows 0) 1))))))

(test an-unbound-slot-lists-a-beliefs-slots-lowercase
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let* ((tool (prolog:make-query-tool (list w p)))
           (rows (coerce
                  (json:jget
                   (json:parse
                    (llm:call-tool
                     tool (%args "text"
                                 (concatenate
                                  'string "(is-a ?c belief-binary) "
                                  "(node-slot-value ?c ?slot ?v)"))))
                   "rows")
                  'list))
           (slots (mapcar (lambda (r) (elt r 1)) rows)))
      (is (member "subject-namespace" slots :test #'string=))
      (is (member "relation" slots :test #'string=))
      (is (notany (lambda (s) (string/= s (string-downcase s))) slots)
          "a slot name is a keyword cell and renders lowercase (#63)"))))
```

- [ ] **Step 2: Run the prolog suite; expect green**

Expected: `Did 48 checks` (40 + 8) `Fail: 0`. A failure here means the engine clone is not at the merged HEAD: check the gate.

- [ ] **Step 3: Docs**

In `docs/agent-tools.md`, `### query`, after the sentence ending "not an object with optional fields." add:

```markdown
Three things the runner does since kraison/vivace-graph#351: a
keyword-valued slot — a namespace, a standing — is filtered by a
string, case-insensitively (`(node-slot-value ?c subject-namespace
"incident")`); an unbound node enumerates, so `(node-slot-value ?c
subject-key "x")` alone finds the claim with no `is-a`; and an
unbound slot lists a vertex's slots, `(node-slot-value ?c ?slot ?v)`,
the slot names rendering lowercase like any keyword cell.
```

- [ ] **Step 4: Commit**

```bash
git add tests-agent-prolog/query-tests.lisp docs/agent-tools.md
git commit -F - <<'EOF'
test(agent/prolog): the query tool after vivace-graph#351 (#64)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
EOF
```
