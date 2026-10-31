;;;; tests-memory/index-tests.lisp -- the semantic index's materialise,
;;;; drain, nearest, rebuild and reset (#78 SS3.3, SS4).

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %embedder-down ()
  "The default embedder failure: a plain ERROR."
  (error "embedder down"))

(defun %counting-embed (dimension &key (fail-times 0)
                                       (fail-with #'%embedder-down))
  "=> (values EMBED COUNTER): EMBED maps text to a DIMENSION vector
whose first component is 1 (so every vector is nearest every other),
counting calls in COUNTER's car; the first FAIL-TIMES calls call
FAIL-WITH, which must not return."
  (let ((counter (list 0)) (failures fail-times))
    (values (lambda (text)
              (declare (ignore text))
              (incf (car counter))
              (when (plusp failures)
                (decf failures)
                (funcall fail-with))
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

(defun %logging-embed (log &optional hook)
  "EMBED recording each text in LOG and numbering the call in the
vector's second component, so a stored vector names the render it came
from.  HOOK, when given, runs after the text is recorded and before the
vector is built."
  (lambda (text)
    (push text (%log-texts log))
    (incf (%log-calls log))
    (when hook (funcall hook text))
    (let ((v (make-array 4 :element-type 'single-float
                           :initial-element 0f0)))
      (setf (aref v 0) 1f0 (aref v 1) (float (%log-calls log) 0f0))
      v)))

(defun %racing-embed (log race)
  "EMBED for a WINDOW 1 race test: %LOGGING-EMBED that -- once, on the
first text of the repo endpoint -- funcalls RACE from inside the embed,
i.e. between the render and the store transaction (#78 SS4.3 step 2)."
  (%logging-embed
   log
   (lambda (text)
     ;; The profile opens with the endpoint as words, so the key's
     ;; hyphens are spaces there (SS2.2).
     (when (and (not (%log-raced log))
                (eql 0 (search "repo cl llm" text)))
       (setf (%log-raced log) t)
       (funcall race)))))

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

(test materialise-creates-in-batches
  "#80 item 1: a pre-#78 store's first sweep is one transaction per
*MATERIALISE-BATCH* vertices, not one over the whole vocabulary; the
count and the vertices are the same whatever the batch."
  (with-memory-graph (g)
    ;; Three endpoints with no vertex: RECORD-ABSENCE touches nothing.
    (gdb:with-transaction (:graph g)
      (dolist (k '("a" "b" "c"))
        (mem:record-absence g (cons :incident k) "postmortem"
                            :producer +p+ :standing :searched-empty)))
    (let ((old (fdefinition 'graph-db::call-with-transaction))
          (transactions 0)
          (created nil))
      (unwind-protect
           (progn
             (setf (fdefinition 'graph-db::call-with-transaction)
                   (lambda (fn tm)
                     (incf transactions)
                     (funcall old fn tm)))
             (let ((mem:*materialise-batch* 2))
               (setf created (mem:materialise-endpoint-vectors g))))
        (setf (fdefinition 'graph-db::call-with-transaction) old))
      (is (= 3 created))
      (is (= 2 transactions)
          "two batches of two for three endpoints, got ~a" transactions)
      (dolist (k '("a" "b" "c"))
        (is-true (mem:endpoint-vector-of g :incident k)
                 "~a has a vertex" k))
      (is (= 0 (mem:materialise-endpoint-vectors g))
          "a second pass creates nothing"))))

(test the-dirty-set-resolves-claims-for-suspects-only
  "#80 item 1: after a clean drain a write dirties two endpoints; the
next dirty set asks whether a belief is current for those two, not
for every endpoint in the vocabulary."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (%pbelief g '(:repo . "cl-llm") "root-cause" '(:cause . "flaky"))
    (%pbelief g '(:decision . "hold") "decided-because"
              '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                         :model "m")
    (is (null (mem:dirty-endpoints g "m")) "control: clean")
    (%pbelief g '(:repo . "cl-llm") "owner" '(:person . "kevin")
              "2026-08-31T08:00:00Z")
    (let ((old (fdefinition 'mem::%any-current-belief-p))
          (asked '())
          (dirty nil))
      (unwind-protect
           (progn
             (setf (fdefinition 'mem::%any-current-belief-p)
                   (lambda (graph namespace key)
                     (push (cons namespace key) asked)
                     (funcall old graph namespace key)))
             (setf dirty (mem:dirty-endpoints g "m")))
        (setf (fdefinition 'mem::%any-current-belief-p) old))
      (is (equal '((:repo . "cl-llm") (:person . "kevin"))
                 (sort (copy-list dirty) #'string< :key #'cdr)))
      (is (= 2 (length asked))
          "five endpoints in the vocabulary, two suspects; asked ~a"
          asked)
      (is (null (set-difference asked dirty :test #'equal))
          "and only the suspects were asked: ~a" asked))))

(test an-endpoint-with-no-vertex-at-all-is-dirty
  "#80 item 1: the dirty set is derived from the vertices, but a store
written before #78 has none -- a current belief with no vertex is
still dirty, and the drain still embeds it."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    ;; Delete the vertices the touch created: a pre-#78 store.
    (let ((gdb:*graph* g))
      (dolist (ep '((:repo . "cl-llm") (:verdict . "green")))
        (dolist (ev (mem::%endpoint-vectors-of g (car ep) (cdr ep)))
          (gdb:mark-deleted ev))))
    (is (null (mem:endpoint-vector-of g :repo "cl-llm"))
        "control: no vertex is left")
    (is (equal '((:repo . "cl-llm") (:verdict . "green"))
               (sort (copy-list (mem:dirty-endpoints g "m"))
                     #'string< :key #'cdr)))
    (is (= 2 (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                                  :model "m")))
    (is (null (mem:dirty-endpoints g "m")))))

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

(test an-absence-that-closes-a-predecessor-dirties-both-endpoints
  "#86: RECORD-ABSENCE closing a predecessor loses it from both the
subject and the object endpoint's profile, same as a supersession.
Each endpoint is kept alive by a belief on a different relation, so it
still has a current line and can show up as dirty rather than as an
endpoint with no profile at all."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (%pbelief g '(:repo . "cl-llm") "root-cause" '(:cause . "flaky"))
    (%pbelief g '(:decision . "hold") "decided-because"
              '(:verdict . "green"))
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                         :model "m")
    (is (null (mem:dirty-endpoints g "m")) "clean after the drain")
    (gdb:with-transaction (:graph g)
      (mem:record-absence g '(:repo . "cl-llm") "ci-status"
                          :producer +p+ :standing :searched-empty))
    (let ((dirty (mem:dirty-endpoints g "m")))
      (is (member '(:repo . "cl-llm") dirty :test #'equal)
          "the subject endpoint the closed belief led")
      (is (member '(:verdict . "green") dirty :test #'equal)
          "the object endpoint the closed belief led"))))

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

(test another-models-vectors-poison-the-top-k-until-cleared
  "#80 item 2: the segment answers K hits before the model filter, so
until the drain reaches every endpoint a previous model's vectors
crowd the current one's out of the top-k.  The start-time clear
removes them in one transaction and leaves their endpoints dirty."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    ;; Model A's vectors are the unit query itself (cosine 1); model
    ;; B's are 45 degrees off, so A always ranks above B.
    (mem:drain-endpoint-vectors (list g) :embed (%counting-embed 4)
                                         :model "a")
    (let ((b-embed (%near-far-embed 4 "nothing starts with this"))
          (q (%unit-query 4)))
      ;; Switch to B, but stop the drain after its first endpoint, as a
      ;; restart or a stop mid-sweep would: repo is under B now and
      ;; verdict:green still under A.
      (let ((n 0))
        (is (= 1 (mem:drain-endpoint-vectors
                  (list g) :embed b-embed :model "b"
                           :stop-p (lambda () (> (incf n) 1))))))
      (is (string= "b" (mem:ev-model (mem:endpoint-vector-of g :repo
                                                             "cl-llm"))))
      (is (string= "a" (mem:ev-model (mem:endpoint-vector-of g :verdict
                                                             "green")))
          "control: the two models share the segment")
      (is (null (mem:nearest-endpoints g q :k 1 :model "b"))
          "the top-1 is A's vector, filtered out: an empty dense fill")
      (is (= 1 (mem:clear-foreign-endpoint-vectors g "b")))
      (is (= 0 (mem:clear-foreign-endpoint-vectors g "b"))
          "nothing foreign is left")
      (is (equal '((:repo . "cl-llm"))
                 (mapcar #'car (mem:nearest-endpoints g q :k 1
                                                      :model "b")))
          "B's own vector is the top-1 now")
      (is-true (mem:endpoint-vector-value
                (mem:endpoint-vector-of g :repo "cl-llm"))
               "B's vector was kept")
      (is (equal '((:verdict . "green")) (mem:dirty-endpoints g "b"))
          "the cleared endpoint is dirty for the sweep, as before"))))

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

(test a-profile-that-vanishes-mid-pass-ends-with-no-vector
  "#80 item 5: the retraction lands inside the embed call, so the
re-render finds nothing current.  The pass is not stored, the next
pass renders NIL and clears instead of embedding, and the drain ends
with the endpoint vector-less and clean after one embedder call."
  (with-memory-graph (g)
    (let* ((b (%pbelief g '(:repo . "cl-llm") "ci-status"
                        '(:verdict . "green")))
           (log (make-%embed-log))
           (embed (%racing-embed
                   log
                   (lambda ()
                     (gdb:with-transaction (:graph g)
                       (mem:retract-belief b))))))
      (multiple-value-bind (n unsettled)
          (mem:drain-endpoint-vectors (list g) :embed embed :model "m")
        (is (= 0 n) "nothing was stored")
        (is (null unsettled) "and nothing ran out of passes"))
      (is-true (%log-raced log)
               "control: the retraction fired inside an embed call")
      (is (= 1 (%log-calls log))
          "the vanished profile was not embedded again: ~d calls"
          (%log-calls log))
      (dolist (ep '((:repo . "cl-llm") (:verdict . "green")))
        (let ((ev (mem:endpoint-vector-of g (car ep) (cdr ep))))
          (is-true ev "~a keeps its vertex" ep)
          (is-false (mem:endpoint-vector-value ev)
                    "~a holds no vector" ep)))
      (is (null (mem:dirty-endpoints g "m"))
          "nothing current, so nothing dirty")
      (is (null (mem:nearest-endpoints g (%unit-query 4) :k 5
                                       :model "m"))))))

(test clearing-an-endpoint-with-nothing-current-drops-a-stale-vector
  "#80 item 5: %CLEAR-ONE-ENDPOINT's write path.  A vector no write
cleared -- a duplicate vertex, or one from before the touch existed --
on an endpoint with nothing current is dropped from every live vertex
in one transaction; a second call finds nothing and opens none."
  (with-memory-graph (g)
    ;; Two live vertices for one endpoint, both with a vector, and no
    ;; belief at all on it.
    (gdb:with-transaction (:graph g)
      (dotimes (i 2)
        (mem::make-endpoint-vector :graph g :ev-namespace :repo
                                   :ev-key "ghost" :ev-model "m"
                                   :embedding (%unit-query 4))))
    (is (= 2 (count-if #'mem:endpoint-vector-value
                       (mem::%endpoint-vectors-of g :repo "ghost")))
        "control: two stale vectors")
    (is (= 1 (length (mem:nearest-endpoints g (%unit-query 4) :k 5
                                            :model "m")))
        "control: and the ghost is searchable")
    (let ((old (fdefinition 'graph-db::call-with-transaction))
          (transactions 0)
          (first nil) (second nil))
      (unwind-protect
           (progn
             (setf (fdefinition 'graph-db::call-with-transaction)
                   (lambda (fn tm)
                     (incf transactions)
                     (funcall old fn tm)))
             (setf first (mem::%clear-one-endpoint g :repo "ghost")
                   second (mem::%clear-one-endpoint g :repo "ghost")))
        (setf (fdefinition 'graph-db::call-with-transaction) old))
      (is (eq t first) "the first call wrote")
      (is (null second) "the second had nothing to clear")
      (is (= 1 transactions) "and opened no transaction for it"))
    (is (= 0 (count-if #'mem:endpoint-vector-value
                       (mem::%endpoint-vectors-of g :repo "ghost")))
        "every live vertex was cleared")
    (is (null (mem:nearest-endpoints g (%unit-query 4) :k 5
                                     :model "m")))))

(test a-touch-between-re-render-and-commit-never-leaves-a-stale-vector
  "WINDOW 2: the interleaved write commits from inside %STORE-VECTOR --
after the drain transaction's re-render, before its commit -- so the
STRING= check cannot see it.  What catches it is TOUCH-ENDPOINTS'
unconditional save of the endpoint's vertex, which puts that node in
the writer's write set and makes the drain's commit fail validation.
Restore the vector-less skip there and this test goes red while every
other suite stays green (#78 SS4.3 step 2)."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (let* ((log (make-%embed-log))
           (embed (%logging-embed log))
           (store (fdefinition 'mem::%store-vector))
           (raced-at nil))
      (unwind-protect
           (progn
             (setf (fdefinition 'mem::%store-vector)
                   (lambda (graph namespace key vector model)
                     ;; A CREATE-ONLY writer in its own transaction: a
                     ;; first belief on a new relation supersedes
                     ;; nothing, so all its claim writes are creates and
                     ;; VALIDATE (write sets only) would see nothing.
                     (when (and (null raced-at) (eq namespace :repo))
                       (setf raced-at (%log-calls log))
                       (%pbelief g '(:repo . "cl-llm") "owner"
                                 '(:person . "kevin")
                                 "2026-08-31T08:00:00Z"))
                     (funcall store graph namespace key vector model)))
             (mem:drain-endpoint-vectors (list g) :embed embed
                                                  :model "m"))
        (setf (fdefinition 'mem::%store-vector) store))
      (is-true raced-at
               "control: the write fired inside %STORE-VECTOR")
      (is (= 3 (%log-calls log))
          "the conflict cost the repo endpoint one extra pass")
      (is-false (search "owner person:kevin" (%log-text log raced-at))
                "control: the raced render predates the new belief")
      (let* ((v (mem:endpoint-vector-value
                 (mem:endpoint-vector-of g :repo "cl-llm")))
             (n (and v (round (aref v 1)))))
        (is-true v "the repo endpoint ended with a vector")
        (is (eql n (1+ raced-at))
            "its vector is the re-render's, not the raced one's")
        (is-true (search "owner person:kevin" (%log-text log n))
                 "and that text already had the new belief: ~a"
                 (%log-text log n)))
      (is-false (mem:endpoint-dirty-p g :repo "cl-llm" "m")
                "the raced endpoint is clean")
      (is (= 1 (mem:drain-endpoint-vectors (list g) :embed embed
                                                    :model "m"))
          "only the endpoint the race created was left")
      (is-false (mem:dirty-endpoints g "m")))))

;;; The worker (#78 SS4.3).

(defun %seconds-to (thunk)
  "Wall seconds spent FUNCALLing THUNK, as a single float."
  (let ((start (get-internal-real-time)))
    (funcall thunk)
    (/ (float (- (get-internal-real-time) start) 0f0)
       internal-time-units-per-second)))

(test the-worker-drains-after-a-notify-and-stops-cleanly
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (let ((w (mem:start-endpoint-indexer (list g) :embed embed
                                                    :model "m"))
            (stop-seconds nil))
        (unwind-protect
             (progn
               (is (mem:wait-endpoint-indexer w :timeout 10)
                   "the start-up sweep drains")
               (is (= 2 (car counter)))
               (is (= 2 (mem:endpoint-indexer-embedded w)))
               (%pbelief g '(:repo . "cl-llm") "ci-status"
                         '(:verdict . "red") "2026-08-31T08:00:00Z")
               (is (= 2 (car counter)) "the write embedded nothing")
               (mem:notify-endpoint-indexer w)
               (is (mem:wait-endpoint-indexer w :timeout 10))
               (is (= 4 (car counter)) "repo and verdict:red")
               (is (null (mem:dirty-endpoints g "m"))))
          (setf stop-seconds
                (%seconds-to (lambda () (mem:stop-endpoint-indexer w)))))
        (is (not (bt:thread-alive-p (mem::endpoint-indexer-thread w))))
        ;; The idle worker sits in an untimed CONDITION-WAIT, so stop
        ;; is only prompt if its notify lands under the same lock.
        (is (< stop-seconds 2) "stop joined in ~,2fs" stop-seconds)
        (is (null mem:*endpoint-indexer*)
            "and stop cleared the process's worker")))))

(test the-worker-backs-off-on-an-embedder-error-and-retries
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4 :fail-times 1)
      (let ((w (mem:start-endpoint-indexer (list g) :embed embed :model "m"
                                                    :backoff 0.2)))
        (unwind-protect
             (progn
               (is (mem:wait-endpoint-indexer w :timeout 15))
               (is (= 3 (car counter)) "one failure, then both")
               (is (null (mem:dirty-endpoints g "m"))))
          (mem:stop-endpoint-indexer w))))))

(test stop-wakes-the-worker-out-of-a-long-backoff
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4 :fail-times 1000)
      (let ((w (mem:start-endpoint-indexer (list g) :embed embed :model "m"
                                                    :backoff 30.0)))
        (unwind-protect
             (progn
               (loop repeat 200 until (plusp (car counter))
                     do (sleep 0.05))
               (is (plusp (car counter)) "control: the embedder was called")
               ;; Nothing was embedded and the store stays dirty, so the
               ;; worker must not report itself idle (SS4.3).
               (is (null (mem:wait-endpoint-indexer w :timeout 0.3))
                   "a worker whose store is still dirty is never idle")
               (let ((s (%seconds-to
                         (lambda () (mem:stop-endpoint-indexer w)))))
                 ;; A SLEEP backoff would hold the join for 30 seconds.
                 (is (< s 2) "stop woke the backoff wait in ~,2fs" s))
               (is (not (bt:thread-alive-p
                         (mem::endpoint-indexer-thread w))))
               (is (= 0 (mem:endpoint-indexer-embedded w))))
          (mem:stop-endpoint-indexer w))))))

(test notify-without-a-worker-is-a-no-op
  (let ((mem:*endpoint-indexer* nil))
    (finishes (mem:notify-endpoint-indexer))))

(defun %unsettling-embed (g)
  "=> (values EMBED COUNTER): an EMBED that, whenever it is given the
repo endpoint's profile, writes another belief on that endpoint, so no
number of passes settles it.  The drain returns WITHOUT error and
leaves the endpoint dirty -- the bounded-pass fallout (SS4.3 step 2)."
  (let ((counter (list 0)))
    (values (lambda (text)
              (incf (car counter))
              (when (eql 0 (search "repo cl llm" text))
                (%pbelief g '(:repo . "cl-llm")
                          (format nil "note~d" (car counter))
                          '(:digest . "d")))
              (let ((v (make-array 4 :element-type 'single-float
                                     :initial-element 0f0)))
                (setf (aref v 0) 1f0)
                v))
            counter)))

(test a-store-that-never-settles-is-never-reported-idle
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%unsettling-embed g)
      (let ((w (mem:start-endpoint-indexer (list g) :embed embed :model "m"
                                                    :backoff 0.1)))
        (unwind-protect
             (progn
               ;; No error is ever signalled here: the drains complete
               ;; and store, so only the dirty-set check can keep the
               ;; worker from claiming it is drained (SS4.3).
               (is (null (mem:wait-endpoint-indexer w :timeout 1))
                   "idle over an endpoint the passes never settled")
               (is (plusp (mem:endpoint-indexer-embedded w))
                   "control: the drains did store vectors")
               (is (> (car counter) mem:*embed-passes*)
                   "control: one endpoint used up all ~d passes (~d calls)"
                   mem:*embed-passes* (car counter))
               (is-true (member '(:repo . "cl-llm")
                                (mem:dirty-endpoints g "m")
                                :test #'equal)
                        "control: the endpoint really is still dirty")
               ;; Named once per worker, however many drains ran.
               (let ((named (mem::endpoint-indexer-reported w)))
                 (is (= 1 (hash-table-count named))
                     "the fallout was logged once, not once per drain")
                 (is-true (gethash '(:repo . "cl-llm") named)
                          "and it named the endpoint that fell out")))
          (mem:stop-endpoint-indexer w))))))

(test a-notify-does-not-cancel-an-outage-backoff
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4 :fail-times 1000)
      (let ((w (mem:start-endpoint-indexer (list g) :embed embed :model "m"
                                                    :backoff 0.5))
            (stop-seconds nil))
        (unwind-protect
             (progn
               (loop repeat 200 until (plusp (car counter))
                     do (sleep 0.01))
               (is (= 1 (car counter)) "control: the sweep failed once")
               ;; Task 4 wires a notify to every write, so an import
               ;; against a down embedder must not buy one failing
               ;; round trip per write (SS4.3 step 3).
               (dotimes (i 3)
                 (mem:notify-endpoint-indexer w)
                 (sleep 0.05))
               (sleep 1.0)
               (is (= 2 (car counter))
                   "one attempt per backoff period -- 0.5s, then 1.0s ~
                    -- not one per notify; got ~d"
                   (car counter)))
          (setf stop-seconds
                (%seconds-to (lambda () (mem:stop-endpoint-indexer w)))))
        (is (< stop-seconds 2)
            "stop still returns in ~,2fs" stop-seconds)))))

(defun %flaky-prepare (fail-times)
  "=> (values PREPARE COUNTER): a PREPARE that signals on its first
FAIL-TIMES calls, answers NIL on the next, and T from then on,
counting calls in COUNTER's car.  An embedder still loading is a
probe that signals; NIL is the other way PREPARE can say no."
  (let ((counter (list 0)))
    (values (lambda ()
              (incf (car counter))
              (cond ((<= (car counter) fail-times)
                     (error "connection refused"))
                    ((= (car counter) (1+ fail-times)) nil)
                    (t t)))
            counter)))

(test the-worker-retries-prepare-and-embeds-nothing-until-it-succeeds
  "#80 item 3: a cold start.  The probe fails twice, then once answers
NIL; the worker retries it on the backoff, calls the embedder only
after it succeeds, then sweeps; the outage is logged once."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (multiple-value-bind (prepare prepared) (%flaky-prepare 2)
        (let* ((log (make-string-output-stream))
               (*error-output* log)
               (w (mem:start-endpoint-indexer (list g) :embed embed
                                              :model "m" :backoff 0.1
                                              :prepare prepare)))
          (unwind-protect
               (progn
                 (loop repeat 300 until (= 2 (car prepared))
                       do (sleep 0.01))
                 (is (= 2 (car prepared)) "control: two probes failed")
                 (is (= 0 (car counter))
                     "nothing is embedded before the probe succeeds")
                 (is (mem:wait-endpoint-indexer w :timeout 10)
                     "ready, then the sweep")
                 (is (= 4 (car prepared))
                     "two signals, one NIL, then T: ~d calls"
                     (car prepared))
                 (is (= 2 (car counter)) "and the sweep embedded both")
                 (is (null (mem:dirty-endpoints g "m")))
                 (is-false (mem:endpoint-indexer-off-p w))
                 (sleep 0.1)
                 (let ((text (get-output-stream-string log)))
                   (is (= 1 (%count-substring "not ready" text))
                       "the cold start was logged once: ~s" text)
                   (is (= 1 (%count-substring "ready after 3" text))
                       "and so was the recovery: ~s" text)))
            (mem:stop-endpoint-indexer w)))))))

(test the-worker-gives-up-on-prepare-after-the-bound
  "#80 item 3: the retry is bounded.  A probe that never succeeds is
tried PREPARE-ATTEMPTS times, each after the doubling backoff that a
notify does not cut short; then the worker says the index stays off,
sets OFF and stops, having embedded nothing."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter) (%counting-embed 4)
      (multiple-value-bind (prepare prepared) (%flaky-prepare 1000)
        (let* ((log (make-string-output-stream))
               (*error-output* log)
               (w (mem:start-endpoint-indexer (list g) :embed embed
                                              :model "m" :backoff 0.1
                                              :prepare prepare
                                              :prepare-attempts 3)))
          (unwind-protect
               (progn
                 (loop repeat 300 until (plusp (car prepared))
                       do (sleep 0.01))
                 ;; Notifies land during the first backoff (0.1 s).
                 (dotimes (i 3)
                   (mem:notify-endpoint-indexer w)
                   (sleep 0.01))
                 (is (= 1 (car prepared))
                     "a notify did not buy another probe: ~d"
                     (car prepared))
                 (loop repeat 500 until (mem:endpoint-indexer-off-p w)
                       do (sleep 0.01))
                 (is-true (mem:endpoint-indexer-off-p w)
                          "the worker gave up")
                 (is (= 3 (car prepared)) "after exactly the bound")
                 (is (= 0 (car counter)) "and never embedded")
                 (loop repeat 100
                       while (bt:thread-alive-p
                              (mem::endpoint-indexer-thread w))
                       do (sleep 0.01))
                 (is-false (bt:thread-alive-p
                            (mem::endpoint-indexer-thread w))
                           "and its thread returned")
                 (is (null (mem:wait-endpoint-indexer w :timeout 0.2))
                     "an off worker is never idle")
                 (let ((text (get-output-stream-string log)))
                   (is (= 1 (%count-substring "not ready:" text))
                       "the outage was logged once: ~s" text)
                   (is (= 1 (%count-substring "stays off" text))
                       "and the giving up once: ~s" text)))
            (is-true (mem:stop-endpoint-indexer w)
                     "stop still joins a worker that gave up")))))))

(test a-second-start-stops-the-first-worker
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (let ((w1 (mem:start-endpoint-indexer (list g)
                                          :embed (%counting-embed 4)
                                          :model "m")))
      (unwind-protect
           (let ((w2 (mem:start-endpoint-indexer
                      (list g) :embed (%counting-embed 4) :model "m")))
             (is (not (eq w1 w2)))
             (is (not (bt:thread-alive-p
                       (mem::endpoint-indexer-thread w1)))
                 "the worker it replaced was stopped and joined")
             (is (eq w2 mem:*endpoint-indexer*))
             (is (mem:wait-endpoint-indexer w2 :timeout 10)
                 "and the new one drains"))
        (mem:stop-endpoint-indexer mem:*endpoint-indexer*)))))

(defun %count-substring (needle haystack)
  "How many non-overlapping NEEDLEs HAYSTACK contains."
  (let ((n 0) (start 0))
    (loop (let ((hit (search needle haystack :start2 start)))
            (unless hit (return n))
            (incf n)
            (setf start (+ hit (length needle)))))))

(test a-quiet-drain-lets-a-later-outage-report-itself
  (with-memory-graph (g)
    (let ((b (%pbelief g '(:repo . "cl-llm") "ci-status"
                       '(:verdict . "green"))))
      (multiple-value-bind (embed counter)
          (%counting-embed 4 :fail-times 1000)
        (let* ((log (make-string-output-stream))
               (*error-output* log)
               (w (mem:start-endpoint-indexer (list g) :embed embed
                                              :model "m" :backoff 0.5)))
          (unwind-protect
               (progn
                 (loop repeat 300 until (plusp (car counter))
                       do (sleep 0.01))
                 (is (= 1 (car counter)) "control: the sweep failed once")
                 ;; Retracting the only belief leaves both endpoints
                 ;; with nothing current, so the drain at the end of
                 ;; the backoff finds nothing and calls no embedder.
                 (gdb:with-transaction (:graph g) (mem:retract-belief b))
                 (is (null (mem:dirty-endpoints g "m"))
                     "control: nothing is dirty any more")
                 (is (mem:wait-endpoint-indexer w :timeout 10)
                     "the empty drain finished and went idle")
                 (is (= 1 (car counter)) "and called nothing")
                 ;; A second outage: it proved nothing about the
                 ;; embedder, so this must be announced too.
                 (%pbelief g '(:repo . "cl-llm") "owner"
                           '(:person . "kevin") "2026-08-31T08:00:00Z")
                 (mem:notify-endpoint-indexer w)
                 (loop repeat 300 until (< 1 (car counter))
                       do (sleep 0.01))
                 (is (= 2 (car counter)) "the second outage was tried")
                 (sleep 0.1)
                 (let ((text (get-output-stream-string log)))
                   (is (= 2 (%count-substring "drain failed" text))
                       "both outages were logged, not just the first: ~s"
                       text)
                   (is (= 0 (%count-substring "embedder back" text))
                       "and no empty drain claimed the embedder back: ~s"
                       text)))
            (mem:stop-endpoint-indexer w)))))))

(defun %blocking-embed (dimension &key (limit 10.0))
  "=> (values EMBED COUNTER GATE): an EMBED that blocks until GATE's car
is set or LIMIT seconds pass, then answers a DIMENSION vector.  It
stands in for an embedder that has stopped answering; the gate lets the
test release it once the stop has been proved not to wait for it, and
LIMIT keeps a wedged run from hanging the suite."
  (let ((counter (list 0)) (gate (list nil)))
    (values (lambda (text)
              (declare (ignore text))
              (incf (car counter))
              (let ((deadline (+ (get-internal-real-time)
                                 (* limit
                                    internal-time-units-per-second))))
                (loop until (or (car gate)
                                (>= (get-internal-real-time) deadline))
                      do (sleep 0.05)))
              (let ((v (make-array dimension
                                   :element-type 'single-float
                                   :initial-element 0f0)))
                (setf (aref v 0) 1f0)
                v))
            counter gate)))

(test stop-abandons-a-worker-wedged-in-an-embedding
  "SS4.3 step 3: STOP-ENDPOINT-INDEXER is bounded.  A hung embedder used
to hold the join, and through it SIGTERM, until the supervisor's
SIGKILL left the store's .dirty marker behind."
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter gate) (%blocking-embed 4)
      (let* ((log (make-string-output-stream))
             (*error-output* log)
             (w (mem:start-endpoint-indexer (list g) :embed embed
                                                     :model "m"))
             (result :not-run)
             (seconds nil))
        (unwind-protect
             (progn
               (loop repeat 400 until (plusp (car counter))
                     do (sleep 0.01))
               (is (= 1 (car counter))
                   "control: the worker is inside an embedding")
               (setf seconds
                     (%seconds-to
                      (lambda ()
                        (setf result (mem:stop-endpoint-indexer
                                      w :timeout 1)))))
               (is (null result)
                   "a wedged worker is abandoned, not joined")
               (is (< seconds 1.5) "and the stop returned in ~,2fs"
                   seconds)
               (is-true (bt:thread-alive-p
                         (mem::endpoint-indexer-thread w))
                        "control: it really was still running")
               (is (null mem:*endpoint-indexer*)
                   "and it is no longer the process's worker"))
          ;; Release it and join for real: the graph closes next.
          (setf (car gate) t)
          (mem:stop-endpoint-indexer w :timeout 30))
        (multiple-value-bind (fast fast-counter) (%counting-embed 4)
          (declare (ignore fast-counter))
          (let ((w2 (mem:start-endpoint-indexer (list g) :embed fast
                                                         :model "m")))
            (is-true (mem:stop-endpoint-indexer w2 :timeout 2)
                     "control: a worker that is not wedged answers T")))
        (is (= 1 (%count-substring "abandoning the worker"
                                   (get-output-stream-string log)))
            "the abandonment is on the record")))))

(define-condition %embedder-storage-exhausted (storage-condition)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (write-string "simulated storage exhaustion" s)))
  (:documentation "A SERIOUS-CONDITION that is not an ERROR, the shape
STORAGE-CONDITION takes: a HANDLER-CASE on ERROR lets it through, and
under --script or --disable-debugger it takes the process (#78 M3)."))

(test the-worker-survives-a-serious-condition-that-is-not-an-error
  (with-memory-graph (g)
    (%pbelief g '(:repo . "cl-llm") "ci-status" '(:verdict . "green"))
    (multiple-value-bind (embed counter)
        (%counting-embed
         4 :fail-times 1
           :fail-with (lambda () (error '%embedder-storage-exhausted)))
      (let* ((log (make-string-output-stream))
             (*error-output* log)
             (w (mem:start-endpoint-indexer (list g) :embed embed
                                            :model "m" :backoff 0.2)))
        (unwind-protect
             (progn
               (is (mem:wait-endpoint-indexer w :timeout 15)
                   "the worker outlived it and drained afterwards")
               (is-true (bt:thread-alive-p
                         (mem::endpoint-indexer-thread w))
                        "control: the thread is still running")
               (is (= 3 (car counter)) "one refusal, then both")
               (is (null (mem:dirty-endpoints g "m")))
               (sleep 0.1)
               (let ((text (get-output-stream-string log)))
                 (is (= 1 (%count-substring "drain failed" text))
                     "and it was reported once, as a drain failure ~
                      rather than an embedder outage: ~s"
                     text)))
          (mem:stop-endpoint-indexer w))))))
