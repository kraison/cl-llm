# Hybrid Dense+Sparse Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add roll-our-own BM25 sparse retrieval + a hybrid (dense+sparse, RRF-fused) retriever to cl-llm.rag, and wire mine-action's KB to use it — so exact-designation / general-concept queries whose gold document dense retrieval never surfaces (recall plateaus at 0.917) now get recalled.

**Architecture:** A pure designation-preserving tokenizer + BM25 scoring; a `sparse-store` (in-RAM inverted index over chunk text) implementing the store protocol; a `hybrid-retriever` fusing dense `store-search` and `sparse-search` by Reciprocal Rank Fusion. mine-action builds the sparse index from the same graph chunks at open. No graph-db change; no re-embedding.

**Tech Stack:** Common Lisp (SBCL, ASDF, FiveAM). Two repos: `/Users/kraison/work/cl-llm` (the capability) and `/Users/kraison/quicklisp/local-projects/mine-action` (consumer, local checkout).

**Design:** `docs/superpowers/specs/2026-07-19-hybrid-retrieval-design.md` (in cl-llm).

## Global Constraints

- **Tokenizer preserves designations:** `TM-62M` → one token `tm-62m` (NOT `tm`/`62m`); Cyrillic runs whole; lowercase; split on non-alphanumeric except internal `-`/`/`. This is the load-bearing behavior.
- **RRF fusion** — rank-based, `c=60`; no score normalization between cosine and BM25.
- **Sparse store implements the shared protocol** (`store-add`/`store-count`/`store-delete-document`) so a refresh stays consistent across dense+sparse; its search is text-based (`sparse-search`), NOT the vector `store-search`.
- **Chunk identity for fusion is `(document-id . text)`**, NOT `EQ` — dense and sparse stores hold *different* chunk objects (each `vertex->chunk` makes a new one), so EQ would never match.
- **Local only** (sovereignty); no new dependency (BM25 rolled by hand; `cl-ppcre` not even needed — a char-scan tokenizer is Unicode-safe via `alphanumericp`).
- **Lisp: spaces only, no tabs.** Match each file's style.
- BM25 params `*bm25-k1*`=1.2, `*bm25-b*`=0.75; `*rrf-k*`=60 — defparameters, tunable.

## File Structure

- **cl-llm** Create `rag/sparse.lisp` — tokenizer, BM25 helpers, `sparse-store` + `sparse-search`.
- **cl-llm** Create `rag/hybrid.lisp` — `hybrid-retriever`, `retrieve` method, `reciprocal-rank-fusion`.
- **cl-llm** Modify `cl-llm.asd` — add `sparse` + `hybrid` to `cl-llm/rag` components (after `index`), and `sparse`/`hybrid` to `cl-llm/rag/tests`.
- **cl-llm** Modify `rag/packages.lisp` — export the new symbols.
- **cl-llm** Create `tests-rag/sparse.lisp`, `tests-rag/hybrid.lisp`.
- **cl-llm** Modify `vivace/store.lisp` + `vivace/packages.lisp` — add `graph-store-chunks` (all chunks, for building a sparse index); test in `tests-vivace`.
- **mine-action** Modify `src/knowledge-graph.lisp` (build sparse-store at open; hybrid knowledge-store/index; delete fan-out), `src/knowledge-answer.lisp`/`src/knowledge-rest.lisp` (`knowledge-index` → hybrid), `src/knowledge-rest.lisp` (`*kb-default-k*` 5→8).

**Test commands:**
- cl-llm rag: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
- cl-llm vivace: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/vivace/tests")'`
- mine-action compile-check: the non-silent `ql:quickload :mine-action`.

---

### Task 1: tokenizer + BM25 scoring (pure) — `rag/sparse.lisp`

**Files:** Create `rag/sparse.lisp` (partial — the pure fns); Modify `cl-llm.asd`, `rag/packages.lisp`; Create `tests-rag/sparse.lisp`.

**Interfaces:**
- Produces: `tokenize (text) -> list of string`; `bm25-idf (n df) -> double`; `bm25-term-score (idf tf doc-len avgdl) -> double`; `*bm25-k1*`, `*bm25-b*`. Consumed by Task 2.

- [ ] **Step 1: Write the failing tests**

