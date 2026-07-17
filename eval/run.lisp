;;;; eval/run.lisp -- running a suite into a result grid.

(in-package #:cl-llm.eval)

(defvar *eval-map*
  (lambda (function list) (mapcar function list))
  "How RUN-SUITE traverses the (case x variant) grid. Default is a serial
mapcar. Rebind to a parallel map (bordeaux-threads, lparallel, ...) to opt into
concurrency without eval depending on any threading library. Signature:
(function list) -> list.")

(defstruct (cell (:constructor %make-cell (case variant-label response scores error)))
  "One (case, variant) result: the CASE, the VARIANT-LABEL, the RESPONSE (or
NIL), a plist of scorer-name -> SCORE (or NIL for an error cell), and the
captured ERROR condition (or NIL)."
  (case nil)
  (variant-label "" :type string)
  (response nil)
  (scores nil :type list)
  (error nil))

(defstruct (suite-result (:constructor %make-suite-result (suite cells)))
  "The outcome of RUN-SUITE: the SUITE and a list of CELLs."
  (suite nil)
  (cells nil :type list))

(defun run-cell (variant scorers case)
  "Run one CASE through one VARIANT with SCORERS, returning a CELL.
Only the model call is protected: an ASK failure becomes an error cell, but a
scorer's LLM-EVAL-ERROR (a harness/dataset misuse) propagates out of the run,
per the spec -- it is a definition mistake to surface immediately, not an API
outage to record."
  (let ((prompt (funcall (variant-prompt-fn variant) case)))
    ;; ASK returns (values text response); we need the RESPONSE object (the
    ;; second value), not the text, since scorers take a response.
    (multiple-value-bind (response error)
        (handler-case
            (values (nth-value 1 (apply #'llm:ask prompt (variant-args variant))) nil)
          (c:llm-error (e) (values nil e)))
      (if error
          (%make-cell case (variant-label variant) nil nil error)
          (%make-cell case (variant-label variant) response
                      (loop for scorer in scorers
                            collect (scorer-name scorer)
                            collect (run-scorer scorer case response))
                      nil)))))

(defun run-suite (name-or-suite &key provider)
  "Run a suite and return a SUITE-RESULT. When PROVIDER is given it is bound to
*PROVIDER* for the whole run. A cell whose ASK call signals an LLM-ERROR is
recorded as an error cell; the run continues."
  (let* ((suite (find-suite name-or-suite))
         (cl-llm:*provider* (or provider cl-llm:*provider*))
         (dataset (funcall (suite-dataset-fn suite)))
         (variants (suite-variants suite))
         (scorers (suite-scorers suite))
         ;; Build the flat grid of (variant . case) pairs, then map over it.
         (pairs (loop for variant in variants
                      nconc (loop for case in dataset
                                  collect (cons variant case)))))
    (%make-suite-result
     suite
     (funcall *eval-map*
              (lambda (pair) (run-cell (car pair) scorers (cdr pair)))
              pairs))))

(defun cell-score (cell scorer-name)
  "The SCORE for SCORER-NAME in CELL, found by STRING= (a plist keyed by
strings cannot use GETF, which compares with EQ). NIL if absent."
  (loop for (name score) on (cell-scores cell) by #'cddr
        when (string= name scorer-name) return score))

(defun result-suite (result) (suite-result-suite result))
(defun result-cells (result) (suite-result-cells result))

(defun result-mean (result variant-label scorer-name)
  "Mean SCORE-VALUE for a (VARIANT-LABEL, SCORER-NAME) pair over non-error
cells, or NIL when there are none."
  (let ((values (loop for cell in (result-cells result)
                      for score = (and (string= (cell-variant-label cell) variant-label)
                                       (null (cell-error cell))
                                       (cell-score cell scorer-name))
                      when score collect (score-value score))))
    (when values
      (/ (reduce #'+ values) (length values)))))

(defun result-error-count (result variant-label)
  "Number of error cells for VARIANT-LABEL."
  (count-if (lambda (cell) (and (string= (cell-variant-label cell) variant-label)
                                (cell-error cell)))
            (result-cells result)))
