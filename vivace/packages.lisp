;;;; vivace/packages.lisp

(defpackage #:cl-llm.rag.vivace
  (:use #:cl)
  (:local-nicknames (#:rag #:cl-llm.rag)
                    (#:c #:cl-llm.conditions)
                    (#:gdb #:graph-db))
  (:export #:graph-store #:scan-graph-store #:cached-graph-store
           #:segment-graph-store
           #:make-graph-store #:open-graph-store #:ensure-chunk-class
           #:graph-store-graph #:graph-store-type #:graph-store-dimension
           #:graph-store-chunks
           ;; Configuration knobs.  These are documented in the README and in
           ;; the transition guide, so they are part of the public surface --
           ;; a documented variable a caller cannot name without :: is a bug.
           #:*embedding-migration-policy*
           #:*embedding-migration-batch-size*
           #:*segment-migration-batch-size*
           #:*segment-migration-progress-fn*
           #:*segment-overfetch-factor*))
