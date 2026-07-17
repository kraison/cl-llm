;;;; eval/case.lisp -- an evaluation case.

(in-package #:cl-llm.eval)

(defstruct (eval-case (:constructor %make-eval-case (input expected metadata)))
  "One evaluation case: an INPUT (usually a prompt string), an optional
EXPECTED reference answer, and optional METADATA (a plist of user tags)."
  (input nil)
  (expected nil)
  (metadata nil :type list))

(defun make-case (input &key expected metadata)
  "Make an EVAL-CASE. A dataset is simply a list of these."
  (%make-eval-case input expected metadata))

(defun case-input (case) (eval-case-input case))
(defun case-expected (case) (eval-case-expected case))
(defun case-metadata (case) (eval-case-metadata case))