`tests-rag/sparse.lisp` (package `#:cl-llm.rag.test`, suite `cl-llm-rag-suite`):
```lisp
(in-package #:cl-llm.rag.test)
(in-suite cl-llm-rag-suite)

(test tokenize-preserves-designations
  (is (equal '("tm-62m") (rag:tokenize "TM-62M")))                 ; NOT ("tm" "62m")
  (is (equal '("det-cord") (rag:tokenize "det-cord")))
  (is (equal '("the" "tm-62m" "mine") (rag:tokenize "The TM-62M mine.")))
  (is (equal '("a" "b") (rag:tokenize "a, b!")))                   ; punctuation splits
  (is (equal '("vs-6d") (rag:tokenize "  -VS-6D-  ")))             ; trim leading/trailing dashes
  (is (member "тм-62" (rag:tokenize "мина ТМ-62") :test #'string=))) ; Cyrillic run kept whole

(test bm25-idf-rewards-rarity
  ;; a term in 1 of 100 docs has higher IDF than one in 90 of 100
  (is (> (rag:bm25-idf 100 1) (rag:bm25-idf 100 90))))

(test bm25-term-score-saturates-and-normalizes
  (let ((idf 1d0))
    ;; more tf -> higher score, but sub-linear (saturation)
    (is (> (rag:bm25-term-score idf 3 10d0 10d0) (rag:bm25-term-score idf 1 10d0 10d0)))
    (is (< (- (rag:bm25-term-score idf 3 10d0 10d0) (rag:bm25-term-score idf 2 10d0 10d0))
           (- (rag:bm25-term-score idf 2 10d0 10d0) (rag:bm25-term-score idf 1 10d0 10d0))))
    ;; a longer-than-average doc is penalized vs an average-length one at equal tf
    (is (< (rag:bm25-term-score idf 2 20d0 10d0) (rag:bm25-term-score idf 2 10d0 10d0)))))
```

- [ ] **Step 2: Register the files + run tests to verify they fail**

In `cl-llm.asd`, add `(:file "sparse")` after `(:file "index")` in the `cl-llm/rag` `rag` module, and `(:file "sparse")` after `(:file "index")` in `cl-llm/rag/tests` `tests-rag` module.
Run: `sbcl --non-interactive --eval '(ql:register-local-projects)' --eval '(asdf:test-system "cl-llm/rag/tests")'`
Expected: FAIL — `rag/sparse.lisp` doesn't exist / `tokenize` undefined.

- [ ] **Step 3: Create `rag/sparse.lisp` with the pure fns**

```lisp
;;;; rag/sparse.lisp -- lexical (BM25) retrieval: a designation-preserving tokenizer, BM25 scoring,
;;;; and a sparse-store (in-RAM inverted index) complementing the dense stores.
(in-package #:cl-llm.rag)

(defun tokenize (text)
  "Lowercase TEXT -> tokens: maximal runs of alphanumeric chars (Unicode-aware via ALPHANUMERICP,
so Cyrillic counts) plus INTERNAL hyphens/slashes, so a designation like \"TM-62M\" stays ONE
token \"tm-62m\" (not \"tm\"/\"62m\") and \"det-cord\" stays whole.  Leading/trailing -/ are
stripped per token."
  (let ((tokens '()) (cur (make-string-output-stream)))
    (flet ((flush ()
             (let ((tok (string-trim "-/" (get-output-stream-string cur))))
               (when (plusp (length tok)) (push tok tokens)))))
      (loop for ch across (string-downcase (or text "")) do
        (if (or (alphanumericp ch) (char= ch #\-) (char= ch #\/))
            (write-char ch cur)
            (flush)))
      (flush))
    (nreverse tokens)))

(defparameter *bm25-k1* 1.2d0 "BM25 term-frequency saturation parameter.")
(defparameter *bm25-b* 0.75d0 "BM25 document-length normalization parameter.")

(defun bm25-idf (n df)
  "Okapi BM25 IDF for a term present in DF of N documents."
  (log (+ 1d0 (/ (+ (- n df) 0.5d0) (+ df 0.5d0)))))

(defun bm25-term-score (idf tf doc-len avgdl)
  "BM25 contribution of one query term: IDF * saturated tf with length normalization."
  (let ((k1 *bm25-k1*) (b *bm25-b*))
    (* idf (/ (* tf (+ k1 1d0))
              (+ tf (* k1 (+ (- 1d0 b) (* b (/ (float doc-len 1d0) avgdl)))))))))
```

- [ ] **Step 4: Export the pure fns**

