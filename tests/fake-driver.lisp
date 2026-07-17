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
;;; "offline by default" guarantee structural rather than conventional, the
;;; test system below rebinds HTTP:*DRIVER* to NO-FAKE-DRIVER for the whole
;;; suite; WITH-FAKE-DRIVER's LET rebinding overrides it per-test as usual.

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
  "HTTP:*DRIVER*'s real, production default -- captured here before the
suite-wide override below replaces it, so tests can still confirm the
genuine default is a DEXADOR-DRIVER.")

(setf http:*driver* (make-instance 'no-fake-driver))
