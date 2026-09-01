;;;; tests-memory/schema-tests.lisp

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(test the-belief-family-is-temporal
  "Spec SS3: identity includes the validity start, so re-entry works."
  (is-true (st:claim-family-temporal-p (st:claim-family 'mem:belief))))

(test memory-note-is-a-map-less-restricted-source
  "Spec SS7: the third source declares :SPACE :NONE explicitly and is
private.  SOURCE-CONTRACT signals NOT-A-SOURCE on a plain vertex, so
this cannot pass for a class that merely exists."
  (let ((c (st:source-contract 'mem:memory-note)))
    (is (eq :none (st:source-facets-space c)))
    (is (eq :none (st:source-facets-registration c)))
    (is (equal '(:class :restricted) (st:source-facets-sensitivity c)))
    (is (eq :memory-note
            (getf (st:source-facets-identity c) :namespace)))))

(test a-temporal-belief-requires-an-extent
  "The engine's own guard, exercised through OUR constructor name --
without it the write path's defaults would be doing the engine's job."
  (with-memory-graph (g)
    (gdb:with-transaction ((graph-db::transaction-manager g))
      (signals st:missing-claim-identity-component
        (mem:make-belief-binary
         :graph g
         :subject-namespace :repo :subject-key "cl-llm"
         :relation "ci-status"
         :object-namespace :verdict :object-key "green"
         :producer +p+ :standing :observed)))))
