;;;; facade.lisp -- the REPL-first surface.
;;;;
;;;; Every special variable mirrors a keyword argument of the same name, so the
;;;; one-liner and the fully-specified call are the same API.

(in-package #:cl-llm)

(defvar *provider* (make-instance 'anthropic-provider)
  "The provider used when none is given. The API key is resolved per-request,
so constructing this at load time does not require the environment to be set.")

(defvar *model* nil
  "Model override. NIL means PROVIDER-DEFAULT-MODEL decides, which keeps the
default model a property of the provider rather than a global constant.")

(defvar *temperature* nil)
(defvar *top-p* nil)
(defvar *stop* nil)
(defvar *system* nil)
(defvar *tools* nil)

(defvar *max-tool-turns* 8
  "Maximum model/tool round trips in one SEND before signalling LLM-TOOL-ERROR.
The bound is not a nicety: without it a model that keeps requesting tools loops
forever, burning tokens.")

(defun collect-parameters (&key temperature max-tokens top-p stop)
  "Build the conversation parameter plist, omitting unset values."
  (let ((parameters '()))
    (when stop (setf (getf parameters :stop) stop))
    (when top-p (setf (getf parameters :top-p) top-p))
    (when max-tokens (setf (getf parameters :max-tokens) max-tokens))
    (when temperature (setf (getf parameters :temperature) temperature))
    parameters))

(defun resolve-tools (tools)
  "Normalize TOOLS -- a list of symbols, names, or TOOL objects -- to TOOLs."
  (mapcar #'find-tool tools))

(defun send (conversation content &key (tools *tools*)
                                       (max-tool-turns *max-tool-turns*))
  "Send CONTENT as a user turn in CONVERSATION and return the assistant RESPONSE.
Both the user message and the assistant reply are appended to CONVERSATION.
When TOOLS is non-nil the tool loop runs to completion before returning."
  (let ((provider (or (conversation-provider conversation) *provider*))
        (resolved (resolve-tools tools)))
    (add-message conversation (make-message :user content))
    (if resolved
        (run-tool-loop provider conversation resolved max-tool-turns)
        (let ((response (chat-request provider conversation)))
          (add-message conversation (response-message response))
          response))))

(defun ask (prompt &key (provider *provider*)
                        (model *model*)
                        (temperature *temperature*)
                        (max-tokens *max-tokens*)
                        (top-p *top-p*)
                        (stop *stop*)
                        (system *system*)
                        (tools *tools*)
                        (max-tool-turns *max-tool-turns*))
  "Ask PROMPT and return (values TEXT RESPONSE).
The single-shot entry point: it builds a throwaway conversation. Use
MAKE-CONVERSATION and SEND to keep history across turns."
  (let ((conversation (make-conversation
                       :provider provider
                       :model model
                       :system system
                       :parameters (collect-parameters :temperature temperature
                                                       :max-tokens max-tokens
                                                       :top-p top-p
                                                       :stop stop))))
    (let ((response (send conversation prompt :tools tools
                                              :max-tool-turns max-tool-turns)))
      (values (response-text response) response))))
