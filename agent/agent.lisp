;;;; agent/agent.lisp -- the tool set.  Spec SS5.

(in-package #:cl-llm.agent)

(defun make-memory-tools (scope)
  (list (%recall-tool scope) (%trace-tool scope)
        (%decisions-citing-tool scope)
        (%conclude-tool scope) (%conclude-absence-tool scope)
        (%retract-tool scope)))

(defun make-planner-tools (scope)
  (list (%retrieve-tool scope) (%plan-bounds-tool scope)))

(defun make-agent-tools (stores &key write-store producer sources
                                     (k 5) (max-rows 50))
  "The agent's tools over STORES (readable, in scope order) writing to
WRITE-STORE (default the first), as PRODUCER, with SOURCES added to the
planner and K / MAX-ROWS as the caps.  Every bound is fixed here; the
model chooses arguments only (SS5)."
  (let ((scope (make-scope stores :write-store write-store
                                  :producer producer :sources sources
                                  :k k :max-rows max-rows)))
    (append (make-memory-tools scope) (make-planner-tools scope))))
