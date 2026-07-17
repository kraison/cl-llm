;;;; eval/packages.lisp

(defpackage #:cl-llm.eval
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions))
  (:export
   #:score #:score-p #:score-value #:score-explanation
   #:llm-eval-error #:eval-error-message
   ))
