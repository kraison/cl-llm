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

(defun %near-far-embed (dimension near)
  "EMBED giving a text that starts with NEAR the unit query itself
(cosine 1) and every other text its 45-degree neighbour (cosine
1/sqrt 2), so the NEAR endpoint must sort strictly first."
  (lambda (text)
    (let ((v (make-array dimension :element-type 'single-float
                                   :initial-element 0f0)))
      (setf (aref v 0) 1f0)
      (unless (eql 0 (search near text))
        (setf (aref v 1) 1f0))
      v)))

(defstruct (%embed-log (:conc-name %log-))
  "What a race test's EMBED did: CALLS embeddings, TEXTS newest first,
RACED once the interleaved write has fired."
  (calls 0)
  (texts '())
  (raced nil))

(defun %log-text (log n)
  "The text LOG's Nth embed call (1-based) was given."
  (nth (- (%log-calls log) n) (%log-texts log)))

(defun %racing-embed (log race)
  "EMBED for a race test: records each text in LOG, numbers the call in
the vector's second component, and -- once, on the first text of the
repo endpoint -- funcalls RACE from inside the embed, i.e. between the
render and the store (#78 SS4.3 step 2)."
  (lambda (text)
    (push text (%log-texts log))
    (incf (%log-calls log))
    ;; The profile opens with the endpoint as words, so the key's
    ;; hyphens are spaces there (SS2.2).
    (when (and (not (%log-raced log))
               (eql 0 (search "repo cl llm" text)))
      (setf (%log-raced log) t)
      (funcall race))
    (let ((v (make-array 4 :element-type 'single-float
                           :initial-element 0f0)))
      (setf (aref v 0) 1f0 (aref v 1) (float (%log-calls log) 0f0))
      v)))

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
    (mem:drain-endpoint-vectors
     (list g) :embed (%near-far-embed 4 "repo cl llm") :model "m")
    (let ((q (%unit-query 4)))
      (let ((hits (mem:nearest-endpoints g q :k 5 :model "m")))
        (is (= 2 (length hits)))
        (is (equal '(:repo . "cl-llm") (car (first hits)))
            "the nearer endpoint first: ~a" hits)
        (is (equal '(:verdict . "green") (car (second hits))))
        (is (> (cdr (first hits)) (cdr (second hits)))
            "strictly better first: ~a" hits)
        (is (> (cdr (first hits)) 0.99))
        (is (< 0.7 (cdr (second hits)) 0.71) "45 degrees: ~a" hits))
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
    (let* ((log (make-%embed-log))
           (embed (%racing-embed
                   log
                   ;; A SUPERSESSION: the writer closes the belief this
                   ;; render read, so its write set names that claim.
                   (lambda ()
                     (%pbelief g '(:repo . "cl-llm") "ci-status"
                               '(:verdict . "red")
                               "2026-08-31T08:00:00Z")))))
      (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
      (is-true (%log-raced log)
               "control: the write fired inside an embed call")
      (is (= 2 (%log-calls log))
          "the changed profile forced exactly one re-embed")
      (is-true (search "verdict:red" (%log-text log 2))
               "the second call's text is the NEW profile: ~a"
               (%log-text log 2))
      (is-false (search "verdict:red" (%log-text log 1))
                "control: the first call's text was the old profile")
      (let ((v (mem:endpoint-vector-value
                (mem:endpoint-vector-of g :repo "cl-llm"))))
        (is-true v "the repo endpoint ended with a vector")
        (is (= 2f0 (aref v 1))
            "the stored vector is the SECOND render's, not the first's")
        (is (= (float (%log-calls log) 0f0) (aref v 1))
            "which is the last EMBED call: no later render was lost"))
      (is-false (mem:endpoint-dirty-p g :repo "cl-llm" "m")
                "and the raced endpoint is clean")
      (is (equal '((:verdict . "red")) (mem:dirty-endpoints g "m"))
          "only the endpoint the race created is left dirty")
      (is (= 1 (mem:drain-endpoint-vectors (list g) :embed embed
                                                    :model "m")))
      (is-false (mem:dirty-endpoints g "m")))))

(test a-new-belief-between-render-and-store-never-leaves-a-stale-vector
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (let* ((log (make-%embed-log))
           (embed (%racing-embed
                   log
                   ;; A CREATE-ONLY writer: a FIRST belief on a new
                   ;; relation, nothing superseded, so every claim it
                   ;; writes is a create and its claim write set is
                   ;; empty.  Only TOUCH-ENDPOINTS' unconditional save
                   ;; of the endpoint's vertex makes it visible to a
                   ;; concurrent drain's validation (SS4.3 step 2).
                   (lambda ()
                     (%pbelief g '(:repo . "cl-llm") "owner"
                               '(:person . "kevin")
                               "2026-08-31T08:00:00Z")))))
      (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
      (is-true (%log-raced log)
               "control: the write fired inside an embed call")
      (let* ((v (mem:endpoint-vector-value
                 (mem:endpoint-vector-of g :repo "cl-llm")))
             (n (and v (round (aref v 1)))))
        (is-true v "the repo endpoint ended with a vector")
        (is (= 2 n) "the stored vector is the SECOND embed call's")
        (is-true (search "owner person:kevin" (%log-text log n))
                 "and that call's text already had the new belief: ~a"
                 (%log-text log n))
        (is-false (search "owner person:kevin" (%log-text log 1))
                  "control: the first call's text predates it"))
      ;; verdict:green is drained last and its profile never changed,
      ;; so its vector is the LAST text's.
      (is (= (float (%log-calls log) 0f0)
             (aref (mem:endpoint-vector-value
                    (mem:endpoint-vector-of g :verdict "green"))
                   1))
          "the last endpoint drained stored the last text's vector")
      (is-false (mem:endpoint-dirty-p g :repo "cl-llm" "m")
                "and the raced endpoint is clean")
      (is (equal '((:person . "kevin")) (mem:dirty-endpoints g "m"))
          "only the endpoint the race created is left dirty")
      (is (= 1 (mem:drain-endpoint-vectors (list g) :embed embed
                                                    :model "m")))
      (is-false (mem:dirty-endpoints g "m")))))