In `rag/packages.lisp`, add to the exports: `#:tokenize #:bm25-idf #:bm25-term-score #:*bm25-k1* #:*bm25-b*`.

- [ ] **Step 5: Run tests to verify they pass**

Run the rag test-system. Expected: PASS (the 3 new tests + existing suite).

- [ ] **Step 6: Commit**

```bash
git -C /Users/kraison/work/cl-llm add rag/sparse.lisp cl-llm.asd rag/packages.lisp tests-rag/sparse.lisp
git -C /Users/kraison/work/cl-llm commit -m "feat(rag): designation-preserving tokenizer + BM25 scoring"
```

---

### Task 2: `sparse-store` + `sparse-search` — `rag/sparse.lisp`

**Files:** Modify `rag/sparse.lisp` (add the store), `rag/packages.lisp` (export); Modify `tests-rag/sparse.lisp`.

**Interfaces:**
- Consumes: Task 1's `tokenize`/`bm25-idf`/`bm25-term-score`; the existing `chunk`/`make-chunk`/`chunk-text`/`chunk-document-id`, `hit`/`make-hit`/`hit-score`/`hit-chunk`, `store-add`/`store-count`/`store-delete-document` generics.
- Produces: `sparse-store`, `make-sparse-store`, `sparse-search (store query-string k) -> hits`. Consumed by Task 3 + mine-action.

- [ ] **Step 1: Write the failing tests**

Append to `tests-rag/sparse.lisp`:
```lisp
(test sparse-store-add-count-search
  (let ((s (rag:make-sparse-store)))
    (rag:store-add s (list (rag:make-chunk "The TM-62M anti-tank mine has a metal body" :document-id "a")
                           (rag:make-chunk "The PFM-1 is a scatterable mine" :document-id "b")
                           (rag:make-chunk "general notes about mines and safety" :document-id "c")))
    (is (= 3 (rag:store-count s)))
    ;; an exact-designation query surfaces the doc that literally contains it, first
    (let ((hits (rag:sparse-search s "TM-62M" 3)))
      (is (>= (length hits) 1))
      (is (string= "a" (rag:chunk-document-id (rag:hit-chunk (first hits))))))
    ;; a query term in every doc ("mine") must not outweigh a rare exact term
    (let ((hits (rag:sparse-search s "PFM-1 mine" 3)))
      (is (string= "b" (rag:chunk-document-id (rag:hit-chunk (first hits))))))))

(test sparse-store-delete-document
  (let ((s (rag:make-sparse-store)))
    (rag:store-add s (list (rag:make-chunk "TM-62M mine" :document-id "a")
                           (rag:make-chunk "PFM-1 mine" :document-id "b")))
    (is (= 1 (rag:store-delete-document s "a")))
    (is (= 1 (rag:store-count s)))
    (is (null (rag:sparse-search s "TM-62M" 3))))           ; "a" gone -> no match for its term

(test sparse-search-empty-and-no-overlap
  (let ((s (rag:make-sparse-store)))
    (is (null (rag:sparse-search s "anything" 3)))          ; empty store
    (rag:store-add s (list (rag:make-chunk "TM-62M" :document-id "a")))
    (is (null (rag:sparse-search s "zzz-nonexistent" 3)))))  ; no term overlap -> no hits
```

- [ ] **Step 2: Run tests to verify they fail**

Run the rag test-system. Expected: FAIL — `make-sparse-store`/`sparse-search` undefined.

- [ ] **Step 3: Implement the store**

