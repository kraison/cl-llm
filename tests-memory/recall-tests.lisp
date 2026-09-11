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

;;; Cross-producer currency (#82): several instances of one agent share
;;; a store, each writing under its own producer.

(defparameter +px+ "agent/host/x")
(defparameter +py+ "agent/host/y")

(defun %belief-as (g producer object start)
  "A CI-STATUS belief on +SUBJ+ from PRODUCER, valid from START."
  (gdb:with-transaction (:graph g)
    (mem:record-belief g +subj+ "ci-status" object
                       :producer producer :standing :observed
                       :extent (%open-from (%ts start)))))

(defun %verdict (records key)
  (find key records :test #'string=
        :key (lambda (r) (st:claim-object-key
                          (mem:belief-record-claim r)))))

(test a-later-belief-from-another-producer-outdates-the-earlier-one
  "#82: supersession is per producer, so X's belief stays current in
its own series; the record names Y's later belief as what outdates it."
  (with-memory-graph (g)
    (%belief-as g +px+ '(:verdict . "green") "2026-09-01T08:00:00Z")
    (%belief-as g +py+ '(:verdict . "red") "2026-09-02T08:00:00Z")
    (let* ((rs (mem:recall g +subj+ :relation "ci-status"))
           (x (%verdict rs "green"))
           (y (%verdict rs "red")))
      (is (= 2 (length rs)))
      (is (eq t (mem:belief-record-current-p x))
          "current in its own series: nothing superseded it")
      (is (null (mem:belief-record-superseded-by x))
          "control: supersession is per producer and never fired")
      (let ((leader (mem:belief-record-outdated-by x)))
        (is (not (null leader)) "X is outdated by Y's later belief")
        (is (string= "red" (st:claim-object-key leader)))
        (is (string= +py+ (st:claim-producer leader)))
        (is (eq g (mem:belief-record-outdated-by-store x))))
      (is (null (mem:belief-record-outdated-by y))
          "the leader is outdated by nobody"))))

(test two-producers-starting-at-the-same-instant-are-a-disagreement
  "#82: equal validity starts -- neither leads, so neither is outdated."
  (with-memory-graph (g)
    (%belief-as g +px+ '(:verdict . "green") "2026-09-01T08:00:00Z")
    (%belief-as g +py+ '(:verdict . "red") "2026-09-01T08:00:00Z")
    (let ((rs (mem:recall g +subj+ :relation "ci-status")))
      (is (= 2 (length rs)))
      (is (every #'mem:belief-record-current-p rs))
      (is (every (lambda (r) (null (mem:belief-record-outdated-by r))) rs)
          "a disagreement, not an outdating"))))

(test retracting-the-leader-un-outdates-the-earlier-belief
  "#82: currency is derived on read, so withdrawing Y's belief restores
X's without anyone rewriting it."
  (with-memory-graph (g)
    (%belief-as g +px+ '(:verdict . "green") "2026-09-01T08:00:00Z")
    (let ((y (%belief-as g +py+ '(:verdict . "red")
                         "2026-09-02T08:00:00Z")))
      (is (not (null (mem:belief-record-outdated-by
                      (%verdict (mem:recall g +subj+ :relation "ci-status")
                                "green"))))
          "premise: outdated while Y stands")
      (gdb:with-transaction (:graph g) (mem:retract-belief y))
      (let ((rs (mem:recall g +subj+ :relation "ci-status")))
        (is (= 1 (length rs)))
        (is (null (mem:belief-record-outdated-by (first rs)))
            "a retracted claim never leads")))))

(test a-producer-ending-in-a-slash-filters-by-prefix
  "#82: <agent>/<host>/ answers for every instance on that host; any
other name still has to match exactly."
  (with-memory-graph (g)
    (%belief-as g +px+ '(:verdict . "green") "2026-09-01T08:00:00Z")
    (%belief-as g +py+ '(:verdict . "red") "2026-09-02T08:00:00Z")
    (flet ((n (producer)
             (length (mem:recall g +subj+ :relation "ci-status"
                                 :producer producer))))
      (is (= 2 (n "agent/host/")) "the prefix answers for both")
      (is (= 1 (n +px+)) "an exact name is still exact")
      (is (= 0 (n "agent/host"))
          "no trailing slash: an exact name nobody writes under")
      (is (= 0 (n "agent/other/")) "control: another host's prefix"))))
