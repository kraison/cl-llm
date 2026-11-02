;;;; harness/guard.lisp -- the per-run guards (spec SS6.4).
;;;; Enforced by wrapping what LLM:SEND is handed -- the provider and the
;;;; tools -- so core's tool loop is unchanged.  A tool body is never
;;;; interrupted: a slow tool overruns the deadline by its own duration.
;;;; docs/agent-harness.md

(in-package #:cl-llm.harness)

(define-condition run-stop (condition)
  ((reason :initarg :reason :reader run-stop-reason-of))
  (:documentation "A guard stopping the run.  Not an ERROR, so core's
tool handlers, which catch errors, let it through to RUN-PERSONA."))

(defvar *deadline* nil
  "The current run's deadline on *CLOCK*, or NIL.")

(defun %now () (funcall *clock*))

(defun time-left ()
  "Seconds until the current run's deadline, never negative; NIL outside
a run or when the persona has no :max-seconds.  For tool bodies."
  (and *deadline* (max 0 (- *deadline* (%now)))))

(defun %stop (reason)
  (signal 'run-stop :reason reason)
  (error "cl-llm.harness: guard stop ~s outside RUN-PERSONA" reason))

(defun %check-deadline ()
  (let ((left (time-left)))
    (when (and left (<= left 0))
      (%stop :deadline))))

(defun %request-timeout ()
  "LLM:*TIMEOUT*, capped by the time left; unchanged with no deadline."
  (let ((left (time-left)))
    (cond ((null left) llm:*timeout*)
          ((null llm:*timeout*) (max 1 (ceiling left)))
          (t (min llm:*timeout* (max 1 (ceiling left)))))))

(defun %run-tokens (run)
  (+ (run-input-tokens run) (run-output-tokens run)))

(defvar *before-request-hooks* '()
  "Functions of (PERSONA RUN) called before every model request; each
may call %STOP.  The per-persona budgets add theirs here.")

(defvar *after-response-hooks* '()
  "Functions of (PERSONA RUN INPUT-TOKENS OUTPUT-TOKENS) called after
every model response.")

(defclass guarded-provider (llm:provider)
  ((inner :initarg :inner :reader guarded-inner)
   (persona :initarg :persona :reader guarded-persona)
   (run :initarg :run :reader guarded-run))
  (:documentation "Checks the guards around each request to INNER."))

(defmethod llm:chat-request ((provider guarded-provider) conversation
                             &key tools)
  (let ((run (guarded-run provider))
        (persona (guarded-persona provider)))
    (%check-deadline)
    (let ((budget (persona-max-run-tokens persona)))
      (when (and budget (>= (%run-tokens run) budget))
        (%stop :token-budget)))
    (dolist (hook *before-request-hooks*) (funcall hook persona run))
    (let ((response (let ((llm:*timeout* (%request-timeout)))
                      (llm:chat-request (guarded-inner provider)
                                        conversation :tools tools))))
      (incf (run-turns run))
      (let* ((usage (llm:response-usage response))
             (in (or (and usage (llm:usage-input-tokens usage)) 0))
             (out (or (and usage (llm:usage-output-tokens usage)) 0)))
        (incf (run-input-tokens run) in)
        (incf (run-output-tokens run) out)
        (dolist (hook *after-response-hooks*)
          (funcall hook persona run in out)))
      (setf (run-response run) response)
      response)))

(defun %record-tool-call (run name arguments result error-p)
  (setf (run-tool-calls run)
        (append (run-tool-calls run)
                (list (list :name name :arguments arguments
                            :result result :error-p error-p)))))

(defun %wrap-tool (tool run)
  "TOOL, checking the deadline before its body and recording the call."
  (let ((inner (llm:tool-function tool))
        (name (llm:tool-name tool)))
    (llm:copy-tool
     tool
     :function (lambda (&rest arguments)
                 (%check-deadline)
                 (let ((done nil) (result nil) (failure nil))
                   (unwind-protect
                        (handler-bind ((error (lambda (e)
                                                (setf failure
                                                      (princ-to-string e)))))
                          (setf result (apply inner arguments)
                                done t)
                          result)
                     (%record-tool-call
                      run name arguments
                      (if done (princ-to-string result)
                          (or failure "no result"))
                      (not done))))))))
