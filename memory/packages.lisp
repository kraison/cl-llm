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
   #:belief #:belief-unary #:belief-binary
   #:make-belief-unary #:make-belief-binary
   #:trace #:trace-unary #:trace-binary
   #:make-trace-unary #:make-trace-binary
   #:memory-note #:note-name #:note-description #:note-type
   #:note-modified #:note-body
   ;; write
   #:record-belief #:record-absence #:retract-belief
   #:belief-argument-error #:belief-successor-before-predecessor
   ;; recall
   #:recall #:belief-record #:belief-record-claim
   #:belief-record-current-p #:belief-record-superseded-by
   #:belief-record-retracted-at #:belief-record-standing
   #:belief-record-extent
   ;; capture
   #:capture-memory-dir #:capture-listing #:read-frontmatter
   #:body-digest
   ;; cite
   #:claim-cite #:cite-p #:split-cite #:resolve-cite
   #:cite-record #:cite-record-cite #:cite-record-family
   #:cite-record-state #:cite-record-claim #:cite-record-standing
   #:cite-record-extent #:cite-record-changed-since))
