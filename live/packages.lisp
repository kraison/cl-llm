;;;; live/packages.lisp -- package definitions for the live-endpoint suite.

(defpackage #:cl-llm.live
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions))
  (:export #:cl-llm-live-suite))
