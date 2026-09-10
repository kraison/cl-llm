;;;; memory/packages.lisp

(defpackage #:cl-llm.memory
  (:use #:cl)
  (:local-nicknames (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent))
  ;; TRACE names the second claim family (spec SS3); CL:TRACE is a
  ;; macro, and DEF-CLAIM-CLASSES defclass'es it -- shadow or the
  ;; locked CL package refuses the definition.
  (:shadow #:trace)
  (:export
   ;; schema
   #:define-memory-store #:store-name
   #:belief #:belief-unary #:belief-binary
   #:make-belief-unary #:make-belief-binary
   #:trace #:trace-unary #:trace-binary
   #:make-trace-unary #:make-trace-binary
   #:memory-note #:note-name #:note-description #:note-type
   #:note-modified #:note-body
   #:memory-banner #:make-memory-banner #:bn-key #:bn-note
   #:bn-position #:bn-kind #:bn-date #:bn-dated-p #:bn-link #:bn-text
   ;; write
   #:record-belief #:record-absence #:retract-belief
   #:belief-argument-error #:belief-successor-before-predecessor
   ;; endpoint profiles (#78)
   #:endpoint-vector #:ev-namespace #:ev-key #:ev-model
   #:current-beliefs #:endpoint-profile #:*profile-cap*
   #:endpoint-vector-of #:endpoint-vector-value #:endpoint-dirty-p
   #:touch-endpoints
   ;; the semantic index (#78)
   #:nearest-endpoints #:dirty-endpoints #:materialise-endpoint-vectors
   #:drain-endpoint-vectors #:rebuild-endpoint-vectors
   #:reset-endpoint-segment
   ;; scope (S6b)
   #:check-scope #:scope-argument-error
   #:call-with-scope-snapshots #:with-scope-snapshots
   ;; recall
   #:recall #:belief-record #:belief-record-claim
   #:belief-record-current-p #:belief-record-superseded-by
   #:belief-record-retracted-at #:belief-record-standing
   #:belief-record-extent #:belief-record-store
   #:belief-record-superseded-by-store #:claim-before-p
   ;; vocabulary (#64)
   #:vocabulary #:make-vocabulary #:vocabulary-store
   #:vocabulary-namespaces #:vocabulary-relations #:vocabulary-endpoints
   #:namespace-entry #:namespace-entry-name #:namespace-entry-subjects
   #:namespace-entry-objects #:namespace-entry-keys #:namespace-keys
   ;; capture
   #:capture-memory-dir #:capture-listing #:read-frontmatter
   #:body-digest
   ;; banners
   #:banner #:scan-banners #:banner-kind #:banner-position
   #:banner-date #:banner-link #:banner-text #:banner-line
   #:banner-listing
   ;; cite
   #:claim-cite #:cite-p #:split-cite #:resolve-cite
   #:cite-record #:cite-record-cite #:cite-record-family
   #:cite-record-state #:cite-record-claim #:cite-record-standing
   #:cite-record-extent #:cite-record-changed-since
   #:cite-record-store #:cite-record-superseded-by
   ;; trace
   #:conclude #:decision #:decision-id #:decision-outcome
   #:decision-claim #:decision-report #:decision-at #:decision-epoch
   #:trace #:trace-listing #:decisions-citing
   #:decision-record #:decision-record-id #:decision-record-producer
   #:decision-record-at #:decision-record-rule
   #:decision-record-rule-version #:decision-record-confidence
   #:decision-record-outcome #:decision-record-conclusion
   #:decision-record-evidence #:decision-record-refusals
   #:decision-record-store #:decision-record-epoch
   #:decision-record-axis))
