;;;; errors-and-retries.lisp -- the condition hierarchy, timeouts, and retries.
;;;;
;;;; Everything cl-llm signals descends from CL-LLM:LLM-ERROR, so a single
;;;; handler-case can catch anything. 429 and 5xx are retried automatically with
;;;; exponential backoff (honoring Retry-After); a RETRY-REQUEST restart is
;;;; established around every request so the debugger is a useful place to land.
;;;;
;;;; Load this file, then: (examples/errors-and-retries:run)

(ql:quickload :cl-llm)

(defpackage #:examples/errors-and-retries
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run))

(in-package #:examples/errors-and-retries)

;;; The hierarchy (all subtypes of llm-error):
;;;   llm-http-error      -- transport/status failure (carries status, body, url)
;;;     llm-api-error     -- structured provider error (code, type, message)
;;;       llm-rate-limit-error -- 429 (carries retry-after)
;;;       llm-auth-error       -- 401/403, or missing credentials
;;;   llm-timeout-error   -- exceeded *timeout*
;;;   llm-parse-error     -- malformed response/SSE
;;;   llm-tool-error      -- a tool function signalled during the loop

(defun catch-all-example ()
  "One handler-case covers every cl-llm failure; specialize as needed."
  (handler-case
      (let ((llm:*provider* (make-instance 'llm:openai-compatible-provider
                                           :base-url "http://localhost:11434/v1"
                                           :model "qwen2.5:7b")))
        (llm:ask "hello"))
    (llm:llm-auth-error (e)     (format t "auth/subscription: ~a~%" e))
    (llm:llm-rate-limit-error (e) (format t "rate limited, retry after ~a s~%"
                                          (llm:llm-error-retry-after e)))
    (llm:llm-timeout-error (e)  (format t "timed out: ~a~%" e))
    (llm:llm-error (e)          (format t "llm error (~a): ~a~%" (type-of e) e))))

(defun timeout-example ()
  "A slow or unreachable host fails cleanly and on time -- never hangs.
This is offline-safe: 10.255.255.1 is non-routable, so it always times out."
  (let ((llm:*provider* (make-instance 'llm:openai-compatible-provider
                                       :base-url "http://10.255.255.1:11434/v1"
                                       :model "whatever"))
        (llm:*timeout* 3)    ; bound the wait
        (llm:*retries* 0))   ; don't retry the (doomed) connect
    (handler-case (progn (llm:ask "hi") :unexpected)
      (llm:llm-timeout-error (e)
        (format t "clean timeout after ~as: ~a~%" llm:*timeout* e)
        :timed-out))))

(defun retry-tuning-example ()
  "*retries* bounds retryable failures (429/5xx); *timeout* bounds each attempt.
Backoff is 1, 2, 4, ... seconds, capped at 60, unless the server sends Retry-After."
  (format t "current retry budget: *retries*=~a  *timeout*=~as~%"
          llm:*retries* llm:*timeout*)
  ;; Tune per-call by binding the specials around the request:
  ;;   (let ((llm:*retries* 5) (llm:*timeout* 120)) (llm:ask "..."))
  (values))

;;; The RETRY-REQUEST restart: a handler can retry a failed request from scratch.
;;; Useful when you can fix the cause (e.g. refresh a key) inside a handler-bind.
;;;
;;;   (handler-bind ((llm:llm-auth-error
;;;                    (lambda (e)
;;;                      (declare (ignore e))
;;;                      (refresh-my-api-key!)
;;;                      (invoke-restart (find-restart 'cl-llm::retry-request)))))
;;;     (llm:ask "..."))

(defun run ()
  (format t "~&--- timeout (offline, always safe) ---~%")
  (timeout-example)
  (format t "~&--- retry tuning ---~%")
  (retry-tuning-example)
  (format t "~&--- catch-all (needs a reachable provider) ---~%")
  (catch-all-example)
  (values))

;; (examples/errors-and-retries:run)
