;;;; eval/packages.lisp

(defpackage #:cl-llm.eval
  (:use #:cl)
  (:shadow #:cell-error)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions))
  (:export
   #:score #:score-p #:score-value #:score-explanation
   #:llm-eval-error #:eval-error-message
   #:eval-case #:make-case #:case-input #:case-expected #:case-metadata
   #:scorer #:scorer-name #:scorer-function #:defscorer
   #:register-scorer #:find-scorer #:run-scorer #:exact-match
   #:defjudge #:parse-judge-score
   #:variant #:parse-variant #:variant-label #:variant-args #:variant-prompt-fn
   #:suite #:defsuite #:suite-name #:suite-dataset-fn #:suite-variants
   #:suite-scorers #:register-suite #:find-suite
   #:*eval-map* #:run-suite
   #:cell #:cell-case #:cell-variant-label #:cell-response #:cell-scores
   #:cell-error #:cell-score
   #:suite-result #:result-suite #:result-cells #:result-mean #:result-error-count
   #:report
   ))
