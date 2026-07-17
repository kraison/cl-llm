;;;; retry.lisp -- status interpretation, backoff, and the retry-request restart.

(in-package #:cl-llm)

(defvar *retries* 3
  "How many times to retry a retryable request before signalling.")

(defvar *timeout* 60
  "Per-request timeout in seconds.")

(defvar *sleep-function* #'sleep
  "Called to wait between retries. Bound in tests so they do not actually sleep.")

(defun header-value (headers name)
  "Look up NAME in HEADERS, an alist of lowercase string keys."
  (cdr (assoc name headers :test #'string-equal)))

(defun retryable-status-p (status)
  (or (eql status 429) (and (integerp status) (<= 500 status 599))))

(defun backoff-delay (attempt retry-after)
  "Seconds to wait before ATTEMPT (1-based). A server RETRY-AFTER wins verbatim."
  (or retry-after
      (min 60 (expt 2 (1- attempt)))))

(defun parse-retry-after (headers)
  (let ((value (header-value headers "retry-after")))
    (when value
      (ignore-errors (parse-integer value :junk-allowed t)))))

(defun decode-error-body (body)
  "Pull (values MESSAGE TYPE CODE) out of an error BODY.
Handles both the Anthropic and OpenAI shapes, which both nest under \"error\".
Returns all NIL if the body is not JSON at all."
  (let ((payload (ignore-errors (json:parse body))))
    (if payload
        (values (json:jget payload "error" "message")
                (json:jget payload "error" "type")
                (json:jget payload "error" "code"))
        (values nil nil nil))))

(defun signal-http-error (status body url &optional headers)
  "Signal the most specific condition for STATUS. Always signals."
  (multiple-value-bind (message type code) (decode-error-body body)
    (let ((arguments (list :status status :body body :url url
                           :message message :error-type type :code code)))
      (cond
        ((eql status 429)
         (apply #'error 'c:llm-rate-limit-error
                :retry-after (parse-retry-after headers) arguments))
        ((or (eql status 401) (eql status 403))
         (apply #'error 'c:llm-auth-error arguments))
        ((and (integerp status) (<= 400 status 599))
         (apply #'error 'c:llm-api-error arguments))
        (t (error 'c:llm-http-error :status status :body body :url url))))))

(defun request-with-retry (url &key (method :post) headers content
                                    (timeout *timeout*) (retries *retries*)
                                    stream)
  "Perform a request, retrying retryable failures with exponential backoff.
Returns (values BODY-OR-STREAM STATUS HEADERS) on success and signals an
LLM-ERROR otherwise. When STREAM is true the first value is an open character
stream. A RETRY-REQUEST restart is established around the whole operation."
  (let ((attempt 0))
    (loop
      (incf attempt)
      (restart-case
          (multiple-value-bind (body status response-headers)
              (if stream
                  (http:perform-stream-request http:*driver* url
                                               :method method :headers headers
                                               :content content :timeout timeout)
                  (http:perform-request http:*driver* url
                                        :method method :headers headers
                                        :content content :timeout timeout))
            (cond
              ((and (integerp status) (<= 200 status 299))
               (return (values body status response-headers)))
              ((and (retryable-status-p status) (< attempt (1+ retries)))
               ;; A streaming request that failed returns a body, not a stream;
               ;; nothing to close.
               (funcall *sleep-function*
                        (backoff-delay attempt (parse-retry-after response-headers))))
              (t
               (signal-http-error status
                                  (if (streamp body) "" body)
                                  url
                                  response-headers))))
        (retry-request ()
          :report "Retry this LLM request."
          (setf attempt 0))))))
