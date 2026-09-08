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

;;; cl-llm#68: the walk is gone -- counted, not read.

(defvar *vocab-resolutions* nil
  "Node resolutions counted by %COUNT-RESOLUTIONS; NIL when not
counting.")

(defun %count-resolutions (thunk)
  "Run THUNK counting GDB:LOOKUP-VERTEX calls -- the per-node
resolution both the old belief walk (MAP-VERTICES' typed scan) and the
engine's index confirmation (MAP-INDEX, through GRAPH-DB::%NODE-BY-ID)
go through -- by wrapping its fdefinition; restored afterwards.
Returns the count.  Trap: it counts every resolution THUNK makes, not
only the vocabulary's, and it is not thread-safe."
  (let ((old (fdefinition 'gdb:lookup-vertex)))
    (setf (fdefinition 'gdb:lookup-vertex)
          (lambda (&rest args)
            (when *vocab-resolutions* (incf *vocab-resolutions*))
            (apply old args)))
    (unwind-protect
         (let ((*vocab-resolutions* 0))
           (funcall thunk)
           *vocab-resolutions*)
      (setf (fdefinition 'gdb:lookup-vertex) old))))

(defun %vbelief-at (g subject relation object minute)
  "A belief valid from 2026-09-01T08:MINUTE, open-ended.  Trap: a
series needs strictly increasing starts -- RECORD-BELIEF supersedes."
  (gdb:with-transaction (:graph g)
    (mem:record-belief
     g subject relation object
     :producer +p+ :standing :observed
     :extent (%open-from
              (%ts (format nil "2026-09-01T08:~2,'0D:00Z" minute))))))

(test vocabulary-with-retracted-included-does-not-resolve-every-claim
  "cl-llm#68: with INCLUDE-RETRACTED the names and counts come from the
engine's index ranges (vivace-graph#350), so a store of N beliefs is
answered with fewer than N node resolutions.  Control: the default
(:current) path must resolve at least N, since telling current from
retracted needs the node."
  (with-memory-graph (g)
    (let ((n 40))
      ;; 5 subject keys x 8 object keys, one claim each: N claims over
      ;; 16 names, so per-name cost is far under per-claim cost.
      (dotimes (i n)
        (%vbelief-at g (cons :incident (format nil "i~D" (mod i 5)))
                     "outage-root-cause"
                     (cons :cause (format nil "c~D" (mod i 8))) i))
      (mem:with-scope-snapshots ((list g))
        (let ((fast (%count-resolutions
                     (lambda () (mem:vocabulary g :include-retracted t))))
              (slow (%count-resolutions
                     (lambda () (mem:vocabulary g)))))
          (is (>= slow n)
              "control: the :current path resolved ~D for ~D claims"
              slow n)
          (is (< fast n)
              "include-retracted: ~D resolutions for ~D claims -- ~
names should come from index ranges, not a walk"
              fast n)
          (is (= n (mem:namespace-entry-subjects
                    (gethash "incident"
                             (mem:vocabulary-namespaces
                              (mem:vocabulary g :include-retracted t)))))
              "and the counts are still right"))))))
