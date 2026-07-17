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
    (without-sleeping (ds)
      (signals c:llm-rate-limit-error
        (cl-llm::request-with-retry "https://x")))))

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
