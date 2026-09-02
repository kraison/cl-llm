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
