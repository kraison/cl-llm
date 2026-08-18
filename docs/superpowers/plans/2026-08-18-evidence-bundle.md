# The evidence bundle and its scoring — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A ranked evidence bundle from the two retrieval modes that already
work, plus the deterministic instrument that measures it.

**Architecture:** Two new records in the graph-free `cl-llm/rag` — `evidence`
and `bundle` — beside the existing `hit`, which is untouched public API. A
`collect-evidence` generic lets any source contribute evidence; unit 1 ships
dense and sparse, and later units add spatial, temporal and claim traversal
as further methods. Scoring reuses `cl-llm/eval`'s scorer registry through a
small additive generalisation of its runner, with the bundle-aware scorers in
a new `cl-llm/rag/eval` system so neither existing system widens.

**Tech Stack:** Common Lisp (SBCL), ASDF, FiveAM, `local-time`,
`cl-temporal-extent`.

**Spec:** `docs/superpowers/specs/2026-08-18-evidence-bundle-design.md`
(committed `838c5ea`). Executors read both.

## Global Constraints

- **80 columns, hard**, counted in **codepoints not bytes** — these files
  contain `—` and `⚠`. A 96-column line is a defect.
- **Spaces only, never tabs.**
- **Comments are terse and point elsewhere** — a doc, a GH issue, a SHA.
  Docstrings say what it does, what it returns, and the one trap a caller
  must know. Do not narrate reasoning in source.
- **`cl-llm/rag` must not depend on any graph system.** It gains
  `cl-temporal-extent` and nothing else. This is mechanically checkable: the
  system definition simply must not name `graph-db`.
- **`hit`, `retrieve` and `store-search` are public API and do not change.**
  The README documents them and `examples/` uses them.
- **Do not push.** Do not bump any version.
- **Never run two SBCLs at once.** A `mine-action` server and a `cl-mcp`
  REPL are resident on this box; they are not building, so they do not
  contend, but do not start a second build of your own.
- Run tests detached to a log file and read it —
  `nohup sbcl --non-interactive ... > /tmp/log 2>&1 &` then poll with an
  until-loop that also checks the process is alive. Never
  `timeout N sbcl ... | tail`: a capped run against a long build produces a
  killed process and an unreadable pipe.
- **A test whose whole value is that it would fail must be shown to fail.**

---

### Task 1: The records, and the dependency that carries them

**Files:**
- Create: `rag/bundle.lisp`
- Modify: `rag/packages.lisp` (export block)
- Modify: `cl-llm.asd` (`cl-llm/rag`: depend on `cl-temporal-extent`, add the
  `bundle` component)
- Create: `tests-rag/bundle.lisp`
- Modify: `cl-llm.asd` (`cl-llm/rag/tests`: add the `bundle` component)

**Interfaces:**
- Consumes: `rag:chunk`, `rag:make-chunk`, `rag:chunk-document-id` (existing).
- Produces, relied on by Tasks 2, 4 and 5:
  - `(make-evidence &key chunk score method source confidence precision
    extent standing)` → `evidence`
  - readers `evidence-chunk` `evidence-score` `evidence-method`
    `evidence-source` `evidence-confidence` `evidence-precision`
    `evidence-extent` `evidence-standing`
  - `(make-bundle &key query evidence modes)` → `bundle`
  - readers `bundle-query` `bundle-evidence` `bundle-modes`

- [ ] **Step 1: Record the baseline**

Before changing anything, measure and write down the current offline count:

```bash
cd /home/raison/work/cl-llm
nohup sbcl --non-interactive \
  --eval '(ql:register-local-projects)' \
  --eval '(ql:quickload :cl-llm/rag/tests)' \
  --eval '(fiveam:run! (quote cl-llm.rag.test::cl-llm-rag-suite))' \
  > /tmp/bundle-baseline.log 2>&1 &
```

Poll the log; record `Did N checks` in your report. Every later count is
measured against this number.

- [ ] **Step 2: Write the failing test**

Create `tests-rag/bundle.lisp`:

```lisp
;;;; tests-rag/bundle.lisp

(in-package #:cl-llm.rag.test)
(in-suite cl-llm-rag-suite)

(test evidence-carries-its-provenance
  "Every field the epic requires per hit, and STANDING is never NIL."
  (let ((e (rag:make-evidence
            :chunk (rag:make-chunk "text" :document-id "d1")
            :score 1.0d0
            :method :dense
            :standing :indeterminate)))
    (is (string= "d1" (rag:chunk-document-id (rag:evidence-chunk e))))
    (is (eq :dense (rag:evidence-method e)))
    (is (eq :indeterminate (rag:evidence-standing e)))
    (is (null (rag:evidence-extent e)))
    (is (null (rag:evidence-source e)))))

(test evidence-holds-a-real-temporal-extent
  "⚠ Not a re-encoding.  The extent is the library's own struct, which is
what the graph-free dependency bought (vivace-graph#159)."
  (let* ((extent (temporal-extent:make-interval
                  (temporal-extent:exact-bound (local-time:now))
                  (temporal-extent:unknown-bound)
                  :semantics :validity
                  :standing :asserted))
         (e (rag:make-evidence :chunk (rag:make-chunk "t" :document-id "d1")
                               :score 1.0d0 :method :dense
                               :standing :asserted
                               :extent extent)))
    (is (temporal-extent:temporal-extent-p (rag:evidence-extent e)))
    (is (eq :validity
            (temporal-extent:extent-semantics (rag:evidence-extent e))))))

(test a-bundle-is-ordered-and-names-its-modes
  "ORDER IS THE CONTRACT: the bundle preserves the order it was built with."
  (let* ((a (rag:make-evidence :chunk (rag:make-chunk "a" :document-id "a")
                               :score 2.0d0 :method :dense
                               :standing :indeterminate))
         (b (rag:make-evidence :chunk (rag:make-chunk "b" :document-id "b")
                               :score 1.0d0 :method :sparse
                               :standing :indeterminate))
         (bundle (rag:make-bundle :query "q" :evidence (list a b)
                                  :modes '(:dense :sparse))))
    (is (string= "q" (rag:bundle-query bundle)))
    (is (equal '("a" "b")
               (mapcar (lambda (e)
                         (rag:chunk-document-id (rag:evidence-chunk e)))
                       (rag:bundle-evidence bundle))))
    (is (equal '(:dense :sparse) (rag:bundle-modes bundle)))))
```

