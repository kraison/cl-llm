;;;; tests-memory/profile-tests.lisp -- endpoint profiles and the touch
;;;; (#78 SS2, SS4.2).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %pbelief (g subject relation object
                &optional (start "2026-08-30T08:00:00Z") (producer +p+))
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject relation object
                       :producer producer :standing :observed
                       :extent (%open-from (%ts start)))))

(defun %store-vector (g endpoint)
  "Give ENDPOINT's vertex a vector by hand, so a later touch shows as
its removal."
  (gdb:with-transaction (:graph g)
    (let ((c (gdb:copy (mem:endpoint-vector-of g (car endpoint)
                                               (cdr endpoint)))))
      (setf (slot-value c 'mem::embedding)
            (make-array 4 :element-type 'single-float
                          :initial-element 0.5f0)
            (slot-value c 'mem::ev-model) "m")
      (gdb:save c))))

(test a-profile-lists-the-current-beliefs-of-an-endpoint-in-both-roles
  (with-memory-graph (g)
    (%pbelief g '(:incident . "ledger-rollback-2026-08-30") "root-cause"
              '(:cause . "replica-checksum-mismatch"))
    (%pbelief g '(:decision . "freeze-deploys") "decided-because"
              '(:incident . "ledger-rollback-2026-08-30")
              "2026-08-31T08:00:00Z")
    (mem:with-scope-snapshots ((list g))
      (let ((text (mem:endpoint-profile
                   g :incident "ledger-rollback-2026-08-30")))
        (is (stringp text))
        (is (search "incident ledger rollback 2026 08 30" text)
            "the key as words: ~a" text)
        (is (search "root-cause cause:replica-checksum-mismatch" text))
        (is (search "decision:freeze-deploys decided-because" text)
            "the object role too")
        (is (search +p+ text) "the producer")
        (is (< (search "root-cause" text) (search "decided-because" text))
            "subject role first, then object role")))))

(test a-superseded-or-retracted-belief-leaves-the-profile
  (with-memory-graph (g)
    (let ((old (%pbelief g '(:repo . "cl-llm") "ci-status"
                         '(:verdict . "green"))))
      (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "red")
                "2026-08-31T08:00:00Z")
      (mem:with-scope-snapshots ((list g))
        (let ((text (mem:endpoint-profile g :repo "cl-llm")))
          (is (search "verdict:red" text))
          (is (null (search "verdict:green" text)) "superseded: gone"))
        (is (null (mem:endpoint-profile g :verdict "green"))
            "an endpoint with nothing current has no profile"))
      (gdb:with-transaction (:graph g) (mem:retract-belief old))
      (is (null (mem:endpoint-profile g :verdict "green"))))))

(test an-absence-is-never-a-profile-line
  (with-memory-graph (g)
    ;; Positive control: a belief on the endpoint makes the profile
    ;; non-NIL, so the NIL checks below (on a wholly separate,
    ;; absence-only endpoint) are not vacuous.
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:with-scope-snapshots ((list g))
      (is (not (null (mem:endpoint-profile g :repo "cl-llm")))
          "positive control: a belief makes the profile non-nil"))
    (gdb:with-transaction (:graph g)
      (mem:record-absence g '(:repo . "cl-llm") "postmortem"
                          :producer +p+ :standing :searched-empty)
      (mem:record-absence g '(:incident . "standalone") "postmortem"
                          :producer +p+ :standing :searched-empty))
    (mem:with-scope-snapshots ((list g))
      (let ((text (mem:endpoint-profile g :repo "cl-llm")))
        (is (not (null text)))
        (is (null (search "postmortem" text)) "the absence added no line"))
      (is (null (mem:endpoint-profile g :incident "standalone"))
          "an absence-only endpoint has no profile"))
    (is (null (mem:endpoint-vector-of g :incident "standalone"))
        "and recording it touched nothing")))

(test the-profile-is-capped-newest-first
  (with-memory-graph (g)
    (dotimes (i 5)
      (%pbelief g '(:repo . "cl-llm") (format nil "rel~D" i)
                (cons :thing (format nil "t~D" i))
                (format nil "2026-08-~2,'0DT08:00:00Z" (1+ i))))
    (let ((text (mem:endpoint-profile g :repo "cl-llm" :cap 2)))
      (is (search "thing:t4" text))
      (is (search "thing:t3" text))
      (is (null (search "thing:t2" text)) "cap 2 keeps the newest two"))))

(test touching-clears-the-vector-and-creates-the-vertex
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (let ((ev (mem:endpoint-vector-of g :repo "cl-llm")))
      (is (not (null ev)) "the write created the vertex")
      (is (null (mem:endpoint-vector-value ev)))
      (is (mem:endpoint-dirty-p g :repo "cl-llm" "m")))
    ;; Store a vector by hand, then touch: it must be gone.
    (gdb:with-transaction (:graph g)
      (let ((c (gdb:copy (mem:endpoint-vector-of g :repo "cl-llm"))))
        (setf (slot-value c 'mem::embedding)
              (make-array 4 :element-type 'single-float
                            :initial-element 0.5f0)
              (slot-value c 'mem::ev-model) "m")
        (gdb:save c)))
    (is (not (mem:endpoint-dirty-p g :repo "cl-llm" "m")))
    (is (mem:endpoint-dirty-p g :repo "cl-llm" "other-model")
        "a vector from another model reads as dirty")
    (gdb:with-transaction (:graph g)
      (mem:touch-endpoints g '((:repo . "cl-llm"))))
    (is (null (mem:endpoint-vector-value
               (mem:endpoint-vector-of g :repo "cl-llm"))))
    (is (mem:endpoint-dirty-p g :repo "cl-llm" "m"))))

(test an-idempotent-record-touches-nothing
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (gdb:with-transaction (:graph g)
      (let ((c (gdb:copy (mem:endpoint-vector-of g :repo "cl-llm"))))
        (setf (slot-value c 'mem::embedding)
              (make-array 4 :element-type 'single-float
                            :initial-element 0.5f0)
              (slot-value c 'mem::ev-model) "m")
        (gdb:save c)))
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (is (not (null (mem:endpoint-vector-value
                    (mem:endpoint-vector-of g :repo "cl-llm"))))
        "the same object again writes nothing and clears nothing")))

(test superseding-touches-the-old-object-endpoint
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (dolist (ep '((:repo . "cl-llm") (:verdict . "green")))
      (gdb:with-transaction (:graph g)
        (let ((c (gdb:copy (mem:endpoint-vector-of g (car ep) (cdr ep)))))
          (setf (slot-value c 'mem::embedding)
                (make-array 4 :element-type 'single-float
                              :initial-element 0.5f0)
                (slot-value c 'mem::ev-model) "m")
          (gdb:save c))))
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "red")
              "2026-08-31T08:00:00Z")
    (is (null (mem:endpoint-vector-value
               (mem:endpoint-vector-of g :verdict "green")))
        "the superseded belief's object endpoint lost a line")
    (is (null (mem:endpoint-vector-value
               (mem:endpoint-vector-of g :repo "cl-llm"))))
    (is (not (null (mem:endpoint-vector-of g :verdict "red")))
        "the new object endpoint exists, dirty")))

(test a-retract-touches-both-endpoints
  (with-memory-graph (g)
    (let ((b (%pbelief g '(:repo . "cl-llm") "ci-status"
                       '(:verdict . "green"))))
      (dolist (ep '((:repo . "cl-llm") (:verdict . "green")))
        (gdb:with-transaction (:graph g)
          (let ((c (gdb:copy (mem:endpoint-vector-of g (car ep) (cdr ep)))))
            (setf (slot-value c 'mem::embedding)
                  (make-array 4 :element-type 'single-float
                                :initial-element 0.5f0)
                  (slot-value c 'mem::ev-model) "m")
            (gdb:save c))))
      (gdb:with-transaction (:graph g) (mem:retract-belief b))
      (is (null (mem:endpoint-vector-value
                 (mem:endpoint-vector-of g :repo "cl-llm"))))
      (is (null (mem:endpoint-vector-value
                 (mem:endpoint-vector-of g :verdict "green")))))))

(test touching-twice-in-one-transaction-makes-one-vertex
  (with-memory-graph (g)
    (gdb:with-transaction (:graph g)
      (mem:touch-endpoints g '((:repo . "once")))
      (mem:touch-endpoints g '((:repo . "once"))))
    (is (= 1 (length (gdb:index-lookup
                      g 'mem:endpoint-vector '(mem:ev-namespace mem:ev-key)
                      (list :repo "once"))))
        "one transaction, two touches: the guard skips the second")
    ;; Control: two SEPARATE, sequential transactions -- the second
    ;; sees the first's commit and does not duplicate it.
    (gdb:with-transaction (:graph g)
      (mem:touch-endpoints g '((:repo . "twice"))))
    (gdb:with-transaction (:graph g)
      (mem:touch-endpoints g '((:repo . "twice"))))
    (is (= 1 (length (gdb:index-lookup
                      g 'mem:endpoint-vector '(mem:ev-namespace mem:ev-key)
                      (list :repo "twice"))))
        "two sequential transactions also leave one vertex")))

(test two-transactions-on-a-fresh-endpoint-leave-no-vector
  (with-memory-graph (g)
    ;; No DEF-UNIQUE any more (R-a): two transactions can each
    ;; first-touch a never-indexed endpoint, so more than one live
    ;; vertex can exist for it.  Simulate the race: touch once, then
    ;; hand-create a second vertex WITH a vector in its own
    ;; transaction (as another connection racing the index would),
    ;; then touch again -- every live vertex must end up vector-less.
    (gdb:with-transaction (:graph g)
      (mem:touch-endpoints g '((:repo . "race"))))
    (gdb:with-transaction (:graph g)
      (mem::make-endpoint-vector
       :graph g :ev-namespace :repo :ev-key "race" :ev-model "m"
       :embedding (make-array 4 :element-type 'single-float
                                :initial-element 0.5f0)))
    (gdb:with-transaction (:graph g)
      (mem:touch-endpoints g '((:repo . "race"))))
    (let ((evs (gdb:index-lookup
                g 'mem:endpoint-vector '(mem:ev-namespace mem:ev-key)
                (list :repo "race"))))
      (is (= 2 (length evs)) "both benign duplicate vertices remain")
      (dolist (ev evs)
        (is (null (mem:endpoint-vector-value ev)))))))

(test a-belief-another-producer-outdates-leaves-the-profile
  "#82: currency is cross-producer on read, so X's line must leave the
subject's profile when Y's later belief leads -- and the write that
outdated it must touch X's object endpoint, or the stale line stays
embedded there."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green")
              "2026-08-30T08:00:00Z" +px+)
    (mem:with-scope-snapshots ((list g))
      (is (not (null (mem:endpoint-profile g :verdict "green")))
          "premise: X's belief is in the profile while it leads"))
    (%store-vector g '(:verdict . "green"))
    (let ((y (%pbelief g '(:repo . "cl-llm") "ci-status"
                       '(:verdict . "red") "2026-08-31T08:00:00Z" +py+)))
      (mem:with-scope-snapshots ((list g))
        (let ((text (mem:endpoint-profile g :repo "cl-llm")))
          (is (search "verdict:red" text))
          (is (null (search "verdict:green" text))
              "outdated by Y: X's line leaves the subject's profile"))
        (is (null (mem:endpoint-profile g :verdict "green"))
            "and the endpoint it named has nothing current"))
      (is (null (mem:endpoint-vector-value
                 (mem:endpoint-vector-of g :verdict "green")))
          "Y's write touched the endpoint its belief outdated")
      (%store-vector g '(:verdict . "green"))
      (gdb:with-transaction (:graph g) (mem:retract-belief y))
      (is (null (mem:endpoint-vector-value
                 (mem:endpoint-vector-of g :verdict "green")))
          "retracting Y touched it again")
      (mem:with-scope-snapshots ((list g))
        (is (not (null (mem:endpoint-profile g :verdict "green")))
            "X leads again, so its line comes back")))))
