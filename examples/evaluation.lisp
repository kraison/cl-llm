;;;; evaluation.lisp -- tune by measuring: dataset x variants x scorers.
;;;;
;;;; cl-llm/eval defines a suite as a dataset (cases), a set of variants (model /
;;;; prompt / parameter combinations to compare), and scorers. RUN-SUITE runs the
;;;; cross product and returns a result you can REPORT as a table.
;;;;
;;;; This example runs entirely OFFLINE via a mock provider, so it needs no
;;;; network and no API key -- swap the provider for a real one to evaluate
;;;; actual models. Load it, then: (examples/evaluation:run)

(ql:quickload :cl-llm/eval)

(defpackage #:examples/evaluation
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:eval #:cl-llm.eval))
  (:export #:run))

(in-package #:examples/evaluation)

;;; A dataset is just a list of cases: an input, and an optional expected answer.
(defparameter *facts*
  (list (eval:make-case "capital of France?" :expected "Paris")
        (eval:make-case "7 times 8?"         :expected "56")
        (eval:make-case "color of the sky?"  :expected "blue")))

;;; Scorers return a SCORE (a value in [0,1] plus an optional explanation).
;;; exact-match ships built in; here's a lenient substring scorer via DEFSCORER.
;;; A scorer's RESPONSE may be NIL for an error cell, so tolerate it.
(eval:defscorer contains-expected (case response)
  "1.0 if the expected answer appears anywhere in the response."
  (if (and response
           (search (string-downcase (eval:case-expected case))
                   (string-downcase (llm:response-text response))))
      (eval:score 1.0)
      (eval:score 0.0 :explanation (format nil "~s not found"
                                           (eval:case-expected case)))))

;;; DEFJUDGE builds an LLM-as-judge scorer. Its body returns the GRADING PROMPT;
;;; the machinery calls the model, parses a 0-1 score and rationale from the
;;; reply, and degrades to 0.0 on an unparseable/failed judge (never sinks a run).
(eval:defjudge concise-judge (case response)
  (declare (ignore case))
  (format nil "Rate from 0 to 1 how concise this answer is, number first: ~a"
          (and response (llm:response-text response))))

;;; A suite ties it together. Variants are ask-arg plists plus an optional
;;; :label and :prompt-fn. Here two "models" (both mocked) are compared.
(eval:defsuite demo-suite
  :dataset *facts*
  :variants ((:model "model-a" :temperature 0.0 :label "a")
             (:model "model-b" :temperature 0.0 :label "b"))
  :scorers (contains-expected concise-judge))

;;; A scripted mock that stands in for two real models, so the bakeoff shows a
;;; meaningful difference. The responder sees the whole conversation, including
;;; CONVERSATION-MODEL (set from each variant's :model), so it can answer
;;; differently per variant -- here "model-b" flubs the arithmetic. A real run
;;; would pass a real provider instead; nothing else changes.
(defun scripted-mock ()
  (llm:make-mock-provider
   :responder
   (lambda (conversation)
     (let* ((messages (llm:conversation-messages conversation))
            (prompt (llm:part-text
                     (first (llm:message-content (car (last messages))))))
            (model (llm:conversation-model conversation)))
       (cond
         ((search "Rate from" prompt) "0.9 concise and direct") ; the judge's ask
         ((search "France"     prompt) "Paris")
         ((search "times"      prompt) (if (equal model "model-b") "sixty-three" "56"))
         ((search "sky"        prompt) "blue")
         (t "unsure"))))))

(defun run ()
  ;; RUN-SUITE binds *provider* for the whole run (variant calls AND judge calls).
  (let ((result (eval:run-suite 'demo-suite :provider (scripted-mock))))
    (format t "~&--- summary table (variants x scorers -> mean) ---~%")
    (princ result)                       ; print-object renders the summary
    (format t "~%~%--- full report with per-case detail ---~%")
    (eval:report result :detail t))
  ;; => variant  contains-expected  concise-judge
  ;;    a        1.00               0.90
  ;;    b        0.67               0.90          ; model-b flubbed "7 times 8"
  ;; A model-call failure during a run becomes an "error cell" (the run
  ;; continues, that variant's mean shows as an em dash with an error count);
  ;; a harness/dataset mistake (e.g. a case missing :expected) surfaces
  ;; immediately as an llm-eval-error.
  (values))

;; (examples/evaluation:run)
