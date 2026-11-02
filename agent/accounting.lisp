;;;; agent/accounting.lisp -- a harness run recorded as claims (#85).
;;;; docs/agent-harness.md, "Accounting".

(in-package #:cl-llm.agent)

(defparameter +run-rule+ "harness-run"
  "The rule every accounting decision is concluded under.")

(defun %rfc3339 (universal-time)
  (local-time:format-rfc3339-timestring
   nil (local-time:universal-to-timestamp universal-time)))

(defun %count (n) (cons :count (princ-to-string (or n 0))))

(defun %run-facts (run)
  "(relation object) pairs describing RUN."
  (list (list "ran-as" (cons :persona (harness:run-persona-name run)))
        (list "stopped"
              (cons :stop-reason
                    (string-downcase
                     (symbol-name (or (harness:run-stop-reason run)
                                      :unknown)))))
        (list "turns" (%count (harness:run-turns run)))
        (list "input-tokens" (%count (harness:run-input-tokens run)))
        (list "output-tokens" (%count (harness:run-output-tokens run)))
        (list "elapsed-ms"
              (%count (round (* 1000 (or (harness:run-elapsed run) 0)))))
        (list "started"
              (cons :instant (%rfc3339 (harness:run-started run))))))

(defun record-run (graph run &key (scope (list graph)))
  "Record RUN in GRAPH as observed beliefs about (:run . <run-id>),
under the run's own producer: its persona, stop reason, turns, tokens,
elapsed time and start.  Returns the decisions, one per fact.  Owns its
transactions, like MEM:CONCLUDE: call it outside one."
  (let ((subject (cons :run (harness:run-id run))))
    (loop for (relation object) in (%run-facts run)
          collect (mem:conclude graph
                                (list :belief subject relation object
                                      :standing :observed)
                                :producer (harness:run-producer run)
                                :rule +run-rule+ :rule-version "1"
                                :scope scope))))