- [ ] **Step 3: Register the test file, then run it to see RED**

ASDF will not compile a file it does not know about, so the component must
be added *before* the failing run is observable. In `cl-llm.asd`, in
`cl-llm/rag/tests`' components, after `(:file "hybrid")`:

```lisp
                             (:file "bundle")
```

Then run the suite as in Step 1. Expected: a compile failure —
`RAG:MAKE-EVIDENCE` is undefined. Record what you actually saw.

- [ ] **Step 4: Add the dependency and the component**

In `cl-llm.asd`, `cl-llm/rag`:

```lisp
  :depends-on ("cl-llm" "cl-temporal-extent")
```

and in its components, after `(:file "hybrid")`:

```lisp
                             (:file "bundle")
```

⚠ Leave `(:file "answer")` last as it already is; append `bundle` before it
only if that ordering compiles — `bundle.lisp` depends on nothing in
`answer.lisp`, so placing it directly after `hybrid` is correct.

- [ ] **Step 5: Write the records**

Create `rag/bundle.lisp`:

```lisp
;;;; rag/bundle.lisp -- the evidence bundle: one ranked artifact from every
;;;; retrieval mode.  Design: docs/superpowers/specs/2026-08-18-evidence-
;;;; bundle-design.md (cl-llm#13 unit 1).

(in-package #:cl-llm.rag)

(defstruct evidence
  "One retrieved item and everything known about where it came from.
STANDING is never NIL: absence carries a reason, so a reader can tell
\"nobody looked\" from \"we looked and found nothing\"."
  (chunk nil)
  (score 0.0d0)
  (method nil)        ; :DENSE :SPARSE :SPATIAL :TEMPORAL :CLAIM
  (source nil)
  (confidence nil)
  (precision nil)
  (extent nil)        ; a TEMPORAL-EXTENT:TEMPORAL-EXTENT, or NIL
  (standing nil))

(defstruct bundle
  "A query and its ranked evidence.  The ORDER of EVIDENCE is the contract:
a reordering is a regression, so nothing may sort it on the way out."
  (query "")
  (evidence nil)
  (modes nil))
```

- [ ] **Step 6: Export the new names**

In `rag/packages.lisp`, in the `:export` list, before the
`;; grows in later tasks` comment:

```lisp
   #:evidence #:make-evidence #:evidence-chunk #:evidence-score
   #:evidence-method #:evidence-source #:evidence-confidence
   #:evidence-precision #:evidence-extent #:evidence-standing
   #:bundle #:make-bundle #:bundle-query #:bundle-evidence #:bundle-modes
```

- [ ] **Step 7: Run the suite and confirm GREEN**

Expected: baseline + 12 checks (5 + 2 + 3 in the three new tests, plus the 2
in `evidence-holds-a-real-temporal-extent`). Report the actual number and
decompose it per test.

- [ ] **Step 8: Prove `cl-llm/rag` still has no graph dependency**

```bash
grep -n 'graph-db' cl-llm.asd | grep -A2 -B2 'cl-llm/rag"'
```

Expected: no match inside the `cl-llm/rag` system. Also confirm the system
loads with no graph system present:

```bash
nohup sbcl --non-interactive \
  --eval '(ql:register-local-projects)' \
  --eval '(ql:quickload :cl-llm/rag)' \
  --eval '(format t "~&NO-GRAPH: ~a~%" (null (find-package :graph-db)))' \
  > /tmp/bundle-nograph.log 2>&1 &
```

Expected: `NO-GRAPH: T`. This is the seam; measure it rather than assume it.

- [ ] **Step 9: Commit**

```bash
git add rag/bundle.lisp rag/packages.lisp cl-llm.asd tests-rag/bundle.lisp
git commit -m "feat(rag): the evidence bundle records (#13)

EVIDENCE and BUNDLE sit beside HIT, which is public API and unchanged.
STANDING is never NIL -- absence carries a reason.  cl-llm/rag gains
cl-temporal-extent and no graph dependency, so the extent is the library's
own struct rather than a re-encoding.  [skip-docs]"
```

---

### Task 2: The source protocol, and fusion into a bundle

**Files:**
- Modify: `rag/bundle.lisp` (append)
- Modify: `rag/packages.lisp` (export block)
- Modify: `tests-rag/bundle.lisp` (append)

**Interfaces:**
- Consumes: Task 1's records; existing `store-search`, `sparse-search`,
  `embed`, `reciprocal-rank-fusion`, `hit-chunk`, `hit-score`.
