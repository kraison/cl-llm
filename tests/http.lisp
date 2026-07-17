;;;; tests/http.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test http-driver-protocol-exists
  (is (find-class 'http:driver))
  (is (subtypep 'http:dexador-driver 'http:driver))
  (is (typep *production-driver* 'http:dexador-driver)
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

;;; -- Finding 1: NORMALIZE-RESPONSE-HEADERS -----------------------------
;;;
;;; The real driver is never exercised by the offline suite (the fake
;;; overrides it via CLOS dispatch), so this normalization is pulled out
;;; into its own function and tested directly against the shapes dexador
;;; can actually hand back.

(test normalize-response-headers-converts-populated-hash-table
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "content-type" ht) "application/json")
    (setf (gethash "retry-after" ht) "30")
    (let ((alist (http:normalize-response-headers ht)))
      (is (listp alist))
      (is (not (hash-table-p alist)))
      (is (string= "30" (cdr (assoc "retry-after" alist :test #'string-equal))))
      (is (string= "application/json"
                   (cdr (assoc "content-type" alist :test #'string-equal)))))))

(test normalize-response-headers-lowercases-keys
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "Retry-After" ht) "7")
    (let ((alist (http:normalize-response-headers ht)))
      (is (string= "7" (cdr (assoc "retry-after" alist :test #'string=)))))))

(test normalize-response-headers-handles-empty-hash-table
  (is (null (http:normalize-response-headers (make-hash-table :test 'equal)))))

(test normalize-response-headers-passes-through-existing-alist
  (let ((alist '(("retry-after" . "5"))))
    (is (equal alist (http:normalize-response-headers alist)))))

(test normalize-response-headers-handles-nil
  (is (null (http:normalize-response-headers nil))))

(test normalize-response-headers-is-robust-to-unexpected-input
  "Must not error on a shape dexador has never actually produced."
  (is (null (http:normalize-response-headers 42)))
  (is (null (http:normalize-response-headers "not-headers"))))

;;; -- Finding 2: read-timeout translation --------------------------------
;;;
;;; dexador signals SB-SYS:IO-TIMEOUT (not USOCKET:TIMEOUT-ERROR) when the
;;; read deadline expires mid-response. It is not a subtype of
;;; USOCKET:TIMEOUT-ERROR, so it needs its own handler in
;;; WITH-TRANSLATED-ERRORS. Exercised directly against the macro with a
;;; manually signalled condition -- no network involved.

#+sbcl
(test read-timeout-translates-to-llm-timeout-error
  (signals c:llm-timeout-error
    (http::with-translated-errors ("https://example/x")
      (error 'sb-sys:io-timeout :stream *standard-output*
                                 :direction :input :seconds 1))))

(test connect-timeout-still-translates-to-llm-timeout-error
  "Regression guard: adding the SB-SYS:IO-TIMEOUT handler must not disturb
the existing USOCKET:TIMEOUT-ERROR handler."
  (signals c:llm-timeout-error
    (http::with-translated-errors ("https://example/x")
      (error 'usocket:timeout-error))))

;;; -- Finding 3: an omitted timeout must not become an explicit NIL -----

(test timeout-request-args-omits-keywords-when-timeout-is-nil
  (is (null (http::timeout-request-args nil))))

(test timeout-request-args-includes-both-keywords-when-timeout-is-supplied
  (is (equal '(:read-timeout 5 :connect-timeout 5)
             (http::timeout-request-args 5))))

;;; -- Finding 4: forgotten WITH-FAKE-DRIVER must fail loudly ------------

(test suite-default-driver-is-the-guard
  "Outside WITH-FAKE-DRIVER, HTTP:*DRIVER* must be the guard, not a live
dexador driver -- otherwise a forgotten WITH-FAKE-DRIVER in some future
test would silently reach the network instead of failing immediately."
  (is (typep http:*driver* 'no-fake-driver)))

(test no-fake-driver-guard-signals-on-both-methods
  (let ((guard (make-instance 'no-fake-driver)))
    (signals error (http:perform-request guard "https://example/x"))
    (signals error (http:perform-stream-request guard "https://example/x"))))

(test with-fake-driver-still-overrides-the-guard
  (with-fake-driver (d (:status 200 :body "\"ok\""))
    (is (typep http:*driver* 'fake-driver))
    (is (string= "\"ok\"" (http:perform-request http:*driver* "https://x")))))
