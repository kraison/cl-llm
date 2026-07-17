;;;; http.lisp -- the only file that knows about dexador.
;;;;
;;;; The driver contract is deliberately dumb: perform one request and report
;;;; what came back, including error statuses. Interpreting a status and
;;;; deciding whether to retry belongs to the layer above (retry.lisp), which
;;;; is what lets the test suite substitute a trivial fake driver here.

(in-package #:cl-llm.http)

(defclass driver ()
  ()
  (:documentation "Abstract HTTP driver. Specialize PERFORM-REQUEST and
PERFORM-STREAM-REQUEST to swap the HTTP backend."))

(defclass dexador-driver (driver)
  ()
  (:documentation "The default driver, backed by dexador."))

(defvar *driver* (make-instance 'dexador-driver)
  "The HTTP driver used for all requests. Bind to substitute a backend.")

(defgeneric perform-request (driver url &key method headers content timeout)
  (:documentation "Perform a request and return (values BODY STATUS HEADERS).
Must NOT signal on a non-2xx status -- return the status instead. Signals
LLM-TIMEOUT-ERROR on timeout."))

(defgeneric perform-stream-request (driver url &key method headers content timeout)
  (:documentation "Like PERFORM-REQUEST, but returns (values STREAM STATUS HEADERS)
where STREAM is an open character stream the caller must close."))

(defmacro with-translated-errors ((url) &body body)
  "Translate dexador's non-2xx conditions into return values, and connection
timeouts into LLM-TIMEOUT-ERROR."
  (let ((error-var (gensym "E")))
    `(handler-case (progn ,@body)
       (dex:http-request-failed (,error-var)
         (values (dex:response-body ,error-var)
                 (dex:response-status ,error-var)
                 (dex:response-headers ,error-var)))
       (usocket:timeout-error (,error-var)
         (declare (ignore ,error-var))
         (error 'c:llm-timeout-error :url ,url)))))

(defmethod perform-request ((driver dexador-driver) url
                            &key (method :post) headers content timeout)
  (with-translated-errors (url)
    (multiple-value-bind (body status response-headers)
        (dex:request url
                     :method method
                     :headers headers
                     :content content
                     :read-timeout timeout
                     :connect-timeout timeout
                     :force-string t
                     :keep-alive nil)
      (values body status response-headers))))

(defmethod perform-stream-request ((driver dexador-driver) url
                                   &key (method :post) headers content timeout)
  (with-translated-errors (url)
    (multiple-value-bind (stream status response-headers)
        (dex:request url
                     :method method
                     :headers headers
                     :content content
                     :read-timeout timeout
                     :connect-timeout timeout
                     :want-stream t
                     :keep-alive nil)
      (values stream status response-headers))))