- Produces, relied on by Tasks 4 and 5:
  - `(collect-evidence source query &key k bounds)` → list of `evidence`
  - `(make-dense-source embedder store)` → `dense-source`
  - `(make-sparse-source store)` → `sparse-source`
  - `(fuse sources query &key k)` → `bundle`

- [ ] **Step 1: Write the failing tests**

Append to `tests-rag/bundle.lisp`:

```lisp
(defun %bundle-doc-ids (bundle)
  (mapcar (lambda (e) (rag:chunk-document-id (rag:evidence-chunk e)))
          (rag:bundle-evidence bundle)))

(test a-dense-source-produces-evidence-marked-dense
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store :dimension 8)))
    (rag:store-add store
                   (list (rag:make-chunk "anti-tank mine fuze"
                                         :document-id "d1"
                                         :embedding (rag:embed embedder
                                                               "anti-tank"))))
    (let ((ev (rag:collect-evidence (rag:make-dense-source embedder store)
                                    "anti-tank" :k 1)))
      (is (= 1 (length ev)))
      (is (eq :dense (rag:evidence-method (first ev))))
      (is (eq :indeterminate (rag:evidence-standing (first ev))))
      (is (string= "d1" (rag:chunk-document-id
                         (rag:evidence-chunk (first ev))))))))

(test a-sparse-source-produces-evidence-marked-sparse
  (let ((store (rag:make-sparse-store)))
    (rag:store-add store
                   (list (rag:make-chunk "TM-62 fuze" :document-id "d2")))
    (let ((ev (rag:collect-evidence (rag:make-sparse-source store)
                                    "TM-62" :k 1)))
      (is (= 1 (length ev)))
      (is (eq :sparse (rag:evidence-method (first ev))))
      (is (eq :indeterminate (rag:evidence-standing (first ev)))))))

(test fuse-names-every-mode-that-contributed
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store :dimension 8))
         (sparse-store (rag:make-sparse-store))
         (chunk (rag:make-chunk "TM-62 anti-tank mine" :document-id "d1"
                                :embedding (rag:embed embedder "TM-62"))))
    (rag:store-add dense-store (list chunk))
    (rag:store-add sparse-store (list chunk))
    (let ((b (rag:fuse (list (rag:make-dense-source embedder dense-store)
                             (rag:make-sparse-source sparse-store))
                       "TM-62" :k 5)))
      (is (string= "TM-62" (rag:bundle-query b)))
      (is (member :dense (rag:bundle-modes b)))
      (is (member :sparse (rag:bundle-modes b)))
      (is (every (lambda (e) (rag:evidence-standing e))
                 (rag:bundle-evidence b))))))

(test fusion-order-is-deterministic
  "⚠ Ordering is the regression contract, so it must not depend on hash
order or on which source answered first."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store :dimension 8))
         (sparse-store (rag:make-sparse-store))
         (chunks (list (rag:make-chunk "alpha mine" :document-id "a"
                                       :embedding (rag:embed embedder "alpha"))
                       (rag:make-chunk "beta mine" :document-id "b"
                                       :embedding (rag:embed embedder "beta"))
                       (rag:make-chunk "gamma mine" :document-id "c"
                                       :embedding (rag:embed embedder "gamma")))))
    (rag:store-add dense-store chunks)
    (rag:store-add sparse-store chunks)
    (let* ((sources (list (rag:make-dense-source embedder dense-store)
                          (rag:make-sparse-source sparse-store)))
           (first-run (%bundle-doc-ids (rag:fuse sources "mine" :k 3)))
           (second-run (%bundle-doc-ids (rag:fuse sources "mine" :k 3))))
      (is (equal first-run second-run)))))
```

- [ ] **Step 2: Run and confirm RED**

Expected: `RAG:COLLECT-EVIDENCE` undefined. Record what you saw.

- [ ] **Step 3: Write the protocol and the two sources**

Append to `rag/bundle.lisp`:

```lisp
(defgeneric collect-evidence (source query &key k bounds)
  (:documentation "Return a list of EVIDENCE for QUERY, best first.
BOUNDS is the planner's region/window and is accepted by every method; unit
1's sources ignore it (cl-llm#13 unit 2 supplies it)."))

(defclass dense-source ()
  ((embedder :initarg :embedder :reader dense-source-embedder)
   (store :initarg :store :reader dense-source-store))
  (:documentation "Vector retrieval as a bundle source."))

(defun make-dense-source (embedder store)
  (make-instance 'dense-source :embedder embedder :store store))

(defclass sparse-source ()
  ((store :initarg :store :reader sparse-source-store))
  (:documentation "Sparse (BM25) retrieval as a bundle source."))

(defun make-sparse-source (store)
  (make-instance 'sparse-source :store store))

(defun %hit->evidence (hit method)
  "Wrap HIT as EVIDENCE attributed to METHOD.  STANDING is :INDETERMINATE:
no claim has been consulted, which is not the same as having consulted one
and found nothing (that is :SEARCHED-EMPTY, cl-llm#13 unit 3)."
  (make-evidence :chunk (hit-chunk hit)
                 :score (hit-score hit)
                 :method method
                 :standing :indeterminate))

(defmethod collect-evidence ((source dense-source) query &key (k 5) bounds)
  (declare (ignore bounds))
  (mapcar (lambda (h) (%hit->evidence h :dense))
          (store-search (dense-source-store source)
                        (embed (dense-source-embedder source) query)
                        k)))

(defmethod collect-evidence ((source sparse-source) query &key (k 5) bounds)
  (declare (ignore bounds))
  (mapcar (lambda (h) (%hit->evidence h :sparse))
          (sparse-search (sparse-source-store source) query k)))
```