Append to `rag/sparse.lisp`:
```lisp
(defclass sparse-store ()
  ((chunks :initform (make-array 0 :adjustable t :fill-pointer 0) :reader store-chunks)
   (postings :initform (make-hash-table :test 'equal) :reader %postings)   ; token -> list of (idx . tf)
   (doc-lengths :initform (make-array 0 :adjustable t :fill-pointer 0) :reader %doc-lengths)
   (total-length :initform 0 :accessor %total-length))
  (:documentation "In-RAM BM25 inverted index over chunk text; complements a dense store."))

(defun make-sparse-store () (make-instance 'sparse-store))

(defun %index-chunk (store chunk idx)
  (let ((tf (make-hash-table :test 'equal)) (n 0))
    (dolist (tok (tokenize (chunk-text chunk))) (incf (gethash tok tf 0)) (incf n))
    (maphash (lambda (tok f) (push (cons idx f) (gethash tok (%postings store)))) tf)
    (vector-push-extend n (%doc-lengths store))
    (incf (%total-length store) n)))

(defmethod store-add ((store sparse-store) chunks)
  (dolist (chunk chunks)
    (vector-push-extend chunk (store-chunks store))
    (%index-chunk store chunk (1- (fill-pointer (store-chunks store)))))
  store)

(defmethod store-count ((store sparse-store)) (length (store-chunks store)))

(defmethod store-delete-document ((store sparse-store) document-id)
  "Rebuild the index excluding chunks whose DOCUMENT-ID matches; return the count removed."
  (let* ((old (store-chunks store))
         (kept (remove document-id old :key #'chunk-document-id :test #'equal))
         (removed (- (length old) (length kept))))
    (setf (fill-pointer old) 0 (fill-pointer (%doc-lengths store)) 0 (%total-length store) 0)
    (clrhash (%postings store))
    (store-add store (coerce kept 'list))
    removed))

(defun %avgdl (store)
  (let ((n (store-count store))) (if (zerop n) 1d0 (/ (float (%total-length store) 1d0) n))))

(defgeneric sparse-search (store query-string k)
  (:documentation "Up to K HITs for QUERY-STRING by BM25, highest score first."))

(defmethod sparse-search ((store sparse-store) query-string k)
  (let ((n (store-count store)) (scores (make-hash-table :test 'eql)))
    (when (plusp n)
      (let ((avgdl (%avgdl store)) (lengths (%doc-lengths store)))
        (dolist (tok (remove-duplicates (tokenize query-string) :test #'equal))
          (let ((postings (gethash tok (%postings store))))
            (when postings
              (let ((idf (bm25-idf n (length postings))))
                (dolist (p postings)
                  (incf (gethash (car p) scores 0d0)
                        (bm25-term-score idf (cdr p) (aref lengths (car p)) avgdl)))))))))
    (let ((hits (loop for idx being the hash-keys of scores using (hash-value sc)
                      collect (make-hit (aref (store-chunks store) idx) sc))))
      (subseq (sort hits #'> :key #'hit-score) 0 (min k (length hits))))))
```

- [ ] **Step 4: Export**

In `rag/packages.lisp`, add: `#:sparse-store #:make-sparse-store #:sparse-search`.

- [ ] **Step 5: Run tests to verify they pass**

