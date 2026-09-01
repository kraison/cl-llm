;;;; tests-claims/source-tests.lisp -- the claim-traversal source
;;;; (#13 unit 3), against a real on-disk claim store.

(in-package #:cl-llm.rag.claims/tests)

(def-suite :cl-llm-rag-claims
  :description "cl-llm/rag/claims offline suite.")
(in-suite :cl-llm-rag-claims)

;; A neutral test family on its own graph name.  Class names are
;; global in graph-db, so this deliberately stays out of any tenant's
;; namespace.
(st:def-claim-classes probe-claim :cl-llm-claims-test)

(defun %call-with-graph (fn)
  (let* ((dir (format nil "/tmp/cl-llm-claims-test-~a-~a/"
                      (get-internal-real-time) (random 1000000)))
         (gdb:*system-directory*
           (format nil "/tmp/cl-llm-claims-sys-~a-~a/"
                   (get-internal-real-time) (random 1000000)))
         (graph (gdb:make-graph :cl-llm-claims-test dir
                                :buffer-pool-size 1000)))
    (unwind-protect (funcall fn graph)
      (ignore-errors (gdb:close-graph graph))
      (ignore-errors (uiop:delete-directory-tree
                      (pathname dir) :validate t))
      (ignore-errors (uiop:delete-directory-tree
                      (pathname gdb:*system-directory*)
                      :validate t :if-does-not-exist :ignore)))))

(defmacro with-claims-graph ((g) &body body)
  `(%call-with-graph (lambda (,g) ,@body)))

(defun %seed (g &key (subject "d42") (object "s1")
                     (relation "feeds") (producer "rule-a")
                     (standing :observed) extent)
  (gdb:with-transaction ((graph-db::transaction-manager g))
    (let ((claim (make-probe-claim-binary
                  :graph g
                  :subject-namespace :device :subject-key subject
                  :relation relation
                  :object-namespace :sensor :object-key object
                  :producer producer :standing standing)))
      (when extent (setf (st:claim-extent claim) extent))
      claim)))

(defun %extract-devices (&rest keys)
  "An extractor recognising exactly KEYS, whatever the query says --
the tenant's vocabulary is stubbed, which is the point of the seam."
  (lambda (query) (declare (ignore query))
    (mapcar (lambda (k) (cons :device k)) keys)))

(test a-touching-claim-becomes-claim-evidence
  (with-claims-graph (g)
    (%seed g :extent (temporal-extent:make-interval
                      (temporal-extent:exact-bound
                       (local-time:parse-timestring
                        "2026-01-01T00:00:00Z"))
                      (temporal-extent:unknown-bound)
                      :standing :observed))
    (let* ((source (claims:make-claim-source
                    g 'probe-claim (%extract-devices "d42")))
           (evs (rag:collect-evidence source "tell me about d42")))
      (is (= 1 (length evs)))
      (let ((e (first evs)))
        (is (eq :claim (rag:evidence-method e)))
        (is (eq :observed (rag:evidence-standing e))
            "the claim's own standing rides the evidence")
        (is-true (rag:evidence-extent e))
        (is-true (search "device:d42" (rag:chunk-text
                                       (rag:evidence-chunk e))))
        (is-true (search "feeds" (rag:chunk-text
                                  (rag:evidence-chunk e))))
        (is-true (getf (rag:chunk-metadata (rag:evidence-chunk e))
                       :extent)
                 "the §9.5 facet contract: the extent sexp rides the ~
                  chunk metadata too")))))

(test a-recognised-key-with-no-claims-is-searched-empty
  "The §3 distinction made live: looked, found none -- an item the
bundle carries, not an omission."
  (with-claims-graph (g)
    (let* ((source (claims:make-claim-source
                    g 'probe-claim (%extract-devices "ghost")))
           (evs (rag:collect-evidence source "ghost?")))
      (is (= 1 (length evs)))
      (is (eq :searched-empty (rag:evidence-standing (first evs))))
      (is-true (search "no claims touch device:ghost"
                       (rag:chunk-text
                        (rag:evidence-chunk (first evs))))))))

(test an-extractor-recognising-nothing-contributes-nothing
  "No key, no consultation: NIL, which downstream reads as
:INDETERMINATE territory -- never :SEARCHED-EMPTY, which would claim
a search that did not happen."
  (with-claims-graph (g)
    (%seed g)
    (let ((source (claims:make-claim-source
                   g 'probe-claim (%extract-devices))))
      (is (null (rag:collect-evidence source "nothing recognisable"))))))

(test one-claim-reached-through-both-endpoints-fuses-to-one
  (with-claims-graph (g)
    (%seed g)
    (let* ((source (claims:make-claim-source
                    g 'probe-claim
                    (lambda (q) (declare (ignore q))
                      '((:device . "d42") (:sensor . "s1")))))
           (evs (rag:collect-evidence source "d42 and s1")))
      (is (= 1 (length evs))
          "subject-side and object-side retrieval of one claim must ~
           carry one identity"))))

(test the-candidate-depth-caps-claims-but-not-absences
  (with-claims-graph (g)
    (dotimes (i 4)
      (%seed g :object (format nil "s~d" i)))
    (let* ((source (claims:make-claim-source
                    g 'probe-claim
                    (lambda (q) (declare (ignore q))
                      '((:device . "d42") (:device . "ghost")))))
           (evs (rag:collect-evidence source "d42" :k 2)))
      (is (= 3 (length evs))
          "two claims (capped at k) plus the ghost's absence item")
      (is (equal '(:observed :observed :searched-empty)
                 (mapcar #'rag:evidence-standing evs))))))

(test a-bound-excludes-a-claim-outside-it-but-never-an-absence
  (with-claims-graph (g)
    (%seed g :extent (temporal-extent:make-interval
                      (temporal-extent:exact-bound
                       (local-time:parse-timestring
                        "2020-01-01T00:00:00Z"))
                      (temporal-extent:exact-bound
                       (local-time:parse-timestring
                        "2020-06-01T00:00:00Z"))
                      :standing :observed))
    (let* ((window (temporal-extent:make-interval
                    (temporal-extent:exact-bound
                     (local-time:parse-timestring
                      "2026-01-01T00:00:00Z"))
                    (temporal-extent:exact-bound
                     (local-time:parse-timestring
                      "2026-12-31T00:00:00Z"))
                    :standing :asserted))
           (bounds (rag:make-bounds :window window
                                    :window-standing :asserted))
           (source (claims:make-claim-source
                    g 'probe-claim
                    (lambda (q) (declare (ignore q))
                      '((:device . "d42") (:device . "ghost")))))
           (evs (rag:collect-evidence source "d42" :bounds bounds)))
      (is (= 1 (length evs))
          "the 2020 claim is definitely outside a 2026 window")
      (is (eq :searched-empty (rag:evidence-standing (first evs)))
          "an absence carries no extent, and a bound excludes only ~
           what it KNOWS to fall outside"))))