- [ ] **Step 4: Write the fusion**

Append to `rag/bundle.lisp`:

```lisp
(defun %evidence->hit (evidence)
  (make-hit (evidence-chunk evidence) (evidence-score evidence)))

(defun fuse (sources query &key (k 5))
  "Collect evidence from each SOURCE and merge it into one ranked BUNDLE.
Ranking is RECIPROCAL-RANK-FUSION over each source's list, which is why the
sources' incomparable native scores never share a scale.  The bundle's order
is the contract; nothing downstream may re-sort it."
  (let* ((per-source (mapcar (lambda (s) (collect-evidence s query :k k))
                             sources))
         (by-key (make-hash-table :test 'equal))
         (fused (reciprocal-rank-fusion
                 (mapcar (lambda (evs) (mapcar #'%evidence->hit evs))
                         per-source))))
    ;; RECIPROCAL-RANK-FUSION works on HITs, so map back to the EVIDENCE that
    ;; produced each chunk, preferring the first source that offered it.
    (loop for evs in per-source
          do (dolist (e evs)
               (let ((key (chunk-document-id (evidence-chunk e))))
                 (unless (gethash key by-key)
                   (setf (gethash key by-key) e)))))
    (make-bundle
     :query query
     :evidence (loop for h in fused
                     for key = (chunk-document-id (hit-chunk h))
                     for e = (gethash key by-key)
                     when e
                       collect (make-evidence :chunk (evidence-chunk e)
                                              :score (hit-score h)
                                              :method (evidence-method e)
                                              :source (evidence-source e)
                                              :confidence (evidence-confidence e)
                                              :precision (evidence-precision e)
                                              :extent (evidence-extent e)
                                              :standing (evidence-standing e)))
     :modes (remove-duplicates
             (loop for evs in per-source
                   when evs collect (evidence-method (first evs)))))))
```

- [ ] **Step 5: Export the new names**

In `rag/packages.lisp`, beside Task 1's block:

```lisp
   #:collect-evidence #:dense-source #:make-dense-source
   #:sparse-source #:make-sparse-source #:fuse
```

- [ ] **Step 6: Run the suite and confirm GREEN**

Report the new count and decompose it per test added.

- [ ] **Step 7: Prove the ordering test is not vacuous**

Temporarily make `fuse` return its evidence sorted by document id
(`(sort ... #'string< :key ...)`) — a plausible "tidy-up" someone could
make. `fusion-order-is-deterministic` will still pass, because sorting is
also deterministic. That is the point: **it does not catch re-sorting**, and
Task 5's golden-file test is what does. Record this observation in your
report and restore the code. Do not add a weaker assertion to paper over it.

- [ ] **Step 8: Commit**

```bash
git add rag/bundle.lisp rag/packages.lisp tests-rag/bundle.lisp
git commit -m "feat(rag): evidence sources and fusion into a bundle (#13)

COLLECT-EVIDENCE is the seam later units extend: unit 3's claim expansion
becomes a third method, and BOUNDS is threaded now so unit 2's planner does
not have to touch every method.  [skip-docs]"
```

---

### Task 3: Let the eval runner grade something other than a model reply

**Files:**
- Modify: `eval/suite.lisp` (`variant` struct, `parse-variant`)
- Modify: `eval/run.lisp` (`run-cell`)
- Modify: `eval/packages.lisp` (export `variant-run-fn`)
- Modify: `tests-eval/` — add to the existing suite file for variants; if
  none exists, create `tests-eval/variant.lisp` and register it in
  `cl-llm/eval/tests`

**Interfaces:**
- Produces, relied on by Tasks 4 and 5: `variant-run-fn`, and
  `parse-variant` accepting `:run-fn`.

- [ ] **Step 1: Write the failing tests**

```lisp
(test a-variant-without-a-run-fn-is-unchanged
  "⚠ The generalisation must not alter existing behaviour: every variant in
every existing suite has no RUN-FN."
  (let ((v (eval:parse-variant (list :model "m" :label "plain"))))
    (is (null (eval:variant-run-fn v)))
    (is (string= "plain" (eval:variant-label v)))
    (is (equal '(:model "m") (eval:variant-args v)))))

(test a-run-fn-is-stripped-from-the-args-forwarded-to-ask
  "RUN-FN is an eval-only key, like :LABEL and :PROMPT-FN -- forwarding it to
ASK would make it a model parameter."
  (let ((v (eval:parse-variant
            (list :model "m" :run-fn (lambda (case) (declare (ignore case)) :b)))))
    (is (functionp (eval:variant-run-fn v)))
    (is (equal '(:model "m") (eval:variant-args v)))))
```

- [ ] **Step 2: Run and confirm RED** (`VARIANT-RUN-FN` undefined)

- [ ] **Step 3: Add the slot**

In `eval/suite.lisp`, replace the `variant` defstruct:

