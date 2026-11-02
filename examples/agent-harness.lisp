;;;; agent-harness.lisp -- run a persona as a bounded, accounted run.
;;;;
;;;; Load this file, then:
;;;;   (examples/agent-harness:offline)   ; no network: a mock model
;;;;   (examples/agent-harness:run)       ; a local llama-server model
;;;; Guide: docs/agent-harness.md

(ql:quickload :cl-llm/harness)

(defpackage #:examples/agent-harness
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:harness #:cl-llm.harness))
  (:export #:offline #:run #:show))

(in-package #:examples/agent-harness)

(llm:deftool add-integers ((a :type integer) (b :type integer))
  "Add two integers together."
  (+ a b))

(defun show (run)
  "Print what RUN did and how it stopped."
  (format t "~&~a~%  stop ~s~@[ (~a)~]~%  text ~s~%  turns ~d, ~
             tokens ~d in / ~d out, ~,2f s~%  tool calls ~s~%"
          (harness:run-producer run) (harness:run-stop-reason run)
          (harness:run-error run) (harness:run-text run)
          (harness:run-turns run) (harness:run-input-tokens run)
          (harness:run-output-tokens run) (harness:run-elapsed run)
          (harness:run-tool-calls run))
  run)

(defun looping-model ()
  "A mock model that asks for a tool on every turn, forever."
  (llm:make-mock-provider
   :responder (lambda (conversation)
                (declare (ignore conversation))
                (make-instance
                 'llm:response
                 :content (list (llm:make-tool-use-part
                                 "t1" "add-integers"
                                 (let ((h (make-hash-table :test #'equal)))
                                   (setf (gethash "a" h) 1
                                         (gethash "b" h) 2)
                                   h)))
                 :stop-reason :tool-use
                 :usage (make-instance 'llm:usage :input-tokens 50
                                                  :output-tokens 10)))))

(defun offline ()
  "Two guards stopping a runaway model, with no network."
  (harness:reset-persona-state)
  ;; The turn cap stops it...
  (show (harness:run-persona
         (harness:make-persona :name "runaway" :tools '("add-integers")
                               :provider (looping-model) :max-turns 3)
         "add forever"))
  ;; ...and so does a token budget, before the request that would
  ;; start past it.
  (show (harness:run-persona
         (harness:make-persona :name "runaway-2" :tools '("add-integers")
                               :provider (looping-model)
                               :max-run-tokens 100)
         "add forever")))

(defparameter *here* (or *load-truename* *default-pathname-defaults*)
  "This file, captured at load: *LOAD-TRUENAME* is NIL when RUN runs.")

(defun run (&key (persona-file (merge-pathnames "local-adder.persona"
                                                *here*)))
  "A persona file for a local llama-server model, run with a tool.  Edit
the file's :base-url, :model and :api-key-file for your server."
  (let ((persona (harness:load-persona-file persona-file)))
    (show (harness:run-persona
           persona "Use add-integers to add 17 and 25. Just the number."))))
