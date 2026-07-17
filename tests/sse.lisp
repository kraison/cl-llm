;;;; tests/sse.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun read-all-events (text)
  (with-input-from-string (s text)
    (loop for event = (sse:read-event s)
          while event
          collect event)))

(test sse-reads-single-event
  (let ((events (read-all-events
                 (format nil "event: content_block_delta~%data: {\"a\":1}~%~%"))))
    (is (= 1 (length events)))
    (is (string= "content_block_delta" (sse:sse-event-type (first events))))
    (is (string= "{\"a\":1}" (sse:sse-event-data (first events))))))

(test sse-reads-multiple-events
  (let ((events (read-all-events
                 (format nil "event: a~%data: 1~%~%event: b~%data: 2~%~%"))))
    (is (= 2 (length events)))
    (is (string= "b" (sse:sse-event-type (second events))))
    (is (string= "2" (sse:sse-event-data (second events))))))

(test sse-joins-multiple-data-lines
  "Per the SSE spec, repeated data: lines are joined with newlines."
  (let ((events (read-all-events (format nil "data: one~%data: two~%~%"))))
    (is (string= (format nil "one~%two") (sse:sse-event-data (first events))))))

(test sse-handles-crlf
  "Servers may send CRLF; the trailing CR must not end up in the data."
  (let ((events (read-all-events
                 (format nil "event: a~C~%data: 1~C~%~C~%" #\Return #\Return #\Return))))
    (is (= 1 (length events)))
    (is (string= "a" (sse:sse-event-type (first events))))
    (is (string= "1" (sse:sse-event-data (first events))))))

(test sse-ignores-comments-and-blank-padding
  (let ((events (read-all-events
                 (format nil "~%: this is a ping comment~%data: 1~%~%"))))
    (is (= 1 (length events)))
    (is (string= "1" (sse:sse-event-data (first events))))))

(test sse-tolerates-missing-space-after-colon
  (let ((events (read-all-events (format nil "event:a~%data:1~%~%"))))
    (is (string= "a" (sse:sse-event-type (first events))))
    (is (string= "1" (sse:sse-event-data (first events))))))

(test sse-event-without-event-field
  "OpenAI-compatible servers send bare data: lines with no event: field."
  (let ((events (read-all-events (format nil "data: [DONE]~%~%"))))
    (is (null (sse:sse-event-type (first events))))
    (is (string= "[DONE]" (sse:sse-event-data (first events))))))

(test sse-returns-nil-at-end-of-stream
  (with-input-from-string (s "")
    (is (null (sse:read-event s)))))

(test sse-final-event-without-trailing-blank-line
  "A truncated final event must still be returned rather than dropped."
  (let ((events (read-all-events (format nil "data: 1~%"))))
    (is (= 1 (length events)))
    (is (string= "1" (sse:sse-event-data (first events))))))
