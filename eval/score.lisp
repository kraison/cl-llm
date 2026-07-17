;;;; eval/score.lisp -- the score value type and the harness-error condition.

(in-package #:cl-llm.eval)

(define-condition llm-eval-error (c:llm-error)
  ((message :initarg :message :initform nil :reader eval-error-message))
  (:report (lambda (condition stream)
             (format stream "cl-llm/eval error~@[: ~a~]"
                     (eval-error-message condition))))
  (:documentation "A harness misuse: a bad score value, a missing expected
answer, an unknown suite or scorer, or a malformed variant."))

(defstruct (score (:constructor %make-score (value explanation)))
  "One scorer's verdict: a numeric VALUE in [0,1] and an optional EXPLANATION."
  (value 0.0 :type real)
  (explanation nil :type (or null string)))

(defun score (value &key explanation)
  "Make a SCORE. A real VALUE is clamped to [0,1]; a non-real signals
LLM-EVAL-ERROR (that is a programming mistake, not noisy model output)."
  (unless (realp value)
    (error 'llm-eval-error
           :message (format nil "score value must be a real, got ~s" value)))
  (%make-score (max 0 (min 1 value)) explanation))
