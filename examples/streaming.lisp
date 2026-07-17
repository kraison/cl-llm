;;;; streaming.lisp -- pull-based, thread-free streaming.
;;;;
;;;; The response object owns the live HTTP stream; you pull one event at a time
;;;; in your own thread -- no background threads, so it works everywhere,
;;;; including thread-less ECL builds. WITH-STREAMED-RESPONSE guarantees the
;;;; stream is closed on exit, normal or not.
;;;;
;;;; The tradeoff: a streamed response is single-consumer and not restartable.
;;;;
;;;; Load this file, then: (examples/streaming:run)

(ql:quickload :cl-llm)

(defpackage #:examples/streaming
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run))

(in-package #:examples/streaming)

(defun provider ()
  (make-instance 'llm:openai-compatible-provider
                 :base-url "http://localhost:11434/v1"
                 :model    "qwen2.5:7b"))

(defun run ()
  (setf llm:*provider* (provider))

  ;; 1. DO-DELTAS is the common case: run a body per text delta as it arrives.
  (format t "~&--- do-deltas (print as it streams) ---~%")
  (llm:with-streamed-response (r "Write one sentence about the sea.")
    (llm:do-deltas (delta r)
      (write-string delta)
      (force-output)))
  (terpri)

  ;; 2. NEXT-DELTA is the primitive: pull deltas by hand until it returns NIL.
  (format t "~&--- next-delta (manual pull) ---~%")
  (llm:with-streamed-response (r "List three primes, comma-separated.")
    (loop for delta = (llm:next-delta r)
          while delta
          do (write-string delta) (force-output)))
  (terpri)

  ;; 3. Nothing is lost by streaming. After (or even during) consumption,
  ;;    FINISH-RESPONSE drains the rest and returns the fully assembled
  ;;    response object -- same shape you'd get from a non-streaming ASK.
  (format t "~&--- finish-response (assembled result) ---~%")
  (llm:with-streamed-response (r "Say hello.")
    (llm:next-delta r)                       ; read just one delta...
    (let ((response (llm:finish-response r))) ; ...then assemble the whole thing
      (format t "full text: ~s~%stop: ~s~%"
              (llm:response-text response)
              (llm:response-stop-reason response))))

  (values))

;; (examples/streaming:run)
