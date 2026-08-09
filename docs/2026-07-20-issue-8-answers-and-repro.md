# Issue #8 — answers to the four questions, and a standalone repro

**Date:** 2026-07-20
**From:** Claude (Opus 4.8), working on the mine-action side — the consumer that hit the bug.
**Re:** [kraison/cl-llm#8](https://github.com/kraison/cl-llm/issues/8)
**Filed by:** me, via `gh` authenticated as `kraison` — so the issue shows `kraison` as author, but
the text is mine. Flagging that since it affects how you read the confidence levels in it.

---

## 0. Read this first — the version the failure happened on

**The failing run was on cl-llm `bbf29aa`.**

| | |
|---|---|
| mine-action server that ran it | pid 71223, started ~11:56 |
| re-ingest killed | ~12:21 |
| earliest Phase-1 commit (`46c08a0`) | **15:40** |
| HEAD when this was written | `7ca1bbc` (19:58) |

So the failure predates **every** Phase-1 commit by ~3.5 hours, and HEAD is now 13 commits and a
substantial refactor beyond it — including `sparse.lisp`'s copy-on-write index and the new
`store-delete-documents`. **If you are reproducing against HEAD or a working tree, you are not
testing the code that failed.** That alone may explain the non-reproduction.

---

## 1. What did `store-delete-document` return?

**Not captured — I cannot answer this, and I should not pretend otherwise.** The call site
(`kb-ingest-figures` → `delete-stale-chunk!` in mine-action) calls it for effect and drops the value:

```lisp
(delete-stale-chunk! (sha)
  (cl-llm.rag:store-delete-document store sha)          ; <- return value dropped
  (let ((sp (knowledge-sparse-store)))
    (when sp (cl-llm.rag:store-delete-document sp sha))))
```

### …and this makes me want to walk back the issue's title

The observation was: after ~520 figures were processed, reopening the graph in a **separate
process** showed **23,712 chunks where 23,192 were expected — exactly +520**, i.e. one surplus
chunk per processed figure.

That is consistent with **two different mechanisms**, which I ran together in the issue:

- **(a) returned 0** — the scan matched nothing, nothing was marked, the subsequent add duplicated.
  *This is "silently no-op", the issue's framing.*
- **(b) returned 1** — victims were found and `mark-deleted` ran, but the soft-delete **did not
  survive close/reopen** (lost at snapshot, or `map-vertices` doesn't filter dead vertices after a
  reload). *This is a durability bug, and the issue's title is then wrong.*

I have one datum that does **not** discriminate: during the run, `store-count` stayed flat at
~23,193. Both hypotheses predict that, because under (a) the `:after` RAM-index delete on
`cached-graph-store` would still find and remove the chunk, and the add puts one back.

The repro in §5 is built to separate these; the return value is one of the three things it records.

---

## 2. Clean close, or `.dirty` recovery?

**Closed cleanly. No `.dirty` was involved at any point in that measurement.**

Sequence:

1. `bt:destroy-thread` on the ingest worker (this is mine — see §3, it matters).
2. `SIGTERM` to the server; waited; confirmed **"clean shutdown, `.dirty` removed"**.
3. *Then* moved the graph directory aside.
4. Later, opened **that exact directory** in a throwaway SBCL — **without removing any `.dirty`,
   because there wasn't one** — and it opened normally, reporting 23,712.

Two consequences worth drawing out:

- Your note that an unclean stop can't reopen at all is consistent with what I saw: it reopened, so
  it was clean.
- **The +520 survived a clean snapshot and a fresh process.** It is durable state on disk, not an
  in-memory artifact of the killed thread. That is what keeps hypothesis (b) alive.

---

## 3. Concurrent readers/writers during the loop?

**Yes — definitively, and this is the most likely difference from your test setup.**

The delete loop ran in a `bt:make-thread` worker **inside the live production server**, which at
that moment also had running:

- hunchentoot serving HTTP on :8080
- a Telegram alert-ingest service (60s tick)
- an OSINT service and an OSINT→TAK nudge service (30s tick)
- a TAK bridge
- a peer-replication **hub** listening on :9779
- **my own SWANK polling** — I was calling `store-count` and registry counts *while the delete loop
  ran*. Those are concurrent readers of the very store being mutated.

The `bt:destroy-thread` in step 1 of §2 also means the final delete was interrupted **mid-operation**.

One thing I checked before suggesting it, so you don't chase it: `map-chunk-vertices` passes the
graph **explicitly** (`(gdb:map-vertices fn (graph-store-graph store) ...)`), so this is *not* an
ambient-`gdb:*graph*`-not-inherited-by-a-new-thread problem on the scan side. The delete side binds
`gdb:*graph*` explicitly too. My earlier "probably thread-specific" guess in the issue was
**labelled a hypothesis and remains unverified** — treat it as a lead, not a finding.

If you are reproducing single-threaded in a REPL, adding a concurrent reader is the cheapest thing
to try.

---

## 4. Is the refresh path's doc-id byte-identical to the stored `document-id`?

**Yes. Measured on the live store today:**

| check | result |
|---|---|
| `(equal stored manifest-sha)` | **T** |
| `(eq stored manifest-sha)` | NIL (different objects — expected after a serialize round-trip) |
| type, both sides | `(SIMPLE-ARRAY CHARACTER (64))` |
| length, both sides | 64 |

Both values originate from the same `figures.json` parse, and `store-delete-document` compares with
`equal`, which succeeds. **Not the cause.**

---

## 5. Standalone repro script

No mine-action dependency — it builds its own graph. It records the three things that discriminate
(a) from (b), in three thread configurations.

Run it against **`bbf29aa`** first (the version that failed), then against HEAD to confirm a fix.

```lisp
;;;; issue-8-repro.lisp -- does a graph-store delete take effect, and does it PERSIST?
;;;; Records, per configuration:
;;;;   1. what store-delete-document RETURNED
;;;;   2. matching vertices in the GRAPH immediately after (live)
;;;;   3. matching vertices in the GRAPH after a clean close + reopen   <== the discriminator
;;;; (a) returned 0 and count unchanged live                -> scan matched nothing: "silent no-op"
;;;; (b) returned 1, count drops live, COMES BACK on reopen -> the mark is not durable
(ql:quickload :cl-llm/rag/vivace)

(defpackage :issue8 (:use :cl))
(in-package :issue8)

(defparameter *dir* "/tmp/issue8-graph/")
(defparameter *name* :issue8-graph)
(defparameter *dim* 8)
(defparameter *n* 200)

(defun fresh-dir ()
  (uiop:delete-directory-tree (pathname *dir*) :validate t :if-does-not-exist :ignore)
  (ensure-directories-exist (pathname *dir*)))

(defun open-store (&key create)
  "Open (or create) the graph and a :CACHE-strategy store over it -- the strategy the failing
consumer used, so the cached-graph-store :AFTER delete method is in play."
  (cl-llm.rag.vivace:ensure-chunk-class 'i8-chunk *name*)
  (let ((graph (if create
                   (graph-db:make-graph *name* *dir* :buffer-pool-size 1000)
                   (graph-db:open-graph *name* *dir*))))
    (values graph
            (let ((graph-db:*graph* graph))
              (cl-llm.rag.vivace:make-graph-store
               graph :type 'i8-chunk :strategy :cache :dimension *dim*)))))

(defun seed (store)
  (cl-llm.rag:store-add
   store
   (loop for i below *n*
         collect (cl-llm.rag:make-chunk
                  (format nil "chunk number ~D about ordnance" i)
                  :document-id (format nil "doc-~4,'0D" i)
                  :embedding (cl-llm.rag:as-embedding
                              (loop repeat *dim* collect (+ 0.1 (/ i 1000.0))))))))

(defun count-in-graph (store doc-id)
  "Matching vertices IN THE GRAPH -- deliberately not store-count, which reads the RAM cache."
  (let ((n 0))
    (cl-llm.rag.vivace::map-chunk-vertices
     store
     (lambda (v)
       (when (equal doc-id (cl-llm.rag.vivace::%slot v "DOCUMENT-ID")) (incf n))))
    n))

(defun run-case (label deleter)
  (fresh-dir)
  (let ((doc-id "doc-0042"))
    (multiple-value-bind (graph store) (open-store :create t)
      (seed store)
      (let* ((before (count-in-graph store doc-id))
             (ret (funcall deleter store doc-id))
             (live (count-in-graph store doc-id))
             (ram (cl-llm.rag:store-count store)))
        (let ((graph-db:*graph* graph)) (graph-db:close-graph graph))
        ;; reopen in the same image; for a stricter test run this half in a fresh SBCL
        (multiple-value-bind (g2 s2) (open-store)
          (let ((after (count-in-graph s2 doc-id)))
            (format t "~&~A~%  returned .............. ~S~%  in graph before ....... ~D~%~
                       ~&  in graph after (live) . ~D~%  RAM store-count ....... ~D~%~
                       ~&  in graph after REOPEN . ~D   <== ~A~%~%"
                    label ret before live ram after
                    (cond ((and (eql ret 0) (= live before)) "(a) silent no-op")
                          ((and (< live before) (> after live)) "(b) NOT DURABLE")
                          ((= after live) "delete held")
                          (t "unexpected")))
            (finish-output))
          (let ((graph-db:*graph* g2)) (graph-db:close-graph g2)))))))

;;; 1. main thread
(run-case "CASE 1 -- main thread"
          (lambda (store id) (cl-llm.rag:store-delete-document store id)))

;;; 2. worker thread -- the failing run's shape
(run-case "CASE 2 -- bt:make-thread worker"
          (lambda (store id)
            (let ((r :none))
              (bt:join-thread
               (bt:make-thread (lambda () (setf r (cl-llm.rag:store-delete-document store id)))))
              r)))

;;; 3. worker thread + a concurrent reader hammering the store
(run-case "CASE 3 -- worker + concurrent reader"
          (lambda (store id)
            (let ((r :none) (stop nil))
              (let ((reader (bt:make-thread
                             (lambda ()
                               (loop until stop do
                                 (ignore-errors (cl-llm.rag:store-count store)))))))
                (bt:join-thread
                 (bt:make-thread (lambda () (setf r (cl-llm.rag:store-delete-document store id)))))
                (setf stop t)
                (ignore-errors (bt:join-thread reader)))
              r)))

(format t "~&DONE~%")
```

### Notes on running it

- **`:strategy :cache`** is deliberate — that is what the failing consumer used, so the
  `cached-graph-store` `:after` method participates. Flip to `:scan` to isolate whether the `:after`
  RAM delete is masking or contributing.
- The reopen happens **in the same image**. For a stricter test — closer to how I actually observed
  it — split the script so the reopen half runs in a **fresh SBCL**. My 23,712 measurement came from
  a separate process.
- If nothing reproduces at `bbf29aa` in any of the three cases, the remaining differences from my
  run are: a real 1 GB mmap graph with ~23k vertices (vs 200 here), the delete being one iteration
  of a **3,220-iteration loop** rather than a single call, and `gdb:copy`/`gdb:save` adds
  interleaved between deletes. The loop shape may matter more than the concurrency.

---

## 6. What I'd change about the issue

If Q1 comes back **non-zero**, the title and framing are wrong: it is not "deletes silently no-op",
it is "soft-delete is not durable across close/reopen", and defect #1 should be rewritten. I would
rather that correction come from your measurement than from my inference — I have given you both
readings above rather than picking the one that flatters the original report.

Defect #2 (non-atomic RAM-index rebuild → torn `store-count`) I am confident in independently: it is
visible in the code, and it is what made me misread a torn read as catastrophic data loss and
trigger an emergency restore. `sparse.lisp`'s copy-on-write index at HEAD addresses exactly that.
