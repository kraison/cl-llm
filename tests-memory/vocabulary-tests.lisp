;;;; tests-memory/vocabulary-tests.lisp -- what a store's beliefs name
;;;; (#64, spec SS2).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %vbelief (g subject relation object)
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from (%ts "2026-09-01T08:00:00Z")))))

(test vocabulary-counts-namespaces-relations-and-keys
  (with-memory-graph (g)
    (%vbelief g '(:incident . "a") "outage-root-cause" '(:cause . "x"))
    (%vbelief g '(:incident . "b") "outage-root-cause" '(:cause . "y"))
    (%vbelief g '(:project . "p") "superseded-by-project" '(:project . "q"))
    (gdb:with-transaction (:graph g)
      (mem:record-absence g '(:incident . "c") "postmortem"
                          :producer +p+ :standing :searched-empty))
    (mem:with-scope-snapshots ((list g))
      (let* ((v (mem:vocabulary g))
             (ns (mem:vocabulary-namespaces v))
             (inc (gethash "incident" ns))
             (proj (gethash "project" ns))
             (cause (gethash "cause" ns)))
        (is (eq g (mem:vocabulary-store v)))
        (is (= 3 (hash-table-count ns)))
        (is (= 3 (mem:namespace-entry-subjects inc)))
        (is (= 0 (mem:namespace-entry-objects inc)))
        (is (= 3 (hash-table-count (mem:namespace-entry-keys inc))))
        (is (= 1 (gethash "a" (mem:namespace-entry-keys inc))))
        (is (= 1 (mem:namespace-entry-subjects proj)))
        (is (= 1 (mem:namespace-entry-objects proj)))
        (is (= 2 (mem:namespace-entry-objects cause)))
        (is (= 2 (gethash "outage-root-cause" (mem:vocabulary-relations v))))
        (is (= 1 (gethash "postmortem" (mem:vocabulary-relations v))))
        (is (= 7 (length (mem:vocabulary-endpoints v))))
        (is (member '(:cause . "y") (mem:vocabulary-endpoints v)
                    :test #'equal))
        (is (equal '(("a" . 1) ("b" . 1) ("c" . 1))
                   (sort (mem:namespace-keys v "incident") #'string<
                         :key #'car)))
        (is (null (mem:namespace-keys v "nothing")))))))

(test vocabulary-counts-every-claim-on-a-key
  "Supersession keeps both claims current on the transaction axis, so
a key written twice counts twice; the walk counts claims, not values."
  (with-memory-graph (g)
    (%vbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (gdb:with-transaction (:graph g)
      (mem:record-belief g '(:repo . "cl-llm") "ci-status"
                         '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (%open-from (%ts "2026-09-02T08:00:00Z"))))
    (mem:with-scope-snapshots ((list g))
      (let* ((v (mem:vocabulary g))
             (repo (gethash "repo" (mem:vocabulary-namespaces v))))
        (is (= 2 (mem:namespace-entry-subjects repo)))
        (is (= 2 (gethash "cl-llm" (mem:namespace-entry-keys repo))))
        (is (= 2 (gethash "ci-status" (mem:vocabulary-relations v))))
        (is (= 3 (length (mem:vocabulary-endpoints v))))))))

(test vocabulary-skips-a-retracted-belief-unless-asked
  (with-memory-graph (g)
    (let ((c (%vbelief g '(:incident . "a") "outage-root-cause"
                       '(:cause . "x"))))
      (gdb:with-transaction (:graph g) (mem:retract-belief c))
      (mem:with-scope-snapshots ((list g))
        (is (= 0 (hash-table-count
                  (mem:vocabulary-namespaces (mem:vocabulary g)))))
        (is (null (mem:vocabulary-endpoints (mem:vocabulary g))))
        (let ((v (mem:vocabulary g :include-retracted t)))
          (is (= 1 (mem:namespace-entry-subjects
                    (gethash "incident" (mem:vocabulary-namespaces v))))))))))

(test make-vocabulary-builds-one-by-hand
  "The keyword constructor is the seam vivace-graph#350 and the
extractor tests use."
  (let ((v (mem:make-vocabulary :endpoints '((:a . "k")))))
    (is (equal '((:a . "k")) (mem:vocabulary-endpoints v)))
    (is (= 0 (hash-table-count (mem:vocabulary-namespaces v))))))
