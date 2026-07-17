;;;; eval/suite.lisp -- variants and suites.

(in-package #:cl-llm.eval)

;;; Variants

(defstruct (variant (:constructor %make-variant (label args prompt-fn)))
  "One point in the grid: a LABEL, a plist of ARGS forwarded to ASK, and a
PROMPT-FN of (case) -> prompt string."
  (label "" :type string)
  (args nil :type list)
  (prompt-fn nil :type function))

(defun compact-label (args)
  "A short human label from a variant's forwarded ARGS."
  (with-output-to-string (out)
    (loop for (key value) on args by #'cddr
          for first = t then nil
          unless first do (write-string " " out)
          do (format out "~(~a~)=~a" key value))))

(defun parse-variant (plist)
  "Turn a variant PLIST into a VARIANT, stripping the eval-only keys :label and
:prompt-fn from the args forwarded to ASK."
  (when (oddp (length plist))
    (error 'llm-eval-error
           :message (format nil "malformed variant plist (odd length): ~s" plist)))
  (let ((args '()) (label nil) (prompt-fn nil))
    (loop for (key value) on plist by #'cddr
          do (case key
               (:label (setf label value))
               (:prompt-fn (setf prompt-fn value))
               (t (setf args (append args (list key value))))))
    (%make-variant (or label (compact-label args))
                   args
                   (or prompt-fn #'case-input))))

;;; Suites

(defclass suite ()
  ((name :initarg :name :reader suite-name :type string)
   (dataset-fn :initarg :dataset-fn :reader suite-dataset-fn)
   (variants :initarg :variants :reader suite-variants :type list)
   (scorers :initarg :scorers :reader suite-scorers :type list))
  (:documentation "A named dataset x variants x scorers evaluation."))

(defvar *suites-registry* (make-hash-table :test 'equal)
  "Maps suite name (string) to SUITE.")

(defun register-suite (suite)
  (setf (gethash (suite-name suite) *suites-registry*) suite))

(defun find-suite (designator)
  "Resolve DESIGNATOR -- a SUITE, symbol, or string -- to a SUITE."
  (etypecase designator
    (suite designator)
    ((or symbol string)
     (let ((name (string-downcase (string designator))))
       (or (gethash name *suites-registry*)
           (error 'llm-eval-error
                  :message (format nil "no suite named ~s; define it with defsuite"
                                   name)))))))

(defmacro defsuite (name &key dataset variants scorers)
  "Register a suite NAME. DATASET is a form evaluated at run time (so it can
reference a special holding the cases). VARIANTS is a list of plists. SCORERS
is a list of scorer designators, resolved now."
  `(register-suite
    (make-instance 'suite
                   :name ,(string-downcase (string name))
                   :dataset-fn (lambda () ,dataset)
                   :variants (list ,@(mapcar (lambda (v) `(parse-variant (list ,@v)))
                                             variants))
                   :scorers (list ,@(mapcar (lambda (s) `(find-scorer ',s)) scorers)))))
