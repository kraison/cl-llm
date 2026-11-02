;;;; harness/packages.lisp -- the agent harness (#85).
;;;; Spec: docs/superpowers/specs/
;;;;       2026-11-02-agent-harness-and-conversational-rag-design.md SS6

(defpackage #:cl-llm.harness
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export
   ;; personas
   #:persona #:make-persona #:persona-error
   #:persona-name #:persona-system #:persona-tools #:persona-provider
   #:persona-parameters #:persona-max-turns #:persona-max-run-tokens
   #:persona-max-seconds #:persona-max-concurrent #:persona-max-queued
   #:persona-daily-token-budget #:persona-daily-run-budget
   #:persona-make-provider #:load-persona-file
   #:find-persona #:make-persona-directory
   ;; runs
   #:run #:run-id #:run-persona-name #:run-producer #:run-input
   #:run-started #:run-finished #:run-elapsed #:run-turns
   #:run-input-tokens #:run-output-tokens #:run-stop-reason #:run-error
   #:run-text #:run-tool-calls #:run-response
   #:make-run-id #:host-principal #:run-producer-for #:*clock*
   ;; running
   #:run-persona #:time-left
   ;; per-persona state
   #:*wall-clock* #:persona-usage #:reset-persona-state))
