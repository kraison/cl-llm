;;;; harness/state.lisp -- per-persona concurrency and daily budgets
;;;; (spec SS6.4).  In-image state keyed by persona name: a restart
;;;; resets the day's counters.  docs/agent-harness.md

(in-package #:cl-llm.harness)

(defvar *wall-clock* #'get-universal-time
  "A function returning universal time: the clock the UTC day reads.
Tests rebind it.")

(defstruct (persona-state (:constructor %make-persona-state))
  (lock (bt:make-lock "cl-llm.harness persona"))
  (vacancy (bt:make-condition-variable))
  (active 0)
  (waiting 0)
  (day nil)
  (day-tokens 0)
  (day-runs 0))

(defvar *states-lock* (bt:make-lock "cl-llm.harness states"))
(defvar *states* (make-hash-table :test #'equal))

(defun %state (name)
  (bt:with-lock-held (*states-lock*)
    (or (gethash name *states*)
        (setf (gethash name *states*) (%make-persona-state)))))

(defun %roll-day (state)
  "Start a new day's counters when the UTC day changed.  Hold the lock."
  (let ((today (floor (funcall *wall-clock*) 86400)))
    (unless (eql today (persona-state-day state))
      (setf (persona-state-day state) today
            (persona-state-day-tokens state) 0
            (persona-state-day-runs state) 0))))

(defun persona-usage (name)
  "(values TOKENS-TODAY RUNS-TODAY ACTIVE WAITING) for persona NAME."
  (let ((state (%state name)))
    (bt:with-lock-held ((persona-state-lock state))
      (%roll-day state)
      (values (persona-state-day-tokens state)
              (persona-state-day-runs state)
              (persona-state-active state)
              (persona-state-waiting state)))))

(defun reset-persona-state (&optional name)
  "Forget persona NAME's counters, or every persona's.  For tests and
operators; never while that persona has runs in flight."
  (bt:with-lock-held (*states-lock*)
    (if name (remhash name *states*) (clrhash *states*))))

(defun %day-spent-p (persona state)
  "True when PERSONA's day's runs or tokens are at budget.  Hold the lock."
  (let ((runs (persona-daily-run-budget persona))
        (tokens (persona-daily-token-budget persona)))
    (or (and runs (>= (persona-state-day-runs state) runs))
        (and tokens (>= (persona-state-day-tokens state) tokens)))))

(defun %admit (persona)
  "Take a run slot for PERSONA: :OK, or the stop reason :DAILY-BUDGET,
:BUSY or :DEADLINE.  Waits in the queue until a slot or the deadline."
  (let ((state (%state (persona-name persona))))
    (bt:with-lock-held ((persona-state-lock state))
      (%roll-day state)
      (flet ((vacant-p ()
               (< (persona-state-active state)
                  (persona-max-concurrent persona)))
             (take ()
               (incf (persona-state-active state))
               (incf (persona-state-day-runs state))
               :ok))
        (cond ((%day-spent-p persona state) :daily-budget)
              ((vacant-p) (take))
              ((>= (persona-state-waiting state)
                   (persona-max-queued persona))
               :busy)
              (t
               (incf (persona-state-waiting state))
               (unwind-protect
                    (loop
                      (let ((left (time-left)))
                        (when (and left (<= left 0)) (return :deadline))
                        (if left
                            (bt:condition-wait (persona-state-vacancy state)
                                               (persona-state-lock state)
                                               :timeout left)
                            (bt:condition-wait (persona-state-vacancy state)
                                               (persona-state-lock state))))
                      (%roll-day state)
                      (cond ((%day-spent-p persona state)
                             ;; Pass the one notify on, or the next
                             ;; waiter never hears of the vacancy.
                             (bt:condition-notify
                              (persona-state-vacancy state))
                             (return :daily-budget))
                            ((vacant-p) (return (take)))))
                 (decf (persona-state-waiting state)))))))))

(defun %release (persona)
  "Give back PERSONA's run slot and wake one queued run."
  (let ((state (%state (persona-name persona))))
    (bt:with-lock-held ((persona-state-lock state))
      (decf (persona-state-active state))
      (bt:condition-notify (persona-state-vacancy state)))))

(defun %daily-before-request (persona run)
  (declare (ignore run))
  (let ((state (%state (persona-name persona))))
    (when (bt:with-lock-held ((persona-state-lock state))
            (%roll-day state)
            (let ((tokens (persona-daily-token-budget persona)))
              (and tokens (>= (persona-state-day-tokens state) tokens))))
      (%stop :daily-budget))))

(defun %daily-after-response (persona run input-tokens output-tokens)
  (declare (ignore run))
  (let ((state (%state (persona-name persona))))
    (bt:with-lock-held ((persona-state-lock state))
      (%roll-day state)
      (incf (persona-state-day-tokens state)
            (+ input-tokens output-tokens)))))

(pushnew '%daily-before-request *before-request-hooks*)
(pushnew '%daily-after-response *after-response-hooks*)
