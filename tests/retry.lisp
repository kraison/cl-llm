;;;; tests/retry.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defmacro without-sleeping ((&optional (delays (gensym))) &body body)
  "Run BODY with sleeping stubbed out, collecting requested delays into DELAYS."
  `(let* ((,delays '()))
     (let ((cl-llm::*sleep-function*
             (lambda (seconds) (push seconds ,delays))))
       ,@body)
     (nreverse ,delays)))

(test retry-succeeds-without-retrying
  (with-fake-driver (d (:status 200 :body "{\"ok\":true}"))
    (multiple-value-bind (body status) (cl-llm::request-with-retry "https://x")
      (is (string= "{\"ok\":true}" body))
      (is (= 200 status))
      (is (= 1 (length (fake-requests d)))))))

(test retry-retries-429-then-succeeds
  (with-fake-driver (d (:status 429 :body "{}") (:status 200 :body "{\"ok\":true}"))
    (let ((delays (without-sleeping (ds)
                    (is (= 200 (nth-value 1 (cl-llm::request-with-retry "https://x")))))))
      (is (= 2 (length (fake-requests d))))
      (is (equal '(1) delays) "First backoff must be 1 second"))))

(test retry-honors-retry-after-header
  (with-fake-driver (d (:status 429 :headers '(("retry-after" . "7")) :body "{}")
                       (:status 200 :body "{}"))
    (let ((delays (without-sleeping (ds) (cl-llm::request-with-retry "https://x"))))
      (is (equal '(7) delays) "Retry-After must win over computed backoff"))))

(test retry-backoff-is-exponential
  (with-fake-driver (d (:status 500 :body "{}") (:status 500 :body "{}")
                       (:status 500 :body "{}") (:status 200 :body "{}"))
    (let ((delays (without-sleeping (ds)
                    (let ((cl-llm::*retries* 5))
                      (cl-llm::request-with-retry "https://x")))))
      (is (equal '(1 2 4) delays)))))

(test retry-gives-up-and-signals-rate-limit
  (with-fake-driver (d (:status 429 :body "{}") (:status 429 :body "{}")
                       (:status 429 :body "{}") (:status 429 :body "{}"))
    (let ((delays (without-sleeping (ds)
                    (signals c:llm-rate-limit-error
                      (cl-llm::request-with-retry "https://x")))))
      (is (= 3 (length delays)) "Must sleep exactly 3 times (once per retry)")
      (is (= 4 (length (fake-requests d)))
          "Must make exactly 4 requests (1 initial + 3 retries) before giving up"))))

(test retry-parse-retry-after-rejects-negative
  "A negative Retry-After is not a usable value; treat it as absent so the
computed exponential backoff is used instead."
  (is (null (cl-llm::parse-retry-after '(("retry-after" . "-5"))))))

(test retry-parse-retry-after-accepts-zero
  "Retry-After: 0 means retry immediately -- it is a legitimate value, not
an absent one, so it must not be rejected."
  (is (eql 0 (cl-llm::parse-retry-after '(("retry-after" . "0"))))))

(test retry-negative-retry-after-does-not-crash
  "CL:SLEEP signals a SIMPLE-TYPE-ERROR on a negative argument. A negative
Retry-After must never reach the sleep function verbatim -- it must fall
back to the computed exponential backoff instead of crashing the retry
loop with a raw type error."
  (with-fake-driver (d (:status 429 :headers '(("retry-after" . "-5")) :body "{}")
                       (:status 200 :body "{}"))
    (let ((delays '()))
      (finishes
        (let ((cl-llm::*sleep-function*
                (lambda (seconds)
                  ;; Mirrors CL:SLEEP's real argument contract (a
                  ;; non-negative real) without actually sleeping, so a
                  ;; regression here reproduces the same class of error
                  ;; SLEEP itself would signal on a negative delay.
                  (unless (and (realp seconds) (>= seconds 0))
                    (error 'type-error :datum seconds :expected-type '(real 0)))
                  (push seconds delays))))
          (cl-llm::request-with-retry "https://x")))
      (is (equal '(1) (nreverse delays))
          "Negative Retry-After must fall back to computed backoff (1s), not -5"))))

(test retry-zero-retry-after-is-honored
  "Retry-After: 0 must be honoured verbatim as an immediate retry, not
treated as absent."
  (with-fake-driver (d (:status 429 :headers '(("retry-after" . "0")) :body "{}")
                       (:status 200 :body "{}"))
    (let ((delays (without-sleeping (ds) (cl-llm::request-with-retry "https://x"))))
      (is (equal '(0) delays) "Retry-After: 0 must be honoured as an immediate retry"))))

(test retry-does-not-retry-400
  (with-fake-driver (d (:status 400 :body "{\"error\":{\"message\":\"bad\"}}"))
    (signals c:llm-api-error (cl-llm::request-with-retry "https://x"))
    (is (= 1 (length (fake-requests d))) "400 must not be retried")))

(test retry-401-signals-auth-error
  (with-fake-driver (d (:status 401 :body "{\"error\":{\"message\":\"nope\"}}"))
    (signals c:llm-auth-error (cl-llm::request-with-retry "https://x"))
    (is (= 1 (length (fake-requests d))))))

(test retry-error-carries-status-and-message
  (with-fake-driver (d (:status 400 :body "{\"error\":{\"message\":\"bad thing\",\"type\":\"invalid_request_error\"}}"))
    (handler-case (cl-llm::request-with-retry "https://x")
      (c:llm-api-error (e)
        (is (= 400 (c:llm-error-status e)))
        (is (string= "bad thing" (c:llm-error-message e)))
        (is (string= "invalid_request_error" (c:llm-error-type e)))))))

(test retry-request-restart-is-available
  "The debugger must offer a way to retry a failed request."
  (with-fake-driver (d (:status 400 :body "{}") (:status 200 :body "{\"ok\":true}"))
    (handler-bind ((c:llm-api-error
                     (lambda (e)
                       (declare (ignore e))
                       (let ((restart (find-restart 'cl-llm::retry-request)))
                         (is-true restart "retry-request restart must be established")
                         (invoke-restart restart)))))
      (is (= 200 (nth-value 1 (cl-llm::request-with-retry "https://x")))))))
