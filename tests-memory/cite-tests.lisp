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
  (with-memory-graph (g)
    (let* ((c (%one-belief g '(:verdict . "green")))
           (r (mem:resolve-cite g (mem:claim-cite c) (local-time:now))))
      (is (eq :resolved (mem:cite-record-state r)))
      (is (null (mem:cite-record-changed-since r))))))

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
