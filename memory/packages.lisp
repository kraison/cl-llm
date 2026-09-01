;;;; memory/packages.lisp

(defpackage #:cl-llm.memory
  (:use #:cl)
  (:local-nicknames (#:st #:graph-db.spacetime)
                    (#:gdb #:graph-db)
                    (#:te #:temporal-extent))
  (:export
   ;; schema
   #:belief #:belief-unary #:belief-binary
   #:make-belief-unary #:make-belief-binary
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
   #:body-digest))
