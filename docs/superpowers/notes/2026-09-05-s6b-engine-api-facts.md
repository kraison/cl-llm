# S6b engine and code facts, verified before the plan (cl-llm#24)

Recon for `docs/superpowers/specs/2026-09-05-s6b-cross-store-memory-design.md`.
Every code assumption the spec makes, checked against the source it
would change. Nothing here is a defect to fix; the plan argues from
this.

Sources, all read-only:

- cl-llm `/home/raison/work/cl-llm/.worktrees/s6b`, branch
  `feat/s6b-adversarial-pass` (2163f2b).
- engine `/home/raison/work/vivace-graph-v3/.worktrees/epoch-axis`,
  branch `feat/epoch-axis` (63743b6) = `experiment` 3a8ca96 + #347.
  Its own recon is
  `docs/superpowers/notes/2026-09-05-epoch-axis-engine-api-facts.md`.

**One image was run**, `sbcl --non-interactive` over `:cl-llm/memory`
built from the two worktrees with a private FASL cache and a scratch
`gdb:*system-directory*`. Lines marked **VERIFIED (image)** quote its
output; the probe and its stores were deleted afterwards. It settled
clock attachment across a close/reopen (E2), the cross-graph refusal on
cl-llm's own `recall` (E1), and the epoch sequence over two memory
stores (E3, E10).

---

# §E — the ten items

## E1. Scope helper and snapshots (spec §3)

**`call-with-read-snapshot` takes the thunk FIRST.**
`transactions.lisp:3324` and the macro at `:3383`:

```lisp
(defun call-with-read-snapshot (thunk &optional (graph *graph*))
```

```lisp
(defmacro with-read-snapshot ((&optional (graph '*graph*)) &body body)
  "Evaluate BODY with reads of GRAPH pinned to a single consistent MVCC snapshot.
See CALL-WITH-READ-SNAPSHOT."
  `(call-with-read-snapshot (lambda () ,@body) ,graph))
