;;;; tests-eval/report.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(defun run-tiny-suite ()
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite report-suite
      :dataset (list (eval:make-case "hi" :expected "hi")
                     (eval:make-case "yo" :expected "NOPE"))
      :variants ((:model "m" :temperature 0.0 :label "cold"))
      :scorers (eval:exact-match))
    (eval:run-suite 'report-suite)))

(test print-object-renders-a-table
  (let ((text (princ-to-string (run-tiny-suite))))
    (is (search "cold" text) "variant label appears")
    (is (search "exact-match" text) "scorer column appears")))

(test report-returns-the-result
  (let ((result (run-tiny-suite)))
    (is (eq result (eval:report result :stream (make-broadcast-stream))))))

(test report-detail-shows-explanations
  (let* ((result (run-tiny-suite))
         (text (with-output-to-string (s)
                 (eval:report result :detail t :stream s))))
    ;; the mismatching case's explanation mentions the expected value
    (is (search "NOPE" text) "detail shows the expected value from the explanation")))

(test report-summary-shows-mean
  (let* ((result (run-tiny-suite))
         (text (with-output-to-string (s)
                 (eval:report result :stream s))))
    ;; one match out of two -> mean 0.5 appears in some rendering
    (is (or (search "0.5" text) (search "0.50" text)))))

;;; Alignment tests -- render-summary must size each column from the data
;;; (header width vs. widest value in that column), not a hardcoded width, and
;;; must justify the errors column's header and value consistently.

(eval:defscorer very-long-scorer-name-example (case response)
  "A scorer whose NAME is deliberately much wider than any hardcoded column
width, to catch a renderer that doesn't size columns from the data."
  (declare (ignore case))
  (eval:score (if response 1.0 0.0)))

(defun run-two-scorer-suite ()
  "A suite with two scorers: exact-match (11 chars, one over the old
hardcoded 10-column field) and a scorer with a much longer name."
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite two-scorer-suite
      :dataset (list (eval:make-case "hi" :expected "hi"))
      :variants ((:model "m" :label "cold"))
      :scorers (eval:exact-match very-long-scorer-name-example))
    (eval:run-suite 'two-scorer-suite)))

(defun run-error-column-suite ()
  "A suite with one scorer plus an error cell, so the errors column renders."
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (let ((prompt (llm:part-text
                                       (first (llm:message-content
                                               (car (last (llm:conversation-messages
                                                           conversation))))))))
                          (if (string= prompt "boom")
                              (error 'llm:llm-api-error :status 500 :message "down")
                              prompt))))))
    (eval:defsuite error-col-suite
      :dataset (list (eval:make-case "ok" :expected "ok")
                     (eval:make-case "boom" :expected "boom"))
      :variants ((:model "m" :label "v1"))
      :scorers (eval:exact-match))
    (eval:run-suite 'error-col-suite)))

(defun split-lines (text)
  "Split TEXT on newlines into a list of lines (no trailing empty line)."
  (let ((lines '()) (start 0))
    (loop for i from 0 below (length text)
          when (char= (char text i) #\Newline)
            do (push (subseq text start i) lines) (setf start (1+ i)))
    (when (< start (length text)) (push (subseq text start) lines))
    (nreverse lines)))

(defun split-fields-with-pos (line)
  "Split LINE into fields separated by runs of 2+ spaces. Returns a list of
(FIELD-TEXT . START-COLUMN) so callers can compare column positions directly,
rather than relying on SEARCH (which can't tell two occurrences of the same
text apart)."
  (let ((fields '()) (start 0) (n (length line)) (i 0))
    (loop while (< i n)
          do (if (and (char= (char line i) #\Space)
                      (< (1+ i) n) (char= (char line (1+ i)) #\Space))
                 (progn
                   (when (> i start) (push (cons (subseq line start i) start) fields))
                   (loop while (and (< i n) (char= (char line i) #\Space)) do (incf i))
                   (setf start i))
                 (incf i)))
    (when (> n start) (push (cons (subseq line start n) start) fields))
    (nreverse fields)))

(defun assert-columns-aligned (header data)
  "Assert HEADER and DATA (two rendered table lines) have the same number of
whitespace-delimited columns, and that each column starts at the same
character position in both lines."
  (let ((header-fields (split-fields-with-pos header))
        (data-fields (split-fields-with-pos data)))
    (is (= (length header-fields) (length data-fields))
        "header ~s and data ~s must have the same number of columns" header data)
    (loop for (htext . hpos) in header-fields
          for (dtext . dpos) in data-fields
          do (is (= hpos dpos)
                 "column ~s starts at ~d in the header but ~s starts at ~d in the data row"
                 htext hpos dtext dpos))))

(test render-summary-aligns-multiple-scorer-columns
  "Each scorer-value column must be sized from max(header, widest value) in
that column, not a hardcoded width -- otherwise exact-match's 11-char header
(one over the old hardcoded 10) drifts every column after it."
  (let* ((result (run-two-scorer-suite))
         (text (with-output-to-string (s) (eval:report result :stream s)))
         (lines (split-lines text)))
    (assert-columns-aligned (first lines) (second lines))))

(test render-summary-aligns-errors-column
  "The errors column's header and its count must occupy the same start
column -- the old code mixed a left-justified header with a right-justified
count."
  (let* ((result (run-error-column-suite))
         (text (with-output-to-string (s) (eval:report result :stream s)))
         (lines (split-lines text)))
    (assert-columns-aligned (first lines) (second lines))))

(test print-object-shows-dash-for-nil-mean
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (c) (declare (ignore c))
                        (error 'llm:llm-api-error :status 500 :message "x")))))
    (eval:defsuite dash-suite
      :dataset (list (eval:make-case "x" :expected "x"))
      :variants ((:model "m" :label "v"))
      :scorers (eval:exact-match))
    (let ((text (princ-to-string (eval:run-suite 'dash-suite))))
      (is (search "—" text) "a nil mean renders as an em dash"))))
