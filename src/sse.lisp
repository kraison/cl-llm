;;;; sse.lisp -- Server-Sent Events parsing.
;;;;
;;;; Pure parsing over a character stream: no HTTP, no threads. READ-EVENT
;;;; blocks on the stream and returns exactly one event, which is what makes
;;;; the pull-based streaming API possible without threads.

(in-package #:cl-llm.sse)

(defstruct (sse-event (:constructor make-sse-event (type data)))
  "One Server-Sent Event. TYPE is the event: field (a string) or NIL when the
server sent none. DATA is the concatenated data: field content."
  (type nil :type (or null string))
  (data "" :type string))

(defun strip-cr (line)
  "Remove a trailing carriage return left by READ-LINE on CRLF input."
  (let ((length (length line)))
    (if (and (plusp length) (char= #\Return (char line (1- length))))
        (subseq line 0 (1- length))
        line)))

(defun field-value (line prefix-length)
  "Extract a field value from LINE, skipping PREFIX-LENGTH characters and one
optional leading space."
  (let ((value (subseq line prefix-length)))
    (if (and (plusp (length value)) (char= #\Space (char value 0)))
        (subseq value 1)
        value)))

(defun prefixp (prefix line)
  (and (>= (length line) (length prefix))
       (string= prefix line :end2 (length prefix))))

(defun read-event (stream)
  "Read one Server-Sent Event from STREAM, blocking until it is complete.
Returns an SSE-EVENT, or NIL at end of stream. Blank lines before an event and
lines beginning with a colon (comments, used as keep-alive pings) are ignored."
  (let ((event-type nil)
        (data-lines '())
        (started nil))
    (flet ((finish ()
             (make-sse-event
              event-type
              (format nil "~{~a~^~%~}" (nreverse data-lines)))))
      (loop
        (let ((line (read-line stream nil nil)))
          (cond
            ;; End of stream: emit a truncated final event rather than lose it.
            ((null line)
             (return (when started (finish))))
            (t
             (let ((line (strip-cr line)))
               (cond
                 ((string= line "")
                  (when started (return (finish))))
                 ((prefixp ":" line))          ; comment / ping -- ignore
                 ((prefixp "data:" line)
                  (setf started t)
                  (push (field-value line 5) data-lines))
                 ((prefixp "event:" line)
                  (setf started t)
                  (setf event-type (field-value line 6)))
                 (t))))))))))          ; unknown field -- ignore per spec