```

Both exported (`package.lisp:282-283`), as is `*read-snapshots*`
(`:290`). **VERIFIED (source).**

**Nesting composes, per store, with no single instant.** The mechanism
is a registry keyed on the graph, not a `*transaction*` binding
(`transactions.lisp:31-33`):

```lisp
(defvar *read-snapshots* nil
  "Graph -> read-only snapshot transaction, or NIL.  Read-only snapshots are
per graph and may compose; read-write transactions are not (GH #53).")
```

and the docstring says the composition is deliberate
(`transactions.lisp:3333-3337`):

```lisp
The snapshot is recorded in *READ-SNAPSHOTS* under GRAPH rather than bound to
*TRANSACTION*, so snapshots on several graphs COMPOSE: a cross-graph query holds
one snapshot per participating graph, each internally consistent, with
deliberately no single instant across them (GH #53).  An enclosing snapshot of
the SAME graph is inherited, as is a read-write transaction on it.
```

Pinned by `composed-snapshots-each-hide-their-own-graphs-later-commits`
(`tests/multi-graph-tests.lisp:1145-1173`), which is the discriminating
test: a commit into either graph after both snapshots start is invisible
to that graph's read and visible outside. **VERIFIED (source).**

**No extra per-store pin is needed.** The helper already takes one
(`transactions.lisp:3339-3345`):

```lisp
Also takes a read-epoch pin on GRAPH's own manager for the extent (GH #168):
under a shared image clock, a cross-store composition holds one such pin per
participating store, so store B's reaper cannot free a version store A's
snapshot could still dereference.  Nesting composes this for free -- each
graph's own CALL-WITH-READ-SNAPSHOT pins only its own manager, and the named
cost (spec sec.6) is that a long cross-store query delays reaping in every
store it touched.
```

**VERIFIED (image):** inside two nested snapshots over two cl-llm memory
stores, `gdb:*transaction*` is `NIL`, `*read-snapshots*` holds 2 entries,
both `recall`s answer, and the table is `NIL` again on exit:

```
B3 *transaction* inside snapshots    = NIL
B4 *read-snapshots* entries          = 2
B5 recall w / p under snapshots      = 1 1
B6 *read-snapshots* after extent      = NIL
```

**`*transaction*` bound on store A, entering a snapshot of store B.**
The helper does *not* refuse. Its cond
(`transactions.lisp:3347-3356`) inherits only when the transaction
covers *this* graph:

```lisp
      ((and *transaction* (%transaction-covers-graph-p *transaction* graph))
       (funcall thunk))
```

so B falls through to the `t` branch and gets a real snapshot. **The
refusal comes later, at the read.** `lookup-vertex` is
`(lookup-object id (vertex-table graph) *transaction* graph)`
(`vertex.lisp:114`), and with a non-NIL transaction the transactional
method fires (`transactions.lisp:319-324`):

```lisp
  (:method (id table transaction (graph t))
    ;; A read-write transaction is single-graph (GH #53).
    (let ((txn-graph (graph transaction)))
      (unless (eq graph txn-graph)
        (error 'cross-graph-transaction-error
               :node id :transaction-graph txn-graph :node-graph graph))))
```

The read path from `claims-touching` reaches it: `index-lookup`
(`index.lisp:1008`) calls `%node-by-id`, which is
`(or (lookup-vertex id :graph graph) (lookup-edge id :graph graph))`
(`spatial-query.lisp:37-40`). An existing snapshot of B does **not**
rescue it — pinned by
`read-write-transaction-blocks-a-foreign-read-even-under-a-snapshot`
(`tests/multi-graph-tests.lisp:1175-1191`).

**VERIFIED (image)**, through cl-llm's own `mem:recall`:

```
B7 recall of P inside a tx on W: CROSS-GRAPH-TRANSACTION-ERROR
B8 same, P snapshotted first: CROSS-GRAPH-TRANSACTION-ERROR
B9 recall of W inside a tx on W       = 1 rows
```

**Consequence for §3.** The helper's own up-front refusal on
`gdb:*transaction*` is the right design and is the *only* guard for the
own-store half: a scope read of the writer's own store inside its
transaction succeeds and shows uncommitted state (B9, and
`claims-touching`'s own docstring, `spacetime/claim-query.lisp:327-329`:
"Inside an open transaction the answer is what THAT transaction will
commit"). The engine refuses only the foreign half.

## E2. Clock attachment visibility

**`graph-system-clock` is an in-memory slot with a public reader.**
`graph-class.lisp:223-229`:

```lisp
   ;; The image-level epoch clock (GH #168), or NIL for this store's own
   ;; counter.  NIL is the pre-#168 behaviour and the default.  Reader
   ;; public, writer internal: ATTACH-TO-SYSTEM-CLOCK is the only entry
   ;; point -- a bare SETF would skip its watermark/journal (GH #183).
   (system-clock :reader graph-system-clock
                 :accessor %graph-system-clock
                 :initarg :system-clock :initform nil)
```

"Same clock" is `eq` on the object; the struct's own accessors are not
exported. `#:graph-system-clock` and `#:attach-to-system-clock` are
(`package.lisp:46-47`). **VERIFIED (source).**

**`make-graph` and `open-graph` both attach for you.** Both take
`(system-clock *system-clock*)` (`graph.lisp:618`, `:1120`) and both
call, at the same point after the transaction manager is installed
(`graph.lisp:585-586`, `:1089-1090`):

```lisp
      (when system-clock
        (attach-to-system-clock graph system-clock))
```

So binding `gdb:*system-clock*` around the opens is sufficient; no
separate attach call is needed on open. **VERIFIED (source).**

**Attaching post-open works and refuses mid-transaction.**
`transactions.lisp:3233-3266`, abridged:

```lisp
(defun attach-to-system-clock (graph clock)
  "Raise CLOCK above GRAPH's persisted history and record the attach --
...
  (let ((tm (transaction-manager graph)))
    (with-transaction-manager-lock (tm)
      (when (minimum-start-transaction-id tm)
        (error 'attach-with-active-transactions :graph graph))
      (let ((watermark (max (load-highest-transaction-id graph)
                            ...)))
        (with-recursive-lock-held ((system-clock-lock clock))
          (clock-observe-epoch clock watermark)
          (journal-append clock :attach :store (graph-name graph)
                          :location (namestring (location graph)))
          (setf (%graph-system-clock graph) clock)))))
  graph)
```

**The attach does not persist.** The only record is
`(setf (%graph-system-clock graph) clock)` — an in-memory slot — and a
`:ATTACH` record in the *clock's* journal, which `open-graph` never
reads back. **VERIFIED (image)**, on a store that already had one
committed transaction:

```
A1 pre-attach commit id (own counter)  = 1
A2 claim-commit-epoch of that claim    = 1
A3 graph-system-clock before attach    = NIL
A4 attach-to-system-clock post-open  = OK
A5 graph-system-clock EQ the clock    = T
A6 post-attach commit id (clock)      = 2
A7 graph-system-clock after reopen    = NIL
A8 commit id after clockless reopen   = 3
A9 claim-commit-epoch of r2's claim   = 2
```

A7/A8 is the trap: after a `close-graph` and an `open-graph` with no
`:system-clock`, the store is detached, yet its own counter resumes at
3 — the numbers *look* like a continuation of the clock's sequence and
are not. See C1.

**`open-system-clock` locks the directory, one holder per process.**
`system-clock.lisp:73-76`:

```lisp
(defun open-system-clock (location &key (block-size 4096))
  "Open or create the system clock in directory LOCATION.  Ids resume above
the persisted ceiling, so a crash never reissues one.  Signals
SYSTEM-CLOCK-IN-USE if another live process holds LOCATION (GH #182)."
```

The lock is `flock(LOCK_EX|LOCK_NB)` on an fd held for the clock's
lifetime (`:26-34`, `:78-90`), so a *second open in the same image*
refuses too. **VERIFIED (image):**

```
B11 attach mid-transaction: ATTACH-WITH-ACTIVE-TRANSACTIONS
B12 second open of held clock: SYSTEM-CLOCK-IN-USE
```

**Where `scripts/memory-image.lisp` opens it.** `start`
(`scripts/memory-image.lisp:42-68`) sets `gdb:*system-directory*` at
`:58` and then opens exactly one store at `:60-62`. The clock must be
opened after `:58` and before `:60`, and — given A7 — the store must be
opened *with* it, either by `:system-clock` or by setting
`gdb:*system-clock*` for the image's whole life. `stop` (`:70-76`)
closes the graph and should close the clock after it.

## E3. Transaction id after commit (spec §7)

**`transaction-id` is `graph-db::` — internal.** `package.lisp` exports
neither `#:transaction-id` nor `#:graph-open-p`. It is an accessor on
the `tx` class (`transactions.lisp:506-509`), assigned once at commit
(`:3459`):

```lisp
               (setf (transaction-id tx) (tm-next-epoch tm))
```

`with-transaction` returns its body's value, so the engine's own idiom
works (`tests/spacetime/epoch-tests.lisp:49-56`):

```lisp
(defun %tx (graph thunk)
  "Run THUNK in a transaction on GRAPH; return the committed epoch --
the transaction's id, readable after the commit (#347 recon E2)."
  (graph-db::transaction-id
   (with-transaction (:graph graph)
     (funcall thunk)
     graph-db:*transaction*)))
```

**VERIFIED (image)** — the probe used exactly this shape for every write
(A1/A6/A8/B2 above).

**The alternative is `claim-commit-epoch` on the outcome claim.**
`spacetime/claim-query.lisp:140-149`:

```lisp
(defun claim-commit-epoch (claim)
  "The epoch of the transaction that committed CLAIM's version, or NIL
for a REAPED-CLAIM (a version the store no longer holds) and for a
version not yet committed -- an epoch is assigned at commit, so a claim
read inside its own open transaction has none.  The number is the
writer's own TRANSACTION-ID, comparable across stores only while they
share one SYSTEM-CLOCK -- see GRAPH-DB:GRAPH-SYSTEM-CLOCK (GH #347)."
  (unless (reaped-claim-p claim)
    (let ((e (graph-db:commit-epoch claim)))
      (and (plusp e) e))))
```

`commit-epoch` is exported (`package.lisp:368`) and is a node-head slot
(`node-class.lisp:424`), so reading it costs nothing beyond the claim
object already in hand.

**Which `conclude` should record.** Capturing `*transaction*` inside the
`with-transaction` is the cheaper of the two — no re-read, no second
index lookup — and it works on **both** of `conclude`'s paths, including
`%write-refusal`, which opens its own transaction (`memory/trace.lisp:
122-129`) and whose refused claims are the only ones a refusal has. The
`claim-commit-epoch` route needs a claim, so it is what `trace` must use
(it has the outcome claim and no transaction). Both agree: A2 and A9
show `claim-commit-epoch` returning exactly the committing
`transaction-id`.

## E4. `recall`'s inputs (spec §4)

**`claims-touching` takes no snapshot and reads its own store's
indexes** — its own words, `spacetime/claim-query.lisp:285-287`:

```lisp
CLAIM-CLASS is the PARENT class name; one call covers both arities.  Answers
from the claim graph's own indexes -- no cross-graph read, no snapshot, which
is what makes it implementable in this unit (design §8).
```

so a per-store snapshot taken by the caller is the only thing that makes
each store's answer internally consistent. **VERIFIED (source).**

**The `:at` filter path is per store and identity-based.**
`memory/recall.lisp:77-92`:

```lisp
  (let* ((all (st:claims-touching graph 'belief (car subject)
                                  (cdr subject) :role :subject))
         ;; The engine's :AT is the validity filter (cl-temporal-extent#2
         ;; fixed the open-ended case it used to get wrong).
         (at-window (and at (st:claims-touching
                             graph 'belief (car subject) (cdr subject)
                             :role :subject :at at)))
         (wanted (remove-if-not
                  (lambda (c)
                    (and ...
                         (or (null at) (member c at-window))))
                  all))
```

`(member c at-window)` is EQL on claim objects, so it is sound only
between two calls on the *same* store (and only because the node cache
hands back one instance). The `at` filter must stay per store, before
the union.

**The ordering helper.** `memory/recall.lisp:55-65`, unchanged by §4:

```lisp
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
```

Its inputs: `%start-instant` (`memory/write.lisp:54-55`,
`(te:bound-earliest (te:extent-start (st:claim-extent claim)))`) and
`%recorded-at` (`recall.lisp:25-30`, `st:claim-recorded-at` with a
unix-0 fallback for a pre-axis claim). Both wall clock; §10 keeps them
there.

**`belief-record` is constructed in exactly one place**,
`memory/recall.lisp:99-105`. Adding a `store` slot is a known-size
change; every reader of its fields:

| site | fields |
|---|---|
| `agent/render.lisp:63-77` (`%record-json`) | claim, superseded-by, extent, standing, current-p |
| `agent/memory-tools.lisp:26,32-33` | claim |
| `memory/capture.lisp:241-247` (`capture-listing`) | claim, superseded-by, current-p |
| `tests-memory/recall-tests.lisp:27,40,49,51,53,54,62,82,90,92` | all |
| `tests-memory/capture-tests.lisp:56,57,73-76` | claim, current-p, superseded-by |
| `tests-memory/trace-tests.lisp:54,73-82` | claim, current-p, superseded-by |
| `tests-memory/banner-tests.lisp:86-93,197-204,240` | current-p, standing, claim, extent, retracted-at |
| `tests-agent/memory-tools-tests.lisp:261,305,306` | claim, standing |
| `tests-agent-prolog/query-tests.lisp:129-131` | claim |

No consumer constructs one, so a new slot is additive everywhere.
`%record-json` is the only signature that changes: it is
`(%record-json store record)` today and becomes `(%record-json record)`,
one call site (`agent/memory-tools.lisp:39`).

**The cross-store merge lives in `%recall-tool`**,
`agent/memory-tools.lisp:22-41`:

```lisp
            (rows '()))
       (when subject
         (dolist (g (scope-stores scope))
           (dolist (r (mem:recall g subject :relation relation :at instant))
             (note-cite scope (mem:claim-cite (mem:belief-record-claim r))
                        g)
             (push (cons g r) rows))))
       (setf rows (stable-sort (nreverse rows)
                               (lambda (a b)
                                 (mem:claim-before-p
                                  (mem:belief-record-claim (cdr a))
                                  (mem:belief-record-claim (cdr b))))))
```

Removing it changes the JSON in three ways, all of them what §4 wants:
`"store"` comes from the record rather than the loop variable;
`"superseded-by"` can name a claim in another store; `"current"` can be
false for a claim nothing closed. The `stable-sort`-on-scope-order
tie-break must survive: it is asserted in both orders by
`recall-breaks-a-genuine-cross-store-tie-by-scope-order`
(`tests-agent/memory-tools-tests.lisp:98-115`), so `recall`'s own union
must build the list store-major in scope order and `stable-sort` it.

`current-p` today is `(and (st:claim-current-p c) (%open-p c))`
(`recall.lisp:99-101`) and never consults `superseded-by`: within one
store a superseded claim has had its validity *closed* by
`%close-validity` (`write.lisp:84-97`), so `%open-p` is already false.
§4's redefinition therefore leaves every single-store assertion —
including `capture-listing`'s golden column 4
(`tests-memory/golden/capture.sexp`) — unchanged.

## E5. `conclude`'s shape (spec §5)

`memory/trace.lisp:133-170`, whole:

```lisp
(defun conclude (graph proposal
                 &key producer evidence rule rule-version confidence)
  "Decide PROPOSAL from EVIDENCE under RULE (SS4).  Owns its
transaction; signals BELIEF-ARGUMENT-ERROR when one is already open.
Returns a DECISION -- a refusal is RETURNED as one with :OUTCOME
:REFUSED and REPORT set, never signalled."
  (when gdb:*transaction*
    (%arg-error :transaction gdb:*transaction*
                "CONCLUDE owns its transaction; call it outside one"))
  (%check-producer producer)
  (unless (stringp rule) (%arg-error :rule rule "a string naming the rule"))
  (%check-proposal proposal)
  (let ((id (%mint-id))
        (pairs (mapcar (lambda (e) (%evidence-of e (store-name graph)))
                       evidence))
        (claim nil) (outcome nil))
    (handler-case
        (progn
          (gdb:with-transaction (:graph graph)
            (setf claim (%stage graph proposal producer rule rule-version
                                confidence))
            (let ((report (gdb:validate-transaction graph)))
              (when (gdb:validation-report-violations report)
                (error '%refused :report report)))
            (setf outcome
                  (%trace-claim graph id "concluded" :claim
                                (claim-cite claim) producer :inferred
                                :method rule :rule-version rule-version
                                :confidence confidence))
            (%write-evidence graph id pairs producer))
          (make-decision :id id :outcome :concluded :claim claim
                         :at (st:claim-recorded-at outcome)))
      (%refused (c)
        (%write-refusal graph id (%refused-report c) pairs producer
                        rule rule-version))
      (gdb:constraint-violation (c)
        ;; The report is advisory (SS2); the commit is the enforcement.
        (%write-refusal graph id c pairs producer rule rule-version)))))
```

The pre-transaction window §5 needs already exists: `pairs` is computed
at `:146-147`, before `with-transaction` opens at `:151`, and A8 of the
adversarial pass names that as the pattern.

**`%write-refusal`** (`:116-131`):

```lisp
(defun %write-refusal (graph id report pairs producer rule rule-version)
  "A fresh transaction recording the refusal (SS4 step 2/3): one REFUSED
claim per violated family, and one ATTEMPTED claim naming the rule the
agent was applying, with CONCLUDED's slots, so a refused decision still
says under which rule (#35)."
  (let ((outcome nil))
    (gdb:with-transaction (:graph graph)
      (%trace-claim graph id "attempted" :rule rule producer :observed
                    :method rule :rule-version rule-version)
      (dolist (row (%violation-families report))
        (setf outcome
              (%trace-claim graph id "refused" :violation (car row)
                            producer :observed :method (cdr row))))
      (%write-evidence graph id pairs producer))
    (make-decision :id id :outcome :refused :report report
                   :at (st:claim-recorded-at outcome))))
```

So a refusal family is one `trace-binary` with relation `"refused"`,
**object namespace `:violation`, object key = the family string**, and
`method` = the text. `outcome` is bound only inside the `dolist`: a
report yielding no rows leaves it NIL and `st:claim-recorded-at` then
signals. A `scope-conflict` report must yield at least one row.

**`%violation-families`** (`:103-114`) has exactly two branches:

```lisp
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
```

The else-branch hard-codes the family `"commit"`. See C2.

**`decision-report`** holds whatever was refused (`:6-11`):

```lisp
(defstruct decision
  "What CONCLUDE returns (SS4).  OUTCOME is :CONCLUDED or :REFUSED; CLAIM
the belief or absence written (NIL when refused); REPORT the
VALIDATION-REPORT or the commit condition (NIL when concluded); AT the
outcome claim's RECORDED-AT."
  id outcome claim report at)
```

Only one test constrains its type, on the validator path:
`(is (typep (mem:decision-report d) 'gdb:validation-report))`
(`tests-memory/trace-tests.lisp:222`). A `(:scope-conflict cite store)`
list widens the slot without breaking it.

**`%stage`** (`:43-58`) dispatches on the proposal kind and calls
`record-belief` for `:belief`, `record-absence` for `:absence`.

**`record-belief`'s predecessor search closes the prior in the SAME
store only** (`memory/write.lisp:119-127`):

```lisp
  (let ((start (te:bound-earliest (te:extent-start extent)))
        (pred (%current-predecessor graph producer subject relation)))
    (when pred
      (cond ((%same-object-p object pred)
             (return-from record-belief pred))
            ((not (local-time:timestamp< (%start-instant pred) start))
             (error 'belief-successor-before-predecessor
                    :predecessor pred :start start))
            (t (%close-validity pred start))))
```

and `%current-predecessor` (`:77-82`) is:

```lisp
(defun %current-predecessor (graph producer subject relation)
  "The one open, current binary belief on the series, or NIL."
  (find-if (lambda (c) (and (typep c 'belief-binary)
                            (st:claim-current-p c)
                            (%open-p c)))
           (%series graph producer subject relation)))
```

over `%series` (`:67-75`), which filters `claims-touching` on producer
and relation. **The series key matches `%series-key`
(`recall.lisp:32-36`) exactly** — producer, subject namespace, subject
key, relation — so the pre-transaction scope read can reuse the same
key. It must not reuse `%current-predecessor` itself: see C3.

## E6. Cites (spec §6)

**`resolve-cite`** (`memory/cite.lisp:98-128`), whole:

```lisp
(defun resolve-cite (graph cite at)
  "CITE as of AT (SS5): find the claim by identity among the subject's
claims, then ask the engine for the version believed at AT.  Never
substitutes the current version -- it is consulted only for
CHANGED-SINCE.  A claim from a family with no validity extent can only
report CHANGED-SINCE :RETRACTED, :UPDATED or NIL -- :SUPERSEDED needs
%OPEN-P, which such a claim never satisfies."
  (multiple-value-bind (family ns key ikey) (split-cite cite)
    (let* ((current (%current-among ikey
                                    (st:claims-touching graph family ns key
                                                        :role :subject)))
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

**`%current-among`** (`:88-96`):

```lisp
(defun %current-among (ikey claims)
  "The claim in CLAIMS whose identity key is IKEY, preferring one still
current.  The key survives retraction and re-assertion
(kraison/vivace-graph#303), so retract-and-re-record of the identical
fact leaves two nodes on one key; anchoring on whichever the index
hands back first reported a held belief as :RETRACTED (#30)."
  (let ((matches (remove ikey claims :key #'st:claim-identity-key
                                     :test-not #'string=)))
    (or (find-if #'st:claim-current-p matches) (first matches))))
```

It draws from one graph's `claims-touching` and cannot pick the wrong
store's half; under a scope, the loop over stores wraps *it*, not
replaces it.

**`cite-record`** (`:60-66`) already has `store`:

```lisp
(defstruct cite-record
  "One cite resolved AS OF an instant (SS5).  STATE is :RESOLVED, :REAPED
or :ABSENT; CLAIM is the version believed then when :RESOLVED.
CHANGED-SINCE is :RETRACTED, :SUPERSEDED, :UPDATED or NIL.  STORE names
the store the cite was actually resolved against -- NIL when none was
(SS4.3); RESOLVE-CITE leaves it to its caller, which knows the graph."
  cite family (state :absent) claim standing extent changed-since store)
```

Four constructor calls: `cite.lisp:119`, `:121`, `:123`, and
`trace.lisp:204`. Only the three in `cite.lisp` need to start filling
`store`; the `trace.lisp` one is the out-of-scope `:absent` case, which
by contract carries no store (pinned by
`trace-omits-store-for-an-out-of-scope-evidence-cite`,
`tests-agent/memory-tools-tests.lisp:178-192`).

**`note-cite` and `cite-store`** (`agent/scope.lisp:50-63`):

```lisp
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
```

Every caller of `note-cite`: `agent/scope.lisp:62` (inside `cite-store`
itself, already first-wins by construction),
`agent/memory-tools.lisp:26` (recall's loop — the last-wins site),
`agent/memory-tools.lisp:131` (`%decision-json`, the write store),
`agent/planner-tools.lisp:44` (`%evidence-json`, the first source).
Four sites; the first-wins guard belongs in `note-cite`, so all four
inherit it.

**The retract tool's error result** (`agent/memory-tools.lisp:221-225`):

```lisp
     (let ((g (cite-store scope cite)))
       (unless g (error "no claim for cite ~a in scope" cite))
       (unless (eq g (scope-write-store scope))
         (error "store ~a is not writable in this scope"
                (mem:store-name g)))
```

It is a plain `cl:error`, which `llm:call-tool` (`src/tools.lisp:
300-309`) wraps into `c:llm-tool-error` with the message as
`:underlying`; the tool loop shows the model the text. It is not a JSON
result. Pinned by `retract-acts-on-the-write-store-only`
(`tests-agent/memory-tools-tests.lisp:308-327`), which uses
`(signals llm:llm-tool-error ...)`.

## E7. Decisions (spec §7)

**`decisions-citing`** (`memory/trace.lisp:274-290`) — bare ids,
unioned, `%recorded-instant` then id:

```lisp
(defun decisions-citing (graph claim-or-cite &key (scope (list graph)))
  "Ids of the decisions whose EVIDENCE cites CLAIM-OR-CITE, RECORDED-AT
descending then id (SS5), unioned over every store in SCOPE (SS4.3).
NIL means no decisions cite it."
  (let* ((cite (%cite-of claim-or-cite))
         (claims (loop for g in scope
                       append (st:claims-touching g 'trace :claim cite
                                                  :role :object
                                                  :relation "evidence"))))
    (mapcar #'cdr
            (sort (mapcar (lambda (c) (cons (%recorded-instant c)
                                            (st:claim-subject-key c)))
                          claims)
                  ...))))
```

`GRAPH` is unused in the body — the union is entirely over `scope`.
Every consumer of the return value: `agent/annotate.lisp:50`,
`agent/memory-tools.lisp:93-101`, `tests-agent/loop-tests.lisp:63`,
`tests-memory/store-tests.lisp:119-120`,
`tests-memory/trace-tests.lisp:352-355`. See C6.

**`trace`** (`:206-256`) resolves the decision in `graph` alone:

```lisp
  (let* ((claims (%decision-claims graph decision-id))
```

with `%decision-claims` (`:179-180`):

```lisp
(defun %decision-claims (graph id)
  (st:claims-touching graph 'trace :decision id :role :subject))
```

`:scope` is used only for evidence, through `%resolve-in` (`:192-204`):

```lisp
(defun %resolve-in (cite store-name graph scope at)
  "CITE resolved in the store its evidence claim named, when that store
is in SCOPE; unit-1 evidence (no store) resolves in GRAPH; a store out
of scope is :ABSENT (SS4.3). ..."
  (let ((g (if store-name (%store-in-scope store-name scope) graph)))
    (if g
        (let ((r (resolve-cite g cite at)))
          (setf (cite-record-store r) (store-name g))
          r)
        (make-cite-record :cite cite :state :absent))))
```

and `%store-in-scope` (`:189-190`) is
`(find name scope :key #'store-name :test #'string=)`.

**`trace-listing`** (`:258-272`) dereferences unconditionally at `:264`:

```lisp
  (loop for id in decision-ids
        for rec = (trace graph id :scope scope)
        collect (list (decision-record-outcome rec)
```

Its row shape is built explicitly, so an `epoch` slot on
`decision-record` does not move `tests-memory/golden/trace.sexp`; a
`:missing` outcome row would, and the golden fixture
(`%trace-fixture`, `trace-tests.lisp:398-407`) has no missing id.

**`%write-evidence`** (`:90-96`), the pair-key bug:

```lisp
(defun %write-evidence (graph id pairs producer)
  ;; :FROM-END T: the first store recorded for a repeated cite wins,
  ;; matching %VIOLATION-FAMILIES' first-per-family rule.
  (dolist (pair (remove-duplicates pairs :key #'car :test #'string=
                                   :from-end t))
    (%trace-claim graph id "evidence" :claim (car pair) producer :observed
                  :method (cdr pair))))
```

**`%evidence-of`** (`:77-88`) and **`%claim-store`** (`:70-75`):

```lisp
(defun %claim-store (claim)
  "The name of the store holding CLAIM, or NIL.  RESOLVE-NODE-GRAPH is
the engine's only route from a node to its store and is internal
(noted on kraison/vivace-graph#322)."
  (let ((g (graph-db::resolve-node-graph (gdb:id claim))))
    (and g (store-name g))))
```

`resolve-node-graph` still exists on `feat/epoch-axis`
(`interface.lisp:7-20`) and still returns three values:

```lisp
(defun resolve-node-graph (id &key class-hint)
  "The open store holding ID, as (values GRAPH STATUS STORE-ID) with
STATUS one of :RESOLVED, :DETACHED (registry knows the tag, no open
graph carries it) or :UNKNOWN. ..."
```

Still `graph-db::`-internal (`package.lisp:149` exports
`#:resolve-node-graph` — it *is* exported; the `::` in `%claim-store`
is unnecessary but harmless). Values unchanged since the adversarial
pass; A6's latent finding stands and is out of §11's scope.

**`agent/annotate.lisp`** `%newest-decision-by` (`:48-55`):

```lisp
(defun %newest-decision-by (graph cite producer scope since)
  "The newest decision citing CITE that PRODUCER made at or after SINCE."
  (loop for id in (mem:decisions-citing graph cite :scope scope)
        for rec = (mem:trace graph id :scope scope)
        when (and (string= producer (mem:decision-record-producer rec))
                  (not (local-time:timestamp< (mem:decision-record-at rec)
                                              since)))
          return id))
```

`graph` is `(first stores)` at the call site (`:134-135`); a foreign id
makes `rec` NIL and `decision-record-producer` signals.

**`%find-decision`** (`agent/memory-tools.lisp:43-47`):

```lisp
(defun %find-decision (scope id)
  "The store holding decision ID, or NIL."
  (find-if (lambda (g) (st:claims-touching g 'mem:trace :decision id
                                           :role :subject :limit 1))
           (scope-stores scope)))
```

Used by the trace tool (`:57`) and to label `decisions-citing` rows
(`:101`). Both disappear once `trace` searches the scope and
`decisions-citing` returns pairs.

**`decision` and `decision-record` consumers.** `decision`
(`trace.lisp:6-11`, slots `id outcome claim report at`): read by
`agent/memory-tools.lisp:127-142`, and by tests at
`tests-memory/trace-tests.lisp` (33-38, 68, 81-96, 108, 119-122,
155-163, 220-261, 272-279, 312, 330, 351, 395), `store-tests.lisp`
(57, 75, 85, 98, 112-118, 146), `write-tests.lisp` (163, 176),
`tests-agent/memory-tools-tests.lisp` (163-239, 424, 510).
`decision-record` (`:172-177`, slots
`id producer at rule rule-version confidence outcome conclusion
evidence refusals`): read by `agent/memory-tools.lisp:68-81,140`,
`agent/annotate.lisp:52-53`, `live-agent/live.lisp:29-35`,
`memory/trace.lisp:264-272`, and tests at
`tests-memory/trace-tests.lisp` (227, 273-294, 313, 331-335),
`store-tests.lisp` (115, 117), `tests-agent/annotate-tests.lisp`
(124-142), `loop-tests.lisp` (68-71). No consumer constructs either
struct outside `memory/trace.lisp`, so an `epoch` slot is additive.

**`claims/source.lisp`.** `%claim-doc-id` (`:114-124`):

```lisp
(defun %claim-doc-id (claim)
  "The fusion identity: RRF keys on (DOCUMENT-ID . TEXT), so one claim
reached through two queried endpoints must carry one id."
  (format nil "claim:~a:~(~a~)~@[:~a~]:~(~a~)"
          (%endpoint (st:claim-subject-namespace claim)
                     (st:claim-subject-key claim))
          (st:claim-relation claim)
          (and (%binary-p claim)
               (%endpoint (st:claim-object-namespace claim)
                          (st:claim-object-key claim)))
          (st:claim-producer claim)))
```

Two callers: `%claim-evidence` (`:101`, the chunk's `document-id`) and
`collect-evidence`'s `seen` table (`:166`). Both have `source` in hand.

`%absence-evidence` (`:126-142`) shows the store form to match:

```lisp
           :document-id (format nil "claim-absence:~(~a~):~a"
                                (graph-db:graph-name
                                 (claim-source-graph source))
                                (%endpoint namespace key)))
```

— `graph-db:graph-name` downcased, **not** `mem:store-name`: see C7.

RRF's key is `(document-id . text)` (`rag/hybrid.lisp:10-13`):

```lisp
(defun %chunk-key (chunk)
  "Fusion identity for a chunk: (document-id . text).  NOT EQ -- dense and sparse stores hold
DIFFERENT chunk objects for the same underlying slice (each vertex->chunk makes a new one)."
  (cons (chunk-document-id chunk) (chunk-text chunk)))
```

so a store segment in the document id splits the two copies and stops
the double-scoring at `hybrid.lisp:24`'s `incf`.

## E8. Store names and validation (spec §3 `check-scope`)

**`store-name`** (`memory/schema.lisp:49-51`):

```lisp
(defun store-name (graph)
  "GRAPH's name as the string a model sees: downcased (SS5)."
  (string-downcase (symbol-name (gdb:graph-name graph))))
```

`symbol-name`, not `string` — A5+B7's latent finding. `graph-name` is an
accessor on the graph class (`graph-class.lisp:96`) and is exported
(`package.lisp:246`).

**"Open" is `graph-db::graph-open-p`, and it is NOT exported.**
`graph-class.lisp:101`:

```lisp
   (graph-open-p :accessor graph-open-p :initarg :graph-open-p :initform nil)
```

set T at the end of both `make-graph` (`graph.lisp:590`) and
`open-graph` (`:1094`), and cleared by `close-graph`. `package.lisp`
exports neither `#:graph-open-p` nor `#:transaction-id`. Checking the
transaction manager instead is worse: the slot is what the engine's own
registry collision guard consults (`graph-class.lisp:58`).

**`agent:make-scope`'s existing checks** (`agent/scope.lisp:25-41`):

```lisp
(defun make-scope (stores &key write-store producer sources
                                (k 5) (max-rows 50))
  (unless (and (consp stores) (every #'%graph-p stores))
    (%scope-error "STORES must be a non-empty list of open graphs"))
  (let ((write (or write-store (first stores))))
    (unless (member write stores)
      (%scope-error "the write store must be one of the readable stores"))
    (unless (st:canonical-producer-p producer)
      ...
```

Note the message already says "open graphs" and nothing checks it;
`%graph-p` is `(typep x 'graph-db::graph)` (`:14-15`). Distinctness,
openness and the clock are all unchecked today. One shared validator can
back both: `make-scope` keeps its producer/`k`/`max-rows` checks and
delegates the store-list checks.

**`scope-error`** (`agent/scope.lisp:6-8`):

```lisp
(define-condition scope-error (error)
  ((reason :initarg :reason :reader scope-error-reason))
  (:report (lambda (c s) (format s "~a" (scope-error-reason c)))))
```

**`belief-argument-error`** (`memory/write.lisp:7-15`):

```lisp
(define-condition belief-argument-error (error)
  ((argument :initarg :argument :reader belief-argument-error-argument)
   (value :initarg :value :reader belief-argument-error-value)
   (reason :initarg :reason :reader belief-argument-error-reason))
  (:report (lambda (c s)
             (format s "~a ~s: ~a"
                     (belief-argument-error-argument c)
                     (belief-argument-error-value c)
                     (belief-argument-error-reason c)))))
```

signalled only through `%arg-error` (`:25-27`), which hard-codes the
parent class. See C12.

Name collision to avoid: `%open-p` (`memory/write.lisp:57-65`) already
means "this claim's validity is still open". A store-open predicate
must not reuse it.

## E9. Test fixtures

**`tests-memory/harness.lisp:10-27`** — one store, `*system-directory*`
bound per test, **no** `*system-clock*` binding:

```lisp
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
      ...)))
```

**`tests-memory` already has a two-store fixture**, in
`store-tests.lisp:12-33` (`%call-with-two-stores` / `with-two-stores`),
with its own `(mem:define-memory-store :memory-private)` at `:10`. It
binds `gdb:*system-directory*` and no clock.

**`tests-agent/harness.lisp:15-35`** — the same shape for two stores:

```lisp
(defun %call-with-stores (fn)
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (dirs (list (format nil "/tmp/cl-llm-agent-w-~a/" stamp)
                     (format nil "/tmp/cl-llm-agent-p-~a/" stamp)))
         (gdb:*system-directory* (format nil "/tmp/cl-llm-agent-sys-~a/"
                                         stamp))
         (working (gdb:make-graph :cl-llm-memory (first dirs)
                                  :buffer-pool-size 1000))
         (private (gdb:make-graph :memory-private (second dirs)
                                  :buffer-pool-size 1000)))
```

Neither binds `graph-db:*system-clock*`; nothing in cl-llm mentions a
system clock today (no hit in `docs/*.md` or any `.lisp`).

**The model to copy** is `with-clocked-stores`
(`tests/spacetime/epoch-tests.lisp:22-47` in the epoch-axis worktree):

```lisp
(defmacro with-clocked-stores ((a b) &body body)
  "Two fresh stores A and B on ONE system clock, all in scratch dirs.
The attach is asserted inside the fixture: a store that silently failed
to attach would let every epoch test pass for the wrong reason."
  ...
           (let ((,clock (graph-db:open-system-clock (namestring ,cdir))))
             (unwind-protect
                  (let ((,a (make-graph *ep-a-name* (namestring ,da)
                                        :buffer-pool-size 1000
                                        :system-clock ,clock))
                        ...)
                    (unwind-protect
                         (progn
                           (is (eq (graph-db:graph-system-clock ,a)
                                   (graph-db:graph-system-clock ,b))
                               "fixture: both stores on one clock")
                           ,@body)
                      (ignore-errors (close-graph ,a))
                      (ignore-errors (close-graph ,b))
                      (collect-garbage)))
               (graph-db:close-system-clock ,clock))))))
```

Three requirements a cl-llm clocked fixture inherits: a **third** scratch
directory for the clock; `close-system-clock` in the *outer*
`unwind-protect`, outside the stores' (B12: a leaked clock refuses every
later open in the image); and the `eq` assertion inside the fixture, or
a silently unattached store passes every epoch test vacuously. Ruling 1
of the engine's own rulings note also applies: no `declare` at the head
of the body, because the fixture splices it after its `is` form.

**How the suites run.** `cl-llm.asd:240-242` and `:275-277`:

```lisp
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-memory)
               (error "cl-llm/memory suite failed."))))
```

```lisp
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-agent)
               (error "cl-llm/agent suite failed."))))
```

Both are plain `run!` on the suite keyword with **no** `:perform`-level
binding of `gdb:*system-directory*` — every harness binds its own, so
the FiveAM-bypasses-fixture-setup trap does not apply here. The
`:in-order-to ((test-op (test-op "cl-llm/memory/tests")))` links at
`:222` and `:259` are what make `asdf:test-system` non-vacuous
(cl-llm#26).

CI runs both through `.github/workflows/test.yml` (`asdf:test-system
:cl-llm/memory` and `:cl-llm/agent`, among six) against
`vivace-graph` `experiment` at branch head. **No check count for either
suite is written down anywhere** — `grep -rn "Did [0-9]" docs/ .github/`
finds only two unrelated lines
(`plans/2026-09-03-banner-round-trip.md:1040`,
`plans/2026-07-17-cl-llm-core.md:237`). The plan must record the
baseline it starts from.

## E10. Epoch reads today

**cl-llm calls `claims-touching :as-of` in exactly one place**:
`memory/cite.lisp:117`, inside `resolve-cite`:

```lisp
                               (st:claims-touching graph family ns key
                                                   :role :subject
                                                   :as-of at)))))
```

That is the single site that later moves to `:as-of-epoch`. Its `at`
comes from `%resolve-in`'s caller, `trace` (`trace.lisp:217,250-255`),
which passes `(%recorded-instant outcome)` — the deciding store's own
`recorded-at`. Nothing else in cl-llm uses `:as-of`;
`st:claims-by-producer` is called only from tests, never with `:as-of`.

**The #347 API, verbatim.** `claim-commit-epoch` is quoted in full under
E3. The `:as-of-epoch` keyword is on both readers
(`spacetime/claim-query.lisp:281-283` and `:505`):

```lisp
(defun claims-touching (graph claim-class namespace key
                        &key (role :either) current at during
                             relation limit offset as-of as-of-epoch)
```

```lisp
(defun claims-by-producer (graph claim-class producer
                           &key limit offset as-of as-of-epoch)
```

with `(check-type as-of-epoch (or null unsigned-byte))`, a refusal when
both axes are passed, and `%refuse-epoch-axis` on a clockless store
(`:340-345`, `:526-529`). The contract
(`claim-query.lisp:311-319`):

```lisp
:AS-OF-EPOCH (an integer) answers on the same axis by commit epoch (GH
#347): each claim is the version whose committing transaction id is the
newest at or below it, dropped when that version is retracted, and a
REAPED-CLAIM when older versions existed but are past :KEEP-REVISIONS
-- told from "created after" by the oldest retained REVISION.  Epochs
compare across stores only while the stores share one SYSTEM-CLOCK; a
clockless store signals EPOCH-AXIS-UNAVAILABLE.  One of :AS-OF or
:AS-OF-EPOCH, not both.  :CURRENT is redundant on this axis: only
versions still believed are ever selected.
```

**`epoch-axis-unavailable`** (`spacetime/claim-query.lisp:151-160`):

```lisp
(define-condition epoch-axis-unavailable
    (graph-db:query-precondition-error)
  ((graph-name :initarg :graph-name
               :reader epoch-axis-unavailable-graph-name))
  (:documentation "An :AS-OF-EPOCH read of a store with no system clock.
Its epochs are a private counter, so an answer would look like the
attached case and mean something unrelated (GH #347 recon E9).  The
parent's REASON is filled at the signal site. ..."))
```

Readers: `epoch-axis-unavailable-graph-name` (the graph name *symbol*,
not the store-name string) and the parent's
`graph-db:query-precondition-error-reason`. Both exported
(`spacetime/package.lisp:59-60`).

**The epoch sequence is one counter across stores. VERIFIED (image)**,
over two cl-llm memory stores on one clock:

```
B1 both stores EQ one clock          = T
B2 epochs across stores w,p,w        = 1 2 3 (<: T)
B10 claim-commit-epoch in w / p       = 1 2
```

---

# §C — corrections to the spec's assumptions

## C1. A clock attachment does not survive a reopen, and the epochs keep counting anyway

Spec §3: "an existing store without a clock is attached with
`attach-to-system-clock` on open."

Two things are wrong. First, `open-graph` already attaches when given
`:system-clock` (E2) — a separate `attach-to-system-clock` call is dead
code on that path. Second, and materially: the attach is an in-memory
slot plus a record in the *clock's* journal. After a `close-graph` and
an `open-graph` with no clock, `graph-system-clock` is NIL again and the
store resumes its **own** counter — seeded from its persisted highest
id, so it *continues the same integers*. VERIFIED (image), A6→A8: the
clock issued 2, the detached store then issued 3. Nothing signals,
nothing looks wrong, and the recorded epochs of two stores drift into
collision.

Consequence: `scripts/memory-image.lisp` must open the clock and hold it
for the image's life, passing it (or binding `gdb:*system-clock*`) on
**every** `open-graph`/`make-graph`, and `stop` must
`close-system-clock` after `close-graph`. `check-scope`'s clock check is
the only detector and it fires only for a scope wider than one store, so
a single-store image can drift undetected. `docs/agent-memory.md` should
say the clock is a property of the *image*, not of the store on disk.

## C2. `%violation-families` cannot render a `scope-conflict` row as written

Spec §5: "`%violation-families` renders that list as one `scope-conflict`
row." It has exactly two branches (quoted at E5) and the non-report
branch hard-codes `(cons "commit" (princ-to-string ...))`. A
`(:scope-conflict cite store-name)` report renders today as one row with
family `"commit"` and text `"(:SCOPE-CONFLICT ...)"` — the wrong family
name, and text the model reads as a Lisp form.

The change is a third branch keyed on the list's head, producing
`("scope-conflict" . "<prose naming the cite and its store>")`. It must
produce at least one row: `%write-refusal` binds `outcome` only inside
the `dolist`, so an empty family list makes `(st:claim-recorded-at nil)`
signal out of a function whose whole contract is to return a decision.

## C3. "The governing prior" is not `%current-predecessor`, and it does not exist for `:absence`

Spec §5 defines the governing prior as "the current claim in the series
whose validity start is latest but not later than the proposal's start."
`%current-predecessor` (quoted at E5) is a `find-if` over an unordered
`%series` for *any* open, current, **binary** claim. In the write store
that is unambiguous — `record-belief` closes the predecessor's validity,
so at most one is open. Across a scope nobody closes anything (GH #53),
so several stores can each hold an open current claim and `find-if`
would return whichever came first. The scope pre-read must compute
latest-start-not-after-the-proposal itself, over the union, then apply
the trust rule; it cannot delegate to `%current-predecessor`.

Second gap: `%stage` routes `(:absence ...)` to `record-absence`
(`write.lisp:168-187`), which has **no** predecessor search and no
supersession semantics at all. "The proposal's series" is undefined for
an absence. §5 should say the pre-read applies to `(:belief ...)` only,
and that `conclude-absence` therefore reaches it as a no-op — which is
compatible with §5's "`conclude-absence` needs no separate path" but for
a different reason than the spec gives.

## C4. `docs/decision-trace.md` does not exist

Spec §11's file table lists it. `docs/` holds only
`agent-memory.md`, `agent-tools.md`, `ci.md`, `evidence-bundle.md` and
two dated notes. The decision-trace surface is documented inside
`docs/agent-tools.md` (the `trace` / `decisions-citing` sections, and
the limits list at `:496-498`). The epoch note §7 asks for ("an older
decision's epoch is the store's own counter") belongs there, or the plan
creates the file deliberately.

## C5. `tests-memory` already has a two-store fixture, and a clocked one has three constraints

Spec §9 says "`tests-memory` gains `with-scoped-stores`". It already has
`with-two-stores` (`store-tests.lisp:12-33`) with its own
`(mem:define-memory-store :memory-private)`; adding a third fixture
duplicates the store declaration and the temp-dir dance. Extend it, or
say why not.

Whatever it is called, the clocked fixture must: allocate a **third**
scratch directory for the clock; `close-system-clock` in an outer
`unwind-protect` around the stores' (VERIFIED image B12: a second open
of a held clock signals `system-clock-in-use` *in the same process*, so
a leaked clock breaks every later test in the run); and assert
`(eq (graph-system-clock a) (graph-system-clock b))` inside the fixture,
because a store that silently failed to attach passes every epoch
assertion vacuously.

## C6. `decisions-citing` returning pairs breaks six call sites, three of them assertions

Spec §7 states the new return shape without naming the fallout:
`agent/annotate.lisp:50` (`for id in`), `agent/memory-tools.lisp:93-101`
(and `%find-decision` at `:101` becomes dead),
`tests-agent/loop-tests.lisp:63`,
`tests-memory/store-tests.lisp:119-120`, and
`tests-memory/trace-tests.lisp:352-355` (three `equal` comparisons
against flat id lists). The last two are existing green tests that must
be rewritten in the same commit, not left to CI.

## C7. `%claim-doc-id` cannot use `mem:store-name`, and needs a new argument

Spec §7: "`%claim-doc-id` includes the store name as its first segment
after `claim:`, matching `%absence-evidence`." `cl-llm/rag/claims`
depends on `cl-llm/rag` and `graph-db/spacetime` only (`cl-llm.asd:
179-190`) — never on `cl-llm/memory` — so `store-name` is unreachable
there. `%absence-evidence` uses `(graph-db:graph-name
(claim-source-graph source))` inside a `~(~a~)` directive, which
downcases the keyword; that is what "matching" must mean. Also
`%claim-doc-id` takes only the claim today; it needs the source (both
callers have it), which changes its signature and both call sites
(`source.lisp:101`, `:166`).

## C8. The snapshot helper's argument order, and the pin it need not take

Spec §3 proposes `(call-with-scope-snapshots scope thunk)`. The engine's
is `(call-with-read-snapshot thunk &optional graph)` — thunk first.
Matching the engine costs nothing and reads better at the one nesting
site. Separately, §3's "Is there any per-store read pin the helper must
take beyond the snapshot?" is answered no: `call-with-read-snapshot`
takes `pin-read-epoch` on each store's own manager and says nesting
composes it for free (quoted at E1).

## C9. Only the foreign half of a scope read is refused by the engine

Spec §3 says a scope read inside an open write transaction "would either
see the writer's own uncommitted state or hit the engine's cross-graph
refusal." Both halves are exactly right, and the asymmetry matters for
the test: the own-store read **succeeds** and shows uncommitted state
(VERIFIED image B9; `claims-touching`'s docstring at `:327-329` promises
it), so cl-llm's own `*transaction*` check is the *only* guard for it,
and §9's "the engine's cross-graph error never surfaces" test proves
only the foreign half. A single-store scope inside a transaction must be
refused by the same check or the guard is half a guard.

## C10. `transaction-id` and `graph-open-p` are internal symbols

Neither is in `graph-db`'s export list. §7's epoch recording needs
`graph-db::transaction-id` and §3's closed-graph check needs
`graph-db::graph-open-p`, both with double colons, both as deliberate
internal-symbol uses that the plan should note the way `%claim-store`
notes `resolve-node-graph`. `commit-epoch` *is* exported by #347, so the
`claim-commit-epoch` route needs no `::` at all — which is one more
reason `trace` should use it.

## C11. `memory/cite.lisp` needs less than §11 says

§11's row is "`resolve-cite :scope`, `%changed-since` through the
resolved store". The second half is already true: `%changed-since`
(`cite.lisp:77-86`) compares `then` and `current`, both drawn from the
single `graph` the function was called with, so once `resolve-cite`
picks a store the comparison is inside it by construction. And
`resolve-cite` has exactly one in-tree caller, `%resolve-in`
(`trace.lisp:201`), which passes an explicitly named store — adding
`&key (scope (list graph))` leaves it untouched. The row is one function.

## C12. `scope-argument-error` cannot be signalled through `%arg-error`

`%arg-error` (`write.lisp:25-27`) hard-codes `'belief-argument-error`.
A subtype needs either a `type` parameter on `%arg-error` or its own
`%scope-arg-error`. The condition also inherits a `(:report ...)` that
prints `value` with `~s`; a scope's value is a list of graph objects,
which prints long. Give `scope-argument-error` its own report, or pass
the store *names* as the value.

---

# §S — shape of the smallest correct change

In dependency order. Signatures are what the callers below assume.

### 1. `memory/scope.lisp` (new) — no dependencies

```lisp
(define-condition scope-argument-error (belief-argument-error) ())
(defun %scope-error (value reason) ...)          ; -> signals the above
(defun %store-open-p (graph) ...)                ; graph-db::graph-open-p
(defun check-scope (scope &key write-store) ...) ; -> scope
(defun call-with-scope-snapshots (thunk scope) ...)   ; thunk first (C8)
(defmacro with-scope-snapshots ((scope) &body body) ...)
```

`check-scope` refuses: empty; a non-`graph-db::graph`; a closed graph
(`graph-db::graph-open-p`); a repeated graph (`eq`); two graphs with one
`store-name`; `write-store` given and not `member`; and, when
`(rest scope)`, any store whose `gdb:graph-system-clock` is NIL or not
`eq` the first's — message naming the offending `store-name`s.
`call-with-scope-snapshots` refuses on `gdb:*transaction*` **before** any
engine call, for a scope of any size (C9), then nests
`gdb:call-with-read-snapshot` over the scope in order.

### 2. `memory/recall.lisp`

```lisp
(defstruct belief-record ... store)              ; new slot, last
(defun %successor (claim series scope) ...)      ; trust-order restricted
(defun recall (graph subject &key relation producer at include-retracted
                                  (scope (list graph))) ...)
```

`recall` calls `check-scope`, wraps `with-scope-snapshots`, runs today's
per-store filtering (including the EQL `at-window` membership, E4) once
per store, builds one `%series-key` table over the union of `all` lists,
and sorts the union with the existing `%before-p` **store-major in scope
order first** so `stable-sort` keeps the cross-store tie-break
(`memory-tools-tests.lisp:98`). `%successor` gains the scope-position
comparison; `current-p` becomes `(and (st:claim-current-p c) (%open-p c)
(null successor))`.

### 3. `memory/cite.lisp`

```lisp
(defun resolve-cite (graph cite at &key (scope (list graph))) ...)
```

First store in scope order whose `%current-among` answers wins; fill
`cite-record-store` there (three constructor sites). `%changed-since`
unchanged (C11).

### 4. `memory/trace.lisp`

```lisp
(defstruct decision ... epoch)
(defstruct decision-record ... epoch)
(defun %governing-prior (proposal producer scope write-store) ...)
(defun %scope-conflict-report (cite store-name) ...)  ; -> list
(defun %violation-families (report-or-condition) ...)  ; + a third branch
(defun %write-evidence (graph id pairs producer) ...)  ; :test #'equal
(defun conclude (graph proposal &key producer evidence rule rule-version
                                     confidence (scope (list graph))) ...)
(defun decisions-citing (graph claim-or-cite &key (scope (list graph)))
  ...)                                          ; -> ((id . store-name) ...)
(defun trace (graph decision-id &key (scope (list graph))) ...)
(defun trace-listing (graph decision-ids &key (scope (list graph))) ...)
```

`%governing-prior` runs under `with-scope-snapshots`, before
`with-transaction`, on `(:belief ...)` only (C3), reusing `%series-key`'s
four components. `conclude` records `epoch` by capturing
`(graph-db::transaction-id gdb:*transaction*)` inside both its own
`with-transaction` and `%write-refusal`'s (E3, C10); `trace` reads
`(st:claim-commit-epoch outcome)`. `%write-evidence`'s dedupe key
becomes the whole pair. `trace` finds `%decision-claims` in the first
scope store that answers, then reconstructs unchanged.

### 5. `memory/packages.lisp`

Export `check-scope`, `scope-argument-error`, `call-with-scope-snapshots`,
`with-scope-snapshots`, `belief-record-store`, `decision-epoch`,
`decision-record-epoch`.

### 6. `cl-llm.asd`

Add `(:file "scope")` to `cl-llm/memory` after `"write"` (it uses
`belief-argument-error` and `%arg-error`) and before `"recall"`.

### 7. `agent/scope.lisp`

```lisp
(defun note-cite (scope cite graph) ...)   ; first-wins
(defun make-scope (stores &key ...) ...)   ; delegates to mem:check-scope
```

`note-cite` becomes `(unless (nth-value 1 (gethash cite (scope-cites
scope))) (setf ...))`. `make-scope` wraps `mem:check-scope` in a
`handler-case` re-signalling `scope-error` with the message, per §8.

### 8. `agent/render.lisp`

```lisp
(defun %record-json (record) ...)          ; store from the record
```

`"store"` from `mem:belief-record-store`; `"superseded-by"` becomes
`(json:jobject "cite" ... "store" ...)` or NIL.

### 9. `agent/memory-tools.lisp`

Drop the merge loop in `%recall-tool` (one `mem:recall` with `:scope`,
note each row's own store). `%find-decision` deleted; the trace tool
calls `mem:trace` with the scope; `%decisions-citing-tool` renders the
pair's `store` directly. `%decision-json` gains `"epoch"` and keeps its
scope-less `mem:trace` (the decision is always in the write store).
`%retract-tool` unchanged — `cite-store` now agrees with it (C6, E6).

### 10. `agent/annotate.lisp`

`%newest-decision-by` iterates pairs, traces with the scope, and skips a
NIL `rec` before touching `decision-record-producer`.

### 11. `claims/source.lisp`

```lisp
(defun %claim-doc-id (source claim) ...)   ; graph-name first segment
```

Both callers pass `source` (C7).

### 12. `scripts/memory-image.lisp`

`start` opens the clock from `CL_LLM_MEMORY_CLOCK` (default
`~/.cl-llm-memory/clock/`) after `gdb:*system-directory*` is set and
before the store, keeps it in a `*clock*` special, and passes
`:system-clock` to both `open-graph` and `make-graph`. `stop` closes the
graph then the clock. The banner line should print the clock location
(C1: nothing else makes a detached reopen visible).

### 13. Fixtures

`tests-memory`: clock the existing `%call-with-two-stores` (C5), keeping
`with-memory-graph` untouched. `tests-agent`: clock
`%call-with-stores` the same way. Both take a third scratch dir, close
the clock in an outer `unwind-protect`, and assert the `eq` of the two
`graph-system-clock`s inside the fixture.

### Tests the plan must pin

Red-first against the single-store code, each named for its mechanism.

- **`check-scope`**, one test per refusal (duplicate graph; two graphs
  one `store-name`; a closed graph — `gdb:close-graph` then check;
  write store not in the list; two clocks; one clocked and one not),
  plus a positive for a clockless **single**-store scope.
- **Snapshot discipline**: a scope read inside `gdb:with-transaction` is
  `scope-argument-error`, for a two-store *and* a one-store scope (C9);
  a control asserting the engine's `cross-graph-transaction-error` is
  what would otherwise surface.
- **Trust rule** (#46): one series split across two clocked stores, both
  directions, with the reversed scope order as the control; assert
  `belief-record-superseded-by`, its store, and `current-p` on both rows.
- **`conclude`** (#50): higher-trust prior refused with a
  `"scope-conflict"` family whose text names the cite and store, and
  `st:claims-by-producer` unchanged in *both* stores; lower-trust prior
  concluded with the overridden cite as an evidence row whose `method`
  is that store's name; write-store prior still the validator path
  (`retract-then-conclude-at-the-same-valid-from-is-refused` is the
  control).
- **Cites** (#48): `resolve-cite` first-in-scope; `cite-store` after a
  `recall` over both stores still names the first store; `retract`
  refused by name for the non-writable copy and successful for the
  writable one — the existing
  `trace-names-the-store-the-decision-resolved-against` fixture
  (`memory-tools-tests.lisp:480-490`) already builds the one-cite,
  two-stores shape.
- **Decisions** (#47, #51, #49): `decisions-citing` returns
  `(id . store-name)` and the tool JSON carries `"store"`;
  `trace-listing` and `annotate-banners` survive a decision held only by
  the private store; one cite in two stores gives two evidence rows;
  two copies give two `retrieve` items with distinct `document-id`s and
  no doubled RRF score.
- **Epoch**: two `conclude`s on two stores under one clock record
  integer `epoch`s in increasing order, and a decision in a clockless
  single-store scope records one too (its own counter) — with a comment
  saying it is not comparable.
- **Runs**: memory then agent, foreground, one at a time; record the
  before/after check counts in the SDD ledger (E9: no baseline exists
  today).
