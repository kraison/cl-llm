;;;; tests-memory/cite-tests.lisp -- spec 2026-09-02 SS3 (cites) and
;;;; SS5 (resolution states, CHANGED-SINCE).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defparameter +cs+ '(:repo . "cl-llm"))

(defun %one-belief (g object &key (start "2026-09-01T08:00:00Z"))
  "Record and return one belief on +CS+ / ci-status."
  (gdb:with-transaction (:graph g)
    (mem:record-belief g +cs+ "ci-status" object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts start)))))

(test a-cite-names-the-family-and-the-identity-key
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite c)))
      (is (mem:cite-p cite))
      (is (string= (format nil "cl-llm.memory::belief|~a"
                           (st:claim-identity-key c))
                   cite))
      (multiple-value-bind (family ns key ikey) (mem:split-cite cite)
        (is (eq 'mem:belief family))
        (is (eq :repo ns))
        (is (string= "cl-llm" key))
        (is (string= (st:claim-identity-key c) ikey))))))

(test split-cite-honours-the-escape-rule
  "A | or \\ inside a key is escaped by the engine; the split must not
break on it (kraison/vivace-graph#321)."
  (with-memory-graph (g)
    (let* ((c (gdb:with-transaction (:graph g)
                (mem:record-belief g '(:path . "a|b\\c") "content"
                                   '(:digest . "d") :producer +p+
                                   :standing :asserted
                                   :extent (%open-from
                                            (%ts "2026-09-01T08:00:00Z")))))
           (cite (mem:claim-cite c)))
      (multiple-value-bind (family ns key) (mem:split-cite cite)
        (declare (ignore family))
        (is (eq :path ns))
        (is (string= "a|b\\c" key))))))

(test a-malformed-cite-is-an-argument-error
  (signals mem:belief-argument-error (mem:split-cite "no-family-here"))
  (signals mem:belief-argument-error
    (mem:split-cite "no.such.package::belief|p|:ns|k|r")))

(test a-cite-resolves-to-the-version-believed-then
  "SS5: after the cited belief is superseded, resolution AS OF an earlier
instant returns the open version, flagged :SUPERSEDED."
  (with-memory-graph (g)
    (let* ((green (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite green))
           (at (local-time:now)))
      (sleep 0.01)
      (%one-belief g '(:verdict . "red") :start "2026-09-02T08:00:00Z")
      (let ((r (mem:resolve-cite g cite at)))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (te:bound-unknown-p
             (te:extent-end (st:claim-extent (mem:cite-record-claim r))))
            "the as-of version still has its open validity end")
        (is (eq :superseded (mem:cite-record-changed-since r)))
        (is (eq :observed (mem:cite-record-standing r)))))))

(test a-retracted-cite-reads-as-retracted-since
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite c))
           (at (local-time:now)))
      (sleep 0.01)
      (gdb:with-transaction (:graph g) (mem:retract-belief c))
      (let ((r (mem:resolve-cite g cite at)))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (eq :retracted (mem:cite-record-changed-since r)))))))

(test an-unchanged-cite-has-no-changed-since
  "The node cache is weak-valued and on by default, so two lookups of the
same claim can hand back one EQ instance -- disabled here so the
comparison is genuinely by value, not by luck (see the engine's own
tests/spacetime/claim-query-tests.lisp,
CLAIMS-TOUCHING-RETURNS-EACH-CLAIM-ONCE, in vivace-graph)."
  (with-memory-graph (g)
    (let ((graph-db::*cache-enabled* nil))
      (let* ((c (%one-belief g '(:verdict . "green")))
             (r (mem:resolve-cite g (mem:claim-cite c) (local-time:now))))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (null (mem:cite-record-changed-since r)))))))

(test a-cite-created-after-the-instant-is-absent
  "A claim that did not exist at AT resolves :ABSENT, not to its
current version."
  (with-memory-graph (g)
    (let ((at (local-time:now)))
      (sleep 0.01)
      (let* ((c (%one-belief g '(:verdict . "green")))
             (r (mem:resolve-cite g (mem:claim-cite c) at)))
        (is (eq :absent (mem:cite-record-state r)))
        (is (null (mem:cite-record-claim r)))))))

(test changed-since-is-updated-on-an-in-place-edit
  "A field edit that touches neither the transaction axis (retraction)
nor validity (supersession) still moves the version stamp -- the third
CHANGED-SINCE case (SS5)."
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite c))
           (at (local-time:now)))
      (sleep 0.01)
      (gdb:with-transaction (:graph g)
        (let ((c2 (gdb:copy c)))
          (setf (st:claim-confidence c2) 0.5d0)
          (gdb:save c2)))
      (let ((r (mem:resolve-cite g cite at)))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (eq :updated (mem:cite-record-changed-since r)))))))