```lisp
(defstruct (variant (:constructor %make-variant (label args prompt-fn
                                                 &optional run-fn)))
  "One point in the grid: a LABEL, a plist of ARGS forwarded to ASK, and a
PROMPT-FN of (case) -> prompt string.  RUN-FN, when given, replaces the model
call entirely: it takes the case and returns whatever the scorers grade, so
the harness can measure a retrieval bundle and not only a reply."
  (label "" :type string)
  (args nil :type list)
  (prompt-fn nil :type function)
  (run-fn nil))
```

- [ ] **Step 4: Strip `:run-fn` in `parse-variant`**

In `eval/suite.lisp`, inside `parse-variant`'s `let` and `case`:

```lisp
  (let ((args '()) (label nil) (prompt-fn nil) (run-fn nil))
    (loop for (key value) on plist by #'cddr
          do (case key
               (:label (setf label value))
               (:prompt-fn (setf prompt-fn value))
               (:run-fn (setf run-fn value))
               (t (setf args (append args (list key value))))))
    (%make-variant (or label (compact-label args))
                   args
                   (or prompt-fn #'case-input)
                   run-fn))
```

- [ ] **Step 5: Use it in `run-cell`**

In `eval/run.lisp`, replace the body of `run-cell`'s `let`:

```lisp
  (if (variant-run-fn variant)
      ;; A RUN-FN produces the graded artifact directly; no model is called,
      ;; so there is no LLM-ERROR to convert into an error cell.
      (let ((response (funcall (variant-run-fn variant) case)))
        (%make-cell case (variant-label variant) response
                    (loop for scorer in scorers
                          collect (scorer-name scorer)
                          collect (run-scorer scorer case response))
                    nil))
      (let ((prompt (funcall (variant-prompt-fn variant) case)))
        ...existing body unchanged...))
```

⚠ Keep the existing `ask` path byte-identical inside the `else` branch. The
first test above exists to catch a change to it.

- [ ] **Step 6: Export `variant-run-fn`**

In `eval/packages.lisp`, beside `#:variant-prompt-fn`:

```lisp
   #:variant-run-fn
```

- [ ] **Step 7: Run the eval suite and confirm GREEN**

```bash
nohup sbcl --non-interactive \
  --eval '(ql:register-local-projects)' \
  --eval '(ql:quickload :cl-llm/eval/tests)' \
  --eval '(asdf:test-system :cl-llm/eval)' > /tmp/eval-suite.log 2>&1 &
```

Report the count before and after.

- [ ] **Step 8: Commit**

```bash
git add eval/suite.lisp eval/run.lisp eval/packages.lisp tests-eval/
git commit -m "feat(eval): a variant may supply its own runner (#13)

RUN-CELL was hard-wired to LLM:ASK, so the harness could only grade a model
reply.  A variant with a RUN-FN produces the graded artifact directly.
Additive: a variant without one takes the ASK path unchanged.  [skip-docs]"
```

---

### Task 4: The bundle scorers, in their own system

**Files:**
- Create: `rag-eval/packages.lisp`
- Create: `rag-eval/scorers.lisp`
- Modify: `cl-llm.asd` (new `cl-llm/rag/eval` and `cl-llm/rag/eval/tests`)
- Create: `tests-rag-eval/packages.lisp`
- Create: `tests-rag-eval/suite.lisp`
- Create: `tests-rag-eval/scorers.lisp`

**Interfaces:**
- Consumes: Tasks 1-2's records, Task 3's `variant-run-fn`,
  `eval:defscorer`, `eval:make-case`, `eval:case-expected`.
- Produces, relied on by Task 5: `bundle-recall-at-k`, `bundle-containment`,
  `bundle-standing-well-formed`, `bundle-method-attributed`.

- [ ] **Step 1: Create the systems**

In `cl-llm.asd`, after `cl-llm/rag/vivace/tests`:

```lisp
(defsystem "cl-llm/rag/eval"
  :description "Deterministic scoring of retrieval bundles."
  :license "MIT"
  :depends-on ("cl-llm/rag" "cl-llm/eval")
  :serial t
  :pathname "rag-eval/"
  :components ((:file "packages")
               (:file "scorers"))
  :in-order-to ((test-op (test-op "cl-llm/rag/eval/tests"))))

(defsystem "cl-llm/rag/eval/tests"
  :description "Offline test suite for cl-llm/rag/eval."
  :license "MIT"
  :depends-on ("cl-llm/rag/eval" "fiveam")
  :serial t
  :pathname "tests-rag-eval/"
  :components ((:file "packages")
               (:file "suite")
               (:file "scorers"))
  :perform (test-op (op c)
             (unless (uiop:symbol-call :fiveam :run!
                                       :cl-llm-rag-eval-suite)
               (error "cl-llm/rag/eval test suite failed."))))
```

- [ ] **Step 2: Write the packages**

`rag-eval/packages.lisp`:

```lisp
;;;; rag-eval/packages.lisp

(defpackage #:cl-llm.rag.eval
  (:use #:cl)
  (:local-nicknames (#:rag #:cl-llm.rag)
                    (#:eval #:cl-llm.eval))
  (:export
   #:bundle-recall-at-k #:bundle-containment
   #:bundle-standing-well-formed #:bundle-method-attributed))
```

`tests-rag-eval/packages.lisp`:

```lisp
;;;; tests-rag-eval/packages.lisp

(defpackage #:cl-llm.rag.eval.test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rag #:cl-llm.rag)
                    (#:eval #:cl-llm.eval)
                    (#:re #:cl-llm.rag.eval))
  (:export #:cl-llm-rag-eval-suite))
```

