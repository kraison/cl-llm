;;;; tool-loop.lisp -- the bounded automatic tool loop.
;;;;
;;;; The bound is not a nicety: without it a model that keeps requesting tools
;;;; loops forever, burning tokens. MAX-TURNS makes that impossible rather than
;;;; merely unlikely.

(in-package #:cl-llm)

(defun execute-tool-call (call tools)
  "Execute one TOOL-USE-PART, returning a TOOL-RESULT-PART.
A tool that signals produces an error result the model can see and react to,
rather than aborting the whole exchange."
  (let ((tool (find-tool-among call tools)))
    (handler-case
        (make-tool-result-part (part-id call)
                               (princ-to-string (call-tool tool (part-arguments call))))
      (c:llm-tool-error (e)
        (make-tool-result-part (part-id call)
                               (princ-to-string (c:llm-error-underlying e))
                               :errorp t)))))

(defun find-tool-among (call tools)
  "Resolve the tool CALL names, restricted to TOOLS.
A model naming a tool that was not offered is a protocol violation, not
something to paper over."
  (or (find (part-name call) tools :key #'tool-name :test #'string-equal)
      (error 'c:llm-tool-error
             :tool-name (part-name call)
             :underlying "The model requested a tool that was not offered.")))

(defun run-tool-loop (provider conversation tools max-turns)
  "Drive the model/tool exchange to a final answer.
CONVERSATION already ends with the triggering user message. Returns the first
RESPONSE whose stop reason is not :TOOL-USE."
  (loop for turn from 1 to max-turns
        for response = (chat-request provider conversation :tools tools)
        do (add-message conversation (response-message response))
           (let ((calls (response-tool-calls response)))
             (if (and (eq (response-stop-reason response) :tool-use) calls)
                 ;; Every result for this turn goes in ONE user message, which is
                 ;; what the Messages API requires.
                 (add-message conversation
                              (make-message
                               :user
                               (mapcar (lambda (call) (execute-tool-call call tools))
                                       calls)))
                 (return response)))
        finally
           (error 'c:llm-tool-error
                  :tool-name nil
                  :underlying (format nil "The model still requested tools after ~
                                           ~d turns (max-tool-turns). Giving up."
                                      max-turns))))
