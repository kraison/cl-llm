# Dense-Preserving (Backfill) Fusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dense-preserving "backfill" fusion to cl-llm's `hybrid-retriever` — keep dense's ranking untouched and let sparse (BM25) only *recover* documents dense never surfaced — then have mine-action opt into it, fixing the recall@8 regression that pure RRF fusion introduced (0.875 → target ≈ 0.958, no per-case regression).

**Architecture:** A new pure `dense-preserving-fusion` function beside `reciprocal-rank-fusion` in `rag/hybrid.lisp`; a `fusion` slot on `hybrid-retriever` (`:rrf` default | `:backfill`) whose `retrieve` method `ecase`-dispatches; mine-action's `knowledge-index` passes `:fusion :backfill`. No re-embedding, no schema change.

**Tech Stack:** Common Lisp (SBCL, ASDF, FiveAM). Two repos: `/Users/kraison/work/cl-llm` (the capability) and `/Users/kraison/quicklisp/local-projects/mine-action` (consumer, on `main`).

**Design:** `docs/superpowers/specs/2026-07-19-dense-preserving-fusion-design.md` (in cl-llm).

## Global Constraints

- **Dense-preserving:** the fusion NEVER reorders documents dense found. It only appends, into reserved tail slots, documents that are **dense-missed** (no chunk of that `document-id` appears anywhere in dense's candidate list). When nothing qualifies, the result is **exactly dense's top-k, unchanged**.
- **Recovery rule:** recoveries are sparse hits whose `document-id` is dense-missed, walked in **sparse rank order**, **deduped by `document-id`** (each recovered document contributes its top sparse chunk once), capped at `*backfill-max*`.
- **`*backfill-max*`** — defparameter, default **2**, tunable.
- **Synthetic score:** returned hits carry a **descending double-float score monotonic with final position** (dense cosine and sparse BM25 are incomparable scales; never mix native scores into one ranked list). `hit`'s `score` slot is `double-float` — use `1d0`-typed literals.
- **Fusion default stays `:rrf`** — backward-compatible; the RRF path and its tests remain intact. mine-action opts into `:backfill`.
- **`*kb-default-k*` stays 8** (already set by the hybrid-retrieval work) — no change.
- **No new dependency; local only. Lisp: spaces only, never tabs.**

**Test commands:**
- cl-llm rag: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
- mine-action compile-check: the non-silent `ql:quickload :mine-action` (see Task 3).

---

### Task 1: `dense-preserving-fusion` + `*backfill-max*` — `rag/hybrid.lisp`

**Files:**
- Modify: `/Users/kraison/work/cl-llm/rag/hybrid.lisp` (append the fn + defparameter)
- Modify: `/Users/kraison/work/cl-llm/rag/packages.lisp:27` (exports)
- Test: `/Users/kraison/work/cl-llm/tests-rag/hybrid.lisp` (append 4 tests)

**Interfaces:**
- Consumes: existing `hit`/`make-hit`/`hit-chunk`, `chunk`/`make-chunk`/`chunk-document-id`/`chunk-text`; the `%hits` helper already in `tests-rag/hybrid.lisp` (`(%hits docids)` → ranked hit list, each chunk text `"text-<id>"`, document-id `<id>`).
- Produces: `dense-preserving-fusion (dense-hits sparse-hits k &key max-backfill) -> list of hit`; `*backfill-max*` (defparameter, default 2). Consumed by Task 2.

- [ ] **Step 1: Write the failing tests**

Append to `/Users/kraison/work/cl-llm/tests-rag/hybrid.lisp`:
```lisp
(test backfill-recovers-dense-missed-and-preserves-dense
  ;; dense ranks a,b,c ; sparse ranks x (dense-missed) then a. k=3, max-backfill=2.
  ;; -> dense top-(k-1)=[a b] then recovery x; dense's tail c is displaced, a/b keep order.
  (let* ((dense (%hits '("a" "b" "c")))
         (sparse (%hits '("x" "a")))
         (fused (rag:dense-preserving-fusion dense sparse 3 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (equal '("a" "b" "x") ids))
    ;; scores strictly descending with final position
    (is (apply #'> (mapcar #'rag:hit-score fused)))))

(test backfill-no-recovery-returns-dense-topk-unchanged
  ;; sparse overlaps dense entirely -> no dense-missed doc -> result IS dense's top-k (the RRF regression guard).
  (let* ((dense (%hits '("a" "b" "c" "d")))
         (sparse (%hits '("b" "a")))
         (fused (rag:dense-preserving-fusion dense sparse 3 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (equal '("a" "b" "c") ids))))

(test backfill-dedups-recoveries-by-document
  ;; two sparse hits are different chunks of the SAME dense-missed doc "x" -> ONE slot, its top chunk.
  (let* ((dense (%hits '("a" "b" "c")))
         (sparse (list (rag:make-hit (rag:make-chunk "chunk one of x" :document-id "x") 2d0)
                       (rag:make-hit (rag:make-chunk "chunk two of x" :document-id "x") 1d0)))
         (fused (rag:dense-preserving-fusion dense sparse 3 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (equal '("a" "b" "x") ids))
    (is (string= "chunk one of x" (rag:chunk-text (rag:hit-chunk (third fused)))))))

(test backfill-caps-at-max-backfill
  ;; three dense-missed docs, max-backfill 2, k 4 -> only top-2 recoveries; k never exceeded.
  (let* ((dense (%hits '("a" "b" "c" "d")))
         (sparse (%hits '("x" "y" "z")))
         (fused (rag:dense-preserving-fusion dense sparse 4 :max-backfill 2))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (= 4 (length fused)))
    (is (equal '("a" "b" "x" "y") ids))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
Expected: FAIL — `dense-preserving-fusion` undefined (the 4 new tests error; the existing suite is unaffected).

- [ ] **Step 3: Implement `dense-preserving-fusion` + `*backfill-max*`**

Append to `/Users/kraison/work/cl-llm/rag/hybrid.lisp` (after the existing `retrieve` method):
```lisp
(defparameter *backfill-max* 2
  "Dense-preserving fusion: the maximum number of sparse-only recoveries (distinct documents) that
may fill reserved tail slots per query.")

(defun dense-preserving-fusion (dense-hits sparse-hits k &key (max-backfill *backfill-max*))
  "Fuse by PRESERVING dense's ranking and only BACKFILLING documents dense never surfaced.
DENSE-HITS is dense's full candidate list (cosine order); SPARSE-HITS is BM25 order.  A document is
dense-missed iff none of its chunks appear anywhere in DENSE-HITS.  Up to MAX-BACKFILL dense-missed
documents -- deduped by document-id, in sparse rank order, each contributing its TOP sparse chunk --
fill the last slots; the first (k - n) hits are dense's, in dense order.  When no document qualifies
(n=0) the result is EXACTLY dense's top-k, unchanged.  Returned hits carry a synthetic descending
score monotonic with final position (dense cosine and sparse BM25 are incomparable scales, so native
scores are never mixed into one ranked list)."
  (let ((dense-docs (make-hash-table :test 'equal)))
    (dolist (h dense-hits)
      (setf (gethash (chunk-document-id (hit-chunk h)) dense-docs) t))
    (let ((recoveries '())
          (seen (make-hash-table :test 'equal)))
      (block collect
        (dolist (h sparse-hits)
          (let ((doc (chunk-document-id (hit-chunk h))))
            (unless (or (gethash doc dense-docs) (gethash doc seen))
              (setf (gethash doc seen) t)
              (push h recoveries)
              (when (>= (length recoveries) max-backfill) (return-from collect))))))
      (setf recoveries (nreverse recoveries))
      (let* ((n (min (length recoveries) k))
             (head (subseq dense-hits 0 (min (- k n) (length dense-hits))))
             (chosen (append head (subseq recoveries 0 n)))
             (total (length chosen)))
        (loop for h in chosen
              for i from 0
              collect (make-hit (hit-chunk h) (float (- total i) 1d0)))))))
```

- [ ] **Step 4: Export the new symbols**

In `/Users/kraison/work/cl-llm/rag/packages.lisp:27`, change:
```lisp
   #:hybrid-retriever #:make-hybrid-retriever #:reciprocal-rank-fusion #:*rrf-k*
```
to:
```lisp
   #:hybrid-retriever #:make-hybrid-retriever #:reciprocal-rank-fusion #:*rrf-k*
   #:dense-preserving-fusion #:*backfill-max*
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
Expected: PASS — the 4 new tests plus the existing suite, output pristine (no compiler warnings). If SBCL warns about a single-float literal at a `make-hit` score, a `1.0` slipped in where `1d0` is required — fix it.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kraison/work/cl-llm add rag/hybrid.lisp rag/packages.lisp tests-rag/hybrid.lisp
git -C /Users/kraison/work/cl-llm commit -m "feat(rag): dense-preserving (backfill) fusion + *backfill-max*"
```

---

### Task 2: `fusion` slot on `hybrid-retriever` + dispatch — `rag/hybrid.lisp`

**Files:**
- Modify: `/Users/kraison/work/cl-llm/rag/hybrid.lisp:26-42` (class, constructor, `retrieve`)
- Test: `/Users/kraison/work/cl-llm/tests-rag/hybrid.lisp` (append 1 end-to-end test)

**Interfaces:**
- Consumes: Task 1's `dense-preserving-fusion`/`*backfill-max*`; existing `reciprocal-rank-fusion`, `store-search`, `sparse-search`, `embed`, `retrieve` generic, `make-mock-embedder`, `make-memory-store`, `make-sparse-store`, `store-add`, `make-chunk`.
- Produces: `hybrid-retriever` with a `fusion` slot (`:rrf` | `:backfill`, default `:rrf`); `make-hybrid-retriever` gains a `:fusion` keyword (default `:rrf`). Consumed by Task 3.

- [ ] **Step 1: Write the failing test**

Append to `/Users/kraison/work/cl-llm/tests-rag/hybrid.lisp`:
```lisp
(test hybrid-retriever-backfill-fusion-runs-end-to-end
  ;; a :backfill retriever dispatches through dense-preserving-fusion and returns the
  ;; exact-designation document (smoke test of the fusion slot + retrieve dispatch).
  (let* ((emb (rag:make-mock-embedder :dimension 8))
         (chunks (list (rag:make-chunk "the TM-62M anti-tank mine" :document-id "tm62m"
                                       :embedding (rag:embed emb "the TM-62M anti-tank mine"))
                       (rag:make-chunk "general safety notes" :document-id "notes"
                                       :embedding (rag:embed emb "general safety notes"))))
         (dense (rag:make-memory-store))
         (sparse (rag:make-sparse-store)))
    (rag:store-add dense chunks) (rag:store-add sparse chunks)
    (let* ((r (rag:make-hybrid-retriever :embedder emb :dense-store dense :sparse-store sparse
                                         :fusion :backfill))
           (hits (rag:retrieve r "TM-62M" :k 2))
           (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) hits)))
      (is (member "tm62m" ids :test #'string=)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
Expected: FAIL — `make-hybrid-retriever` does not yet accept `:fusion` (unknown `&key` argument).

- [ ] **Step 3: Add the `fusion` slot, constructor keyword, and dispatch**

In `/Users/kraison/work/cl-llm/rag/hybrid.lisp`, replace lines 26-42 (the class, constructor, and `retrieve` method) with:
```lisp
(defclass hybrid-retriever ()
  ((embedder :initarg :embedder :reader retriever-embedder)
   (dense-store :initarg :dense-store :reader hybrid-dense-store)
   (sparse-store :initarg :sparse-store :reader hybrid-sparse-store)
   (candidate-k :initarg :candidate-k :initform 20 :reader hybrid-candidate-k)
   (fusion :initarg :fusion :initform :rrf :reader hybrid-fusion))
  (:documentation "Fuses dense (embedding cosine) + sparse (BM25) retrieval.  FUSION selects the
strategy: :rrf (Reciprocal Rank Fusion -- reorders by fused rank) or :backfill (dense-preserving --
keeps dense's order, sparse only recovers documents dense never surfaced)."))

(defun make-hybrid-retriever (&key embedder dense-store sparse-store (candidate-k 20) (fusion :rrf))
  (make-instance 'hybrid-retriever :embedder embedder :dense-store dense-store
                 :sparse-store sparse-store :candidate-k candidate-k :fusion fusion))

(defmethod retrieve ((r hybrid-retriever) query &key (k 5))
  (let* ((kc (max k (hybrid-candidate-k r)))
         (dense (store-search (hybrid-dense-store r) (embed (retriever-embedder r) query) kc))
         (sparse (sparse-search (hybrid-sparse-store r) query kc)))
    (ecase (hybrid-fusion r)
      (:rrf (let ((fused (reciprocal-rank-fusion (list dense sparse))))
              (subseq fused 0 (min k (length fused)))))
      (:backfill (dense-preserving-fusion dense sparse k :max-backfill *backfill-max*)))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
Expected: PASS — the new `:backfill` end-to-end test, the existing `:rrf` end-to-end test (`hybrid-retriever-recalls-exact-designation`, still default), and the whole suite; output pristine.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kraison/work/cl-llm add rag/hybrid.lisp tests-rag/hybrid.lisp
git -C /Users/kraison/work/cl-llm commit -m "feat(rag): hybrid-retriever fusion slot (:rrf default | :backfill)"
```

---

### Task 3: mine-action opts into `:backfill` — `src/knowledge-answer.lisp`

**Files:**
- Modify: `/Users/kraison/quicklisp/local-projects/mine-action/src/knowledge-answer.lisp:32` (the `make-hybrid-retriever` call in `knowledge-index`)

**Interfaces:**
- Consumes: Task 2's `make-hybrid-retriever` `:fusion` keyword.

- [ ] **Step 1: Pass `:fusion :backfill`**

In `/Users/kraison/quicklisp/local-projects/mine-action/src/knowledge-answer.lisp`, in `knowledge-index`, change the hybrid branch from:
```lisp
      (cl-llm.rag:make-hybrid-retriever :embedder embedder :dense-store store :sparse-store sparse)
```
to:
```lisp
      (cl-llm.rag:make-hybrid-retriever :embedder embedder :dense-store store :sparse-store sparse
                                        :fusion :backfill)
```
(Leave the docstring and the dense-only fallback line untouched.)

- [ ] **Step 2: Non-silent compile-check**

The cl-llm local checkout must be on `feat/hybrid-retrieval` with Tasks 1–2 committed (so the `:fusion` keyword exists). Run:
```bash
sbcl --non-interactive --eval '(ql:register-local-projects)' \
     --eval '(handler-case (progn (ql:quickload :mine-action) (format t "~&OK~%")) (error (e) (format t "~&ERR ~A~%" e)))'
```
Expected: `OK`, with no undefined-function / bad-keyword warning for `make-hybrid-retriever`. Read the output — a warning is a finding, not just a missing `OK`. (mine-action has no automated test framework; the compile-check is the verification.)

- [ ] **Step 3: Commit (mine-action)**

Stage ONLY this file (leave the repo's other uncommitted changes — `config.ini`, `docs/`, untracked scratch — alone):
```bash
git -C /Users/kraison/quicklisp/local-projects/mine-action add src/knowledge-answer.lisp
git -C /Users/kraison/quicklisp/local-projects/mine-action commit -m "feat(kb): use dense-preserving (:backfill) fusion for the knowledge index"
```

---

### Task 4: restart + recall re-measure (operational — controller-driven)

**Manual/operational, not TDD.** Driven on the live dev-hub server. This is the acceptance gate.

- [ ] **Step 1: Clean restart** — clean SIGTERM the running mine-action sbcl (confirm graceful shutdown: `knowledge-graph/.dirty` removed), relaunch `tools/run-server.sh` (no `--rebuild`; the sparse index rebuilds at open from existing chunks). Confirm the log shows `knowledge substrate up (chunks=8577)` and, via SWANK, that `knowledge-index` returns a `HYBRID-RETRIEVER` whose `hybrid-fusion` is `:BACKFILL`.

- [ ] **Step 2: Re-measure recall** — via SWANK (client at the session scratchpad `swank_eval.py`), load `mine-action/tests` + `tests/knowledge-eval.lisp` and re-run the deterministic dense-vs-hybrid recall sweep (the `measure-recall.lisp` helper from the hybrid-retrieval Task 5, which compares `make-index` dense-only vs `knowledge-index` at k=5/8/20 over the 24 gold cases). Confirm:
  - **hybrid (`:backfill`) recall@8 ≥ dense's 0.917** (target ≈ 0.958), with the Cooper/det-cord document recovered;
  - **no per-case regression at k=8** — every gold document dense ranked ≤ 8 is still within the backfill top-8 (dump the per-case dense-rank vs hybrid-rank as in the hybrid-retrieval Task 5, and confirm no gold doc dense had ≤8 fell out).

- [ ] **Step 3: Record the outcome** in the finishing summary (before/after recall table, the recovered document, per-case regression check). No commit (live graph). The SpotlightAI gold document remaining unrecovered is the known, out-of-scope pre-existing gap.

---

## Self-Review (completed by plan author)

- **Spec coverage:** `dense-preserving-fusion` + `*backfill-max*` (T1) · `fusion` slot + dispatch, default `:rrf` (T2) · mine-action `:backfill` opt-in (T3) · restart + recall re-measure acceptance (T4) — every §3/§4 spec item maps to a task.
- **Type consistency:** `dense-preserving-fusion (dense-hits sparse-hits k &key max-backfill) -> hits`, `*backfill-max*` (default 2), `hybrid-fusion` reader, `make-hybrid-retriever :fusion` keyword (default `:rrf`) — identical at defs, tests, and call sites. Synthetic score is `1d0`-typed (matches the `hit` `score` double-float slot, the Task-3 finding from the hybrid-retrieval work).
- **No placeholders:** every code step carries actual code; every run step names the command + expected result.
- **Dense-preserving guarantee is tested (T1 Step 1, `backfill-no-recovery-returns-dense-topk-unchanged`)** — the property RRF failed. Dedup-by-document, cap, and recovery+preservation are each their own test.
- **Backward-compat:** default `:rrf` keeps the existing RRF end-to-end test green (T2 Step 4); only mine-action opts into `:backfill`.
- **Acceptance is recall (deterministic), re-measured live (T4).**