`tests-rag-eval/suite.lisp`:

```lisp
;;;; tests-rag-eval/suite.lisp

(in-package #:cl-llm.rag.eval.test)

(def-suite cl-llm-rag-eval-suite
  :description "Deterministic bundle scorers.")

(in-suite cl-llm-rag-eval-suite)

(defun %ev (doc-id &key (method :dense) (standing :indeterminate))
  (rag:make-evidence :chunk (rag:make-chunk (format nil "text-~a" doc-id)
                                            :document-id doc-id)
                     :score 1.0d0 :method method :standing standing))

(defun %bundle (doc-ids &key (modes '(:dense)))
  (rag:make-bundle :query "q"
                   :evidence (mapcar #'%ev doc-ids)
                   :modes modes))
```

- [ ] **Step 3: Write the failing tests**

`tests-rag-eval/scorers.lisp`:

```lisp
;;;; tests-rag-eval/scorers.lisp

(in-package #:cl-llm.rag.eval.test)
(in-suite cl-llm-rag-eval-suite)

(test recall-at-k-distinguishes-a-hit-from-a-miss
  (let ((case (eval:make-case "q" :expected '("b"))))
    (is (= 1.0d0 (eval:score-value
                  (re:bundle-recall-at-k case (%bundle '("a" "b" "c"))))))
    (is (= 0.0d0 (eval:score-value
                  (re:bundle-recall-at-k case (%bundle '("a" "c"))))))))

(test containment-catches-evidence-with-no-real-chunk
  "⚠ A fabricated citation must be catchable deterministically, not merely
instructed against."
  (let* ((case (eval:make-case "q" :expected '("a")))
         (good (%bundle '("a")))
         (bad (rag:make-bundle
               :query "q"
               :evidence (list (rag:make-evidence :chunk nil :score 1.0d0
                                                  :method :dense
                                                  :standing :indeterminate))
               :modes '(:dense))))
    (is (= 1.0d0 (eval:score-value (re:bundle-containment case good))))
    (is (= 0.0d0 (eval:score-value (re:bundle-containment case bad))))))

(test standing-well-formed-rejects-nil-and-non-vocabulary
  "⚠ This scorer is what makes the absence discipline mechanical.  A version
that passes on NIL is worse than none."
  (let ((case (eval:make-case "q")))
    (is (= 1.0d0 (eval:score-value
                  (re:bundle-standing-well-formed case (%bundle '("a"))))))
    (is (= 0.0d0
           (eval:score-value
            (re:bundle-standing-well-formed
             case (rag:make-bundle :query "q"
                                   :evidence (list (%ev "a" :standing nil))
                                   :modes '(:dense))))))
    (is (= 0.0d0
           (eval:score-value
            (re:bundle-standing-well-formed
             case (rag:make-bundle
                   :query "q"
                   :evidence (list (%ev "a" :standing :probably))
                   :modes '(:dense))))))))

(test method-attributed-rejects-an-unattributed-item
  (let ((case (eval:make-case "q")))
    (is (= 1.0d0 (eval:score-value
                  (re:bundle-method-attributed case (%bundle '("a"))))))
    (is (= 0.0d0
           (eval:score-value
            (re:bundle-method-attributed
             case (rag:make-bundle :query "q"
                                   :evidence (list (%ev "a" :method nil))
                                   :modes '(:dense))))))))
```

`eval:score-value` is the reader on the `SCORE` struct that `eval:score`
returns; both are exported from `cl-llm.eval` (`eval/packages.lisp:9`).
Verified — use it as written.

- [ ] **Step 4: Run and confirm RED**

- [ ] **Step 5: Write the scorers**

`rag-eval/scorers.lisp`:

```lisp
;;;; rag-eval/scorers.lisp -- deterministic scoring of a retrieval bundle.
;;;; Design: docs/superpowers/specs/2026-08-18-evidence-bundle-design.md.

(in-package #:cl-llm.rag.eval)

(defun %bundle-doc-ids (bundle)
  (loop for e in (rag:bundle-evidence bundle)
        for chunk = (rag:evidence-chunk e)
        when chunk collect (rag:chunk-document-id chunk)))

(eval:defscorer bundle-recall-at-k (case bundle)
  "1.0 when every expected document id appears in BUNDLE, else 0.0."
  (let ((expected (eval:case-expected case)))
    (eval:score (if (and bundle
                         (every (lambda (id)
                                  (member id (%bundle-doc-ids bundle)
                                          :test #'equal))
                                expected))
                    1.0d0
                    0.0d0))))

(eval:defscorer bundle-containment (case bundle)
  "1.0 when every evidence item carries a real chunk with a document id.
An item that traces to nothing is a fabricated citation."
  (declare (ignore case))
  (eval:score (if (and bundle
                       (every (lambda (e)
                                (let ((c (rag:evidence-chunk e)))
                                  (and c (rag:chunk-document-id c))))
                              (rag:bundle-evidence bundle)))
                  1.0d0
                  0.0d0)))

(eval:defscorer bundle-standing-well-formed (case bundle)
  "1.0 when every evidence item's STANDING is a member of the vocabulary.
NIL fails: absence must carry a reason (cl-llm#13 unit 1)."
  (declare (ignore case))
  (eval:score (if (and bundle
                       (every (lambda (e)
                                (temporal-extent:standingp
                                 (rag:evidence-standing e)))
                              (rag:bundle-evidence bundle)))
                  1.0d0
                  0.0d0)))

(eval:defscorer bundle-method-attributed (case bundle)
  "1.0 when every evidence item names the mode that produced it."
  (declare (ignore case))
  (eval:score (if (and bundle
                       (every (lambda (e) (rag:evidence-method e))
                              (rag:bundle-evidence bundle)))
                  1.0d0
                  0.0d0)))
```

