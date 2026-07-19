;;;; vivace/packages.lisp

(defpackage #:cl-llm.rag.vivace
  (:use #:cl)
  (:local-nicknames (#:rag #:cl-llm.rag)
                    (#:c #:cl-llm.conditions)
                    (#:gdb #:graph-db))
  (:export #:graph-store #:scan-graph-store #:cached-graph-store
           #:make-graph-store #:open-graph-store #:ensure-chunk-class
           #:graph-store-graph #:graph-store-type #:graph-store-dimension
           #:graph-store-chunks))
