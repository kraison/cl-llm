;;;; eval/report.lisp -- text rendering of a suite result.

(in-package #:cl-llm.eval)

(defun variant-labels (result)
  "Distinct variant labels in the RESULT, in first-seen order."
  (let ((seen '()))
    (dolist (cell (result-cells result) (nreverse seen))
      (pushnew (cell-variant-label cell) seen :test #'string=))))

(defun scorer-names (result)
  "The RESULT's suite's scorer names, in order."
  (mapcar #'scorer-name (suite-scorers (result-suite result))))

(defun format-mean (mean)
  (if mean (format nil "~,2f" mean) "—"))

(defun any-errors-p (result)
  (some #'cell-error (result-cells result)))

(defun render-summary (result stream)
  "Render the summary table: variants x scorers, cells = mean."
  (let* ((labels (variant-labels result))
         (scorers (scorer-names result))
         (errors-p (any-errors-p result))
         (label-width (reduce #'max labels :key #'length
                                            :initial-value (length "variant"))))
    (format stream "~&~va" label-width "variant")
    (dolist (name scorers) (format stream "  ~10a" name))
    (when errors-p (format stream "  ~6a" "errors"))
    (terpri stream)
    (dolist (label labels)
      (format stream "~va" label-width label)
      (dolist (name scorers)
        (format stream "  ~10a" (format-mean (result-mean result label name))))
      (when errors-p
        (format stream "  ~6d" (result-error-count result label)))
      (terpri stream))))

(defmethod print-object ((result suite-result) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (result stream :type t)
        (format stream "~a~%" (suite-name (result-suite result)))
        (render-summary result stream))))

(defun render-detail (result stream)
  "Per-case breakdown: each cell's scores and explanations."
  (format stream "~&~%Detail:~%")
  (dolist (cell (result-cells result))
    (format stream "~&[~a] input=~s"
            (cell-variant-label cell) (case-input (cell-case cell)))
    (if (cell-error cell)
        (format stream "  ERROR: ~a~%" (cell-error cell))
        (progn
          (terpri stream)
          (loop for (name score) on (cell-scores cell) by #'cddr
                do (format stream "    ~a: ~,2f~@[  (~a)~]~%"
                           name (score-value score) (score-explanation score)))))))

(defun report (result &key (detail nil) (stream *standard-output*))
  "Print RESULT's summary table to STREAM. With DETAIL, also print a per-case
breakdown including each scorer's explanation. Returns RESULT."
  (render-summary result stream)
  (when detail (render-detail result stream))
  result)
