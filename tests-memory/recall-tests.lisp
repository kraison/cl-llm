;;;; tests-memory/recall-tests.lisp -- spec SS6.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %seed-series (g)
  "green from 09-01, red from 09-02, green again from 09-03; and an
absence on another relation.  Returns nothing; RECALL is the reader."
  (flet ((at (s) (%open-from (%ts s))))
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                         :producer +p+ :standing :observed
                         :extent (at "2026-09-01T08:00:00Z")))
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-belief g +subj+ "ci-status" '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (at "2026-09-02T08:00:00Z")))
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (mem:record-belief g +subj+ "ci-status" '(:verdict . "green")
                         :producer +p+ :standing :observed
                         :extent (at "2026-09-03T08:00:00Z"))
      (mem:record-absence g +subj+ "release-date" :producer +p+
                          :standing :searched-empty))))

(defun %objects (records)
  (mapcar (lambda (r)
            (let ((c (mem:belief-record-claim r)))
              (if (typep c 'mem:belief-binary)
                  (st:claim-object-key c)
                  (st:claim-standing c))))
          records))

(test recall-orders-newest-validity-first-and-marks-the-current-one
  "Spec SS6: order is the contract."
  (with-memory-graph (g)
    (%seed-series g)
    (let ((rs (mem:recall g +subj+ :relation "ci-status")))
      (is (equal '("green" "red" "green") (%objects rs)))
      (is (equal '(t nil nil)
                 (mapcar #'mem:belief-record-current-p rs))))))

(test a-superseded-belief-names-its-successor-and-is-never-current
  (with-memory-graph (g)
    (%seed-series g)
    (let* ((rs (mem:recall g +subj+ :relation "ci-status"))
           (red (second rs))
           (first-green (third rs)))
      (is (string= "green" (st:claim-object-key
                            (mem:belief-record-superseded-by red))))
      (is (string= "red" (st:claim-object-key
                          (mem:belief-record-superseded-by
                           first-green))))
      (is (null (mem:belief-record-superseded-by (first rs))))
      (is-false (mem:belief-record-current-p red)))))

(test recall-at-an-instant-returns-what-held-then
  (with-memory-graph (g)
    (%seed-series g)
    (let ((rs (mem:recall g +subj+ :relation "ci-status"
                          :at (%ts "2026-09-02T12:00:00Z"))))
      (is (equal '("red") (%objects rs)))
      (is-false (mem:belief-record-current-p (first rs))
                "held THEN, superseded since -- not current"))))

(test an-absence-is-recalled-as-itself-and-a-nil-read-is-not-one
  "Spec SS10: distinguishable in both directions.  The control asks for
a relation nobody wrote: NIL, which is not :UNCOVERED and not
:SEARCHED-EMPTY."
  (with-memory-graph (g)
    (%seed-series g)
    (is (equal '(:searched-empty)
               (%objects (mem:recall g +subj+ :relation "release-date"))))
    (is (null (mem:recall g +subj+ :relation "never-written"))
        "control: nothing recorded reads as nothing, not as an absence")))

(test a-retracted-belief-is-hidden-unless-asked-for-and-then-dated
  (with-memory-graph (g)
    (%seed-series g)
    (let* ((current (first (mem:recall g +subj+ :relation "ci-status")))
           (when-wrong (%tomorrow)))
      (gdb:with-transaction ((graph-db::transaction-manager g))
        (mem:retract-belief (mem:belief-record-claim current)
                            :at when-wrong))
      (is (equal '("red" "green")
                 (%objects (mem:recall g +subj+ :relation "ci-status"))))
      (let ((all (mem:recall g +subj+ :relation "ci-status"
                             :include-retracted t)))
        (is (equal '("green" "red" "green") (%objects all)))
        (is (local-time:timestamp= when-wrong
                                   (mem:belief-record-retracted-at
                                    (first all))))
        (is-false (mem:belief-record-current-p (first all)))))))

(test recall-without-a-relation-spans-every-series-of-the-subject
  (with-memory-graph (g)
    (%seed-series g)
    (is (= 4 (length (mem:recall g +subj+))))
    (is (= 0 (length (mem:recall g +subj+ :producer "someone/else"))))))