(test an-absence-standing-is-not-a-resolved-absent-state
  "SS3/global constraint: absence is not a value.  A recorded absence
resolves :RESOLVED, with its STANDING carrying what the search found --
:ABSENT names a cite that could not be resolved at all, not a belief-
unary's standing."
  (with-memory-graph (g)
    (let* ((a (gdb:with-transaction (:graph g)
                (mem:record-absence g +cs+ "no-such-relation"
                                    :producer +p+
                                    :standing :searched-empty)))
           (cite (mem:claim-cite a))
           (at (local-time:now)))
      (let ((r (mem:resolve-cite g cite at)))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (eq :searched-empty (mem:cite-record-standing r)))
        (is (typep (mem:cite-record-claim r) 'mem:belief-unary))
        (is (null (mem:cite-record-changed-since r)))))))

(test a-swept-cite-is-absent
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (cite (mem:claim-cite c))
           (at (local-time:now)))
      (sleep 0.01)
      (gdb:with-transaction (:graph g)
        (st:delete-claims-by-producer g 'mem:belief +p+))
      (is (eq :absent (mem:cite-record-state
                       (mem:resolve-cite g cite at)))))))

(test changed-since-of-a-claim-against-itself-is-nil
  "%CHANGED-SINCE compares a claim to itself: same CURRENT-P, same
OPEN-P, same version stamp -- NIL, not a signal."
  (with-memory-graph (g)
    (let ((v (%one-belief g '(:verdict . "green"))))
      (is (cl-llm.memory::%open-p v) "control: v is open")
      (is (null (cl-llm.memory::%changed-since v v))))))

(test open-p-does-not-signal-on-a-claim-with-no-validity-extent
  "Final review #14 unit 1 finding 2: %OPEN-P must not blow up on a
claim whose family carries no validity extent -- TE:EXTENT-END on NIL
is a type error.  Both public writers always give a claim an extent,
so there is no way to reach this through them; force it directly on a
COPY inside an open transaction with its extent-sexp cleared, and
never SAVE it -- the engine's own family constraints on a NIL extent
are not under test here, only %OPEN-P's NIL branch."
  (with-memory-graph (g)
    (let ((c (%one-belief g '(:verdict . "green"))))
      (gdb:with-transaction (:graph g)
        (let ((c2 (gdb:copy c)))
          (setf (st:claim-extent-sexp c2) nil)
          (is (null (cl-llm.memory::%open-p c2))))))))

(test a-cite-under-an-uninterned-namespace-resolves-absent
  "Final review follow-up: SPLIT-CITE validates the namespace as
canonical and then interns, rather than requiring it already be
interned.  A fresh image's first read of a decision must resolve its
evidence to :ABSENT, not signal, when nothing has yet been read under
that namespace -- here a hand-built cite over one no test records."
  (with-memory-graph (g)
    (%one-belief g '(:verdict . "green"))
    (let ((cite (concatenate
                 'string "cl-llm.memory::belief|" +p+
                 "|:zzznever|k|:verdict|yes|r"
                 "|((9680 28800 0) (9680 28800 0))")))
      ;; Never write the keyword literally: the READER would intern it
      ;; and the test would pass against FIND-SYMBOL too.
      (is (null (find-symbol "ZZZNEVER" :keyword))
          "precondition: nothing has interned this namespace yet")
      (multiple-value-bind (family ns) (mem:split-cite cite)
        (is (eq 'mem:belief family))
        (is (keywordp ns))
        (is (string= "ZZZNEVER" (symbol-name ns))))
      (let ((r (mem:resolve-cite g cite (local-time:now))))
        (is (eq :absent (mem:cite-record-state r)))
        (is (string= cite (mem:cite-record-cite r)))))
    (signals mem:belief-argument-error
      (mem:split-cite (concatenate
                       'string "cl-llm.memory::belief|" +p+
                       "|:Zzz Fab|k|:verdict|yes|r"
                       "|((9680 28800 0) (9680 28800 0))")))))

(test an-identical-re-assertion-after-retraction-is-refused
  "#30's premise, pinned the other way round: the family's unique tuple
canonicalises a temporal extent to its START, so it IS the identity
key, and a retracted claim still holds it -- two nodes on one key
cannot be written.  RESOLVE-CITE still prefers a current claim among
equal keys (%CURRENT-AMONG) in case the engine ever admits them; if
this test starts failing, that day has come and the anchoring must be
re-examined."
  (with-memory-graph (g)
    (let* ((c1 (%one-belief g '(:v . "1")))
           (key (st:claim-identity-key c1)))
      (gdb:with-transaction (:graph g) (mem:retract-belief c1))
      (signals gdb:unique-constraint-violation
        (gdb:with-transaction (:graph g)
          (mem:make-belief-binary
           :graph g
           :subject-namespace (car +cs+) :subject-key (cdr +cs+)
           :relation "ci-status" :object-namespace :v :object-key "1"
           :producer +p+ :standing :observed
           :extent (te:make-interval
                    (te:extent-start (st:claim-extent c1))
                    (te:exact-bound (%ts "2026-12-01T00:00:00Z"))
                    :semantics :validity :standing :asserted))))
      (let ((all (st:claims-touching g 'mem:belief (car +cs+) (cdr +cs+)
                                     :role :subject)))
        (is (= 1 (count key all :key #'st:claim-identity-key
                                :test #'string=)))
        (is (equalp (gdb:id c1)
                    (gdb:id (mem::%current-among key all))))))))
