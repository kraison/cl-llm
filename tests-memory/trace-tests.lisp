;;;; tests-memory/trace-tests.lisp -- spec 2026-09-02 SS4 (conclude),
;;;; SS5 (trace, decisions-citing), SS7.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defparameter +ts+ '(:repo . "cl-llm"))

(defun %belief (g relation object &key (start "2026-09-01T08:00:00Z"))
  (gdb:with-transaction (:graph g)
    (mem:record-belief g +ts+ relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts start)))))

(defun %trace-claims (g id)
  (st:claims-touching g 'mem:trace :decision id :role :subject))

(defun %relations (claims)
  (sort (mapcar #'st:claim-relation claims) #'string<))

(test conclude-writes-the-belief-and-its-trace
  "SS4: outcome :CONCLUDED; the belief is recorded with the rule; the
trace has one CONCLUDED and one EVIDENCE claim per cite."
  (with-memory-graph (g)
    (let* ((e1 (%belief g "ci-status" '(:verdict . "green")))
           (e2 (%belief g "last-push" '(:sha . "abc")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e1 e2)
                            :rule "green-and-pushed" :rule-version "1"
                            :confidence 0.9)))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (typep (mem:decision-claim d) 'mem:belief-binary))
      (is (string= "green-and-pushed"
                   (st:claim-method (mem:decision-claim d))))
      (is (string= "1" (st:claim-rule-version (mem:decision-claim d))))
      (is (typep (mem:decision-at d) 'local-time:timestamp))
      (let ((claims (%trace-claims g (mem:decision-id d))))
        (is (equal '("concluded" "evidence" "evidence")
                   (%relations claims)))
        (let ((concluded (find "concluded" claims
                               :key #'st:claim-relation :test #'string=)))
          (is (string= (mem:claim-cite (mem:decision-claim d))
                       (st:claim-object-key concluded)))
          (is (eq :inferred (st:claim-standing concluded)))
          (is (string= "green-and-pushed" (st:claim-method concluded))))
        (is (every (lambda (c) (eq :observed (st:claim-standing c)))
                   (remove "concluded" claims
                           :key #'st:claim-relation :test #'string=)))
        ;; SS6: the recalled belief carries the rule too
        (let ((r (first (mem:recall g +ts+ :relation "releasable"))))
          (is (string= "green-and-pushed"
                       (st:claim-method (mem:belief-record-claim r)))))))))

(test conclude-an-absence
  (with-memory-graph (g)
    (let ((d (mem:conclude g (list :absence +ts+ "release-date"
                                   :standing :searched-empty)
                           :producer +p+ :rule "looked-in-changelog")))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (typep (mem:decision-claim d) 'mem:belief-unary))
      (is (equal '("concluded") (%relations
                                 (%trace-claims g (mem:decision-id d))))))))

(test evidence-may-be-cites-and-duplicates-collapse
  (with-memory-graph (g)
    (let* ((e (%belief g "ci-status" '(:verdict . "green")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+
                            :evidence (list e (mem:claim-cite e))
                            :rule "r")))
      (is (equal '("concluded" "evidence")
                 (%relations (%trace-claims g (mem:decision-id d))))))))

(test concluding-the-object-already-held-is-a-new-decision
  "SS4: RECORD-BELIEF's idempotent path -- CONCLUDED cites the existing
belief, and the trace is new."
  (with-memory-graph (g)
    (let* ((held (%belief g "releasable" '(:verdict . "yes")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :rule "r")))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (equalp (gdb:id held) (gdb:id (mem:decision-claim d))))
      (is (= 1 (length (mem:recall g +ts+ :relation "releasable"))))
      (is (= 1 (length (%trace-claims g (mem:decision-id d))))))))

(test conclude-refuses-to-nest-in-a-callers-transaction
  (with-memory-graph (g)
    (gdb:with-transaction (:graph g)
      (signals mem:belief-argument-error
        (mem:conclude g (list :belief +ts+ "x" '(:v . "1")
                              :standing :inferred)
                      :producer +p+ :rule "r")))
    (is (null (mem:recall g +ts+)) "nothing was written")))

(test a-malformed-proposal-records-no-decision
  (with-memory-graph (g)
    (signals mem:belief-argument-error
      (mem:conclude g (list :belief +ts+ :not-a-string '(:v . "1")
                            :standing :inferred)
                    :producer +p+ :rule "r"))
    (signals mem:belief-argument-error
      (mem:conclude g (list :wish +ts+ "x") :producer +p+ :rule "r"))
    (is (null (st:claims-by-producer g 'mem:trace +p+))
        "no trace claims either")))

(test evidence-may-cite-any-claim-family
  "SS3/SS6: a decision cites any claim family, not only BELIEF -- here
a TRACE claim (a prior decision's CONCLUDED) is itself evidence."
  (with-memory-graph (g)
    (let* ((e (%belief g "ci-status" '(:verdict . "green")))
           (d1 (mem:conclude g (list :belief +ts+ "releasable"
                                     '(:verdict . "yes")
                                     :standing :inferred)
                             :producer +p+ :evidence (list e)
                             :rule "r"))
           (concluded (find "concluded"
                            (%trace-claims g (mem:decision-id d1))
                            :key #'st:claim-relation :test #'string=))
           (d2 (mem:conclude g (list :belief +ts+ "shippable"
                                     '(:verdict . "yes")
                                     :standing :inferred)
                             :producer +p+ :evidence (list concluded)
                             :rule "r2"))
           (evidence (find "evidence"
                           (%trace-claims g (mem:decision-id d2))
                           :key #'st:claim-relation :test #'string=)))
      (is (string= (mem:claim-cite concluded)
                   (st:claim-object-key evidence)))
      (is (= 0 (search "cl-llm.memory::trace|"
                       (st:claim-object-key evidence)))))))

(test a-non-claim-as-evidence-is-an-argument-error
  (with-memory-graph (g)
    (signals mem:belief-argument-error
      (mem:conclude g (list :belief +ts+ "x" '(:v . "1")
                            :standing :inferred)
                    :producer +p+ :evidence (list 42) :rule "r"))))

(defun %lapsed-belief (g &key (subject +ts+))
  "A belief on SUBJECT / ci-status held over [2026-01-01, 2026-03-01],
written closed: no current predecessor, so a re-assertion stages a
fresh claim (SS7).  Written closed in one go -- RECORD-BELIEF would
otherwise take its idempotent path against an open green belief on the
same subject and hand back THAT one."
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject "ci-status" '(:verdict . "green")
                       :producer +p+ :standing :observed
                       :extent (te:make-interval
                                (te:exact-bound (%ts "2026-01-01T00:00:00Z"))
                                (te:exact-bound (%ts "2026-03-01T00:00:00Z"))
                                :semantics :validity :standing :asserted))))

(defun %refused-families (g id)
  (sort (mapcar #'st:claim-object-key
                (remove "refused" (%trace-claims g id)
                        :key #'st:claim-relation :test-not #'string=))
        #'string<))

(test a-refused-proposal-is-recorded-and-writes-no-belief
  "SS4 step 2 / SS7: the extent-disjointness validator refuses the
overlap; the trace says so; RECALL shows no new belief."
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let ((d (mem:conclude g (list :belief +ts+ "ci-status"
                                   '(:verdict . "green")
                                   :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-02-01T00:00:00Z")))
                           :producer +p+ :rule "r")))
      (is (eq :refused (mem:decision-outcome d)))
      (is (null (mem:decision-claim d)))
      (is (typep (mem:decision-report d) 'gdb:validation-report))
      (is (equal '("subsystem") (%refused-families g (mem:decision-id d))))
      (is (= 1 (length (mem:recall g +ts+ :relation "ci-status"
                                   :include-retracted t)))
          "the lapsed belief is the only one; nothing new was written"))))

(test a-repeated-identity-is-refused-by-the-unique-family
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let ((d (mem:conclude g (list :belief +ts+ "ci-status"
                                   '(:verdict . "green")
                                   :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-01-01T00:00:00Z")))
                           :producer +p+ :rule "r")))
      (is (eq :refused (mem:decision-outcome d)))
      (is (member "unique" (%refused-families g (mem:decision-id d))
                  :test #'string=))
      (is (= 1 (length (mem:recall g +ts+ :relation "ci-status"
                                   :include-retracted t)))
          "the lapsed belief is the only one; nothing new was written"))))

(test a-refused-decision-still-records-its-evidence
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let* ((e (%belief g "last-push" '(:sha . "abc")))
           (d (mem:conclude g (list :belief +ts+ "ci-status"
                                    '(:verdict . "green")
                                    :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-02-01T00:00:00Z")))
                            :producer +p+ :evidence (list e) :rule "r")))
      (is (equal '("evidence" "refused")
                 (%relations (%trace-claims g (mem:decision-id d)))))
      (is (typep (mem:decision-at d) 'local-time:timestamp)))))

(test trace-reconstructs-a-decision
  (with-memory-graph (g)
    (let* ((e1 (%belief g "ci-status" '(:verdict . "green")))
           (e2 (%belief g "last-push" '(:sha . "abc")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e2 e1)
                            :rule "r" :rule-version "2" :confidence 0.5))
           (rec (mem:trace g (mem:decision-id d))))
      (is (string= (mem:decision-id d) (mem:decision-record-id rec)))
      (is (string= +p+ (mem:decision-record-producer rec)))
      (is (eq :concluded (mem:decision-record-outcome rec)))
      (is (string= "r" (mem:decision-record-rule rec)))
      (is (string= "2" (mem:decision-record-rule-version rec)))
      (is (= 0.5 (mem:decision-record-confidence rec)))
      (is (local-time:timestamp= (mem:decision-at d)
                                 (mem:decision-record-at rec)))
      (let ((c (mem:decision-record-conclusion rec)))
        (is (eq :resolved (mem:cite-record-state c)))
        (is (string= "yes" (st:claim-object-key
                            (mem:cite-record-claim c)))))
      ;; SS5 order: evidence in cite-string order, whatever was passed
      (let ((ev (mem:decision-record-evidence rec)))
        (is (= 2 (length ev)))
        (is (equal (sort (mapcar #'mem:claim-cite (list e1 e2)) #'string<)
                   (mapcar #'mem:cite-record-cite ev)))
        (is (every (lambda (r) (eq :resolved (mem:cite-record-state r)))
                   ev))
        (is (every (lambda (r) (null (mem:cite-record-changed-since r)))
                   ev)))
      (is (null (mem:decision-record-refusals rec))))))

(test trace-of-an-unknown-id-is-nil
  (with-memory-graph (g)
    (is (null (mem:trace g "no-such-decision")))))

(test trace-returns-the-evidence-as-believed-then
  "SS5 / #14 acceptance: the ground moved after the decision; the trace
still returns the version believed then, flagged."
  (with-memory-graph (g)
    (let* ((e (%belief g "ci-status" '(:verdict . "green")))
           (d (mem:conclude g (list :belief +ts+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e) :rule "r")))
      (sleep 0.01)
      (%belief g "ci-status" '(:verdict . "red")
               :start "2026-09-02T08:00:00Z")
      (let* ((rec (mem:trace g (mem:decision-id d)))
             (r (first (mem:decision-record-evidence rec))))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (string= "green" (st:claim-object-key
                              (mem:cite-record-claim r))))
        (is (te:bound-unknown-p
             (te:extent-end (st:claim-extent (mem:cite-record-claim r)))))
        (is (eq :superseded (mem:cite-record-changed-since r)))))))

(test trace-of-a-refusal
  (with-memory-graph (g)
    (%lapsed-belief g)
    (let* ((d (mem:conclude g (list :belief +ts+ "ci-status"
                                    '(:verdict . "green")
                                    :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-02-01T00:00:00Z")))
                            :producer +p+ :rule "r"))
           (rec (mem:trace g (mem:decision-id d))))
      (is (eq :refused (mem:decision-record-outcome rec)))
      (is (null (mem:decision-record-conclusion rec)))
      (is (equal '("subsystem")
                 (mapcar #'car (mem:decision-record-refusals rec))))
      (is (stringp (cdr (first (mem:decision-record-refusals rec))))))))

(test decisions-citing-finds-the-conclusions-resting-on-a-belief
  "SS5: the reverse direction, newest first; an uncited belief yields
NIL, which is 'no decisions', not an absence."
  (with-memory-graph (g)
    (let* ((e (%belief g "ci-status" '(:verdict . "green")))
           (other (%belief g "last-push" '(:sha . "abc")))
           (d1 (mem:conclude g (list :belief +ts+ "a" '(:v . "1")
                                     :standing :inferred)
                             :producer +p+ :evidence (list e) :rule "r"))
           (d2 (progn (sleep 0.01)
                      (mem:conclude g (list :belief +ts+ "b" '(:v . "1")
                                            :standing :inferred)
                                    :producer +p+ :evidence (list e)
                                    :rule "r"))))
      (is (equal (list (mem:decision-id d2) (mem:decision-id d1))
                 (mem:decisions-citing g e)))
      (is (equal (mem:decisions-citing g e)
                 (mem:decisions-citing g (mem:claim-cite e))))
      (is (null (mem:decisions-citing g other))))))

(defun %golden-trace-path ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/golden/trace.sexp"))

(defparameter +other+ '(:repo . "other")
  "The refused decision's subject: its lapsed belief must not share a
series with +TS+'s open ci-status, or RECORD-BELIEF's idempotent path
turns the refusal into a conclusion.")

(defun %trace-fixture (g)
  "Three decisions: one concluded, one refused, one whose ground moves.
Returns their ids in that order."
  (let* ((e1 (%belief g "ci-status" '(:verdict . "green")))
         (e2 (%belief g "last-push" '(:sha . "abc")))
         (d1 (mem:conclude g (list :belief +ts+ "releasable"
                                   '(:verdict . "yes") :standing :inferred
                                   :extent (%open-from
                                            (%ts "2026-09-01T09:00:00Z")))
                           :producer +p+ :evidence (list e1 e2)
                           :rule "green-and-pushed" :rule-version "1")))
    (%lapsed-belief g :subject +other+)
    (let ((d2 (mem:conclude g (list :belief +other+ "ci-status"
                                    '(:verdict . "green")
                                    :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-02-01T00:00:00Z")))
                            :producer +p+ :evidence (list e2)
                            :rule "re-assert")))
      (sleep 0.01)
      (let ((d3 (mem:conclude g (list :belief +ts+ "deployable"
                                      '(:verdict . "yes")
                                      :standing :inferred
                                      :extent (%open-from
                                               (%ts "2026-09-01T10:00:00Z")))
                              :producer +p+ :evidence (list e1)
                              :rule "green" :rule-version "1")))
        (sleep 0.01)
        (%belief g "ci-status" '(:verdict . "red")
                 :start "2026-09-02T08:00:00Z")
        (list (mem:decision-id d1) (mem:decision-id d2)
              (mem:decision-id d3))))))

(test trace-listing-matches-the-golden
  "Capture-and-diff (programme SS11): ordering is the contract."
  (with-memory-graph (g)
    (let* ((ids (%trace-fixture g))
           (rows (mem:trace-listing g ids))
           (golden (with-open-file (in (%golden-trace-path))
                     (let ((*package* (find-package :keyword)))
                       (read in)))))
      (is (equal golden rows)
          "diff: ~s" (set-exclusive-or golden rows :test #'equal)))))