`temporal-extent:standingp` is `(and (member x +standings+) t)`, so it is
false for `NIL` and for any non-member — exactly the check needed. Verified;
do not reimplement it locally.

- [ ] **Step 6: Run and confirm GREEN.** Report the count.

- [ ] **Step 7: Prove the standing scorer is load-bearing**

Replace `temporal-extent:standingp` with `(lambda (x) (declare (ignore x)) t)`
and confirm `standing-well-formed-rejects-nil-and-non-vocabulary` goes RED on
both the NIL case and the `:probably` case. Restore, reconfirm, `git status`
clean.

- [ ] **Step 8: Commit**

```bash
git add rag-eval/ tests-rag-eval/ cl-llm.asd
git commit -m "feat(rag/eval): deterministic bundle scorers (#13)

Four scorers in their own system, so neither cl-llm/eval learns about
retrieval nor cl-llm/rag about evaluation.  BUNDLE-STANDING-WELL-FORMED is
what makes the absence discipline mechanical rather than reviewed.
[skip-docs]"
```

---

### Task 5: Capture-and-diff, with ordering as the contract

**Files:**
- Create: `rag-eval/golden.lisp`
- Modify: `rag-eval/packages.lisp` (exports)
- Modify: `cl-llm.asd` (`cl-llm/rag/eval`: add the `golden` component)
- Create: `tests-rag-eval/golden.lisp`
- Modify: `cl-llm.asd` (`cl-llm/rag/eval/tests`: add the `golden` component)

**Interfaces:**
- Produces: `(bundle-projection bundle)` → list of
  `(document-id method standing rank)`; `(write-golden bundle path)`;
  `(check-golden bundle path)` → `(values ok-p first-divergence)`.

- [ ] **Step 1: Write the failing tests**

`tests-rag-eval/golden.lisp`:

```lisp
;;;; tests-rag-eval/golden.lisp

(in-package #:cl-llm.rag.eval.test)
(in-suite cl-llm-rag-eval-suite)

(defmacro with-temp-golden ((var) &body body)
  `(let ((,var (merge-pathnames (format nil "golden-~a.sexp" (random 100000))
                                #p"/tmp/")))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(test a-projection-omits-scores-and-text
  "⚠ Scores are floats and text is large; neither is a regression contract.
The projection is what stays stable across runs."
  (let ((p (re:bundle-projection (%bundle '("a" "b")))))
    (is (equal '(("a" :dense :indeterminate 0)
                 ("b" :dense :indeterminate 1))
               p))))

(test a-matching-bundle-passes-the-golden-file
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a" "b")) path)
    (is-true (re:check-golden (%bundle '("a" "b")) path))))

(test a-reordering-fails-the-golden-file
  "⚠ THE contract.  A comparison that sorted before diffing would pass this
and catch nothing."
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a" "b")) path)
    (is-false (re:check-golden (%bundle '("b" "a")) path))))

(test a-failed-check-does-not-rewrite-the-golden-file
  "⚠ A golden file that heals itself proves nothing.  Regeneration is
explicit, and this test exists so making it implicit is a visible change."
  (with-temp-golden (path)
    (re:write-golden (%bundle '("a" "b")) path)
    (let ((before (uiop:read-file-string path)))
      (re:check-golden (%bundle '("b" "a")) path)
      (is (string= before (uiop:read-file-string path))))))
```

- [ ] **Step 2: Run and confirm RED**

- [ ] **Step 3: Write the harness**

`rag-eval/golden.lisp`:

```lisp
;;;; rag-eval/golden.lisp -- capture-and-diff over a bundle's stable
;;;; projection.  Design: docs/superpowers/specs/2026-08-18-evidence-bundle-
;;;; design.md.

(in-package #:cl-llm.rag.eval)

(defun bundle-projection (bundle)
  "BUNDLE reduced to what is stable across runs: (DOCUMENT-ID METHOD
STANDING RANK) per item, in order.  Scores and text are deliberately absent
-- floats drift and would make the diff fail for reasons nobody cares about."
  (loop for e in (rag:bundle-evidence bundle)
        for rank from 0
        collect (list (let ((c (rag:evidence-chunk e)))
                        (and c (rag:chunk-document-id c)))
                      (rag:evidence-method e)
                      (rag:evidence-standing e)
                      rank)))

(defun write-golden (bundle path)
  "Write BUNDLE's projection to PATH.  Called explicitly to (re)generate a
golden file; CHECK-GOLDEN never calls it."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-readably* nil) (*print-pretty* t))
        (print (bundle-projection bundle) out)
        (terpri out))))
  path)

(defun check-golden (bundle path)
  "Compare BUNDLE's projection against the golden file at PATH.
Two values: whether they match, and the first differing (expected actual)
pair.  ⚠ Never rewrites PATH -- a self-healing golden file proves nothing."
  (let ((expected (with-open-file (in path) (read in)))
        (actual (bundle-projection bundle)))
    (if (equal expected actual)
        (values t nil)
        (values nil
                (loop for e in expected
                      for a in actual
                      unless (equal e a) return (list e a)
                        finally (return (list expected actual)))))))
```

- [ ] **Step 4: Add the components and exports**

`cl-llm.asd`, `cl-llm/rag/eval` components: `(:file "golden")` after
`scorers`. Its test system: `(:file "golden")` after `scorers`.

`rag-eval/packages.lisp` exports:

```lisp
   #:bundle-projection #:write-golden #:check-golden
```

- [ ] **Step 5: Run and confirm GREEN.** Report the count.

- [ ] **Step 6: Prove the ordering test is load-bearing**

Change `check-golden` to compare
`(sort (copy-list expected) #'string< :key #'first)` against the
similarly-sorted actual — the "tidy-up" the spec warns about. Confirm
`a-reordering-fails-the-golden-file` goes RED. Restore, reconfirm,
`git status` clean. Report the observed red.

- [ ] **Step 7: Commit**

```bash
git add rag-eval/golden.lisp rag-eval/packages.lisp tests-rag-eval/golden.lisp cl-llm.asd
git commit -m "feat(rag/eval): capture-and-diff over a stable projection (#13)

A raw bundle is not a regression contract: scores are floats and embeddings
drift.  The golden file stores (document-id method standing rank) in order,
and ordering is what must fail.  CHECK-GOLDEN never rewrites the file.
[skip-docs]"
```

---

### Task 6: Documentation

**Files:**
- Create: `docs/evidence-bundle.md`
- Modify: `README.md` (a short section pointing at it)

**This is the commit that carries the unit's documentation.** Every prior
task used `[skip-docs]`.

- [ ] **Step 1: Write `docs/evidence-bundle.md`**

Read `docs/` for an existing design doc to match in structure and register
before writing. Cover, with no placeholders:

- What a bundle is and why it, rather than prose, is the artifact.
- The `evidence` record field by field, and that `standing` is never `NIL`.
- The absence discipline: `:indeterminate` means no claim was consulted;
  `:searched-empty` (unit 3) means one was and found nothing. Say plainly
  that unit 1 produces only the former.
- `collect-evidence` as the extension seam, and that `bounds` is threaded
  but ignored until unit 2.
- The four scorers and what each catches.
- Capture-and-diff: the projection, why scores are excluded, that ordering
  is the contract, and that regeneration is explicit **by design**.
- That `cl-llm/rag` depends on `cl-temporal-extent` and on no graph system,
  and why that is what makes the graph-free configuration a real one.
- What unit 1 does not do: no spatial, temporal or claim modes; no planner;
  no narration; no LLM judge.

- [ ] **Step 2: Note it in the README**

Add a short section after the existing retrieval material, pointing at the
new doc. Read the surrounding prose and match it; do not restructure.

- [ ] **Step 3: Run every affected suite once more**

`cl-llm/rag/tests`, `cl-llm/eval/tests`, `cl-llm/rag/eval/tests`, one at a
time, in fresh detached processes. Documentation-only, so **every count must
be unchanged** from the end of Task 5. If one moves, stop and report.

- [ ] **Step 4: Commit**

```bash
git add docs/evidence-bundle.md README.md
git commit -m "docs: the evidence bundle and its scoring (#13)"
```

- [ ] **Step 5: Do not push. Report and stop.**

Report every suite count and stop. Pushing is outward-facing and needs
Kevin's approval; issue updates happen after that, not before.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| The records (`evidence`, `bundle`) | 1 |
| `cl-temporal-extent` dependency, no graph | 1 (Step 8 measures it) |
| Beside `hit`, nothing existing changes | 1 |
| Absence carries a reason | 1, 2 (`%hit->evidence`), 4 (the scorer) |
| `collect-evidence`, the two sources, `fuse` | 2 |
| `bounds` threaded and ignored | 2 |
| Eval runner generalisation | 3 |
| `cl-llm/rag/eval` as a new system | 4 |
| The four scorers | 4 |
| Projection, ordering, no self-healing | 5 |
| Fixtures offline; real corpus opt-in | 1-5 use fixtures only; the opt-in suite is **not** built here — see the gap below |
| What unit 1 does not do | 6 |

**One gap, deliberately left:** the spec mentions a separate opt-in suite
scoring against the real corpus, following the `cl-llm/live` pattern. No task
builds it. That corpus lives in a private repo and the epic's acceptance
criteria for it ("every latency figure names its host and is the third run")
belong with the modes that make it meaningful. **Ruling: unit 1 ships the
fixtures-only harness; the real-corpus suite lands with unit 3, when there is
something to measure that fixtures cannot show.** Recorded here rather than
silently dropped.

**Placeholder scan:** none. Every code step carries the code; the docs step
enumerates required content rather than saying "write docs".

**Type consistency:** `evidence-chunk/-score/-method/-source/-confidence/
-precision/-extent/-standing`, `bundle-query/-evidence/-modes`,
`collect-evidence`, `make-dense-source`, `make-sparse-source`, `fuse`,
`bundle-projection`, `write-golden`, `check-golden`, `variant-run-fn` —
spelled identically in every task that names them.

**Two facts Task 4 leans on, both verified while writing this plan** rather
than left as instructions to check: `eval:score-value` is exported from
`cl-llm.eval`, and `temporal-extent:standingp` is
`(and (member x +standings+) t)` and so is false for `NIL`. A plan that says
"go and confirm X" is a plan that has not finished thinking.
