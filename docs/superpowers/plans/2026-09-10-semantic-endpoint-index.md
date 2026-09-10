# Semantic Endpoint Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `retrieve` routes a paraphrase to the endpoints it means, by
embedding one profile per endpoint in the store's own vector segment,
lexical hits first, with nothing stale ever searchable.

**Architecture:** `cl-llm/memory` gains an `endpoint-vector` vertex per
endpoint (its `embedding` slot `:vector-index t`), a profile renderer, a
write-path touch that clears the vectors of the endpoints a belief write
changes, and an indexer (a drain, a worker thread, a start-time segment
reset) that takes an embedding *function* and a model name.
`cl-llm/agent` wraps a `rag:embedder` with its floor into an
`endpoint-embedder` on the scope and gives `retrieve` a hybrid extractor:
today's lexical matches first, then dense candidates above the floor.
The image and the solo server read the embedder from the environment and
host the worker; empty configuration leaves everything inert.

**Tech Stack:** SBCL 2.6.6, ASDF, Quicklisp; vivace-graph `experiment`
b787516 (`graph-db/spacetime`, vector segments); `cl-llm/rag` embedders;
`bordeaux-threads`; `fiveam`.

**Spec:** `docs/superpowers/specs/2026-09-10-semantic-memory-indexing-design.md`
(kraison/cl-llm#78). Section numbers (§) below refer to it. Engine facts:
`docs/superpowers/notes/2026-09-10-semantic-index-engine-facts.md` (E1–E12).

## Global Constraints

- Lisp: spaces only, never tabs; hard 80-column limit in code, comments,
  docstrings and strings; terse comments naming #78 or a spec section.
- `cl-llm/memory` depends on the engine, `ironclad`, `babel` and (from
  Task 3) `bordeaux-threads` only. It never depends on `cl-llm`,
  `cl-llm/rag` or `cl-llm/rag/claims` (§5). The embedder reaches it as a
  function `(lambda (text) vector)` plus a model string.
- Every write-path change runs inside the caller's transaction (E8);
  nothing in the write path calls the embedding function (§4.2, test 8).
- A vector is "present" only when the slot holds a
  `(simple-array single-float (*))` (E2, §2.5).
- With no embedder configured, every existing suite must pass with its
  current check counts (§7 test 9): memory 489, agent 347, agent/mcp 163
  (at main 3e3e17a against engine b787516).
- Suites run in a subprocess, never in a shared image; one SBCL at a
  time, foreground, timeout ≥ 5 min; never `pkill`, `pgrep -f`, `kill`;
  never touch ports 4007–4029, `~/.cl-llm-memory*`, `~/work/cl-llm`
  (main) or `~/work/vg-c3` (the engine clone, read-only).
  Registry: `/home/raison/work/vg-c3-notes/registry-78.lisp` (exists).
- Docs travel with the code: every task that adds behaviour touches
  `docs/agent-memory.md` or `docs/agent-tools.md` in the same commit.
- Commit trailers:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013BfdWuKGebCvLBKsbU753o`.

Running a suite (SYS one of `memory`, `agent`, `agent/mcp`):

```bash
N=/home/raison/work/vg-c3-notes
cd /home/raison/work/cl-llm/.worktrees/semantic-index
SYS=memory; L=$(echo $SYS | tr / -)
sbcl --dynamic-space-size 4096 --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" --load "$N/registry-78.lisp" \
  --eval "(ql:quickload :cl-llm/$SYS/tests :silent t)" \
  --eval "(asdf:test-system :cl-llm/$SYS)" > "$N/suite-78-$L.log" 2>&1
echo "exit=$?"; grep -E "^ *Did [0-9]+ checks|^ *Fail:" "$N/suite-78-$L.log"
```

One test: same preamble, then
`--eval "(ql:quickload :cl-llm/$SYS/tests :silent t)" --eval "(let ((r (fiveam:run '<pkg>::<test>))) (fiveam:explain! r) (sb-ext:exit :code (if (fiveam:results-status r) 0 1)))"`
(`<pkg>` is `cl-llm.memory/tests`, `cl-llm.agent/tests` or
`cl-llm.agent.mcp/tests`). The fixtures set the system directory
themselves, so a bare `run` works here (unlike the engine's own suites).

---

## File structure

| file | responsibility |
|---|---|
| `memory/schema.lisp` | `endpoint-vector` and its two named declarations inside `define-memory-store` (§2.5) |
| `memory/profile.lisp` (new) | current beliefs of an endpoint, the profile text, the vector predicate, `touch-endpoints` (§2, §4.2) |
| `memory/write.lisp` | the touch calls at the create, supersede and retract points (§4.2, E8) |
| `memory/index.lisp` (new) | `nearest-endpoints`, `drain-endpoint-vectors`, `rebuild-endpoint-vectors`, `reset-endpoint-segment`, the worker (§3.3, §4.3–4.4) |
| `memory/packages.lisp` | exports |
| `agent/extract.lisp` | `endpoint-embedder`, `make-hybrid-key-extractor` (§3) |
| `agent/scope.lisp`, `agent/agent.lisp`, `agent/planner-tools.lisp`, `agent/memory-tools.lisp` | the embedder on the scope, passed to the extractors; the query embedded once per call; `conclude`/`retract` notify |
| `agent/mcp/config.lisp`, `agent/mcp/adapter.lisp` | `embedder-from-env`, `make-memory-server :embedder` (§5) |
| `scripts/memory-image.lisp`, `scripts/memory-mcp.lisp` | dimension reset before the listener, worker start/stop in the lifecycle (§4.3 step 4, §4.5) |
| `tests-memory/profile-tests.lisp`, `tests-memory/index-tests.lisp` (new) | Tasks 1–3 |
| `tests-agent/harness.lisp`, `tests-agent/extract-tests.lisp`, `tests-agent/planner-tools-tests.lisp` | the synonym-table embedder; routing tests (Task 4) |
| `tests-agent-mcp/config-tests.lisp` | the environment parse (Task 5) |
| `cl-llm.asd` | the new files; `bordeaux-threads` on `cl-llm/memory` |
| `docs/agent-memory.md`, `docs/agent-tools.md` | the feature, the variables, the calibration recipe |

---

### Task 1: Schema, profile, and the touch

**Files:**
- Modify: `memory/schema.lisp` (inside `define-memory-store`, before `',graph-name`)
- Create: `memory/profile.lisp`
- Modify: `memory/packages.lisp`, `cl-llm.asd` (`cl-llm/memory` components after `"write"`; tests after `"vocabulary-tests"`)
- Test: `tests-memory/profile-tests.lisp`
- Docs: `docs/agent-memory.md` (a new subsection "Endpoint profiles" after "What a store names")

**Interfaces:**
- Consumes: `st:claims-touching`, `%open-p`, `%start-instant` (write.lisp), `gdb:index-lookup`, `gdb:copy`/`gdb:save`.
- Produces (exported): `current-beliefs (graph namespace key)` → claims newest validity first; `endpoint-profile (graph namespace key &key (cap *profile-cap*))` → string or NIL; `endpoint-vector-of (graph namespace key)` → the vertex or NIL; `endpoint-vector-value (vertex)` → the conforming vector or NIL; `endpoint-dirty-p (graph namespace key &optional model)`; `touch-endpoints (graph endpoints)`; the class `endpoint-vector` with readers `ev-namespace`, `ev-key`, `ev-model` (verify the reader names `def-vertex` generates, E1's probe read them; fall back to `slot-value` if none are generated and say so in the report).

- [ ] **Step 1: Write the failing tests**

```lisp
;;;; tests-memory/profile-tests.lisp -- endpoint profiles and the touch
;;;; (#78 SS2, SS4.2).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %pbelief (g subject relation object &optional (start "2026-08-30T08:00:00Z"))
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts start)))))

(test a-profile-lists-the-current-beliefs-of-an-endpoint-in-both-roles
  (with-memory-graph (g)
    (%pbelief g '(:incident . "ledger-rollback-2026-08-30") "root-cause"
              '(:cause . "replica-checksum-mismatch"))
    (%pbelief g '(:decision . "freeze-deploys") "decided-because"
              '(:incident . "ledger-rollback-2026-08-30") "2026-08-31T08:00:00Z")
    (mem:with-scope-snapshots ((list g))
      (let ((text (mem:endpoint-profile g :incident "ledger-rollback-2026-08-30")))
        (is (stringp text))
        (is (search "incident ledger rollback 2026 08 30" text)
            "the key as words: ~a" text)
        (is (search "root-cause cause:replica-checksum-mismatch" text))
        (is (search "decision:freeze-deploys decided-because" text)
            "the object role too")
        (is (search +p+ text) "the producer")
        (is (< (search "root-cause" text) (search "decided-because" text))
            "subject role first, then object role")))))

(test a-superseded-or-retracted-belief-leaves-the-profile
  (with-memory-graph (g)
    (let ((old (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))))
      (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "red")
                "2026-08-31T08:00:00Z")
      (mem:with-scope-snapshots ((list g))
        (let ((text (mem:endpoint-profile g :repo "cl-llm")))
          (is (search "verdict:red" text))
          (is (null (search "verdict:green" text)) "superseded: gone"))
        (is (null (mem:endpoint-profile g :verdict "green"))
            "an endpoint with nothing current has no profile"))
      (gdb:with-transaction (:graph g) (mem:retract-belief old))
      (is (null (mem:endpoint-profile g :verdict "green"))))))

(test an-absence-is-never-a-profile-line
  (with-memory-graph (g)
    (gdb:with-transaction (:graph g)
      (mem:record-absence g '(:repo . "cl-llm") "ci-status"
                          :producer +p+ :standing :searched-empty))
    (is (null (mem:endpoint-profile g :repo "cl-llm")))
    (is (null (mem:endpoint-vector-of g :repo "cl-llm"))
        "and recording it touched nothing")))

(test the-profile-is-capped-newest-first
  (with-memory-graph (g)
    (dotimes (i 5)
      (%pbelief g '(:repo . "cl-llm") (format nil "rel~D" i)
                (cons :thing (format nil "t~D" i))
                (format nil "2026-08-~2,'0DT08:00:00Z" (1+ i))))
    (let ((text (mem:endpoint-profile g :repo "cl-llm" :cap 2)))
      (is (search "thing:t4" text))
      (is (search "thing:t3" text))
      (is (null (search "thing:t2" text)) "cap 2 keeps the newest two"))))

(test touching-clears-the-vector-and-creates-the-vertex
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (let ((ev (mem:endpoint-vector-of g :repo "cl-llm")))
      (is (not (null ev)) "the write created the vertex")
      (is (null (mem:endpoint-vector-value ev)))
      (is (mem:endpoint-dirty-p g :repo "cl-llm" "m")))
    ;; Store a vector by hand, then touch: it must be gone.
    (gdb:with-transaction (:graph g)
      (let ((c (gdb:copy (mem:endpoint-vector-of g :repo "cl-llm"))))
        (setf (slot-value c 'mem::embedding)
              (make-array 4 :element-type 'single-float
                            :initial-element 0.5f0)
              (slot-value c 'mem::ev-model) "m")
        (gdb:save c)))
    (is (not (mem:endpoint-dirty-p g :repo "cl-llm" "m")))
    (is (mem:endpoint-dirty-p g :repo "cl-llm" "other-model")
        "a vector from another model reads as dirty")
    (gdb:with-transaction (:graph g)
      (mem:touch-endpoints g '((:repo . "cl-llm"))))
    (is (null (mem:endpoint-vector-value (mem:endpoint-vector-of g :repo "cl-llm"))))
    (is (mem:endpoint-dirty-p g :repo "cl-llm" "m"))))

(test an-idempotent-record-touches-nothing
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (gdb:with-transaction (:graph g)
      (let ((c (gdb:copy (mem:endpoint-vector-of g :repo "cl-llm"))))
        (setf (slot-value c 'mem::embedding)
              (make-array 4 :element-type 'single-float
                            :initial-element 0.5f0)
              (slot-value c 'mem::ev-model) "m")
        (gdb:save c)))
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (is (not (null (mem:endpoint-vector-value
                    (mem:endpoint-vector-of g :repo "cl-llm"))))
        "the same object again writes nothing and clears nothing")))

(test superseding-touches-the-old-object-endpoint
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (dolist (ep '((:repo . "cl-llm") (:verdict . "green")))
      (gdb:with-transaction (:graph g)
        (let ((c (gdb:copy (mem:endpoint-vector-of g (car ep) (cdr ep)))))
          (setf (slot-value c 'mem::embedding)
                (make-array 4 :element-type 'single-float
                              :initial-element 0.5f0)
                (slot-value c 'mem::ev-model) "m")
          (gdb:save c))))
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "red")
              "2026-08-31T08:00:00Z")
    (is (null (mem:endpoint-vector-value (mem:endpoint-vector-of g :verdict "green")))
        "the superseded belief's object endpoint lost a line")
    (is (null (mem:endpoint-vector-value (mem:endpoint-vector-of g :repo "cl-llm"))))
    (is (not (null (mem:endpoint-vector-of g :verdict "red")))
        "the new object endpoint exists, dirty")))

(test a-retract-touches-both-endpoints
  (with-memory-graph (g)
    (let ((b (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))))
      (dolist (ep '((:repo . "cl-llm") (:verdict . "green")))
        (gdb:with-transaction (:graph g)
          (let ((c (gdb:copy (mem:endpoint-vector-of g (car ep) (cdr ep)))))
            (setf (slot-value c 'mem::embedding)
                  (make-array 4 :element-type 'single-float
                                :initial-element 0.5f0)
                  (slot-value c 'mem::ev-model) "m")
            (gdb:save c))))
      (gdb:with-transaction (:graph g) (mem:retract-belief b))
      (is (null (mem:endpoint-vector-value (mem:endpoint-vector-of g :repo "cl-llm"))))
      (is (null (mem:endpoint-vector-value (mem:endpoint-vector-of g :verdict "green")))))))
```

Check what `%open-from` and `%ts` are called in `tests-memory/` (the
vocabulary tests use `%open-from` on a timestamp; reuse the harness's
helpers, do not redefine them).

- [ ] **Step 2: Run the tests to verify they fail**

Run the single test `a-profile-lists-the-current-beliefs-of-an-endpoint-in-both-roles`.
Expected: FAIL (undefined function `endpoint-profile`) — after adding the
file to the system in Step 3 with an empty body it must fail on the
assertions, not on a compile error of the suite.

- [ ] **Step 3: Schema and the profile module**

In `memory/schema.lisp`, inside the `progn` of `define-memory-store`,
after the `memory-banner` source and before `',graph-name`:

```lisp
     ;; The semantic endpoint index (#78 SS2.5): one vertex per endpoint;
     ;; EMBEDDING holding no conforming vector means lexical-only.  Two
     ;; named declarations: DEF-INDEX looks up, DEF-UNIQUE enforces (E5).
     (gdb:def-vertex endpoint-vector ()
       ((ev-namespace :type keyword)
        (ev-key       :type string)
        (ev-model     :type string)
        (embedding    :type (simple-array single-float (*))
                      :vector-index t))
       ,graph-name)
     (gdb:def-index endpoint-vector (ev-namespace ev-key) ,graph-name
       :name ev-endpoint-index)
     (gdb:def-unique endpoint-vector (ev-namespace ev-key) ,graph-name
       :name ev-endpoint-identity)
```

`memory/profile.lisp`:

```lisp
;;;; memory/profile.lisp -- an endpoint's active profile: the text the
;;;; semantic index embeds, and the touch that clears its vector when a
;;;; write changes it (#78 SS2, SS4.2).

(in-package #:cl-llm.memory)

(defparameter *profile-cap* 32
  "Belief lines a profile keeps, newest validity first (SS2.2).")

(defun current-beliefs (graph namespace key)
  "GRAPH's beliefs on (NAMESPACE . KEY) in either role that are
current in recall's sense -- not retracted, validity open -- newest
validity first.  Trap: an absence is an instant and never open."
  (sort (remove-if-not #'%open-p
                       (st:claims-touching graph 'belief namespace key
                                           :role :either :current t))
        (lambda (a b) (local-time:timestamp> (%start-instant a)
                                             (%start-instant b)))))

(defun %endpoint-words (namespace key)
  (format nil "~(~a~) ~a" namespace (substitute #\Space #\- key)))

(defun %profile-line (claim)
  "CLAIM in RENDER-CLAIM's shape (the memory does not depend on
cl-llm/rag): ns:key relation [ns:key] (producer, standing, valid from
DATE)."
  (let ((start (%start-instant claim)))
    (format nil "~(~a~):~a ~a~@[ ~(~a~):~a~] (~a, ~(~a~), valid from ~a)"
            (st:claim-subject-namespace claim) (st:claim-subject-key claim)
            (st:claim-relation claim)
            (and (typep claim 'belief-binary)
                 (st:claim-object-namespace claim))
            (and (typep claim 'belief-binary) (st:claim-object-key claim))
            (st:claim-producer claim) (st:claim-standing claim)
            (local-time:format-timestring nil start
                                          :format '(:year "-" (:month 2)
                                                    "-" (:day 2))))))
```

Check the `~@[ ~(~a~):~a~]` directive: `~@[` consumes one argument and
prints the clause only when it is non-NIL, but the clause needs TWO
arguments (namespace, key). Write it as two explicit branches instead:

```lisp
(defun %profile-line (claim)
  (let* ((start (%start-instant claim))
         (date (local-time:format-timestring
                nil start :format '(:year "-" (:month 2) "-" (:day 2))))
         (object (and (typep claim 'belief-binary)
                      (format nil " ~(~a~):~a"
                              (st:claim-object-namespace claim)
                              (st:claim-object-key claim)))))
    (format nil "~(~a~):~a ~a~a (~a, ~(~a~), valid from ~a)"
            (st:claim-subject-namespace claim) (st:claim-subject-key claim)
            (st:claim-relation claim) (or object "")
            (st:claim-producer claim) (st:claim-standing claim) date)))

(defun endpoint-profile (graph namespace key &key (cap *profile-cap*))
  "The profile text of (NAMESPACE . KEY) in GRAPH under the caller's
snapshot: the endpoint as words, then one line per current belief, the
subject role first, at most CAP lines.  NIL when nothing is current."
  (let ((claims (current-beliefs graph namespace key)))
    (when claims
      (let ((subject (remove-if-not
                      (lambda (c) (and (eq namespace (st:claim-subject-namespace c))
                                       (string= key (st:claim-subject-key c))))
                      claims))
            (object (remove-if
                     (lambda (c) (and (eq namespace (st:claim-subject-namespace c))
                                      (string= key (st:claim-subject-key c))))
                     claims)))
        (let ((lines (append subject object)))
          (format nil "~a~%~{~a~^~%~}" (%endpoint-words namespace key)
                  (mapcar #'%profile-line
                          (subseq lines 0 (min cap (length lines))))))))))

(defun endpoint-vector-of (graph namespace key)
  "The ENDPOINT-VECTOR vertex of (NAMESPACE . KEY) in GRAPH, or NIL."
  (find-if-not #'gdb:deleted-p
               (gdb:index-lookup graph 'endpoint-vector
                                 '(ev-namespace ev-key)
                                 (list namespace key))))

(defun endpoint-vector-value (vertex)
  "VERTEX's embedding when it is a conforming vector, else NIL --
unbound and NIL both mean no vector (E2)."
  (let ((v (and (slot-boundp vertex 'embedding)
                (slot-value vertex 'embedding))))
    (and (typep v '(simple-array single-float (*))) v)))

(defun endpoint-dirty-p (graph namespace key &optional model)
  "True when the endpoint has a current belief and no vector, or a
vector from another MODEL (SS4.1)."
  (and (current-beliefs graph namespace key)
       (let ((ev (endpoint-vector-of graph namespace key)))
         (or (null ev)
             (null (endpoint-vector-value ev))
             (and model (string/= model (slot-value ev 'ev-model)))))
       t))

(defun touch-endpoints (graph endpoints)
  "Clear the vector of every (NAMESPACE . KEY) in ENDPOINTS, creating
the vertex when absent; each once.  Must run inside the caller's
transaction (SS4.2).  Never embeds."
  (dolist (ep (remove-duplicates endpoints :test #'equal))
    (let ((ev (endpoint-vector-of graph (car ep) (cdr ep))))
      (if ev
          (when (endpoint-vector-value ev)
            (let ((c (gdb:copy ev)))
              (setf (slot-value c 'embedding) nil
                    (slot-value c 'ev-model) "")
              (gdb:save c)))
          (make-endpoint-vector :graph graph
                                :ev-namespace (car ep) :ev-key (cdr ep)
                                :ev-model "")))))
```

Verify `make-endpoint-vector`'s lambda list from the `def-vertex`
expansion (the belief constructors take `:graph`; E1's probe wrote one
successfully). If the generated constructor has a different name or
requires `embedding`, adapt and say so in the report. `index-lookup`
returns nodes (E5); if it returns something else, adapt.

Exports in `memory/packages.lisp` (a new `;; endpoint profiles (#78)`
group): `#:endpoint-vector #:ev-namespace #:ev-key #:ev-model
#:current-beliefs #:endpoint-profile #:*profile-cap* #:endpoint-vector-of
#:endpoint-vector-value #:endpoint-dirty-p #:touch-endpoints`. Export the
reader names only if `def-vertex` generates them.

`cl-llm.asd`: `(:file "profile")` after `"write"` in `cl-llm/memory`;
`(:file "profile-tests")` after `"vocabulary-tests"` in the tests.

- [ ] **Step 4: The touch in the write path**

`memory/write.lisp`, `record-belief`: replace the tail from `(when pred`
to the end with

```lisp
    (when pred
      (cond ((%same-object-p object pred)
             (return-from record-belief pred))
            ((not (local-time:timestamp< (%start-instant pred) start))
             (error 'belief-successor-before-predecessor
                    :predecessor pred :start start))
            (t (%close-validity pred start)
               ;; The predecessor's object endpoint loses a line (#78).
               (touch-endpoints graph
                                (list (cons (st:claim-object-namespace pred)
                                            (st:claim-object-key pred)))))))
    (let ((new (make-belief-binary
                :graph graph
                :subject-namespace (car subject) :subject-key (cdr subject)
                :relation relation
                :object-namespace (car object) :object-key (cdr object)
                :producer producer :standing standing :extent extent
                :confidence confidence :method method
                :rule-version rule-version)))
      (touch-endpoints graph (list subject object))
      new)))
```

`retract-belief`: after `(st:retract-claim claim :at at)` bind its result
and touch:

```lisp
  (let ((graph (or (graph-db::resolve-node-graph (gdb:id claim))
                   gdb:*graph*)))
    (prog1 (st:retract-claim claim :at at)
      ;; Both endpoints lose a line (#78 SS4.2).  RESOLVE-NODE-GRAPH is
      ;; internal (noted on kraison/vivace-graph#322), as in %CLAIM-STORE.
      (touch-endpoints graph
                       (list* (cons (st:claim-subject-namespace claim)
                                    (st:claim-subject-key claim))
                              (and (typep claim 'belief-binary)
                                   (list (cons (st:claim-object-namespace claim)
                                               (st:claim-object-key claim)))))))))
```

`record-absence` is untouched (§2.2, §4.2). `profile.lisp` loads after
`write.lisp` but `write.lisp` calls `touch-endpoints`: that is a
function call resolved at run time, fine under `:serial t`; add
`(declaim (ftype function touch-endpoints))` at the top of `write.lisp`
if the compiler warns.

- [ ] **Step 5: Run the profile tests, then the memory suite**

Expected: `profile-tests` all PASS; memory suite 489 + the new checks,
0 failures. Record the count.

- [ ] **Step 6: Docs**

`docs/agent-memory.md`, after "What a store names": a subsection
"Endpoint profiles" (8–12 lines): what a profile is, recall-current
membership, absences excluded, the cap, and that every belief write
clears the touched endpoints' vectors so the index is never stale
(#78, spec §2, §4.2). State that with no embedder configured the
vertices exist but carry no vector.

- [ ] **Step 7: Commit**

```bash
git add memory/schema.lisp memory/profile.lisp memory/write.lisp memory/packages.lisp cl-llm.asd tests-memory/profile-tests.lisp docs/agent-memory.md
git commit -m "memory: endpoint profiles and the write-path touch for the semantic index (#78)"
```

---

### Task 2: The indexer — nearest, drain, rebuild, reset

**Files:**
- Create: `memory/index.lisp`
- Modify: `memory/packages.lisp`, `cl-llm.asd` (`cl-llm/memory` gains `"bordeaux-threads"` in `:depends-on`; `(:file "index")` after `"profile"`; tests `(:file "index-tests")` after `"profile-tests"`)
- Test: `tests-memory/index-tests.lisp`
- Docs: `docs/agent-memory.md` (the same subsection gains the drain and rebuild)

**Interfaces:**
- Consumes: Task 1's functions; `gdb:vector-search`, `gdb:lookup-vertex`, `mem:vocabulary`, `with-scope-snapshots`; the engine internals `graph-db::vector-segments`, `graph-db::segment-dimension`, `graph-db::rebuild-vector-segment` (E3; read their definitions in `~/work/vg-c3/segment.lisp` and `transactions.lisp` for the exact lambda lists before use).
- Produces (exported): `nearest-endpoints (graph query-vector &key (k 10) model)` → list of `((namespace . key) . cosine)` best first; `dirty-endpoints (graph &optional model)`; `drain-endpoint-vectors (stores &key embed model)` → count embedded; `rebuild-endpoint-vectors (stores &key embed model)`; `reset-endpoint-segment (graph dimension)` → T when it reset; the worker in Task 3.

- [ ] **Step 1: Write the failing tests**

```lisp
;;;; tests-memory/index-tests.lisp -- the semantic index's drain,
;;;; nearest, rebuild and reset (#78 SS3.3, SS4).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %counting-embed (dimension &key (fail-times 0))
  "=> (values EMBED COUNTER): EMBED maps text to a DIMENSION vector
whose first component is 1 (so every vector is nearest every other),
counting calls in COUNTER's car; the first FAIL-TIMES calls signal."
  (let ((counter (list 0)) (failures fail-times))
    (values (lambda (text)
              (declare (ignore text))
              (incf (car counter))
              (when (plusp failures)
                (decf failures)
                (error "embedder down"))
              (let ((v (make-array dimension :element-type 'single-float
                                             :initial-element 0f0)))
                (setf (aref v 0) 1f0)
                v))
            counter)))

(test the-drain-embeds-every-dirty-endpoint-once
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (is (equal '((:repo . "cl-llm") (:verdict . "green"))
                 (sort (copy-list (mem:dirty-endpoints g "m"))
                       #'string< :key #'cdr)))
      (is (= 2 (mem:drain-endpoint-vectors (list g) :embed embed :model "m")))
      (is (= 2 (car counter)))
      (is (null (mem:dirty-endpoints g "m")))
      (is (= 0 (mem:drain-endpoint-vectors (list g) :embed embed :model "m"))
          "nothing dirty, nothing embedded")
      (is (= 2 (car counter))))))

(test nearest-returns-endpoints-best-first-and-skips-other-models
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4) :model "m")
    (let ((q (make-array 4 :element-type 'single-float :initial-element 0f0)))
      (setf (aref q 0) 1f0)
      (let ((hits (mem:nearest-endpoints g q :k 5 :model "m")))
        (is (= 2 (length hits)))
        (is (every (lambda (h) (> (cdr h) 0.99)) hits))
        (is (member '(:repo . "cl-llm") hits :key #'car :test #'equal)))
      (is (null (mem:nearest-endpoints g q :k 5 :model "other"))
          "a vector from another model is not a hit"))))

(test a-write-clears-and-the-next-drain-restores
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
      (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "red")
                "2026-08-31T08:00:00Z")
      (let ((q (make-array 4 :element-type 'single-float :initial-element 0f0)))
        (setf (aref q 0) 1f0)
        (is (null (mem:nearest-endpoints g q :k 5 :model "m"))
            "every touched endpoint is unsearchable until re-embedded")
        (is (= 2 (car counter)) "and the write embedded nothing")
        (is (= 2 (mem:drain-endpoint-vectors (list g) :embed embed :model "m"))
            "repo and verdict:red; verdict:green has nothing current")
        (is (null (mem:endpoint-vector-value
                   (mem:endpoint-vector-of g :verdict "green"))))
        (is (= 2 (length (mem:nearest-endpoints g q :k 5 :model "m"))))))))

(test a-model-change-re-embeds-everything
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4) :model "a")
    (is (= 2 (length (mem:dirty-endpoints g "b"))))
    (is (= 2 (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4) :model "b")))
    (is (null (mem:dirty-endpoints g "b")))))

(test rebuild-re-embeds-clean-endpoints-too
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
      (is (= 2 (mem:rebuild-endpoint-vectors (list g) :embed embed :model "m")))
      (is (= 4 (car counter))))))

(test reset-lets-a-new-dimension-in
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4) :model "m")
    (signals error
      (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 8) :model "n")
      "control: the segment keeps its dimension")
    (is (eq t (mem:reset-endpoint-segment g 8)))
    (is (= 2 (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 8) :model "n")))
    (is (null (mem:reset-endpoint-segment g 8)) "same dimension: no-op")))

(test the-drain-skips-a-failing-embedder-and-keeps-the-endpoint-dirty
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4 :fail-times 1)
      (signals error (mem:drain-endpoint-vectors (list g) :embed embed :model "m"))
      (is (= 1 (car counter)))
      (is (= 2 (length (mem:dirty-endpoints g "m"))) "nothing was written")
      (is (= 2 (mem:drain-endpoint-vectors (list g) :embed embed :model "m"))))))
```

The `control` in `reset-lets-a-new-dimension-in` relies on the engine's
`vector-dimension-violation` at commit (E3); `signals error` is enough,
but name the condition in the message.

- [ ] **Step 2: Run one test to verify it fails**

Run `the-drain-embeds-every-dirty-endpoint-once`. Expected: FAIL on an
undefined function.

- [ ] **Step 3: Implement `memory/index.lisp`**

```lisp
;;;; memory/index.lisp -- the semantic endpoint index: nearest by
;;;; vector, the drain that embeds the derived dirty set, the rebuild,
;;;; the start-time segment reset, and the worker (#78 SS3.3, SS4).
;;;; The embedder is a FUNCTION (text -> vector) plus a model name:
;;;; this system never depends on cl-llm/rag (SS5).

(in-package #:cl-llm.memory)

(defun nearest-endpoints (graph query-vector &key (k 10) model)
  "The endpoints of GRAPH whose profile vectors are nearest
QUERY-VECTOR by cosine, as ((NAMESPACE . KEY) . COSINE) best first, at
most K; a vertex that is deleted, holds no vector, or (with MODEL) was
embedded by another model is skipped.  NIL when no segment exists yet."
  (let ((hits (gdb:vector-search graph 'endpoint-vector 'embedding
                                 query-vector k)))
    (loop for (score . id) in hits
          for ev = (gdb:lookup-vertex id :graph graph)
          when (and ev (not (gdb:deleted-p ev))
                    (endpoint-vector-value ev)
                    (or (null model)
                        (string= model (slot-value ev 'ev-model))))
            collect (cons (cons (slot-value ev 'ev-namespace)
                                (slot-value ev 'ev-key))
                          score))))

(defun dirty-endpoints (graph &optional model)
  "The endpoints of GRAPH that need embedding under MODEL (SS4.1), from
the vocabulary (count-index backed, #70)."
  (with-scope-snapshots ((list graph))
    (remove-if-not (lambda (ep) (endpoint-dirty-p graph (car ep) (cdr ep) model))
                   (vocabulary-endpoints (vocabulary graph)))))

(defun %store-vector (graph namespace key vector model)
  "Write VECTOR and MODEL on the endpoint's vertex in one transaction."
  (gdb:with-transaction (:graph graph)
    (let ((ev (endpoint-vector-of graph namespace key)))
      (if ev
          (let ((c (gdb:copy ev)))
            (setf (slot-value c 'embedding) vector
                  (slot-value c 'ev-model) model)
            (gdb:save c))
          (make-endpoint-vector :graph graph :ev-namespace namespace
                                :ev-key key :ev-model model
                                :embedding vector)))))

(defun %embed-endpoint (graph namespace key embed model)
  "Render, embed and store one endpoint; => T when a vector was
written, NIL when nothing is current (the vertex then keeps no vector).
An error from EMBED propagates, leaving the endpoint dirty."
  (let ((text (with-scope-snapshots ((list graph))
                (endpoint-profile graph namespace key))))
    (when text
      (%store-vector graph namespace key (funcall embed text) model)
      t)))

(defun drain-endpoint-vectors (stores &key embed model)
  "Embed every dirty endpoint of every store in STORES with EMBED under
MODEL, in the calling thread; => the number embedded.  An EMBED error
propagates after the endpoints before it were stored.  Trap: a write
racing the drain clears the vector again -- the last writer wins, and
the worker's notification re-drains."
  (let ((n 0))
    (dolist (g stores n)
      (dolist (ep (dirty-endpoints g model))
        (when (%embed-endpoint g (car ep) (cdr ep) embed model)
          (incf n))))))

(defun rebuild-endpoint-vectors (stores &key embed model)
  "Clear every vector in STORES, then DRAIN-ENDPOINT-VECTORS; => the
number embedded."
  (dolist (g stores)
    (gdb:with-transaction (:graph g)
      (gdb:map-vertices (lambda (ev)
                          (when (endpoint-vector-value ev)
                            (let ((c (gdb:copy ev)))
                              (setf (slot-value c 'embedding) nil
                                    (slot-value c 'ev-model) "")
                              (gdb:save c))))
                        g :vertex-type 'endpoint-vector)))
  (drain-endpoint-vectors stores :embed embed :model model))
```

Check `gdb:map-vertices`'s exact keyword for the type filter
(`:vertex-type`, as `%vocabulary-by-walk` used before #70; see git
history of `memory/vocabulary.lisp` at 4821733) and whether it may be
called inside a transaction; if not, collect the vertices first, then
write.

```lisp
(defun %endpoint-segment (graph)
  "GRAPH's segment for ENDPOINT-VECTOR.EMBEDDING, or NIL.  Engine
internals (E3; an export is asked of the engine)."
  (gethash (cons 'endpoint-vector 'embedding)
           (graph-db::vector-segments graph)))

(defun reset-endpoint-segment (graph dimension)
  "When GRAPH's endpoint segment exists with a dimension other than
DIMENSION, clear every vector and rebuild the segment so vectors of
DIMENSION are accepted; => T when it reset, NIL otherwise.  Must run
before anything can search -- at start, before the listener and the
worker (SS4.3 step 4): the engine's rebuild is unsafe against a
concurrent VECTOR-SEARCH."
  (let ((seg (%endpoint-segment graph)))
    (when (and seg (/= dimension (graph-db::segment-dimension seg)))
      (gdb:with-transaction (:graph graph)
        (gdb:map-vertices (lambda (ev)
                            (when (endpoint-vector-value ev)
                              (let ((c (gdb:copy ev)))
                                (setf (slot-value c 'embedding) nil
                                      (slot-value c 'ev-model) "")
                                (gdb:save c))))
                          graph :vertex-type 'endpoint-vector))
      (graph-db::rebuild-vector-segment graph 'endpoint-vector 'embedding)
      t)))
```

Read `rebuild-vector-segment`'s lambda list (segment.lisp:606) and the
key shape of `vector-segments` (`%segment-key`, transactions.lisp) — the
owner is the declaring class name, which is `endpoint-vector` here — and
adapt the two internal calls. Record the exact forms in the report and
add a comment naming the engine issue (the controller files it; use
"kraison/vivace-graph, exported segment reset" until the number exists).

Exports: `#:nearest-endpoints #:dirty-endpoints #:drain-endpoint-vectors
#:rebuild-endpoint-vectors #:reset-endpoint-segment`.

- [ ] **Step 4: Run the index tests, then the memory suite**

Expected: all PASS; memory suite count recorded.

- [ ] **Step 5: Docs and commit**

`docs/agent-memory.md`, the "Endpoint profiles" subsection gains: the
dirty set is derived (no vector and something current), the drain, the
rebuild, and the reset at start when the dimension changes.

```bash
git add memory/index.lisp memory/packages.lisp cl-llm.asd tests-memory/index-tests.lisp docs/agent-memory.md
git commit -m "memory: the semantic index -- nearest endpoints, the drain over the derived dirty set, rebuild and segment reset (#78)"
```

---

### Task 3: The worker

**Files:**
- Modify: `memory/index.lisp` (append), `memory/packages.lisp`
- Test: `tests-memory/index-tests.lisp` (append)
- Docs: `docs/agent-memory.md`

**Interfaces:**
- Consumes: Task 2; `bordeaux-threads` (`bt:make-lock`, `bt:make-condition-variable`, `bt:condition-wait` with `:timeout`, `bt:condition-notify`, `bt:make-thread`, `bt:join-thread`).
- Produces (exported): `start-endpoint-indexer (stores &key embed model (name "endpoint-indexer"))` → an `endpoint-indexer`; `notify-endpoint-indexer (&optional indexer)`; `stop-endpoint-indexer (indexer)`; `endpoint-indexer-embedded (indexer)` → count so far; `wait-endpoint-indexer (indexer &key (timeout 10))` → T when the queue is empty and idle; the special `*endpoint-indexer*` (the process's worker, NIL when none).

- [ ] **Step 1: Write the failing tests** (append to `index-tests.lisp`)

```lisp
(test the-worker-drains-after-a-notify-and-stops-cleanly
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (let ((w (mem:start-endpoint-indexer (list g) :embed embed :model "m")))
        (unwind-protect
             (progn
               (is (mem:wait-endpoint-indexer w :timeout 10)
                   "the start-up sweep drains")
               (is (= 2 (car counter)))
               (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "red")
                         "2026-08-31T08:00:00Z")
               (is (= 2 (car counter)) "the write embedded nothing")
               (mem:notify-endpoint-indexer w)
               (is (mem:wait-endpoint-indexer w :timeout 10))
               (is (= 4 (car counter)) "repo and verdict:red")
               (is (null (mem:dirty-endpoints g "m"))))
          (mem:stop-endpoint-indexer w))
        (is (not (bt:thread-alive-p (mem::endpoint-indexer-thread w))))))))

(test the-worker-backs-off-on-an-embedder-error-and-retries
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4 :fail-times 1)
      (let ((w (mem:start-endpoint-indexer (list g) :embed embed :model "m"
                                                     :backoff 0.2)))
        (unwind-protect
             (progn
               (is (mem:wait-endpoint-indexer w :timeout 15))
               (is (= 3 (car counter)) "one failure, then both")
               (is (null (mem:dirty-endpoints g "m"))))
          (mem:stop-endpoint-indexer w))))))

(test notify-without-a-worker-is-a-no-op
  (let ((mem:*endpoint-indexer* nil))
    (finishes (mem:notify-endpoint-indexer))))
```

- [ ] **Step 2: Run the first test to verify it fails**

- [ ] **Step 3: Implement the worker** (append to `memory/index.lisp`)

```lisp
(defvar *endpoint-indexer* nil
  "This process's worker, or NIL when no embedder is configured.
NOTIFY-ENDPOINT-INDEXER with no argument uses it (SS4.5).")

(defstruct (endpoint-indexer (:constructor %make-endpoint-indexer))
  stores embed model thread
  (lock (bt:make-lock "endpoint-indexer"))
  (cv (bt:make-condition-variable :name "endpoint-indexer"))
  (pending t)        ; a notify arrived since the last drain began
  (idle nil)         ; the last drain found nothing and no notify since
  (stop-p nil)
  (embedded 0)
  (backoff 1.0)      ; seconds before the next attempt after an error
  (max-backoff 60.0)
  (failing nil))     ; T once an error was logged for this outage

(defun %indexer-log (control &rest args)
  (ignore-errors
   (apply #'format *error-output* control args)
   (finish-output *error-output*)))

(defun %indexer-loop (w)
  (let ((delay nil))
    (loop
      (bt:with-lock-held ((endpoint-indexer-lock w))
        (loop until (or (endpoint-indexer-stop-p w)
                        (endpoint-indexer-pending w))
              do (if delay
                     (progn
                       (bt:condition-wait (endpoint-indexer-cv w)
                                          (endpoint-indexer-lock w)
                                          :timeout delay)
                       (setf (endpoint-indexer-pending w) t))
                     (bt:condition-wait (endpoint-indexer-cv w)
                                        (endpoint-indexer-lock w))))
        (when (endpoint-indexer-stop-p w) (return))
        (setf (endpoint-indexer-pending w) nil
              (endpoint-indexer-idle w) nil))
      (handler-case
          (let ((n (drain-endpoint-vectors (endpoint-indexer-stores w)
                                           :embed (endpoint-indexer-embed w)
                                           :model (endpoint-indexer-model w))))
            (bt:with-lock-held ((endpoint-indexer-lock w))
              (incf (endpoint-indexer-embedded w) n)
              (setf delay nil
                    (endpoint-indexer-backoff w) 1.0)
              (when (endpoint-indexer-failing w)
                (%indexer-log "~&endpoint indexer: embedder back~%")
                (setf (endpoint-indexer-failing w) nil))
              (unless (endpoint-indexer-pending w)
                (setf (endpoint-indexer-idle w) t)
                (bt:condition-notify (endpoint-indexer-cv w)))))
        (error (c)
          (bt:with-lock-held ((endpoint-indexer-lock w))
            (unless (endpoint-indexer-failing w)
              (%indexer-log "~&endpoint indexer: embedder failed: ~a; ~
                             retrying with backoff~%" c)
              (setf (endpoint-indexer-failing w) t))
            (setf delay (endpoint-indexer-backoff w)
                  (endpoint-indexer-backoff w)
                  (min (endpoint-indexer-max-backoff w)
                       (* 2 (endpoint-indexer-backoff w))))))))))

(defun start-endpoint-indexer (stores &key embed model (backoff 1.0)
                                          (name "endpoint-indexer"))
  "Start the worker over STORES with EMBED (text -> vector) and MODEL:
a sweep at once, then a drain after every NOTIFY-ENDPOINT-INDEXER; an
embedder error is logged once per outage and retried with a doubling
BACKOFF (seconds, capped at 60).  => the ENDPOINT-INDEXER, also set as
*ENDPOINT-INDEXER*.  Trap: stop it before closing the stores."
  (let ((w (%make-endpoint-indexer :stores stores :embed embed :model model
                                   :backoff backoff)))
    (setf (endpoint-indexer-thread w)
          (bt:make-thread (lambda () (%indexer-loop w)) :name name))
    (setf *endpoint-indexer* w)))

(defun notify-endpoint-indexer (&optional (indexer *endpoint-indexer*))
  "Wake INDEXER to drain; a no-op when there is none."
  (when indexer
    (bt:with-lock-held ((endpoint-indexer-lock indexer))
      (setf (endpoint-indexer-pending indexer) t
            (endpoint-indexer-idle indexer) nil)
      (bt:condition-notify (endpoint-indexer-cv indexer))))
  nil)

(defun wait-endpoint-indexer (indexer &key (timeout 10))
  "Block until INDEXER has drained and is idle, or TIMEOUT seconds;
=> T when idle.  For tests and scripted sessions (SS4.4)."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (bt:with-lock-held ((endpoint-indexer-lock indexer))
        (when (endpoint-indexer-idle indexer) (return t)))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.05))))

(defun stop-endpoint-indexer (indexer)
  "Stop INDEXER and join its thread; clears *ENDPOINT-INDEXER* when it
was this one.  Idempotent."
  (when indexer
    (bt:with-lock-held ((endpoint-indexer-lock indexer))
      (setf (endpoint-indexer-stop-p indexer) t)
      (bt:condition-notify (endpoint-indexer-cv indexer)))
    (let ((thread (endpoint-indexer-thread indexer)))
      (when (and thread (bt:thread-alive-p thread))
        (bt:join-thread thread)))
    (when (eq indexer *endpoint-indexer*)
      (setf *endpoint-indexer* nil)))
  nil)
```

`bt:condition-wait`'s `:timeout` exists in bordeaux-threads on SBCL
(check the installed version's `condition-wait` lambda list with
`describe`; if absent, replace the timed wait with a loop of short
untimed waits driven by a `sleep`-then-notify helper thread, and say so).
`wait-endpoint-indexer` polls the idle flag rather than waiting on the
condition variable, so a test cannot miss a notify.

Exports: `#:*endpoint-indexer* #:endpoint-indexer #:start-endpoint-indexer
#:notify-endpoint-indexer #:wait-endpoint-indexer #:stop-endpoint-indexer
#:endpoint-indexer-embedded`.

- [ ] **Step 4: Run the worker tests and the memory suite**

Expected: PASS; the three worker tests run under 30 s together.

- [ ] **Step 5: Docs and commit**

`docs/agent-memory.md`: the subsection gains the worker: one per
process, sweep at start, drain on notify, backoff, `wait-endpoint-indexer`
for scripts.

```bash
git add memory/index.lisp memory/packages.lisp tests-memory/index-tests.lisp docs/agent-memory.md
git commit -m "memory: the endpoint indexer worker -- sweep at start, drain on notify, backoff on an embedder outage (#78)"
```

---

### Task 4: Routing — the hybrid extractor, the embedder on the scope

**Files:**
- Modify: `agent/extract.lisp`, `agent/scope.lisp`, `agent/agent.lisp`, `agent/planner-tools.lisp`, `agent/memory-tools.lisp`, `agent/packages.lisp`
- Modify: `tests-agent/harness.lisp` (the synonym-table embedder), `tests-agent/extract-tests.lisp`, `tests-agent/planner-tools-tests.lisp`
- Docs: `docs/agent-tools.md` (`retrieve`), `docs/agent-memory.md` ("Building the tools")

**Interfaces:**
- Consumes: `rag:embedder`, `rag:embed`, `rag:embedder-model`; Task 2's `mem:nearest-endpoints`, Task 3's `mem:notify-endpoint-indexer`.
- Produces (exported): `endpoint-embedder` struct with readers `endpoint-embedder-embedder`, `-model`, `-floor`, `-embed` (the `(lambda (text) vector)` for the memory layer); `make-endpoint-embedder (embedder &key floor)`; `make-hybrid-key-extractor (graph vocabulary endpoint-embedder &key (cap 10) query-vector)`; `scope-embedder`; `make-agent-tools ... :embedder`.

- [ ] **Step 1: The synonym-table embedder** (append to `tests-agent/harness.lisp`)

```lisp
;;; A deterministic embedder for the semantic index tests (#78 SS7):
;;; each concept is one dimension; a word not in the table hashes into
;;; the upper half, so unrelated words never touch a concept.
(defparameter +concepts+
  '(("rollback" "reverted" "revert" "rolled" "undo" "undone")
    ("deploy" "deployment" "release" "shipped" "rollout")
    ("database" "db" "store" "replica")
    ("outage" "incident" "failure" "broke")
    ("cause" "reason" "because" "why" "root")
    ("reindex" "reindexing" "index" "maintenance")
    ("nightly" "periodic" "scheduled" "cron")
    ("checksum" "mismatch" "corrupt")
    ("august" "2026" "08")
    ("ledger" "ledgers")
    ("freeze" "frozen" "halt")))

(defparameter +embed-dimension+ 32)

(defclass %synonym-embedder (rag:embedder) ()
  (:default-initargs :model "synonym-test"))

(defun %concept-index (word)
  (or (position-if (lambda (row) (member word row :test #'string=))
                   +concepts+)
      (+ (length +concepts+)
         (mod (rag::string-hash word)
              (- +embed-dimension+ (length +concepts+))))))

(defmethod rag:embed ((e %synonym-embedder) input)
  (flet ((one (text)
           (let ((v (make-array +embed-dimension+ :element-type 'double-float
                                                  :initial-element 0d0)))
             (dolist (w (rag::words text))
               (incf (aref v (%concept-index w)) 1d0))
             (rag:as-embedding v))))
    (if (listp input) (mapcar #'one input) (one input))))

(defun %embedder (&key (floor 0.3))
  (agent:make-endpoint-embedder (make-instance '%synonym-embedder)
                                :floor floor))
```

`rag::words` splits on space, newline, tab, comma, period, semicolon and
colon (E9; rag/embed.lisp:196); a profile line's `ns:key` therefore
splits at the colon, and hyphenated keys stay one word — which is why
§2.2 writes the endpoint's own key as words on the first line. Check
that `rag:as-embedding` and `rag::string-hash` are reachable (export or
double-colon) and that the test package has a `rag` nickname
(`tests-agent/packages.lisp`).

- [ ] **Step 2: Write the failing routing tests**

Append to `tests-agent/extract-tests.lisp`:

```lisp
(test the-hybrid-extractor-is-lexical-first-then-dense-fill
  "#78 R2: lexical hits keep their order and come first; dense candidates
above the floor fill the cap; the identifier in the query is never
displaced by a decoy whose profile embeds nearer."
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "replica-checksum-mismatch")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (%belief w "root-cause" '(:cause . "rollback-reverted-deploy")
             :subject '(:incident . "sigil-fb73e8e9e67"))
    (let ((ee (%embedder)))
      (mem:drain-endpoint-vectors (list w) :embed (agent:endpoint-embedder-embed ee)
                                           :model "synonym-test")
      (mem:with-scope-snapshots ((list w))
        (let* ((v (mem:vocabulary w))
               (x (agent:make-hybrid-key-extractor w v ee :cap 4))
               (lexical (agent:make-key-extractor v :cap 4)))
          (is (equal '((:incident . "sigil-fb73e8e9e67"))
                     (subseq (funcall x "why was sigil-fb73e8e9e67 reverted") 0 1))
              "the exact identifier is first although the decoy embeds nearer")
          (is (null (funcall lexical "why was the deployment reverted in august")))
          (let ((dense (funcall x "why was the deployment reverted in august")))
            (is (member '(:incident . "ledger-rollback-2026-08-30") dense
                        :test #'equal)
                "the paraphrase routes: ~s" dense))
          (is (null (funcall x "tell me about the pelican migration"))
              "below the floor: nothing")
          (is (equal (funcall lexical "ledger")
                     (subseq (funcall x "ledger") 0 (length (funcall lexical "ledger"))))
              "lexical order is kept ahead of the fill"))))))

(test the-hybrid-extractor-without-an-embedder-is-the-lexical-one
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "bad-deploy")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (mem:with-scope-snapshots ((list w))
      (let ((v (mem:vocabulary w)))
        (is (equal (funcall (agent:make-key-extractor v) "ledger rollback")
                   (funcall (agent:make-hybrid-key-extractor w v nil) "ledger rollback")))))))

(test make-endpoint-embedder-requires-a-model-name
  (signals error (agent:make-endpoint-embedder (rag:make-mock-embedder) :floor 0.5))
  (let ((ee (agent:make-endpoint-embedder (make-instance '%synonym-embedder) :floor 0.4)))
    (is (string= "synonym-test" (agent:endpoint-embedder-model ee)))
    (is (= 0.4 (agent:endpoint-embedder-floor ee)))
    (is (= +embed-dimension+ (length (funcall (agent:endpoint-embedder-embed ee) "x"))))))
```

Append to `tests-agent/planner-tools-tests.lisp`:

```lisp
(test retrieve-routes-a-paraphrase-through-the-semantic-index
  "#78 SS7 test 1: the lexical route finds nothing; the dense fill does,
and retrieve cites the belief.  Control: no embedder refuses."
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "replica-checksum-mismatch")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (let* ((ee (%embedder))
           (tools (agent:make-agent-tools (list w p) :producer +p+ :embedder ee))
           (plain (agent:make-agent-tools (list w p) :producer +p+)))
      (mem:drain-endpoint-vectors (list w) :embed (agent:endpoint-embedder-embed ee)
                                           :model "synonym-test")
      (signals llm:llm-tool-error
        (%call plain "retrieve" "query" "why was the deployment reverted in august"))
      (let ((r (%call tools "retrieve" "query" "why was the deployment reverted in august")))
        (is (equal '("incident:ledger-rollback-2026-08-30")
                   (coerce (json:jget r "endpoints") 'list)))
        (is (= 1 (length (json:jget r "evidence"))))
        (is (search "replica-checksum-mismatch"
                    (json:jget (elt (json:jget r "evidence") 0) "text")))))))

(test retrieve-still-refuses-an-unindexed-topic-with-an-embedder
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "replica-checksum-mismatch")
             :subject '(:incident . "ledger-rollback-2026-08-30"))
    (let* ((ee (%embedder))
           (tools (agent:make-agent-tools (list w p) :producer +p+ :embedder ee)))
      (mem:drain-endpoint-vectors (list w) :embed (agent:endpoint-embedder-embed ee)
                                           :model "synonym-test")
      (handler-case
          (progn (%call tools "retrieve" "query" "tell me about the pelican migration")
                 (fail "must refuse"))
        (llm:llm-tool-error (e)
          (is (search "no endpoint recognised"
                      (princ-to-string (llm:llm-error-underlying e)))))))))

(test retrieve-embeds-the-query-once-per-call-across-stores
  (with-stores (w p)
    (%belief w "root-cause" '(:cause . "x") :subject '(:incident . "ledger-rollback"))
    (%belief p "root-cause" '(:cause . "y") :subject '(:incident . "ledger-freeze"))
    (let* ((calls 0)
           (base (make-instance '%synonym-embedder))
           (ee (agent:make-endpoint-embedder base :floor 0.3))
           (tools (agent:make-agent-tools (list w p) :producer +p+ :embedder ee)))
      (mem:drain-endpoint-vectors (list w p) :embed (agent:endpoint-embedder-embed ee)
                                             :model "synonym-test")
      ;; Count query embeddings only: wrap the generic after the drain.
      (let ((old (fdefinition 'rag:embed)))
        (unwind-protect
             (progn
               (setf (fdefinition 'rag:embed)
                     (lambda (e input) (incf calls) (funcall old e input)))
               (%call tools "retrieve" "query" "why was the deployment reverted")
               (is (= 1 calls) "one embedding for two stores, got ~a" calls))
          (setf (fdefinition 'rag:embed) old))))))

(test conclude-and-retract-notify-the-indexer-and-never-embed
  "#78 SS7 test 8: the write path embeds nothing; it wakes the worker."
  (with-stores (w p)
    (let* ((calls 0) (notified 0)
           (ee (%embedder))
           (tools (agent:make-agent-tools (list w p) :producer +p+ :embedder ee))
           (old (fdefinition 'mem:notify-endpoint-indexer))
           (old-embed (fdefinition 'rag:embed)))
      (unwind-protect
           (progn
             (setf (fdefinition 'mem:notify-endpoint-indexer)
                   (lambda (&optional i) (declare (ignore i)) (incf notified) nil)
                   (fdefinition 'rag:embed)
                   (lambda (e input) (incf calls) (funcall old-embed e input)))
             (let ((r (%call tools "conclude"
                             "proposal" (%args "subject" "incident:ledger-rollback"
                                               "relation" "root-cause"
                                               "object" "cause:bad-deploy")
                             "rule" "test" "evidence" #())))
               (is (= 0 calls))
               (is (= 1 notified))
               (%call tools "retract" "cite" (json:jget r "cite"))
               (is (= 0 calls))
               (is (= 2 notified))))
        (setf (fdefinition 'mem:notify-endpoint-indexer) old
              (fdefinition 'rag:embed) old-embed)))))
```

Read `conclude`'s and `retract`'s tool argument shapes in
`tests-agent/memory-tools-tests.lisp` and use the exact ones (the
`proposal` object and `evidence` shapes above are a guess); the point of
the test is the two counters. `fdefinition` on a generic function works
in SBCL (the extractor tests of #68 used the same probe on
`gdb:lookup-vertex`).

- [ ] **Step 3: Run one routing test to verify it fails**

- [ ] **Step 4: Implement**

`agent/extract.lisp`, append:

```lisp
(defstruct (endpoint-embedder (:constructor %make-endpoint-embedder))
  "A rag EMBEDDER with the MODEL it names and the cosine FLOOR a dense
candidate must clear (#78 R3, R7).  EMBED is the (text -> vector)
function the memory layer takes."
  embedder model floor embed)

(defun make-endpoint-embedder (embedder &key floor)
  "Wrap EMBEDDER for the semantic index.  EMBEDDER must name a model
\(RAG:EMBEDDER-MODEL, recorded per vector); FLOOR is required, a real
in [0, 1]."
  (let ((model (rag:embedder-model embedder)))
    (unless (and (stringp model) (plusp (length model)))
      (error "the embedder names no model; the index records one per vector"))
    (unless (and (realp floor) (<= 0 floor 1))
      (error "FLOOR must be a real in [0, 1], not ~s" floor))
    (%make-endpoint-embedder
     :embedder embedder :model model :floor floor
     :embed (lambda (text) (rag:embed embedder text)))))

(defun make-hybrid-key-extractor (graph vocabulary endpoint-embedder
                                  &key (cap 10) query-vector)
  "A function of a query string returning up to CAP endpoints of GRAPH
as (namespace-keyword . key): VOCABULARY's lexical matches first, in
MAKE-KEY-EXTRACTOR's order, then the endpoints whose profile embeds
nearest the query at cosine >= the embedder's floor, best first.
QUERY-VECTOR is a function of the query returning its embedding (the
caller memoises it across stores); default embeds each call.
ENDPOINT-EMBEDDER NIL is MAKE-KEY-EXTRACTOR.  Trap: an endpoint touched
by a write and not yet re-embedded is reachable lexically only."
  (let ((lexical (make-key-extractor vocabulary :cap cap)))
    (if (null endpoint-embedder)
        lexical
        (let ((qv (or query-vector (endpoint-embedder-embed endpoint-embedder)))
              (floor (endpoint-embedder-floor endpoint-embedder))
              (model (endpoint-embedder-model endpoint-embedder)))
          (lambda (query)
            (let* ((l (funcall lexical query))
                   (room (- cap (length l))))
              (if (plusp room)
                  (let ((dense (loop for (ep . score)
                                       in (mem:nearest-endpoints
                                           graph (funcall qv query)
                                           :k cap :model model)
                                     when (and (>= score floor)
                                               (not (member ep l :test #'equal)))
                                       collect ep)))
                    (append l (subseq dense 0 (min room (length dense)))))
                  l)))))))
```

`agent/scope.lisp`: the struct gains `embedder`; `make-scope` takes
`&key embedder`, checks `(or (null embedder) (endpoint-embedder-p embedder))`
else `%scope-error`, and passes it. `agent/agent.lisp`:
`make-agent-tools` takes `embedder` and passes it; the docstring names
it. `agent/planner-tools.lisp`, `%claim-sources`: build one memo per
call and pass it:

```lisp
  (let* ((cap (* 2 (scope-k scope)))
         (stores (scope-stores scope))
         (ee (scope-embedder scope))
         (cache (make-hash-table :test 'equal))
         (qv (and ee (lambda (q)
                       (or (gethash q cache)
                           (setf (gethash q cache)
                                 (funcall (endpoint-embedder-embed ee) q))))))
         (extractors (mem:with-scope-snapshots (stores)
                       (mapcar (lambda (g)
                                 (make-hybrid-key-extractor
                                  g (mem:vocabulary g) ee
                                  :cap cap :query-vector qv))
                               stores))))
```

(the rest unchanged). `agent/memory-tools.lisp`: after `conclude`'s and
`retract`'s transactions commit (read the two tool bodies), call
`(mem:notify-endpoint-indexer)`; `conclude-absence` does not (absences
touch nothing).

Exports in `agent/packages.lisp`: `#:endpoint-embedder
#:make-endpoint-embedder #:endpoint-embedder-p #:endpoint-embedder-embedder
#:endpoint-embedder-model #:endpoint-embedder-floor #:endpoint-embedder-embed
#:make-hybrid-key-extractor #:scope-embedder`.

- [ ] **Step 5: Run the agent suite**

Expected: 347 + the new checks, 0 failures. Also re-run the memory
suite (unchanged) and record both counts.

- [ ] **Step 6: Docs and commit**

`docs/agent-tools.md`, `retrieve`: after the lexical paragraph, one
paragraph: with an embedder configured, endpoints the query names
lexically come first and the cap is filled with the endpoints whose
profile embeds nearest the query above the embedder's floor; the
refusal is unchanged; the vocabulary sentence loses "walked once per
call" (it is count-index backed since #70). `docs/agent-memory.md`,
"Building the tools": `:embedder` in the `make-agent-tools` argument
list (`make-endpoint-embedder` of a rag embedder and a floor).

```bash
git add agent/ tests-agent/ docs/agent-tools.md docs/agent-memory.md
git commit -m "agent: retrieve routes lexical first then by the semantic index; the embedder rides on the scope (#78)"
```

---

### Task 5: Entry points, configuration, docs

**Files:**
- Modify: `agent/mcp/config.lisp` (`embedder-from-env`), `agent/mcp/adapter.lisp` (`make-memory-server :embedder`), `agent/mcp/packages.lisp`
- Modify: `scripts/memory-image.lisp`, `scripts/memory-mcp.lisp`, `scripts/run-memory.sh`, `scripts/run-memory-mcp.sh`
- Test: `tests-agent-mcp/config-tests.lisp`
- Docs: `docs/agent-memory.md` ("Running a memory image" table and a "Semantic routing" subsection under "The memory as an MCP server")

**Interfaces:**
- Consumes: `rag:make-openai-compatible-embedder`, Task 4's `make-endpoint-embedder`, Tasks 2–3's `reset-endpoint-segment`, `start-/stop-endpoint-indexer`.
- Produces: `mcp:embedder-from-env` → an `endpoint-embedder` or NIL; `make-memory-server ... :embedder`.

- [ ] **Step 1: Write the failing config test** (append to `tests-agent-mcp/config-tests.lisp`; read its existing env helpers first)

```lisp
(test the-embedder-comes-from-the-environment-or-is-absent
  (let ((saved (mapcar (lambda (n) (cons n (uiop:getenv n)))
                       '("CL_LLM_MEMORY_EMBED_URL" "CL_LLM_MEMORY_EMBED_MODEL"
                         "CL_LLM_MEMORY_EMBED_KEY" "CL_LLM_MEMORY_EMBED_FLOOR"))))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_URL") "")
           (is (null (mcp:embedder-from-env)) "empty URL: inert")
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_URL") "http://127.0.0.1:1/v1"
                 (uiop:getenv "CL_LLM_MEMORY_EMBED_MODEL") "m"
                 (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "0.42")
           (let ((ee (mcp:embedder-from-env)))
             (is (agent:endpoint-embedder-p ee))
             (is (string= "m" (agent:endpoint-embedder-model ee)))
             (is (= 0.42 (agent:endpoint-embedder-floor ee))))
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "")
           (signals error (mcp:embedder-from-env) "a URL needs a floor")
           (setf (uiop:getenv "CL_LLM_MEMORY_EMBED_FLOOR") "0.5"
                 (uiop:getenv "CL_LLM_MEMORY_EMBED_MODEL") "")
           (signals error (mcp:embedder-from-env) "and a model"))
      (dolist (p saved) (setf (uiop:getenv (car p)) (or (cdr p) ""))))))
```

- [ ] **Step 2: Implement**

`agent/mcp/config.lisp`:

```lisp
(defun embedder-from-env ()
  "The semantic index's embedder from CL_LLM_MEMORY_EMBED_URL / _MODEL /
_KEY / _FLOOR (#78 SS5), or NIL when the URL is empty -- the feature is
then inert.  A URL without a model or a floor is an error."
  (let ((url (env "CL_LLM_MEMORY_EMBED_URL")))
    (when url
      (let ((model (env "CL_LLM_MEMORY_EMBED_MODEL"))
            (floor (env "CL_LLM_MEMORY_EMBED_FLOOR")))
        (unless model (error "CL_LLM_MEMORY_EMBED_MODEL is required with a URL"))
        (unless floor (error "CL_LLM_MEMORY_EMBED_FLOOR is required with a URL"))
        (agent:make-endpoint-embedder
         (rag:make-openai-compatible-embedder
          :base-url url :model model :api-key (env "CL_LLM_MEMORY_EMBED_KEY"))
         :floor (let ((*read-default-float-format* 'single-float))
                  (let ((v (with-standard-io-syntax
                             (let ((*read-eval* nil)) (read-from-string floor)))))
                    (unless (realp v) (error "CL_LLM_MEMORY_EMBED_FLOOR: ~s" floor))
                    v)))))))
```

`env` returns NIL for empty (check config.lisp:6). The mcp package needs
a `rag` nickname (`agent/mcp/packages.lisp`) and `cl-llm/agent/mcp`
already depends on `cl-llm/agent` which depends on `cl-llm/rag/claims`.

`make-memory-server` gains `embedder` and passes `:embedder` to
`make-agent-tools`.

`scripts/memory-image.lisp`: after the store is open and before
`swank:create-server`:

```lisp
    (let ((ee (mcp:embedder-from-env)))
      (setf *embedder* ee)
      (when ee
        ;; The dimension is known only from an embedding; reset the
        ;; segment now, before anything can search (SS4.3 step 4).
        (mem:reset-endpoint-segment
         *graph* (length (funcall (agent:endpoint-embedder-embed ee) "probe"))))
```

`start-listener` gets `:embedder *embedder*` (add the keyword to
`mcp:start-listener` and thread it to `make-memory-server`; read
listener.lisp). After the listener block:

```lisp
      (when *embedder*
        (setf *indexer* (mem:start-endpoint-indexer
                         (list *graph*)
                         :embed (agent:endpoint-embedder-embed *embedder*)
                         :model (agent:endpoint-embedder-model *embedder*))))
```

The banner gains `; index <model>` or `; index off`. `stop`: first
`(when *indexer* (mem:stop-endpoint-indexer *indexer*) (setf *indexer* nil))`,
then the listener, then the store. A probe embedding that fails at start
(embedder down) is reported on stderr and leaves the index off for this
run (`handler-case` around the reset, like the listener's guard), so an
embedder outage never keeps the image from serving.

`scripts/memory-mcp.lisp`: in `start`, after `open-scope`, the same
reset over every store in scope (the embedder from env); the worker is
started after `start` returns and before `run-server`; `stop` stops it
before `close-scope`. `make-memory-server` gets `:embedder`.

`run-memory.sh` and `run-memory-mcp.sh`: export the four variables with
empty defaults, `${VAR-}` style is not needed (empty and unset are both
inert).

- [ ] **Step 3: Run the mcp suite**

Expected: 163 + the new checks, 0 failures. The image is not booted by
a test here (the process tests already cover the lifecycle without an
embedder; a live-model test is opt-in and not written in this plan).

- [ ] **Step 4: Manual check of the inert path**

`CL_LLM_MEMORY_MCP_PORT= CL_LLM_MEMORY_SWANK_PORT=4108 CL_LLM_MEMORY_STORE=/tmp/x78/working/ CL_LLM_MEMORY_SYSTEM=/tmp/x78/system/ CL_LLM_MEMORY_CLOCK=/tmp/x78/clock/ timeout 120 sh scripts/run-memory.sh`
must print a banner ending in `index off` and start no worker; then
`rm -rf /tmp/x78`. Record the banner line.

- [ ] **Step 5: Docs and commit**

`docs/agent-memory.md`: the four variables in the image's table; a
subsection "Semantic routing" under "The memory as an MCP server":
what it does, inert when unset, the worker and that writes never wait,
the floor with the calibration recipe (`nearest-endpoints` is the
memory-layer call; note `agent:make-endpoint-embedder` and `rag:embed`
for the query), a model change re-embeds in the background, a dimension
change resets at start, and that the embedder need not be on the memory
host.

```bash
git add agent/mcp/ scripts/ tests-agent-mcp/config-tests.lisp docs/agent-memory.md
git commit -m "mcp, scripts: the semantic index's embedder from the environment; the image and the solo server host the worker (#78)"
```

---

### Task 6: Full suites and the residual check

- [ ] Run memory, agent, agent/mcp; record counts against the
  baselines (489 / 347 / 163 plus the new checks).
- [ ] `awk 'length > 80'` and a tab check over every touched `.lisp`
  and `.asd` file; `grep -c '^-[^-]'` on the diff of every test file
  must show no removed test lines.
- [ ] Confirm `cl-llm/memory`'s `:depends-on` names no `cl-llm` system.
- [ ] No commit here unless something was fixed.
