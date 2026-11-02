;;;; harness/run-persona.lisp -- one persona run, start to record
;;;; (spec SS6.3).  docs/agent-harness.md

(in-package #:cl-llm.harness)

(defun %resolve-tools (persona offered)
  "PERSONA's tools as LLM:TOOLs: a name resolves against OFFERED first,
then the deftool registry."
  (mapcar (lambda (designator)
            (cond ((typep designator 'llm:tool) designator)
                  ((find designator offered
                         :key #'llm:tool-name :test #'string-equal))
                  (t (handler-case (llm:find-tool designator)
                       (error ()
                         (%persona-error "persona ~a: no tool named ~s"
                                         (persona-name persona)
                                         designator))))))
          (persona-tools persona)))

(defun %call-with-conversation (conversation persona provider fn)
  "Call FN with CONVERSATION, or a fresh one, set up for PERSONA.  A
supplied conversation lends its messages only: its system, provider and
parameters come back on every exit."
  (if (null conversation)
      (funcall fn (llm:make-conversation
                   :system (persona-system persona)
                   :provider provider
                   :parameters (copy-list (persona-parameters persona))))
      (let ((system (llm:conversation-system conversation))
            (lent (llm:conversation-provider conversation))
            (parameters (llm:conversation-parameters conversation)))
        (unwind-protect
             (progn
               (setf (llm:conversation-system conversation)
                     (persona-system persona)
                     (llm:conversation-provider conversation) provider
                     (llm:conversation-parameters conversation)
                     (copy-list (persona-parameters persona)))
               (funcall fn conversation))
          (setf (llm:conversation-system conversation) system
                (llm:conversation-provider conversation) lent
                (llm:conversation-parameters conversation) parameters)))))

(defun %fail (run condition)
  (setf (run-stop-reason run) :error
        (run-error run) condition))

(defun %execute (run persona input conversation offered)
  "Run PERSONA on INPUT, recording onto RUN.  Never signals."
  (handler-case
      (let* ((tools (mapcar (lambda (tool) (%wrap-tool tool run))
                            (%resolve-tools persona offered)))
             (provider (make-instance 'guarded-provider
                                      :inner (persona-make-provider persona)
                                      :persona persona :run run)))
        (%call-with-conversation
         conversation persona provider
         (lambda (c)
           (let ((response (llm:send c input
                                     :tools tools
                                     :max-tool-turns
                                     (persona-max-turns persona))))
             (setf (run-text run) (llm:response-text response)
                   (run-response run) response
                   (run-stop-reason run)
                   (llm:response-stop-reason response))))))
    (run-stop (stop)
      (setf (run-stop-reason run) (run-stop-reason-of stop)))
    (llm:llm-tool-error (e)
      ;; Core's give-up after MAX-TOOL-TURNS names no tool.
      (if (and (null (llm:llm-error-tool-name e))
               (>= (run-turns run) (persona-max-turns persona)))
          (setf (run-stop-reason run) :max-turns)
          (%fail run e)))
    (error (e) (%fail run e))))

(defun run-persona (persona input &key conversation producer tools)
  "Run PERSONA on INPUT (a string) and return a RUN recording what
happened and how it stopped.  CONVERSATION, when given, is continued:
the turn stays on success and is rolled back otherwise.  TOOLS are
LLM:TOOLs the caller offers; the persona's names choose among them.
Every failure is a returned run; only an uncanonical PRODUCER signals."
  (let* ((id (make-run-id))
         (run (make-instance 'run
                             :id id :persona-name (persona-name persona)
                             :producer (run-producer-for
                                        (persona-name persona) id
                                        :producer producer)
                             :input input
                             :started (get-universal-time)))
         (start (%now))
         (*deadline* (and (persona-max-seconds persona)
                          (+ start (persona-max-seconds persona))))
         (admission (%admit persona)))
    (if (eq admission :ok)
        (unwind-protect (%execute run persona input conversation tools)
          (%release persona))
        (setf (run-stop-reason run) admission))
    (setf (run-finished run) (get-universal-time)
          (run-elapsed run) (- (%now) start))
    run))
