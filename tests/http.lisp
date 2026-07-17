;;;; tests/http.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test http-driver-protocol-exists
  (is (find-class 'http:driver))
  (is (subtypep 'http:dexador-driver 'http:driver))
  (is (typep http:*driver* 'http:dexador-driver)
      "The default driver must be the dexador driver."))

(test fake-driver-records-request-and-returns-response
  (with-fake-driver (d (:status 200 :body "{\"ok\":true}"))
    (multiple-value-bind (body status)
        (http:perform-request http:*driver* "https://example/x"
                              :method :post :content "{\"a\":1}"
                              :headers '(("content-type" . "application/json")))
      (is (string= "{\"ok\":true}" body))
      (is (= 200 status))
      (is (string= "https://example/x" (getf (last-request d) :url)))
      (is (string= "{\"a\":1}" (getf (last-request d) :content))))))

(test fake-driver-does-not-signal-on-error-status
  "The driver contract is to REPORT status, never to signal on it."
  (with-fake-driver (d (:status 429 :body "{\"error\":{}}"))
    (multiple-value-bind (body status)
        (http:perform-request http:*driver* "https://example/x")
      (declare (ignore body))
      (is (= 429 status)))))

(test fake-driver-stream-request-yields-readable-stream
  (with-fake-driver (d (:status 200 :body (format nil "data: 1~%~%")))
    (multiple-value-bind (stream status)
        (http:perform-stream-request http:*driver* "https://example/x")
      (is (= 200 status))
      (is (string= "1" (sse:sse-event-data (sse:read-event stream)))))))

(test fake-driver-responses-are-consumed-in-order
  (with-fake-driver (d (:status 200 :body "\"first\"") (:status 200 :body "\"second\""))
    (is (string= "\"first\"" (http:perform-request http:*driver* "https://x")))
    (is (string= "\"second\"" (http:perform-request http:*driver* "https://x")))))
