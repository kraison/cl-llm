;;;; http.lisp -- the only file that knows about dexador.
;;;;
;;;; The driver contract is deliberately dumb: perform one request and report
;;;; what came back, including error statuses. Interpreting a status and
;;;; deciding whether to retry belongs to the layer above (retry.lisp), which
;;;; is what lets the test suite substitute a trivial fake driver here.
;;;;
;;;; This file also references USOCKET:TIMEOUT-ERROR without depending on
;;;; USOCKET directly -- the 4-dependency cap (dexador, com.inuoe.jzon,
;;;; uiop, fiveam) leaves no room for it, and it is always present anyway
;;;; because dexador depends on it unconditionally.

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

(defun normalize-response-headers (headers)
  "Normalize HEADERS into an alist of (lowercase-string . value), which is
the driver contract's documented shape for the HEADERS return value.

Dexador hands back response headers as a hash-table (:TEST 'EQUAL,
lowercase string keys already, per fast-http) rather than the alist the
contract promises and the fake driver already returns -- so the real
driver must convert before returning. Also tolerates being handed an
alist (or NIL) already, and anything else it doesn't recognize, without
erroring: this runs on every real request, so it must degrade gracefully
rather than take down a response because of a header shape it didn't
expect."
  (cond
    ((hash-table-p headers)
     (let ((alist '()))
       (maphash (lambda (key value)
                  (push (cons (string-downcase (string key)) value) alist))
                headers)
       (nreverse alist)))
    ((listp headers) headers)
    (t nil)))

(defun timeout-request-args (timeout)
  "Build the :READ-TIMEOUT/:CONNECT-TIMEOUT keyword arguments to splice
into a DEX:REQUEST call, omitting both entirely when TIMEOUT is NIL.

This is not a no-op simplification: DEX:REQUEST only applies its own
defaults (*DEFAULT-READ-TIMEOUT*/*DEFAULT-CONNECT-TIMEOUT*, both 10
seconds) when the keywords are absent from the call. Passing an explicit
NIL -- which is what TIMEOUT defaults to -- disables dexador's timeout
mechanism outright, and with this project's hard no-threads constraint an
unbounded blocking read would hang the whole process. Do not simplify
this back to always passing the keywords."
  (when timeout
    (list :read-timeout timeout :connect-timeout timeout)))

(defmacro with-translated-errors ((url) &body body)
  "Translate dexador's non-2xx conditions into return values, and both
connect-phase and read-phase timeouts into LLM-TIMEOUT-ERROR.

USOCKET:TIMEOUT-ERROR covers connect-phase timeouts (usocket wraps those
via WITH-MAPPED-CONDITIONS). It does NOT cover read-phase timeouts:
dexador enforces the read deadline via a socket option, and SBCL signals
SB-SYS:IO-TIMEOUT directly when it expires mid-response -- that condition
is not a subtype of USOCKET:TIMEOUT-ERROR, so it needs its own handler.
That handler is SBCL-specific; on other implementations (ECL, Clozure)
the #+SBCL reader conditional drops the whole clause, leaving connect-phase
translation intact and the macro still compiling cleanly."
  (let ((error-var (gensym "E")))
    `(handler-case (progn ,@body)
       (dex:http-request-failed (,error-var)
         (values (dex:response-body ,error-var)
                 (dex:response-status ,error-var)
                 (normalize-response-headers (dex:response-headers ,error-var))))
       (usocket:timeout-error (,error-var)
         (declare (ignore ,error-var))
         (error 'c:llm-timeout-error :url ,url))
       #+sbcl
       (sb-sys:io-timeout (,error-var)
         (declare (ignore ,error-var))
         (error 'c:llm-timeout-error :url ,url)))))

(defmethod perform-request ((driver dexador-driver) url
                            &key (method :post) headers content timeout)
  (with-translated-errors (url)
    (multiple-value-bind (body status response-headers)
        (apply #'dex:request url
               :method method
               :headers headers
               :content content
               :force-string t
               :keep-alive nil
               (timeout-request-args timeout))
      (values body status (normalize-response-headers response-headers)))))

(defmethod perform-stream-request ((driver dexador-driver) url
                                   &key (method :post) headers content timeout)
  (with-translated-errors (url)
    (multiple-value-bind (stream status response-headers)
        (apply #'dex:request url
               :method method
               :headers headers
               :content content
               :want-stream t
               :keep-alive nil
               (timeout-request-args timeout))
      (values stream status (normalize-response-headers response-headers)))))
