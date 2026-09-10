;;;; tests-memory/index-tests.lisp -- the semantic index's materialise,
;;;; drain, nearest, rebuild and reset (#78 SS3.3, SS4).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %counting-embed (dimension &key (fail-times 0))
  "=> (values EMBED COUNTER): EMBED maps text to a DIMENSION vector
whose first component is 1 (so every vector is nearest every other),
counting calls in COUNTER's car; the first FAIL-TIMES calls signal."
  (let ((counter (list 0)) (failures fail-times))
    (values (lambda (text)
              (declare (ignore text))
              (incf (car counter))
              (when (plusp failures)
                (decf failures)
                (error "embedder down"))
              (let ((v (make-array dimension :element-type 'single-float
                                             :initial-element 0f0)))
                (setf (aref v 0) 1f0)
                v))
            counter)))

(defun %unit-query (dimension)
  "The query every %COUNTING-EMBED vector answers at cosine 1."
  (let ((q (make-array dimension :element-type 'single-float
                                 :initial-element 0f0)))
    (setf (aref q 0) 1f0)
    q))

(test materialise-gives-every-endpoint-a-vector-less-vertex
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    ;; RECORD-ABSENCE touches nothing (SS4.2), so its subject is a
    ;; vocabulary endpoint with no vertex -- as is every endpoint of a
    ;; store written before #78.
    (gdb:with-transaction (:graph g)
      (mem:record-absence g '(:incident . "quiet") "postmortem"
                          :producer +p+ :standing :searched-empty))
    (is-false (mem:endpoint-vector-of g :incident "quiet")
              "control: the absence made no vertex")
    (is (= 1 (mem:materialise-endpoint-vectors g)))
    (let ((eps (mem:with-scope-snapshots ((list g))
                 (mem:vocabulary-endpoints (mem:vocabulary g)))))
      (is (= 3 (length eps)))
      (dolist (ep eps)
        (let ((ev (mem:endpoint-vector-of g (car ep) (cdr ep))))
          (is-true ev "~a has a vertex" ep)
          (is-false (mem:endpoint-vector-value ev)
                    "~a has no vector" ep))))
    (is (= 0 (mem:materialise-endpoint-vectors g))
        "a second pass creates nothing")))

(test the-drain-embeds-every-dirty-endpoint-once
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (is (equal '((:repo . "cl-llm") (:verdict . "green"))
                 (sort (copy-list (mem:dirty-endpoints g "m"))
                       #'string< :key #'cdr)))
      (is (= 2 (mem:drain-endpoint-vectors (list g) :embed embed
                                                    :model "m")))
      (is (= 2 (car counter)))
      (is (null (mem:dirty-endpoints g "m")))
      (is (= 0 (mem:drain-endpoint-vectors (list g) :embed embed
                                                    :model "m"))
          "nothing dirty, nothing embedded")
      (is (= 2 (car counter))))))

(test nearest-returns-endpoints-best-first-and-skips-other-models
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                         :model "m")
    (let ((q (%unit-query 4)))
      (let ((hits (mem:nearest-endpoints g q :k 5 :model "m")))
        (is (= 2 (length hits)))
        (is (every (lambda (h) (> (cdr h) 0.99)) hits))
        (is (member '(:repo . "cl-llm") hits :key #'car :test #'equal)))
      (is (null (mem:nearest-endpoints g q :k 5 :model "other"))
          "a vector from another model is not a hit"))))

(test nearest-returns-one-hit-per-endpoint
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                         :model "m")
    ;; A second live vertex for one endpoint is possible without a
    ;; DEF-UNIQUE (#78 SS2.5): the search must still name it once.
    (gdb:with-transaction (:graph g)
      (mem::make-endpoint-vector :graph g :ev-namespace :repo
                                 :ev-key "cl-llm" :ev-model "m"
                                 :embedding (%unit-query 4)))
    (let ((hits (mem:nearest-endpoints g (%unit-query 4) :k 5
                                       :model "m")))
      (is (= 2 (length hits)) "two endpoints, three vertices: ~a" hits)
      (is (= 1 (count '(:repo . "cl-llm") hits :key #'car
                                               :test #'equal))))))

(test a-write-clears-and-the-next-drain-restores
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
      (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "red")
                "2026-08-31T08:00:00Z")
      (let ((q (%unit-query 4)))
        (is (null (mem:nearest-endpoints g q :k 5 :model "m"))
            "every touched endpoint is unsearchable until re-embedded")
        (is (= 2 (car counter)) "and the write embedded nothing")
        (is (= 2 (mem:drain-endpoint-vectors (list g) :embed embed
                                                      :model "m"))
            "repo and verdict:red; verdict:green has nothing current")
        (is (null (mem:endpoint-vector-value
                   (mem:endpoint-vector-of g :verdict "green"))))
        (is (= 2 (length (mem:nearest-endpoints g q :k 5
                                                :model "m"))))))))

(test a-model-change-re-embeds-everything
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                         :model "a")
    (is (= 2 (length (mem:dirty-endpoints g "b"))))
    (is (= 2 (mem:drain-endpoint-vectors (list g)
                                         :embed (%counting-embed 4)
                                         :model "b")))
    (is (null (mem:dirty-endpoints g "b")))))

(test rebuild-re-embeds-clean-endpoints-too
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
      (is (= 2 (mem:rebuild-endpoint-vectors (list g) :embed embed
                                                      :model "m")))
      (is (= 4 (car counter))))))

