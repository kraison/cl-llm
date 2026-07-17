;;;; eval/packages.lisp

(defpackage #:cl-llm.eval
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions))
  (:export
   #:score #:score-p #:score-value #:score-explanation
   #:llm-eval-error #:eval-error-message
   #:eval-case #:make-case #:case-input #:case-expected #:case-metadata
   #:scorer #:scorer-name #:scorer-function #:defscorer
   #:register-scorer #:find-scorer #:run-scorer #:exact-match
   #:defjudge #:parse-judge-score
   ))
