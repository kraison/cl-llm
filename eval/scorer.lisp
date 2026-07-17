;;;; eval/scorer.lisp -- scorers: named (case response) -> score functions.

(in-package #:cl-llm.eval)

(defclass scorer ()
  ((name :initarg :name :reader scorer-name :type string)
   (function :initarg :function :reader scorer-function))
  (:documentation "A named scoring function of (case response) -> SCORE."))

(defvar *scorers-registry* (make-hash-table :test 'equal)
  "Maps scorer name (string) to SCORER.")

(defun register-scorer (scorer)
  (setf (gethash (scorer-name scorer) *scorers-registry*) scorer))

(defun find-scorer (designator)
  "Resolve DESIGNATOR -- a SCORER, symbol, or string -- to a SCORER."
  (etypecase designator
    (scorer designator)
    ((or symbol string)
     (let ((name (string-downcase (string designator))))
       (or (gethash name *scorers-registry*)
           (error 'llm-eval-error
                  :message (format nil "no scorer named ~s; define it with defscorer"
                                   name)))))))

(defun run-scorer (scorer case response)
  "Run SCORER on CASE and RESPONSE (which may be NIL for an error cell)."
  (funcall (scorer-function scorer) case response))

(defmacro defscorer (name (case response) &body body)
  "Define NAME as a function AND register it as a scorer. BODY returns a SCORE.
CASE is the EVAL-CASE; RESPONSE is the cl-llm RESPONSE, or NIL for an error
cell -- BODY must tolerate a NIL response."
  `(progn
     (defun ,name (,case ,response) ,@body)
     (register-scorer (make-instance 'scorer
                                     :name ,(string-downcase (string name))
                                     :function #',name))
     ',name))

(defscorer exact-match (case response)
  "Score 1.0 when the response text exactly equals the case's expected answer."
  (unless (case-expected case)
    (error 'llm-eval-error
           :message "exact-match needs a case with an :expected answer"))
  (cond
    ((null response) (score 0.0 :explanation "no response (error cell)"))
    ((string= (llm:response-text response) (case-expected case)) (score 1.0))
    (t (score 0.0 :explanation
              (format nil "expected ~s, got ~s"
                      (case-expected case) (llm:response-text response))))))
