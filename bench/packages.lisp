;;;; bench/packages.lisp -- benchmark harness for cl-llm/rag.

(defpackage #:cl-llm.bench
  (:use #:cl)
  (:local-nicknames (#:rag #:cl-llm.rag)
                    (#:v #:cl-llm.rag.vivace)
                    (#:gdb #:graph-db))
  (:export #:build-corpus #:teardown-corpus #:random-unit-vector
           #:run-attribution #:report-attribution))
