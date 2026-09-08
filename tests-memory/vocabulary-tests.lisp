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

(test vocabulary-resolves-no-node-outside-an-as-of-extent
  "cl-llm#70: both paths answer from the family's count indexes
\(vivace-graph#361), so a store of N beliefs is answered with no node
resolution at all.  Control: inside a WITH-AS-OF extent the engine
takes #350's walk instead -- the counters have no history -- and
resolves at least N, with the same answer at the latest epoch."
  (with-memory-graph (g)
    (let ((n 40))
      ;; 5 subject keys x 8 object keys, one claim each: N claims over
      ;; 16 names, so per-name cost is far under per-claim cost.
      (dotimes (i n)
        (%vbelief-at g (cons :incident (format nil "i~D" (mod i 5)))
                     "outage-root-cause"
                     (cons :cause (format nil "c~D" (mod i 8))) i))
      (let ((e (gdb:latest-epoch g)))
        ;; A fresh graph's count maps are built by the first count
        ;; query, one scan resolving every claim per index (vivace-
        ;; graph#361, general-index-design SS6b); pay it before
        ;; measuring.  The :include-retracted path reaches the engine
        ;; on every version of VOCABULARY, so this warms the maps even
        ;; when the default path still walks.
        (mem:vocabulary g :include-retracted t)
        (mem:with-scope-snapshots ((list g))
          (let ((default (%count-resolutions
                          (lambda () (mem:vocabulary g))))
                (all (%count-resolutions
                      (lambda () (mem:vocabulary g :include-retracted t))))
                (v (mem:vocabulary g)))
            (is (< default n)
                "default: ~D resolutions for ~D claims -- counts should ~
come from the count indexes, not a walk" default n)
            (is (= 0 default)
                "default: ~D resolutions -- a count lookup resolves none"
                default)
            (is (< all n)
                "include-retracted: ~D resolutions for ~D claims" all n)
            (is (= 0 all)
                "include-retracted: ~D resolutions -- a count lookup ~
resolves none" all)
            (let* ((ns (mem:vocabulary-namespaces v))
                   (inc (gethash "incident" ns))
                   (cause (gethash "cause" ns)))
              (is (= n (mem:namespace-entry-subjects inc)))
              (is (= n (mem:namespace-entry-objects cause)))
              (is (= 5 (hash-table-count (mem:namespace-entry-keys inc))))
              (is (= 8 (hash-table-count
                        (mem:namespace-entry-keys cause))))
              (is (= n (gethash "outage-root-cause"
                                (mem:vocabulary-relations v))))
              (is (= 13 (length (mem:vocabulary-endpoints v)))))))
        ;; CONTROL, outside WITH-SCOPE-SNAPSHOTS: an as-of snapshot is
        ;; refused inside a plain snapshot of the same graph
        ;; (CALL-WITH-READ-SNAPSHOT, :snapshot-active).
        (let* ((at nil)
               (as-of (%count-resolutions
                       (lambda ()
                         (gdb:with-as-of ((g) e)
                           (setf at (mem:vocabulary g)))))))
          (is (>= as-of n)
              "control: the as-of walk resolved ~D for ~D claims -- ~
the probe or the control is wrong" as-of n)
          (is (= n (mem:namespace-entry-subjects
                    (gethash "incident" (mem:vocabulary-namespaces at))))
              "the as-of answer at the latest epoch equals the live one"))))))
