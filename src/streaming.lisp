;;;; streaming.lisp -- pull-based, thread-free streaming.
;;;;
;;;; The response object owns the live HTTP stream and NEXT-EVENT reads exactly
;;;; one SSE event per call, in the caller's own thread. That is what lets this
;;;; work identically on SBCL, CCL, and thread-less ECL.
;;;;
;;;; The tradeoff, which is real and documented: the stream is a resource, so a
;;;; streamed response is single-consumer and not restartable. Always scope it
;;;; with WITH-STREAMED-RESPONSE.

(in-package #:cl-llm)

(defclass streamed-response ()
  ((provider :initarg :provider :reader streamed-response-provider)
   (stream :initarg :stream :accessor streamed-response-stream)
   (open-p :initform t :accessor streamed-response-open-p)
   (text-parts :initform '() :accessor streamed-text-parts)
   (tool-parts :initform '() :accessor streamed-tool-parts)
   (tool-arguments :initform nil :accessor streamed-tool-arguments)
   (stop-reason :initform nil :accessor streamed-stop-reason)
   (usage :initform nil :accessor streamed-usage))
  (:documentation "A response being consumed incrementally from a live stream."))

(defun close-streamed-response (streamed)
  "Close the underlying stream. Idempotent."
  (when (streamed-response-open-p streamed)
    (setf (streamed-response-open-p streamed) nil)
    (ignore-errors (close (streamed-response-stream streamed))))
  streamed)

(defun merge-usage (streamed usage)
  "Merge a partial USAGE into the accumulated one; Anthropic reports input
tokens at message_start and output tokens at message_delta, so a later event
must not clobber a field the earlier one already set."
  (let ((existing (streamed-usage streamed)))
    (if existing
        (progn
          (when (usage-input-tokens usage)
            (setf (usage-input-tokens existing) (usage-input-tokens usage)))
          (when (usage-output-tokens usage)
            (setf (usage-output-tokens existing) (usage-output-tokens usage))))
        (setf (streamed-usage streamed) usage))))

(defun finalize-tool-arguments (streamed)
  "Parse the accumulated partial JSON into the most recent tool-use part.
An empty fragment set (no INPUT-JSON-DELTA events at all) parses to an empty
object rather than signalling."
  (let ((buffer (streamed-tool-arguments streamed))
        (part (first (streamed-tool-parts streamed))))
    (when (and buffer part)
      (let ((text (get-output-stream-string buffer)))
        (setf (part-arguments part)
              (if (string= text "")
                  (json:jobject)
                  (handler-case (json:parse text)
                    (error ()
                      (error 'c:llm-parse-error :payload text
                             :message "Malformed streamed tool arguments")))))))
    (setf (streamed-tool-arguments streamed) nil)))

(defun accumulate-event (streamed kind value &optional extra-usage)
  "Fold one parsed event into the response being assembled. EXTRA-USAGE
carries a USAGE riding alongside a non-:USAGE kind -- Anthropic's
message_delta event reports output-token usage as a sibling of the
stop_reason it delivers, in the same SSE event, so PARSE-STREAM-EVENT hands
it back as a third value rather than forcing two separate events out of one."
  (case kind
    (:text (push value (streamed-text-parts streamed)))
    (:tool-use-start
     ;; Flush any arguments accumulated for the previous tool block.
     (finalize-tool-arguments streamed)
     (push value (streamed-tool-parts streamed))
     (setf (streamed-tool-arguments streamed) (make-string-output-stream)))
    (:tool-arguments
     (when (streamed-tool-arguments streamed)
       (write-string value (streamed-tool-arguments streamed))))
    (:stop-reason (when value (setf (streamed-stop-reason streamed) value)))
    (:usage (when value (merge-usage streamed value))))
  (when extra-usage (merge-usage streamed extra-usage))
  streamed)

(defun next-event (streamed)
  "Read and interpret the next event. Returns (values KIND VALUE), or
(values NIL NIL) once the stream is exhausted."
  (if (not (streamed-response-open-p streamed))
      (values nil nil)
      (let ((event (sse:read-event (streamed-response-stream streamed))))
        (if (null event)
            (progn (close-streamed-response streamed) (values nil nil))
            (multiple-value-bind (kind value extra-usage)
                (parse-stream-event (streamed-response-provider streamed) event)
              (case kind
                (:done (close-streamed-response streamed) (values nil nil))
                (t (accumulate-event streamed kind value extra-usage)
                   (values kind value))))))))

(defun next-delta (streamed)
  "The next text delta, or NIL when the stream is done.
Non-text events are consumed and folded into the assembled response."
  (loop
    (multiple-value-bind (kind value) (next-event streamed)
      (cond
        ((null kind) (return nil))
        ((eq kind :text) (return value))))))

(defun drain (streamed)
  "Consume the remainder of the stream, accumulating everything."
  (loop while (next-event streamed))
  streamed)

(defun finish-response (streamed)
  "The fully assembled RESPONSE. Drains any unread events first, so a
partial NEXT-DELTA read still yields the complete response."
  (drain streamed)
  (finalize-tool-arguments streamed)
  (make-instance 'response
                 :content (append
                           (when (streamed-text-parts streamed)
                             (list (make-text-part
                                    (apply #'concatenate 'string
                                           (reverse (streamed-text-parts streamed))))))
                           (reverse (streamed-tool-parts streamed)))
                 :stop-reason (streamed-stop-reason streamed)
                 :usage (streamed-usage streamed)))

(defun open-streamed-response (prompt &key (provider *provider*)
                                           (model *model*)
                                           (temperature *temperature*)
                                           (max-tokens *max-tokens*)
                                           (top-p *top-p*)
                                           (stop *stop*)
                                           (system *system*)
                                           tools
                                           conversation)
  "Start a streaming request and return an open STREAMED-RESPONSE.
The caller MUST close it; prefer WITH-STREAMED-RESPONSE."
  (let* ((conversation
           (or conversation
               (make-conversation
                :provider provider :model model :system system
                :messages (list (make-message :user prompt))
                :parameters (collect-parameters :temperature temperature
                                                :max-tokens max-tokens
                                                :top-p top-p :stop stop))))
         (provider (or (conversation-provider conversation) provider))
         (stream (stream-request provider conversation
                                 :tools (resolve-tools tools))))
    (make-instance 'streamed-response :provider provider :stream stream)))

(defmacro with-streamed-response ((var prompt &rest arguments) &body body)
  "Open a streamed response for PROMPT, bind it to VAR, and guarantee the
underlying stream is closed on exit, normal or otherwise."
  `(let ((,var (open-streamed-response ,prompt ,@arguments)))
     (unwind-protect (progn ,@body)
       (close-streamed-response ,var))))

(defmacro do-deltas ((var streamed) &body body)
  "Execute BODY with VAR bound to each successive text delta of STREAMED.
BODY may start with a DECLARE, as in DOLIST/DOTIMES, which is why this uses
LOCALLY rather than PROGN to wrap it."
  (let ((streamed-var (gensym "STREAMED")))
    `(let ((,streamed-var ,streamed))
       (loop for ,var = (next-delta ,streamed-var)
             while ,var
             do (locally ,@body)))))
