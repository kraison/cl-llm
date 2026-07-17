;;;; tests/fake-driver.lisp -- the seam that keeps the default suite offline.

(in-package #:cl-llm.test)

(defclass fake-driver (http:driver)
  ((responses :initform '() :accessor fake-responses
              :documentation "Queue of (status headers body) lists, consumed in order.")
   (requests :initform '() :accessor fake-requests
             :documentation "Recorded requests, oldest first, each a plist."))
  (:documentation "A driver that replays canned responses and records requests."))

(defun enqueue-response (driver &key (status 200) (headers '()) (body "{}"))
  "Queue one response for DRIVER to return."
  (setf (fake-responses driver)
        (append (fake-responses driver) (list (list status headers body))))
  driver)

(defun next-canned-response (driver)
  (let ((response (pop (fake-responses driver))))
    (unless response
      (error "fake-driver: a request was made but no response was enqueued."))
    (values-list response)))

(defun record-request (driver url method headers content)
  (setf (fake-requests driver)
        (append (fake-requests driver)
                (list (list :url url :method method :headers headers :content content)))))

(defun last-request (driver)
  (car (last (fake-requests driver))))

(defun last-request-body (driver)
  "The decoded JSON body of the most recent request."
  (json:parse (getf (last-request driver) :content)))

(defmethod http:perform-request ((driver fake-driver) url
                                 &key (method :post) headers content timeout)
  (declare (ignore timeout))
  (record-request driver url method headers content)
  (multiple-value-bind (status response-headers body) (next-canned-response driver)
    (values body status response-headers)))

(defmethod http:perform-stream-request ((driver fake-driver) url
                                        &key (method :post) headers content timeout)
  (declare (ignore timeout))
  (record-request driver url method headers content)
  (multiple-value-bind (status response-headers body) (next-canned-response driver)
    ;; Mirror dexador: on a non-2xx it has already consumed the body, so it
    ;; hands back a STRING, not a stream. Returning a stream here would let a
    ;; test pass against behaviour the real driver never produces.
    (values (if (<= 200 status 299)
                (make-string-input-stream body)
                body)
            status
            response-headers)))

(defmacro with-fake-driver ((var &rest responses) &body body)
  "Bind HTTP:*DRIVER* to a fresh fake-driver named VAR, pre-loaded with RESPONSES.
Each response is an argument list for ENQUEUE-RESPONSE."
  `(let ((,var (make-instance 'fake-driver)))
     ,@(mapcar (lambda (response) `(enqueue-response ,var ,@response)) responses)
     (let ((http:*driver* ,var))
       ,@body)))

;;; Structural guard against a forgotten WITH-FAKE-DRIVER.
;;;
;;; HTTP:*DRIVER* defaults to a live DEXADOR-DRIVER (see src/http.lisp) --
;;; that default is correct for production use, but if a later task's test
;;; forgets WITH-FAKE-DRIVER, hitting that default means a real outbound
;;; network call instead of an immediate, obvious failure. To make the
;;; "offline by default" guarantee structural rather than conventional,
;;; RUN-OFFLINE-SUITE below rebinds HTTP:*DRIVER* to a fresh NO-FAKE-DRIVER
;;; for the dynamic extent of the suite run only; WITH-FAKE-DRIVER's LET
;;; rebinding overrides it per-test as usual.
;;;
;;; This is a dynamic binding, not a load-time SETF: loading this file (or
;;; the whole cl-llm/tests system) never touches HTTP:*DRIVER*, so a REPL
;;; that loads the test system and keeps working still has the real,
;;; production DEXADOR-DRIVER bound. The guard only exists while
;;; RUN-OFFLINE-SUITE's LET is on the stack, and unwinds automatically --
;;; on pass, fail, or non-local exit -- when that call returns.

(defclass no-fake-driver (http:driver)
  ()
  (:documentation "Guards against a forgotten WITH-FAKE-DRIVER: every method
signals immediately instead of allowing a request through to a real
driver."))

(defmethod http:perform-request ((driver no-fake-driver) url
                                 &key method headers content timeout)
  (declare (ignore url method headers content timeout))
  (error "cl-llm test suite: no fake driver bound -- wrap this test in WITH-FAKE-DRIVER."))

(defmethod http:perform-stream-request ((driver no-fake-driver) url
                                        &key method headers content timeout)
  (declare (ignore url method headers content timeout))
  (error "cl-llm test suite: no fake driver bound -- wrap this test in WITH-FAKE-DRIVER."))

(defvar *production-driver* http:*driver*
  "A load-time snapshot of HTTP:*DRIVER*'s real, production default. This is
just a read, not a workaround for a mutation: RUN-OFFLINE-SUITE's guard is
a dynamic binding, so HTTP:*DRIVER* itself reads as the guard for any test
that runs inside that binding (i.e. every test run via RUN-OFFLINE-SUITE /
ASDF:TEST-SYSTEM) even though the guard is never installed permanently.
HTTP-DRIVER-PROTOCOL-EXISTS uses this snapshot, taken before any dynamic
override is in play, to confirm the genuine default is a DEXADOR-DRIVER.")

(defun run-offline-suite ()
  "Run CL-LLM-SUITE with HTTP:*DRIVER* bound to a fresh NO-FAKE-DRIVER for
the dynamic extent of the run, then return FIVEAM:RUN!'s result. Unlike a
load-time SETF, the LET here guarantees HTTP:*DRIVER* is back to its real,
production default the moment this function returns -- whether the suite
passed, failed, or a test aborted -- so callers (test-op, a REPL) never
observe the guard afterward."
  (let ((http:*driver* (make-instance 'no-fake-driver)))
    (fiveam:run! 'cl-llm-suite)))
