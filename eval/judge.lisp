;;;; eval/judge.lisp -- LLM-as-judge scorers.
;;;;
;;;; A judge is a scorer that itself calls the model. defjudge's BODY returns
;;;; the judge PROMPT (unlike defscorer, whose body returns a SCORE); the
;;;; machinery does the ask + parse. That asymmetry is what makes a judge one
;;;; form instead of ten.

(in-package #:cl-llm.eval)

(defun number-bounds (text)
  "Return (values START END) of the first numeric token in TEXT, or NIL."
  (let ((start (position-if (lambda (ch) (or (digit-char-p ch) (char= ch #\.))) text)))
    (when start
      (let ((end (or (position-if-not
                      (lambda (ch) (or (digit-char-p ch) (char= ch #\.)))
                      text :start start)
                     (length text))))
        (values start end)))))

(defun parse-judge-score (text)
  "Extract a score in [0,1] from a judge's reply TEXT.
Returns (values VALUE RATIONALE). A number in [0,1] is taken as-is; a number in
(1,100] is divided by 100. VALUE is NIL when no number is found."
  (multiple-value-bind (start end) (number-bounds text)
    (if (null start)
        (values nil text)
        (let ((number (ignore-errors
                       (read-from-string (subseq text start end)))))
          (if (realp number)
              (values (max 0 (min 1 (if (> number 1) (/ number 100.0) number)))
                      (string-trim " -:.," (concatenate 'string
                                                        (subseq text 0 start)
                                                        (subseq text end))))
              (values nil text))))))

(defun %split-body-declarations (body)
  "Split a macro BODY into (values DECLARATIONS FORMS): leading (declare ...)
forms, then the rest. Lets DEFJUDGE hoist a body's `(declare (ignore ...))` to
the generated function's head, where an ignore is actually honored."
  (loop for tail on body
        for form = (car tail)
        while (and (consp form) (eq (car form) 'declare))
        collect form into decls
        finally (return (values decls tail))))

(defun %score-judge-reply (prompt)
  "Ask PROMPT, parse a [0,1] score from the reply, and return a SCORE.
An unparseable reply, or a signalled llm-error during the call, yields a 0.0
score with an explanation -- a judge misfire never sinks a run."
  (handler-case
      (let ((reply (llm:ask prompt)))
        (multiple-value-bind (value rationale) (parse-judge-score reply)
          (if value
              (score value :explanation rationale)
              (score 0.0 :explanation
                     (format nil "unparseable judge output: ~a"
                             (subseq reply 0 (min 120 (length reply))))))))
    (c:llm-error (e)
      (score 0.0 :explanation (format nil "judge call failed: ~a" e)))))

(defmacro defjudge (name (case response) &body body)
  "Define an LLM-as-judge scorer NAME. BODY returns the judge PROMPT string.
The scorer calls (ask <prompt>), parses a [0,1] score and rationale from the
reply, and returns a SCORE.

Leading declarations in BODY are hoisted to the generated scorer function's
head, so a body that does not use CASE or RESPONSE may `(declare (ignore ...))`
them without a warning. The remaining forms are pure expressions whose last
value is the prompt."
  (multiple-value-bind (declarations forms) (%split-body-declarations body)
    `(defscorer ,name (,case ,response)
       ,@declarations
       (%score-judge-reply (progn ,@forms)))))
