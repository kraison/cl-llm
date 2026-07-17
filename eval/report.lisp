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

(defun scorer-column-width (result labels name)
  "Column width for scorer NAME: the wider of its header and the widest
formatted mean over LABELS, so the header and every value share one width."
  (reduce #'max labels
          :key (lambda (label) (length (format-mean (result-mean result label name))))
          :initial-value (length name)))

(defun errors-column-width (result labels)
  "Column width for the errors column: the wider of the \"errors\" header and
the widest formatted error count over LABELS."
  (reduce #'max labels
          :key (lambda (label) (length (princ-to-string (result-error-count result label))))
          :initial-value (length "errors")))

(defun render-summary (result stream)
  "Render the summary table: variants x scorers, cells = mean. Every column
(variant label, each scorer, errors) is sized from the data -- the wider of
its header and its widest cell -- so headers and values always line up."
  (let* ((labels (variant-labels result))
         (scorers (scorer-names result))
         (errors-p (any-errors-p result))
         (label-width (reduce #'max labels :key #'length
                                            :initial-value (length "variant")))
         (scorer-widths (mapcar (lambda (name) (scorer-column-width result labels name))
                                 scorers))
         (errors-width (and errors-p (errors-column-width result labels))))
    (format stream "~&~va" label-width "variant")
    (loop for name in scorers
          for width in scorer-widths
          do (format stream "  ~va" width name))
    (when errors-p (format stream "  ~va" errors-width "errors"))
    (terpri stream)
    (dolist (label labels)
      (format stream "~va" label-width label)
      (loop for name in scorers
            for width in scorer-widths
            do (format stream "  ~va" width (format-mean (result-mean result label name))))
      (when errors-p
        (format stream "  ~va" errors-width (princ-to-string (result-error-count result label))))
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