(test reset-lets-a-new-dimension-in
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                         :model "m")
    (signals error
      ;; GDB:VECTOR-DIMENSION-VIOLATION at commit: an empty segment
      ;; keeps its dimension (engine facts E3).
      (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 8)
                                           :model "n"))
    (is (eq t (mem:reset-endpoint-segment g 8)))
    (is (= 2 (mem:drain-endpoint-vectors (list g)
                                         :embed (%counting-embed 8)
                                         :model "n")))
    (is (= 2 (length (mem:nearest-endpoints g (%unit-query 8) :k 5
                                            :model "n"))))
    (is (null (mem:reset-endpoint-segment g 8)) "same dimension: no-op")))

(test the-drain-skips-a-failing-embedder-and-keeps-the-endpoint-dirty
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4 :fail-times 1)
      (signals error (mem:drain-endpoint-vectors (list g) :embed embed
                                                          :model "m"))
      (is (= 1 (car counter)))
      (is (= 2 (length (mem:dirty-endpoints g "m")))
          "nothing was embedded")
      (is (= 2 (mem:drain-endpoint-vectors (list g) :embed embed
                                                    :model "m"))))))

(test a-touch-between-render-and-store-never-leaves-a-stale-vector
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (let* ((texts '()) (calls 0) (raced nil)
           (embed
             (lambda (text)
               (push text texts)
               (incf calls)
               ;; The race (#78 SS4.3 step 2): commit a supersession of
               ;; the belief this render just read, from BETWEEN the
               ;; render and the store.  Once, on the repo endpoint.
               ;; The profile opens with the endpoint as words, so
               ;; the key's hyphens are spaces there (SS2.2).
               (when (and (not raced) (eql 0 (search "repo cl llm" text)))
                 (setf raced t)
                 (%pbelief g '(:repo . "cl-llm") "ci-status"
                           '(:verdict . "red") "2026-08-31T08:00:00Z"))
               (let ((v (make-array 4 :element-type 'single-float
                                      :initial-element 0f0)))
                 (setf (aref v 0) 1f0 (aref v 1) (float calls 0f0))
                 v))))
      (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
      (is-true raced
               "control: the supersession fired inside an embed call")
      (is (= 2 calls) "the conflict forced exactly one re-render")
      (is-true (search "verdict:red" (first texts))
               "the last text embedded is the NEW profile: ~a"
               (first texts))
      (is-false (search "verdict:red" (car (last texts)))
                "the first text embedded was the old profile")
      (let ((v (mem:endpoint-vector-value
                (mem:endpoint-vector-of g :repo "cl-llm"))))
        (is-true v "the repo endpoint ended with a vector")
        (is (= 2f0 (aref v 1))
            "the stored vector is the SECOND render's, not the first's")
        (is (= (float calls 0f0) (aref v 1))
            "which is the last EMBED call: no later render was lost"))
      (is-false (mem:endpoint-dirty-p g :repo "cl-llm" "m")
                "and the raced endpoint is clean")
      (is (equal '((:verdict . "red")) (mem:dirty-endpoints g "m"))
          "only the endpoint the race created is left dirty")
      (is (= 1 (mem:drain-endpoint-vectors (list g) :embed embed
                                                    :model "m")))
      (is (null (mem:dirty-endpoints g "m"))))))
