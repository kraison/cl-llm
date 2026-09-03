;;;; tests-memory/write-tests.lisp -- spec SS4-5.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defparameter +subj+ '(:repo . "cl-llm"))

(defun %touching (g)
  (st:claims-touching g 'mem:belief :repo "cl-llm" :role :subject))

(test a-belief-reads-back-with-standing-and-validity
  (with-memory-graph (g)
    (let ((start (%ts "2026-09-01T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from start)))
      (let ((claims (%touching g)))
        (is (= 1 (length claims)))
        (let ((c (first claims)))
          (is (eq :observed (st:claim-standing c)))
          (is (string= "green" (st:claim-object-key c)))
          (is (te:bound-unknown-p (te:extent-end (st:claim-extent c))))
          (is (local-time:timestamp=
               start (te:bound-earliest
                      (te:extent-start (st:claim-extent c))))))))))

(test the-three-absences-are-distinct-writes-and-distinct-reads
  "Spec SS10: each absence standing reads back as itself, never NIL and
never as one of the others."
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-absence g +subj+ "looked-in-ci" :producer +p+
                          :standing :searched-empty)
      (mem:record-absence g +subj+ "asked-owner" :producer +p+
                          :standing :indeterminate)
      (mem:record-absence g +subj+ "checked-docs" :producer +p+
                          :standing :uncovered))
    (let ((by-relation (mapcar (lambda (c) (cons (st:claim-relation c)
                                                 (st:claim-standing c)))
                               (%touching g))))
      (is (eq :searched-empty (cdr (assoc "looked-in-ci" by-relation
                                          :test #'string=))))
      (is (eq :indeterminate (cdr (assoc "asked-owner" by-relation
                                         :test #'string=))))
      (is (eq :uncovered (cdr (assoc "checked-docs" by-relation
                                     :test #'string=))))
      (is (every (lambda (c) (typep c 'mem:belief-unary)) (%touching g))
          "an absence has no object"))))

(test a-presence-standing-is-refused-on-an-absence-and-vice-versa
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (signals mem:belief-argument-error
        (mem:record-absence g +subj+ "x" :producer +p+
                            :standing :observed))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "x" '(:v . "1") :producer +p+
                           :standing :searched-empty)))))

(test producer-and-relation-are-checked-before-the-write
  "The error names the argument (spec SS5), not the engine's slot."
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "ci-status" '(:v . "1")
                           :standing :observed))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "CI Status" '(:v . "1")
                           :producer +p+ :standing :observed))
      (signals mem:belief-argument-error
        (mem:record-belief g +subj+ "ci-status" '(:v . "1")
                           :producer :keyword :standing :observed)))))

(test a-successor-closes-the-predecessor-s-validity
  "Spec SS4: both claims remain; the old one's end is now just before
the new one's start, so the two never share an instant."
  (with-memory-graph (g)
    (let ((t1 (%ts "2026-09-01T08:00:00Z"))
          (t2 (%ts "2026-09-02T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t1)))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "red")
                           :producer +p+ :standing :observed
                           :extent (%open-from t2)))
      (let* ((claims (%touching g))
             (green (find "green" claims :key #'st:claim-object-key
                                         :test #'string=))
             (red (find "red" claims :key #'st:claim-object-key
                                     :test #'string=)))
        (is (= 2 (length claims)) "supersession keeps both")
        (is (local-time:timestamp<
             (te:bound-latest (te:extent-end (st:claim-extent green)))
             t2))
        (is (te:bound-unknown-p (te:extent-end (st:claim-extent red))))
        (is-true (st:extents-disjoint-p (st:claim-extent green)
                                        (st:claim-extent red)))))))

(test re-asserting-the-held-value-is-idempotent
  (with-memory-graph (g)
    (let ((t1 (%ts "2026-09-01T08:00:00Z"))
          (t2 (%ts "2026-09-02T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t1)))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t2)))
      (is (= 1 (length (%touching g))))
      (is (te:bound-unknown-p
           (te:extent-end (st:claim-extent (first (%touching g)))))
          "the held belief is neither closed nor duplicated"))))

(test a-successor-starting-at-or-before-its-predecessor-is-refused
  (with-memory-graph (g)
    (let ((t1 (%ts "2026-09-02T08:00:00Z")))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                           :producer +p+ :standing :observed
                           :extent (%open-from t1)))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (signals mem:belief-successor-before-predecessor
          (mem:record-belief g +subj+ "ci-status" '(:verdict . "red")
                             :producer +p+ :standing :observed
                             :extent (%open-from t1)))))))

(test retraction-closes-transaction-time-and-leaves-validity-alone
  "Spec SS4: wrong, not outdated.  Control: before retraction the claim
is current."
  (with-memory-graph (g)
    (let (c)
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (setf c (mem:record-belief g +subj+ "ci-status"
                                   '(:verdict . "green")
                                   :producer +p+ :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-09-01T08:00:00Z")))))
      (is-true (st:claim-current-p c) "control")
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:retract-belief c :at (%tomorrow)))
      (let ((c2 (first (%touching g))))
        (is-false (st:claim-current-p c2))
        (is (te:bound-unknown-p (te:extent-end (st:claim-extent c2)))
            "validity untouched")
        (gdb:with-transaction ((graph-db::transaction-manager g))
          (signals mem:belief-argument-error
            (mem:retract-belief c2)))))))

(test only-a-belief-can-be-retracted
  "Final review critical 1: RETRACT-BELIEF type-checked nothing but
currency, so a decision's own trace claim could be closed through it.
Control: a belief still retracts."
  (with-memory-graph (g)
    (let* ((d (mem:conclude g (list :belief +subj+ "releasable"
                                    '(:verdict . "yes")
                                    :standing :inferred)
                            :producer +p+ :rule "r"))
           (id (mem:decision-id d))
           (concluded (lambda ()
                        (find "concluded"
                              (st:claims-touching g 'mem:trace :decision
                                                  id :role :subject)
                              :key #'st:claim-relation :test #'string=))))
      (is-true (st:claim-current-p (funcall concluded)) "control")
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (signals mem:belief-argument-error
          (mem:retract-belief (funcall concluded))))
      (is-true (st:claim-current-p (funcall concluded))
               "the decision's own record still stands")
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:retract-belief (mem:decision-claim d)))
      (is-false (st:claim-current-p (first (%touching g)))
                "control: a belief still retracts"))))
