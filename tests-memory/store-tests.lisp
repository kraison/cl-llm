;;;; tests-memory/store-tests.lisp -- the unit-2 amendments to unit 1:
;;;; a second store, evidence naming its store, TRACE with a scope.
;;;; Spec 2026-09-03 SS4.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

;; The second store's families, declared once at load (spec SS2: the
;; indexes and constraints are per graph name).
(mem:define-memory-store :memory-private)

(defun %call-with-two-stores (fn)
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (gdb:*system-directory* (format nil "/tmp/cl-llm-mem2-sys-~a/" stamp))
         (a (gdb:make-graph :cl-llm-memory
                            (format nil "/tmp/cl-llm-mem2-a-~a/" stamp)
                            :buffer-pool-size 1000))
         (b (gdb:make-graph :memory-private
                            (format nil "/tmp/cl-llm-mem2-b-~a/" stamp)
                            :buffer-pool-size 1000)))
    (unwind-protect (funcall fn a b)
      (ignore-errors (gdb:close-graph a))
      (ignore-errors (gdb:close-graph b))
      (dolist (d (list (format nil "/tmp/cl-llm-mem2-a-~a/" stamp)
                       (format nil "/tmp/cl-llm-mem2-b-~a/" stamp)
                       gdb:*system-directory*))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))

(defmacro with-two-stores ((a b) &body body)
  `(%call-with-two-stores (lambda (,a ,b) ,@body)))

(defparameter +ss+ '(:repo . "cl-llm"))

(defun %belief-in (g relation object)
  (gdb:with-transaction (:graph g)
    (mem:record-belief g +ss+ relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts "2026-09-01T08:00:00Z")))))

(test a-second-store-is-queryable-and-separate
  "SS2: DEFINE-MEMORY-STORE under the second name makes RECALL, CONCLUDE
and the validators live there; the first store sees nothing of it."
  (with-two-stores (a b)
    (%belief-in b "ci-status" '(:verdict . "green"))
    (is (= 1 (length (mem:recall b +ss+))))
    (is (null (mem:recall a +ss+)) "control: the first store is untouched")
    (let ((d (mem:conclude b (list :belief +ss+ "ci-status"
                                   '(:verdict . "green")
                                   :standing :observed
                                   :extent (%open-from
                                            (%ts "2026-09-01T08:00:00Z")))
                           :producer +p+ :rule "dup")))
      ;; same object, same start: RECORD-BELIEF's idempotent path
      (is (eq :concluded (mem:decision-outcome d))))
    (is (string= "memory-private" (mem:store-name b)))
    (is (null (find-symbol "TRACE-BINARY" '#:cl-llm.memory/tests))
        "no duplicate class minted in the caller's package (vg#323)")))

(test evidence-records-the-store-it-was-found-in
  "SS4.2: a decision in store A resting on a claim from store B says so
on the evidence claim's METHOD slot."
  (with-two-stores (a b)
    (let* ((private (%belief-in b "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite private))
           (d (mem:conclude a (list :belief +ss+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+
                            :evidence (list (cons cite "memory-private"))
                            :rule "r"))
           (ev (find "evidence"
                     (st:claims-touching a 'mem:trace :decision
                                         (mem:decision-id d) :role :subject)
                     :key #'st:claim-relation :test #'string=)))
      (is (string= "memory-private" (st:claim-method ev)))
      ;; a claim object records its own store
      (let* ((d2 (mem:conclude a (list :belief +ss+ "deployable" '(:v . "yes")
                                       :standing :inferred)
                               :producer +p+ :evidence (list private)
                               :rule "r"))
             (ev2 (find "evidence"
                        (st:claims-touching a 'mem:trace :decision
                                            (mem:decision-id d2)
                                            :role :subject)
                        :key #'st:claim-relation :test #'string=)))
        (is (string= "memory-private" (st:claim-method ev2))))
      ;; a bare cite records the write store
      (let* ((own (%belief-in a "last-push" '(:sha . "abc")))
             (d3 (mem:conclude a (list :belief +ss+ "x" '(:v . "1")
                                       :standing :inferred)
                               :producer +p+
                               :evidence (list (mem:claim-cite own))
                               :rule "r"))
             (ev3 (find "evidence"
                        (st:claims-touching a 'mem:trace :decision
                                            (mem:decision-id d3)
                                            :role :subject)
                        :key #'st:claim-relation :test #'string=)))
        (is (string= "cl-llm-memory" (st:claim-method ev3)))))))

(test trace-resolves-a-cross-store-cite-within-its-scope
  "SS4.3: with B in scope the cite resolves; without it, :ABSENT --
never silently resolved in the wrong store."
  (with-two-stores (a b)
    (let* ((private (%belief-in b "ci-status" '(:verdict . "green")))
           (d (mem:conclude a (list :belief +ss+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+
                            :evidence (list private) :rule "r"))
           (in (mem:trace a (mem:decision-id d) :scope (list a b)))
           (out (mem:trace a (mem:decision-id d))))
      (is (eq :resolved (mem:cite-record-state
                         (first (mem:decision-record-evidence in)))))
      (is (eq :absent (mem:cite-record-state
                       (first (mem:decision-record-evidence out)))))
      (is (equal (list (mem:decision-id d))
                 (mem:decisions-citing b private :scope (list a b))))
      (is (null (mem:decisions-citing b private))
          "control: B alone holds no decision"))))

(test claim-before-p-is-the-recall-order
  (with-two-stores (a b)
    (declare (ignore b))
    (let ((old (%belief-in a "ci-status" '(:verdict . "green")))
          (new (gdb:with-transaction (:graph a)
                 (mem:record-belief a +ss+ "ci-status" '(:verdict . "red")
                                    :producer +p+ :standing :observed
                                    :extent (%open-from
                                             (%ts "2026-09-02T08:00:00Z"))))))
      (is-true (mem:claim-before-p new old))
      (is-false (mem:claim-before-p old new)))))

(test trace-listing-resolves-cross-store-evidence-in-scope
  "#34: the listing takes the same :SCOPE as TRACE; without it the
other store's evidence is :ABSENT, with it :RESOLVED."
  (with-two-stores (a b)
    (let* ((e (%belief-in b "ci-status" '(:v . "1")))
           (d (mem:conclude a (list :belief +ss+ "releasable"
                                    '(:verdict . "yes") :standing :inferred)
                            :producer +p+
                            :evidence (list (cons (mem:claim-cite e)
                                                  (mem:store-name b)))
                            :rule "r"))
           (id (mem:decision-id d)))
      (is (eq :absent
              (second (first (fourth (first (mem:trace-listing
                                             a (list id))))))))
      (is (eq :resolved
              (second (first (fourth (first (mem:trace-listing
                                             a (list id)
                                             :scope (list a b)))))))))))