Run the rag test-system. Expected: PASS (Task 2's 3 tests + Task 1 + existing).

- [ ] **Step 6: Commit**

```bash
git -C /Users/kraison/work/cl-llm add rag/sparse.lisp rag/packages.lisp tests-rag/sparse.lisp
git -C /Users/kraison/work/cl-llm commit -m "feat(rag): sparse-store (BM25 inverted index) + sparse-search"
```

---

### Task 3: `hybrid-retriever` + RRF, and `graph-store-chunks` (vivace)

**Files:** Create `rag/hybrid.lisp`; Modify `cl-llm.asd`, `rag/packages.lisp`; Create `tests-rag/hybrid.lisp`; Modify `vivace/store.lisp`, `vivace/packages.lisp`, `tests-vivace/` (a test).

**Interfaces:**
- Consumes: Task 2's `sparse-search`; the existing `embed`, `store-search`, `retrieve` generic, `hit`/`make-hit`/`hit-chunk`/`hit-score`, `chunk-document-id`/`chunk-text`, the vivace `map-chunk-vertices`/`vertex->chunk`.
- Produces: `hybrid-retriever`, `make-hybrid-retriever`, `reciprocal-rank-fusion`, `*rrf-k*`; vivace `graph-store-chunks (store) -> list of chunk`.

- [ ] **Step 1: Write the failing tests**

`tests-rag/hybrid.lisp`:
```lisp
(in-package #:cl-llm.rag.test)
(in-suite cl-llm-rag-suite)

(defun %hits (docids)   ; make a ranked hit list from doc-ids (score unused by RRF)
  (loop for id in docids for s downfrom 1.0
        collect (rag:make-hit (rag:make-chunk (format nil "text-~A" id) :document-id id) s)))

(test rrf-surfaces-sparse-only-doc
  ;; dense ranks a,b,c ; sparse ranks x (dense missed x entirely) -> x must enter the fused top-k
  (let* ((dense (%hits '("a" "b" "c")))
         (sparse (%hits '("x" "a")))
         (fused (rag:reciprocal-rank-fusion (list dense sparse)))
         (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) fused)))
    (is (member "x" ids :test #'string=))                    ; the recall win
    (is (string= "a" (first ids)))))                         ; a is in both -> top

(test hybrid-retriever-recalls-exact-designation
  ;; a mock embedder makes dense USELESS for the designation (all cosine ~equal), but sparse
  ;; recalls the exact-designation doc; hybrid must return it.
  (let* ((emb (rag:make-mock-embedder :dimension 8))
         (chunks (list (rag:make-chunk "the TM-62M anti-tank mine" :document-id "tm62m"
                                       :embedding (rag:embed emb "the TM-62M anti-tank mine"))
                       (rag:make-chunk "general safety notes" :document-id "notes"
                                       :embedding (rag:embed emb "general safety notes"))))
         (dense (rag:make-memory-store))
         (sparse (rag:make-sparse-store)))
    (rag:store-add dense chunks) (rag:store-add sparse chunks)
    (let* ((r (rag:make-hybrid-retriever :embedder emb :dense-store dense :sparse-store sparse))
           (hits (rag:retrieve r "TM-62M" :k 2))
           (ids (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h))) hits)))
      (is (member "tm62m" ids :test #'string=)))))
```

- [ ] **Step 2: Register + run to verify fail**

Add `(:file "hybrid")` after `(:file "sparse")` in both `cl-llm/rag` and `cl-llm/rag/tests`. Run the rag test-system. Expected: FAIL — `reciprocal-rank-fusion`/`make-hybrid-retriever` undefined.

- [ ] **Step 3: Implement `rag/hybrid.lisp`**

```lisp
;;;; rag/hybrid.lisp -- hybrid dense+sparse retrieval, fused by Reciprocal Rank Fusion.
(in-package #:cl-llm.rag)

(defparameter *rrf-k* 60 "Reciprocal Rank Fusion constant (standard 60).")

(defun %chunk-key (chunk)
  "Fusion identity for a chunk: (document-id . text).  NOT EQ -- dense and sparse stores hold
DIFFERENT chunk objects for the same underlying slice (each vertex->chunk makes a new one)."
  (cons (chunk-document-id chunk) (chunk-text chunk)))

(defun reciprocal-rank-fusion (ranked-lists &key (k *rrf-k*))
  "Fuse RANKED-LISTS (each a ranked hit list) by RRF on (document-id . text); return one hit list
ordered by fused score.  A chunk's representative hit is taken from the FIRST list it appears in."
  (let ((fused (make-hash-table :test 'equal)))            ; key -> (cons rrf-score representative-hit)
    (dolist (hits ranked-lists)
      (loop for hit in hits for rank from 1
            for key = (%chunk-key (hit-chunk hit))
            for cell = (gethash key fused)
            do (if cell
                   (incf (car cell) (/ 1d0 (+ k rank)))
                   (setf (gethash key fused) (cons (/ 1d0 (+ k rank)) hit)))))
    (let ((merged (loop for cell being the hash-values of fused
                        collect (make-hit (hit-chunk (cdr cell)) (car cell)))))
      (sort merged #'> :key #'hit-score))))

(defclass hybrid-retriever ()
  ((embedder :initarg :embedder :reader retriever-embedder)
   (dense-store :initarg :dense-store :reader hybrid-dense-store)
   (sparse-store :initarg :sparse-store :reader hybrid-sparse-store)
   (candidate-k :initarg :candidate-k :initform 20 :reader hybrid-candidate-k))
  (:documentation "Fuses dense (embedding cosine) + sparse (BM25) retrieval via RRF."))

(defun make-hybrid-retriever (&key embedder dense-store sparse-store (candidate-k 20))
  (make-instance 'hybrid-retriever :embedder embedder :dense-store dense-store
                 :sparse-store sparse-store :candidate-k candidate-k))

(defmethod retrieve ((r hybrid-retriever) query &key (k 5))
  (let* ((kc (max k (hybrid-candidate-k r)))
         (dense (store-search (hybrid-dense-store r) (embed (retriever-embedder r) query) kc))
         (sparse (sparse-search (hybrid-sparse-store r) query kc))
         (fused (reciprocal-rank-fusion (list dense sparse))))
    (subseq fused 0 (min k (length fused)))))
```
(Verify the embedder call: the dense-retriever uses the same one — if it is `(embed embedder text)` keep it; if the embedder API differs, mirror `dense-retriever`'s call in `rag/retrieve.lisp`.)

- [ ] **Step 4: Export (rag) + add `graph-store-chunks` (vivace)**

`rag/packages.lisp`: add `#:hybrid-retriever #:make-hybrid-retriever #:reciprocal-rank-fusion #:*rrf-k*`.

`vivace/store.lisp` — add (after `map-chunk-vertices`), so a caller can build a sparse index from the same chunks:
```lisp
(defun graph-store-chunks (store)
  "All chunks currently in STORE's graph, as rag:chunk objects (for building a secondary index)."
  (let ((out '()))
    (map-chunk-vertices store (lambda (v) (push (vertex->chunk v) out)))
    (nreverse out)))
```
`vivace/packages.lisp`: export `#:graph-store-chunks`.

- [ ] **Step 5: Run tests to verify they pass**

Run the rag test-system (hybrid tests). Then add a vivace test in `tests-vivace/store-cache.lisp`:
```lisp
(test graph-store-chunks-returns-all
  (let* ((dir (format nil "/tmp/cl-llm-vg-gsc-~a/" (get-internal-real-time)))
         (emb (rag:make-mock-embedder)))
    (unwind-protect
         (let* ((g (gdb:make-graph :cl-llm-vg-gsc (pathname dir)))
                (store (v:make-graph-store g :strategy :cache)))
           (rag:store-add store (list (rag:make-chunk "a" :document-id "d1" :embedding (rag:embed emb "a"))
                                      (rag:make-chunk "b" :document-id "d2" :embedding (rag:embed emb "b"))))
           (is (= 2 (length (v:graph-store-chunks store))))
           (gdb:close-graph g))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))
```
Run both rag + vivace test-systems. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kraison/work/cl-llm add rag/hybrid.lisp cl-llm.asd rag/packages.lisp tests-rag/hybrid.lisp vivace/store.lisp vivace/packages.lisp tests-vivace/store-cache.lisp
git -C /Users/kraison/work/cl-llm commit -m "feat(rag): hybrid-retriever + RRF fusion; vivace graph-store-chunks"
```

---

### Task 4: mine-action integration (hybrid knowledge-index + k=8)

**Files:** Modify `src/knowledge-graph.lisp`, `src/knowledge-answer.lisp`, `src/knowledge-rest.lisp` in `/Users/kraison/quicklisp/local-projects/mine-action`.

**Interfaces:**
- Consumes: `cl-llm.rag:make-sparse-store`/`store-add`/`sparse-search`, `cl-llm.rag.vivace:graph-store-chunks`, `cl-llm.rag:make-hybrid-retriever`, `cl-llm.rag:retrieve`.

- [ ] **Step 1: Build the sparse store at open + expose it**

In `src/knowledge-graph.lisp`, add a special `*knowledge-sparse-store*` (near `*knowledge-store*`) and, in `open-knowledge-graph` after the dense store opens successfully (in the locals, committed on success like the dense store), build it from the graph chunks:
```lisp
;; after (setf store (make-graph-store ...)) succeeds, before setf success t:
(setf sparse (let ((sp (cl-llm.rag:make-sparse-store)))
               (cl-llm.rag:store-add sp (cl-llm.rag.vivace:graph-store-chunks store))
               sp))
```
and commit `*knowledge-sparse-store*` on success / NIL on failure, exactly parallel to `*knowledge-store*`. `close-knowledge-graph` sets it NIL too. Add a `(defun knowledge-sparse-store () *knowledge-sparse-store*)` accessor.

- [ ] **Step 2: `knowledge-index` returns a hybrid retriever**

In `src/knowledge-answer.lisp`, change `knowledge-index` so that when a sparse store is available it returns a hybrid retriever, else falls back to the dense index (backward-compatible):
```lisp
(defun knowledge-index (&key (embedder (knowledge-embedder)) (store (knowledge-store))
                             (sparse (knowledge-sparse-store)))
  (unless store (error "knowledge-index: no knowledge store (open-knowledge-graph first)"))
  (if sparse
      (cl-llm.rag:make-hybrid-retriever :embedder embedder :dense-store store :sparse-store sparse)
      (cl-llm.rag:make-index :embedder embedder :store store)))
```
(Confirm `retrieve` works on both — `kb-retrieve-context`/`kb-search-json` call `cl-llm.rag:retrieve` on the returned object, which both `index` and `hybrid-retriever` implement.)

- [ ] **Step 3: Delete fan-out + k=8**

In `src/knowledge-ingest.lisp`'s changed-checksum branch (the refresh), after `store-delete-document` on the dense store, also delete from the sparse store so both stay consistent:
```lisp
(cl-llm.rag:store-delete-document store doc-id)
(let ((sp (knowledge-sparse-store))) (when sp (cl-llm.rag:store-delete-document sp doc-id)))
```
and after `add-documents` (which adds to the dense store via the index), add the new chunks to the sparse store too. NOTE: `add-documents` chunks+embeds+adds to the dense store; the sparse store needs those same chunks. Simplest: after the ingest of a refreshed doc, rebuild is overkill; instead add the doc's chunks to sparse from the dense store's freshly-added chunks. Since re-deriving the exact chunks is awkward, the pragmatic v1: on a refresh, also `store-add` the sparse store from `graph-store-chunks` deltas is complex — instead, document that a changed-checksum refresh updates the DENSE store live but the SPARSE store is rebuilt at next open (a restart), and keep the sparse delete (so stale sparse chunks don't mismatch). Flag this clearly in a comment; full live sparse-refresh is a follow-up. (Deferred→text OCR path and first-ingest happen at build time before the sparse store is built, so they're covered by the open-time hydrate.)

In `src/knowledge-rest.lisp`, change `*kb-default-k*` from `5` to `8`.

- [ ] **Step 4: Non-silent compile-check**

```bash
sbcl --non-interactive --eval '(ql:register-local-projects)' \
     --eval '(handler-case (progn (ql:quickload :mine-action) (format t "~&OK~%")) (error (e) (format t "~&ERR ~A~%" e)))'
```
Expected: `OK`, no undefined-function warning for the new cl-llm symbols.

- [ ] **Step 5: Commit (mine-action)**

```bash
git -C /Users/kraison/quicklisp/local-projects/mine-action add src/knowledge-graph.lisp src/knowledge-answer.lisp src/knowledge-rest.lisp src/knowledge-ingest.lisp
git -C /Users/kraison/quicklisp/local-projects/mine-action commit -m "feat(kb): hybrid dense+sparse retrieval (BM25) + k=8"
```

---

### Task 5: restart + eval recall re-measure (operational — controller-driven)

**Manual/operational, not TDD.** Driven on the live dev-hub server.

- [ ] **Step 1: Clean restart** — SIGTERM the running sbcl, relaunch `run-server.sh` (no `--rebuild`). The sparse index builds at open from the existing chunks (no re-ingest). Confirm `/api/kb/registry` responds + store-count is 8577.

- [ ] **Step 2: Re-measure recall** — load `mine-action/tests` + `tests/knowledge-eval.lisp` in the running image via SWANK; re-run the recall@k sweep AND `run-kb-eval` (with the gpt-oss provider for the judge dims). Confirm **recall rises above the dense-only 0.917 plateau** — specifically that the ~2 persistent dense misses (det-cord / shaped-charge / SpotlightAI class) now surface via the sparse/hybrid path. Record before/after recall.

- [ ] **Step 3: Record the outcome** in the finishing summary. No commit (live graph).

---

## Self-Review (completed by plan author)

- **Spec coverage:** tokenizer (T1) · BM25 (T1) · sparse-store+search (T2) · hybrid-retriever+RRF (T3) · vivace graph-store-chunks (T3) · mine-action hybrid index + k=8 + delete fan-out (T4) · restart + recall re-measure (T5) — mapped.
- **Type consistency:** `tokenize (text)->list`, `bm25-idf (n df)`, `bm25-term-score (idf tf doc-len avgdl)`, `sparse-search (store query-string k)->hits`, `reciprocal-rank-fusion (ranked-lists &key k)->hits`, `make-hybrid-retriever (&key embedder dense-store sparse-store candidate-k)`, `graph-store-chunks (store)->chunks` — identical at defs, tests, and call sites; RRF keyed on `(document-id . text)` (not EQ) as the constraint requires.
- **No placeholders:** every code step carries actual code; every run step names the command + expected result.
- **Known limitation flagged (T4 Step 3):** a live changed-checksum refresh updates the dense store immediately but the sparse index is rebuilt at next open — deletes fan out (no stale matches), full live sparse re-add is a documented follow-up. First-ingest/OCR paths are covered by the open-time hydrate.
- **Acceptance is recall (deterministic), not the noisy LLM-judge dims (T5).**
