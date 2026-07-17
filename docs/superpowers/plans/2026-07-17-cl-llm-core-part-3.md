# cl-llm Core Client Implementation Plan — Part 3 (Tasks 10–15)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Continuation of:** `2026-07-17-cl-llm-core.md` (Tasks 1–4) and `2026-07-17-cl-llm-core-part-2.md` (Tasks 5–9).
**Global Constraints and verified library facts:** see Part 1. They apply to every task here.

---

### Task 10: Facade — `ask`, `send`, and the special variables

**Files:**
- Create: `src/facade.lisp`
- Modify: `cl-llm.asd` (add `(:file "facade")` after the `providers` module), `src/packages.lisp`
- Test: `tests/facade.lisp`

**Interfaces:**
- Consumes: `chat-request` (Task 9), `make-conversation`/`add-message`/`response-message` (Task 7).
- Produces (exported from `cl-llm`):
  - specials `*provider*` (an `anthropic-provider` instance), `*model*` (nil), `*temperature*` (nil), `*system*` (nil), `*tools*` (nil)
  - `(ask prompt &key provider model temperature max-tokens system tools top-p stop max-tool-turns)` → `(values text response)`
  - `(send conversation content &key tools)` → `response`; appends the user message and the assistant reply to the conversation

`*max-tokens*` (Task 9), `*retries*` and `*timeout*` (Task 6) already exist.

- [ ] **Step 1: Write the failing tests**

Create `tests/facade.lisp`:

```lisp
;;;; tests/facade.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defmacro with-test-provider (&body body)
  "Bind *provider* to an Anthropic provider with a fixed key."
  `(let ((llm:*provider* (make-instance 'llm:anthropic-provider :api-key "sk-test")))
     ,@body))

(test facade-defaults
  (is (typep llm:*provider* 'llm:anthropic-provider)
      "*provider* must default to an anthropic-provider")
  (is (null llm:*model*) "*model* defaults to NIL so the provider decides")
  (is (= 4096 llm:*max-tokens*))
  (is (= 8 llm:*max-tool-turns*)))

(test ask-returns-text-and-response
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (multiple-value-bind (text response) (llm:ask "hi")
        (is (string= "Hello" text))
        (is (typep response 'llm:response))
        (is (string= "Hello" (llm:response-text response)))))))

(test ask-sends-the-prompt-as-a-user-message
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (llm:ask "what is CLOS?")
      (let ((body (last-request-body d)))
        (is (string= "user" (json:jget body "messages" 0 "role")))
        (is (string= "what is CLOS?" (json:jget body "messages" 0 "content" 0 "text")))))))

(test ask-honors-keyword-arguments
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (llm:ask "hi" :temperature 0.2 :system "be terse" :max-tokens 50)
      (let ((body (last-request-body d)))
        (is (= 0.2d0 (json:jget body "temperature")))
        (is (string= "be terse" (json:jget body "system")))
        (is (= 50 (json:jget body "max_tokens")))))))

(test ask-honors-special-variables
  "The specials and the keywords must be the same API, not two parallel ones."
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((llm:*model* "claude-haiku-4-5-20251001")
            (llm:*temperature* 0.9))
        (llm:ask "hi"))
      (let ((body (last-request-body d)))
        (is (string= "claude-haiku-4-5-20251001" (json:jget body "model")))
        (is (= 0.9d0 (json:jget body "temperature")))))))

(test ask-keyword-overrides-special
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((llm:*temperature* 0.9))
        (llm:ask "hi" :temperature 0.1))
      (is (= 0.1d0 (json:jget (last-request-body d) "temperature"))))))

(test send-appends-both-messages-to-the-conversation
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((c (llm:make-conversation :system "be terse")))
        (llm:send c "hi")
        (is (= 2 (length (llm:conversation-messages c))))
        (is (eq :user (llm:message-role (first (llm:conversation-messages c)))))
        (is (eq :assistant (llm:message-role (second (llm:conversation-messages c)))))
        (is (string= "Hello"
                     (llm:part-text (first (llm:message-content
                                            (second (llm:conversation-messages c)))))))))))

(test send-accumulates-history-across-turns
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture))
                       (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (let ((c (llm:make-conversation)))
        (llm:send c "one")
        (llm:send c "two")
        (is (= 4 (length (llm:conversation-messages c))))
        (let ((body (last-request-body d)))
          (is (= 3 (length (json:jget body "messages")))
              "The second request must carry the prior turns")
          (is (string= "one" (json:jget body "messages" 0 "content" 0 "text")))
          (is (string= "two" (json:jget body "messages" 2 "content" 0 "text"))))))))

(test send-uses-the-conversation-provider-when-set
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (let* ((p (make-instance 'llm:anthropic-provider
                             :api-key "sk-conv" :base-url "http://conv.example"))
           (c (llm:make-conversation :provider p)))
      (llm:send c "hi")
      (is (string= "http://conv.example/v1/messages" (getf (last-request d) :url))))))

(test ask-propagates-errors
  (with-fake-driver (d (:status 401 :body "{\"error\":{\"message\":\"nope\"}}"))
    (with-test-provider
      (signals c:llm-auth-error (llm:ask "hi")))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `llm:ask` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/facade.lisp`:

```lisp
;;;; facade.lisp -- the REPL-first surface.
;;;;
;;;; Every special variable mirrors a keyword argument of the same name, so the
;;;; one-liner and the fully-specified call are the same API.

(in-package #:cl-llm)

(defvar *provider* (make-instance 'anthropic-provider)
  "The provider used when none is given. The API key is resolved per-request,
so constructing this at load time does not require the environment to be set.")

(defvar *model* nil
  "Model override. NIL means PROVIDER-DEFAULT-MODEL decides, which keeps the
default model a property of the provider rather than a global constant.")

(defvar *temperature* nil)
(defvar *top-p* nil)
(defvar *stop* nil)
(defvar *system* nil)
(defvar *tools* nil)

(defun collect-parameters (&key temperature max-tokens top-p stop)
  "Build the conversation parameter plist, omitting unset values."
  (let ((parameters '()))
    (when stop (setf (getf parameters :stop) stop))
    (when top-p (setf (getf parameters :top-p) top-p))
    (when max-tokens (setf (getf parameters :max-tokens) max-tokens))
    (when temperature (setf (getf parameters :temperature) temperature))
    parameters))

(defun resolve-tools (tools)
  "Normalize TOOLS -- a list of symbols, names, or TOOL objects -- to TOOLs."
  (mapcar #'find-tool tools))

(defun send (conversation content &key (tools *tools*)
                                       (max-tool-turns *max-tool-turns*))
  "Send CONTENT as a user turn in CONVERSATION and return the assistant RESPONSE.
Both the user message and the assistant reply are appended to CONVERSATION.
When TOOLS is non-nil the tool loop runs to completion before returning."
  (let ((provider (or (conversation-provider conversation) *provider*))
        (resolved (resolve-tools tools)))
    (add-message conversation (make-message :user content))
    (if resolved
        (run-tool-loop provider conversation resolved max-tool-turns)
        (let ((response (chat-request provider conversation)))
          (add-message conversation (response-message response))
          response))))

(defun ask (prompt &key (provider *provider*)
                        (model *model*)
                        (temperature *temperature*)
                        (max-tokens *max-tokens*)
                        (top-p *top-p*)
                        (stop *stop*)
                        (system *system*)
                        (tools *tools*)
                        (max-tool-turns *max-tool-turns*))
  "Ask PROMPT and return (values TEXT RESPONSE).
The single-shot entry point: it builds a throwaway conversation. Use
MAKE-CONVERSATION and SEND to keep history across turns."
  (let ((conversation (make-conversation
                       :provider provider
                       :model model
                       :system system
                       :parameters (collect-parameters :temperature temperature
                                                       :max-tokens max-tokens
                                                       :top-p top-p
                                                       :stop stop))))
    (let ((response (send conversation prompt :tools tools
                                              :max-tool-turns max-tool-turns)))
      (values (response-text response) response))))
```

- [ ] **Step 4: Export the new symbols**

In `src/packages.lisp`, add to the `cl-llm` `:export` list:

```lisp
   #:ask #:send
   #:*provider* #:*model* #:*temperature* #:*top-p* #:*stop*
   #:*system* #:*tools*
```

- [ ] **Step 5: Add the files to the ASDF systems**

`cl-llm` src gains `(:file "facade")` after the `providers` module.

**Execution order:** Task 12 (`tools.lisp`) is implemented BEFORE this task, so
`find-tool` genuinely exists here — no stub is needed or wanted.

`facade.lisp` forward-references `run-tool-loop`, which arrives in Task 13. That
is ordinary in Common Lisp: compiling `facade.lisp` emits an undefined-function
style warning that resolves when `tool-loop.lisp` loads. Nothing calls
`run-tool-loop` until `:tools` is passed, and no test in this task passes
`:tools`, so the suite is green regardless.

Add this defvar near the top of `src/facade.lisp` — it is a facade tunable and
lives here permanently, not in `tool-loop.lisp`:

```lisp
(defvar *max-tool-turns* 8
  "Maximum model/tool round trips in one SEND before signalling LLM-TOOL-ERROR.
The bound is not a nicety: without it a model that keeps requesting tools loops
forever, burning tokens.")
```

Also add `#:*max-tool-turns*` to the `cl-llm` `:export` list.
`cl-llm/tests` gains `(:file "facade")` at the end.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 10 facade tests green.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/facade.lisp tests/facade.lisp
git commit -m "feat: ask/send facade with special variables"
```

---

### Task 11: Streaming — `streamed-response`, `next-delta`, `with-streamed-response`

**Files:**
- Create: `src/streaming.lisp`
- Modify: `cl-llm.asd` (add `(:file "streaming")` after `facade`), `src/packages.lisp`, `src/providers/anthropic.lisp` (add `parse-stream-event` and `stream-request` methods)
- Test: `tests/streaming.lisp`

**Interfaces:**
- Consumes: `sse:read-event` (Task 4), `request-with-retry` with `:stream t` (Task 6), `parse-stream-event` GF (Task 8).
- Produces (exported from `cl-llm`):
  - class `streamed-response` (`streamed-response-open-p`)
  - `(next-event streamed-response)` → `(values kind value)`, `(values nil nil)` at end
  - `(next-delta streamed-response)` → next text delta string, or `nil` when the stream is done
  - `(finish-response streamed-response)` → the assembled `response`
  - `(close-streamed-response streamed-response)`
  - macro `(with-streamed-response (var prompt &rest args) &body body)`
  - macro `(do-deltas (var streamed-response) &body body)`
  - Anthropic methods on `parse-stream-event` and `stream-request`

**Anthropic SSE event shapes:**
```
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

event: message_stop
data: {"type":"message_stop"}
```

- [ ] **Step 1: Write the failing tests**

Create `tests/streaming.lisp`:

```lisp
;;;; tests/streaming.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun anthropic-stream-fixture ()
  (format nil
          "event: message_start~%data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":10}}}~%~%~
           event: content_block_start~%data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}~%~%~
           event: content_block_delta~%data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}~%~%~
           event: content_block_delta~%data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}~%~%~
           event: content_block_stop~%data: {\"type\":\"content_block_stop\",\"index\":0}~%~%~
           event: message_delta~%data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}~%~%~
           event: message_stop~%data: {\"type\":\"message_stop\"}~%~%"))

(test streaming-next-delta-yields-text-in-order
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (llm:with-streamed-response (r "hi")
        (is (string= "Hel" (llm:next-delta r)))
        (is (string= "lo" (llm:next-delta r)))
        (is (null (llm:next-delta r)) "NIL signals the end of the stream")))))

(test streaming-do-deltas-collects-everything
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (let ((collected '()))
        (llm:with-streamed-response (r "hi")
          (llm:do-deltas (delta r) (push delta collected)))
        (is (string= "Hello" (apply #'concatenate 'string (nreverse collected))))))))

(test streaming-request-sets-the-stream-flag
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (llm:with-streamed-response (r "hi")
        (llm:do-deltas (delta r) (declare (ignore delta))))
      (is (eq t (json:jget (last-request-body d) "stream"))))))

(test streaming-finish-response-assembles-a-full-response
  "Nothing is lost by streaming: the assembled response must match a normal one."
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (llm:with-streamed-response (r "hi")
        (llm:do-deltas (delta r) (declare (ignore delta)))
        (let ((response (llm:finish-response r)))
          (is (string= "Hello" (llm:response-text response)))
          (is (eq :end-turn (llm:response-stop-reason response)))
          (is (= 3 (llm:usage-output-tokens (llm:response-usage response)))))))))

(test streaming-closes-the-stream-on-normal-exit
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (let ((saved nil))
        (llm:with-streamed-response (r "hi")
          (setf saved r)
          (llm:next-delta r))
        (is (not (llm:streamed-response-open-p saved))
            "with-streamed-response must close the stream")))))

(test streaming-closes-the-stream-on-nonlocal-exit
  "The unwind-protect must fire even when the body throws."
  (with-fake-driver (d (:status 200 :body (anthropic-stream-fixture)))
    (with-test-provider
      (let ((saved nil))
        (ignore-errors
         (llm:with-streamed-response (r "hi")
           (setf saved r)
           (error "boom")))
        (is (not (llm:streamed-response-open-p saved)))))))

(test streaming-signals-api-error-before-reading
  (with-fake-driver (d (:status 429 :body "{\"error\":{\"message\":\"slow\"}}"))
    (with-test-provider
      (without-sleeping (ds)
        (let ((llm:*retries* 0))
          (signals c:llm-rate-limit-error
            (llm:with-streamed-response (r "hi")
              (llm:next-delta r))))))))

(test anthropic-parse-stream-event-text-delta
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event
                "content_block_delta"
                "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")))
    (multiple-value-bind (kind value) (llm:parse-stream-event p event)
      (is (eq :text kind))
      (is (string= "x" value)))))

(test anthropic-parse-stream-event-ping-is-ignored
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event "ping" "{\"type\":\"ping\"}")))
    (is (eq :ignore (llm:parse-stream-event p event)))))

(test anthropic-parse-stream-event-message-stop-is-done
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event "message_stop" "{\"type\":\"message_stop\"}")))
    (is (eq :done (llm:parse-stream-event p event)))))

(test anthropic-parse-stream-event-error-signals
  "An error event mid-stream must surface as a condition, not silence."
  (let ((p (test-anthropic-provider))
        (event (sse:make-sse-event
                "error"
                "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}")))
    (signals c:llm-api-error (llm:parse-stream-event p event))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `llm:with-streamed-response` is undefined.

- [ ] **Step 3: Write the Anthropic streaming methods**

Append to `src/providers/anthropic.lisp`:

```lisp
;;; Streaming

(defmethod parse-stream-event ((provider anthropic-provider) event)
  (let* ((data (sse:sse-event-data event))
         (payload (handler-case (json:parse data)
                    (error ()
                      (error 'c:llm-parse-error :payload data
                             :message "Malformed SSE data from Anthropic"))))
         (type (json:jget payload "type")))
    (cond
      ((equal type "content_block_delta")
       (let ((delta-type (json:jget payload "delta" "type")))
         (cond
           ((equal delta-type "text_delta")
            (values :text (json:jget payload "delta" "text")))
           ((equal delta-type "input_json_delta")
            (values :tool-arguments (json:jget payload "delta" "partial_json")))
           (t (values :ignore nil)))))
      ((equal type "content_block_start")
       (let ((block (json:jget payload "content_block")))
         (if (equal (json:jget block "type") "tool_use")
             (values :tool-use-start
                     (make-tool-use-part (json:jget block "id")
                                         (json:jget block "name")
                                         nil))
             (values :ignore nil))))
      ((equal type "message_start")
       (values :usage (decode-usage (json:jget payload "message"))))
      ((equal type "message_delta")
       (values :stop-reason
               (anthropic-stop-reason (json:jget payload "delta" "stop_reason"))))
      ((equal type "message_stop") (values :done nil))
      ((equal type "error")
       (error 'c:llm-api-error
              :message (json:jget payload "error" "message")
              :error-type (json:jget payload "error" "type")))
      (t (values :ignore nil)))))

(defmethod stream-request ((provider anthropic-provider) conversation &key tools)
  (request-with-retry (provider-endpoint provider)
                      :method :post
                      :headers (provider-headers provider)
                      :content (encode-request provider conversation
                                               :stream t :tools tools)
                      :stream t))
```

- [ ] **Step 4: Write the streaming implementation**

Create `src/streaming.lisp`:

```lisp
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

(defun accumulate-event (streamed kind value)
  "Fold one parsed event into the response being assembled."
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
  streamed)

(defun merge-usage (streamed usage)
  "Merge a partial USAGE into the accumulated one; Anthropic reports input
tokens at message_start and output tokens at message_delta."
  (let ((existing (streamed-usage streamed)))
    (if existing
        (progn
          (when (usage-input-tokens usage)
            (setf (usage-input-tokens existing) (usage-input-tokens usage)))
          (when (usage-output-tokens usage)
            (setf (usage-output-tokens existing) (usage-output-tokens usage))))
        (setf (streamed-usage streamed) usage))))

(defun finalize-tool-arguments (streamed)
  "Parse the accumulated partial JSON into the most recent tool-use part."
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

(defun next-event (streamed)
  "Read and interpret the next event. Returns (values KIND VALUE), or
(values NIL NIL) once the stream is exhausted."
  (if (not (streamed-response-open-p streamed))
      (values nil nil)
      (let ((event (sse:read-event (streamed-response-stream streamed))))
        (if (null event)
            (progn (close-streamed-response streamed) (values nil nil))
            (multiple-value-bind (kind value)
                (parse-stream-event (streamed-response-provider streamed) event)
              (case kind
                (:done (close-streamed-response streamed) (values nil nil))
                (t (accumulate-event streamed kind value)
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
  "The fully assembled RESPONSE. Drains any unread events first."
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
  "Execute BODY with VAR bound to each successive text delta of STREAMED."
  (let ((streamed-var (gensym "STREAMED")))
    `(let ((,streamed-var ,streamed))
       (loop for ,var = (next-delta ,streamed-var)
             while ,var
             do (progn ,@body)))))
```

- [ ] **Step 5: Export the new symbols and update the ASDF systems**

Add to the `cl-llm` `:export` list:

```lisp
   #:streamed-response #:streamed-response-open-p
   #:open-streamed-response #:close-streamed-response
   #:next-event #:next-delta #:finish-response
   #:with-streamed-response #:do-deltas
```

`cl-llm` src gains `(:file "streaming")` after `facade`.
`cl-llm/tests` gains `(:file "streaming")` at the end.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 11 streaming tests green.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/streaming.lisp \
        src/providers/anthropic.lisp tests/streaming.lisp
git commit -m "feat: thread-free pull-based streaming"
```

---

### Task 12: `deftool` and typed lambda-list schema derivation

**Files:**
- Create: `src/tools.lisp`
- Modify: `cl-llm.asd` (add `(:file "tools")` after `core`, **before** `protocol`), `src/packages.lisp`, `src/providers/anthropic.lisp` (add `encode-tool`)
- Test: `tests/tools.lisp`

**Interfaces:**
- Consumes: `json:jobject`/`jarray` (Task 2), conditions (Task 3).
- Produces (exported from `cl-llm`):
  - class `tool` (`tool-name`, `tool-description`, `tool-schema`, `tool-function`)
  - macro `(deftool name (&rest parameters) docstring &body body)`
  - `(find-tool designator)` → `tool`; accepts a `tool`, a symbol, or a string name; signals `llm-tool-error` if unknown
  - `(register-tool tool)`, `(unregister-tool name)`, `*tools-registry*`
  - `(derive-schema parameters)` → JSON schema hash-table
  - `(encode-tool provider tool)` → provider-specific tool JSON

**Parameter specification (from the spec, §7):**

| Form                                | Schema                        |
|-------------------------------------|-------------------------------|
| `city`                              | required string               |
| `(units :celsius :fahrenheit)`      | required enum                 |
| `(depth :type integer)`             | required integer              |
| `(limit :type integer :default 10)` | optional integer, default 10  |
| `(ids :type (list string))`         | required array of strings     |
| `(note :type string :optional t)`   | optional string               |

`:type` accepts `string`, `integer`, `number`, `boolean`, `(list <type>)`.
`:default` implies optional. `&optional` and `&key` markers make subsequent
parameters non-required.

**Disambiguation rule:** a list whose second element is a keyword other than
`:type`, `:default`, or `:optional` is an **enum**; otherwise it is a spec list.
So `(units :celsius :fahrenheit)` is an enum and `(depth :type integer)` is not.

- [ ] **Step 1: Write the failing tests**

Create `tests/tools.lisp`:

```lisp
;;;; tests/tools.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defmacro with-clean-registry (&body body)
  `(let ((cl-llm::*tools-registry* (make-hash-table :test 'equal)))
     ,@body))

(test deftool-defines-a-callable-lisp-function
  "deftool must expand to a plain defun -- nothing hidden."
  (with-clean-registry
    (eval '(llm:deftool tool-add ((a :type integer) (b :type integer))
            "Add two numbers."
            (+ a b)))
    (is (= 3 (funcall 'tool-add 1 2)))))

(test deftool-registers-the-tool
  (with-clean-registry
    (eval '(llm:deftool tool-noop () "Does nothing." nil))
    (let ((tool (llm:find-tool 'tool-noop)))
      (is (typep tool 'llm:tool))
      (is (string= "tool-noop" (llm:tool-name tool)))
      (is (string= "Does nothing." (llm:tool-description tool))))))

(test find-tool-accepts-symbol-string-and-object
  (with-clean-registry
    (eval '(llm:deftool tool-noop () "Does nothing." nil))
    (let ((tool (llm:find-tool 'tool-noop)))
      (is (eq tool (llm:find-tool "tool-noop")))
      (is (eq tool (llm:find-tool tool))))))

(test find-tool-signals-on-unknown-tool
  (with-clean-registry
    (signals c:llm-tool-error (llm:find-tool 'no-such-tool))))

(test schema-bare-symbol-is-required-string
  (let ((schema (cl-llm::derive-schema '(city))))
    (is (string= "object" (json:jget schema "type")))
    (is (string= "string" (json:jget schema "properties" "city" "type")))
    (is (equalp #("city") (json:jget schema "required")))))

(test schema-enum-parameter
  (let ((schema (cl-llm::derive-schema '((units :celsius :fahrenheit)))))
    (is (equalp #("celsius" "fahrenheit")
                (json:jget schema "properties" "units" "enum")))
    (is (string= "string" (json:jget schema "properties" "units" "type")))
    (is (equalp #("units") (json:jget schema "required")))))

(test schema-typed-parameter
  (let ((schema (cl-llm::derive-schema '((depth :type integer)))))
    (is (string= "integer" (json:jget schema "properties" "depth" "type")))
    (is (equalp #("depth") (json:jget schema "required")))))

(test schema-default-implies-optional
  (let ((schema (cl-llm::derive-schema '((limit :type integer :default 10)))))
    (is (string= "integer" (json:jget schema "properties" "limit" "type")))
    (is (= 10 (json:jget schema "properties" "limit" "default")))
    (is (equalp #() (json:jget schema "required"))
        ":default must imply optional")))

(test schema-explicit-optional
  (let ((schema (cl-llm::derive-schema '((note :type string :optional t)))))
    (is (equalp #() (json:jget schema "required")))))

(test schema-list-type
  (let ((schema (cl-llm::derive-schema '((ids :type (list string))))))
    (is (string= "array" (json:jget schema "properties" "ids" "type")))
    (is (string= "string" (json:jget schema "properties" "ids" "items" "type")))))

(test schema-boolean-and-number-types
  (let ((schema (cl-llm::derive-schema '((flag :type boolean) (score :type number)))))
    (is (string= "boolean" (json:jget schema "properties" "flag" "type")))
    (is (string= "number" (json:jget schema "properties" "score" "type")))))

(test schema-optional-marker-makes-rest-non-required
  (let ((schema (cl-llm::derive-schema '(city &optional (depth :type integer)))))
    (is (equalp #("city") (json:jget schema "required")))
    (is (string= "integer" (json:jget schema "properties" "depth" "type")))))

(test schema-rejects-unknown-type
  (signals error (cl-llm::derive-schema '((x :type frobnicate)))))

(test schema-mixed-parameters
  (let ((schema (cl-llm::derive-schema '(city (units :celsius :fahrenheit)
                                         (limit :type integer :default 10)))))
    (is (equalp #("city" "units") (json:jget schema "required")))
    (is (= 3 (hash-table-count (json:jget schema "properties"))))))

(test anthropic-encode-tool
  (with-clean-registry
    (eval '(llm:deftool tool-weather (city) "Look up weather." city))
    (let* ((p (test-anthropic-provider))
           (encoded (json:parse (json:to-json
                                 (llm:encode-tool p (llm:find-tool 'tool-weather))))))
      (is (string= "tool-weather" (json:jget encoded "name")))
      (is (string= "Look up weather." (json:jget encoded "description")))
      (is (string= "string" (json:jget encoded "input_schema" "properties" "city" "type"))))))

(test anthropic-encode-request-includes-tools
  (with-clean-registry
    (eval '(llm:deftool tool-weather (city) "Look up weather." city))
    (let* ((p (test-anthropic-provider))
           (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
           (body (json:parse (llm:encode-request p c
                                                 :tools (list (llm:find-tool 'tool-weather))))))
      (is (string= "tool-weather" (json:jget body "tools" 0 "name"))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `llm:deftool` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/tools.lisp`:

```lisp
;;;; tools.lisp -- deftool and JSON schema derivation.
;;;;
;;;; A tool is an ordinary Lisp function: deftool expands to a plain DEFUN plus
;;;; a registration form, and the tool loop calls it in-process. Tool bodies
;;;; therefore close over whatever a normal function closes over -- live
;;;; database handles, open transactions, special bindings.
;;;;
;;;; SECURITY: the MODEL chooses the arguments. A narrow tool is bounded by its
;;;; schema; a general escape hatch such as (deftool run-query (sql) ...) is
;;;; not, and grants the model arbitrary execution. Prefer narrow tools, and
;;;; treat every argument as untrusted input.

(in-package #:cl-llm)

(defclass tool ()
  ((name :initarg :name :reader tool-name :type string)
   (description :initarg :description :reader tool-description :type string)
   (schema :initarg :schema :reader tool-schema
           :documentation "A JSON Schema object describing the parameters.")
   (function :initarg :function :reader tool-function))
  (:documentation "A Lisp function the model may call, plus its schema."))

(defvar *tools-registry* (make-hash-table :test 'equal)
  "Maps tool name (string) to TOOL.")

(defun register-tool (tool)
  (setf (gethash (tool-name tool) *tools-registry*) tool))

(defun unregister-tool (name)
  (remhash (string-downcase (string name)) *tools-registry*))

(defun find-tool (designator)
  "Resolve DESIGNATOR -- a TOOL, a symbol, or a string -- to a TOOL."
  (etypecase designator
    (tool designator)
    ((or symbol string)
     (let ((name (string-downcase (string designator))))
       (or (gethash name *tools-registry*)
           (error 'c:llm-tool-error
                  :tool-name name
                  :underlying "No such tool is registered. Define it with deftool."))))))

;;; Schema derivation

(defun json-type-name (type)
  "Map a cl-llm parameter type to a JSON Schema type name."
  (case type
    (string "string")
    (integer "integer")
    (number "number")
    (boolean "boolean")
    (t (error "Unsupported tool parameter type ~s. Use string, integer, ~
               number, boolean, or (list <type>)." type))))

(defun type-schema (type)
  "The JSON Schema fragment for TYPE."
  (if (and (consp type) (eq (first type) 'list))
      (json:jobject :type "array"
                    :items (json:jobject :type (json-type-name (second type))))
      (json:jobject :type (json-type-name type))))

(defun enum-spec-p (spec)
  "True when SPEC is an enum, e.g. (units :celsius :fahrenheit).
A spec list is distinguished by its second element being :type, :default, or
:optional; anything else keyword-ish is an enum member."
  (and (consp spec)
       (cdr spec)
       (not (member (second spec) '(:type :default :optional)))))

(defun parameter-schema (spec)
  "Return (values NAME SCHEMA REQUIRED-P) for one parameter SPEC."
  (cond
    ;; Bare symbol: required string.
    ((symbolp spec)
     (values (string-downcase (string spec)) (json:jobject :type "string") t))
    ;; Enum: (units :celsius :fahrenheit)
    ((enum-spec-p spec)
     (values (string-downcase (string (first spec)))
             (json:jobject :type "string"
                           :enum (map 'vector
                                      (lambda (v) (string-downcase (string v)))
                                      (rest spec)))
             t))
    ;; Spec list: (depth :type integer :default 1 :optional t)
    ((consp spec)
     (destructuring-bind (name &key (type 'string) (default nil default-p)
                                    (optional nil))
         spec
       (let ((schema (type-schema type)))
         (when default-p
           (setf (gethash "default" schema) default))
         (values (string-downcase (string name))
                 schema
                 (not (or optional default-p))))))
    (t (error "Malformed tool parameter specification: ~s" spec))))

(defun derive-schema (parameters)
  "Derive a JSON Schema object from a deftool lambda list."
  (let ((properties (make-hash-table :test 'equal))
        (required '())
        (all-optional nil))
    (dolist (spec parameters)
      (cond
        ((eq spec '&optional) (setf all-optional t))
        ((member spec '(&key &rest))
         (error "~s is not supported in a deftool lambda list. Tools are called ~
                 positionally from a decoded JSON object; use :optional or ~
                 :default to make a parameter optional." spec))
        (t
         (multiple-value-bind (name schema requiredp) (parameter-schema spec)
           (setf (gethash name properties) schema)
           (when (and requiredp (not all-optional))
             (push name required))))))
    (json:jobject :type "object"
                  :properties properties
                  :required (coerce (nreverse required) 'vector))))

;;; deftool

(defun parameter-lambda-variable (spec)
  "The Lisp variable name for one parameter SPEC."
  (if (symbolp spec) spec (first spec)))

(defun optional-spec-p (spec)
  "True when SPEC declares :default or :optional, and so cannot be a required
positional parameter."
  (and (consp spec)
       (not (enum-spec-p spec))
       (destructuring-bind (name &key type (default nil default-p) optional)
           spec
         (declare (ignore name type))
         (or default-p optional (and default t)))))

(defun parameter-lambda-list (parameters)
  "Convert a deftool lambda list into an ordinary Lisp lambda list.
An &OPTIONAL marker is inserted automatically before the first optional
parameter, because (defun f (a (b 10))) is a syntax error -- a default is only
legal after &optional."
  (let ((result '())
        (in-optional nil))
    (dolist (spec parameters (nreverse result))
      (cond
        ((eq spec '&optional)
         (unless in-optional (setf in-optional t) (push '&optional result)))
        ((member spec '(&key &rest))
         (error "~s is not supported in a deftool lambda list; use :optional or ~
                 :default instead." spec))
        (t
         (let ((variable (parameter-lambda-variable spec)))
           (cond
             ((optional-spec-p spec)
              (unless in-optional (setf in-optional t) (push '&optional result))
              (let ((default (getf (rest spec) :default)))
                (push (if default (list variable default) variable) result)))
             (in-optional (push variable result))
             (t (push variable result)))))))))

(defmacro deftool (name parameters docstring &body body)
  "Define NAME as an ordinary function AND register it as a tool the model may
call. The JSON schema is derived from PARAMETERS and DOCSTRING.

PARAMETERS entries are one of:
  city                          -- required string
  (units :celsius :fahrenheit)  -- required enum
  (depth :type integer)         -- required integer
  (limit :type integer :default 10) -- optional, defaulted
  (ids :type (list string))     -- required array of strings
  (note :type string :optional t)   -- optional

Types: string, integer, number, boolean, (list <type>).

The expansion is a plain DEFUN plus a REGISTER-TOOL call -- nothing is hidden,
and the function remains callable directly from Lisp."
  (check-type docstring string "a docstring: the model relies on it to decide
when to call this tool")
  (let ((lambda-list (parameter-lambda-list parameters)))
    `(progn
       (defun ,name ,lambda-list
         ,docstring
         ,@body)
       (register-tool
        (make-instance 'tool
                       :name ,(string-downcase (string name))
                       :description ,docstring
                       :schema (derive-schema ',parameters)
                       :function #',name))
       ',name)))

;;; Calling

(defun call-tool (tool arguments)
  "Invoke TOOL with ARGUMENTS, a hash-table of decoded JSON arguments.
Signals LLM-TOOL-ERROR if the tool body signals, so a misbehaving tool cannot
crash the loop opaquely."
  (let ((values '()))
    (maphash (lambda (key value)
               (push (intern (string-upcase key) :keyword) values)
               (push value values))
             (or arguments (make-hash-table :test 'equal)))
    (handler-case
        (apply (tool-function tool) (positional-arguments tool (nreverse values)))
      (c:llm-error (e) (error e))
      (error (e)
        (error 'c:llm-tool-error :tool-name (tool-name tool)
                                 :underlying (princ-to-string e))))))

(defun positional-arguments (tool plist)
  "Order PLIST's values to match TOOL's schema property order.
The model returns a JSON object; the Lisp function takes positional arguments,
so the schema's required-then-optional order is the contract."
  (let* ((schema (tool-schema tool))
         (properties (gethash "properties" schema))
         (names '()))
    (maphash (lambda (key value) (declare (ignore value)) (push key names)) properties)
    ;; Preserve the declaration order recorded in the schema's "required" plus
    ;; any remaining optional properties.
    (let* ((required (coerce (gethash "required" schema) 'list))
           (optional (sort (set-difference names required :test #'string=)
                           #'string<))
           (ordered (append required optional)))
      (loop for name in ordered
            collect (getf plist (intern (string-upcase name) :keyword))))))
```

- [ ] **Step 4: Write `encode-tool` for Anthropic**

Append to `src/providers/anthropic.lisp`:

```lisp
(defmethod encode-tool ((provider anthropic-provider) tool)
  (json:jobject :name (tool-name tool)
                :description (tool-description tool)
                :input_schema (tool-schema tool)))
```

The `defgeneric` for `encode-tool` already lives in `src/protocol.lisp` (Task 8)
alongside the other protocol generic functions; only the method belongs here.

- [ ] **Step 5: Export and wire up the ASDF systems**

Add to the `cl-llm` `:export` list:

```lisp
   #:tool #:deftool #:find-tool #:register-tool #:unregister-tool
   #:tool-name #:tool-description #:tool-schema #:tool-function
   #:encode-tool #:call-tool
```

`cl-llm` src components: insert `(:file "tools")` **after `core` and before
`protocol`**, because `protocol.lisp` and `anthropic.lisp` reference `tool-name`.
`cl-llm/tests` gains `(:file "tools")` at the end.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 16 tool tests green.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/tools.lisp \
        src/providers/anthropic.lisp tests/tools.lisp
git commit -m "feat: deftool with typed lambda-list schema derivation"
```

---

### Task 13: Bounded tool loop

**Files:**
- Create: `src/tool-loop.lisp`
- Modify: `cl-llm.asd` (add `(:file "tool-loop")` after `providers/anthropic`, before `facade`)
- Test: `tests/tool-loop.lisp`

**Interfaces:**
- Consumes: `call-tool`/`find-tool` (Task 12), `chat-request` (Task 9), core objects (Task 7).
- Produces: `cl-llm::run-tool-loop` (provider conversation tools max-turns) → `response`; special `cl-llm:*max-tool-turns*` (default 8); condition `llm-tool-error` used for a loop-limit breach.

**Loop contract:** call `chat-request`; if the response's stop reason is `:tool-use`, append the assistant message, execute every requested tool, append one user message containing all the `tool-result` parts, and repeat. Stop when the stop reason is anything else. If `max-turns` round trips elapse without a non-tool-use stop, signal `llm-tool-error`.

- [ ] **Step 1: Write the failing tests**

Create `tests/tool-loop.lisp`:

```lisp
;;;; tests/tool-loop.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun tool-use-fixture (&key (id "tu_1") (name "tool-echo") (input "{\"text\":\"hi\"}"))
  (format nil "{\"model\":\"m\",\"stop_reason\":\"tool_use\",\"content\":[
                 {\"type\":\"tool_use\",\"id\":\"~a\",\"name\":\"~a\",\"input\":~a}]}"
          id name input))

(test tool-loop-executes-tool-and-returns-final-answer
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo the text." (format nil "echo:~a" text)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (let ((text (llm:ask "say hi" :tools '(tool-echo))))
          (is (string= "Hello" text) "The final non-tool-use response is returned")
          (is (= 2 (length (fake-requests d)))))))))

(test tool-loop-sends-the-tool-result-back
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo the text." (format nil "echo:~a" text)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (llm:ask "say hi" :tools '(tool-echo))
        (let ((body (last-request-body d)))
          ;; messages: user, assistant(tool_use), user(tool_result)
          (is (= 3 (length (json:jget body "messages"))))
          (is (string= "tool_result" (json:jget body "messages" 2 "content" 0 "type")))
          (is (string= "tu_1" (json:jget body "messages" 2 "content" 0 "tool_use_id")))
          (is (string= "echo:hi" (json:jget body "messages" 2 "content" 0 "content"))))))))

(test tool-loop-passes-typed-arguments
  (with-clean-registry
    (eval '(llm:deftool tool-add ((a :type integer) (b :type integer))
            "Add two integers." (+ a b)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture
                                             :name "tool-add" :input "{\"a\":2,\"b\":3}"))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (llm:ask "add" :tools '(tool-add))
        (is (string= "5" (json:jget (last-request-body d)
                                    "messages" 2 "content" 0 "content")))))))

(test tool-loop-reports-tool-errors-back-to-the-model
  "A signalling tool must produce an is_error result, not crash the loop."
  (with-clean-registry
    (eval '(llm:deftool tool-boom (text) "Always fails." (error "kaboom ~a" text)))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture :name "tool-boom"))
                         (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (is (string= "Hello" (llm:ask "go" :tools '(tool-boom))))
        (let ((body (last-request-body d)))
          (is (eq t (json:jget body "messages" 2 "content" 0 "is_error")))
          (is (search "kaboom" (json:jget body "messages" 2 "content" 0 "content"))))))))

(test tool-loop-respects-max-tool-turns
  "A model that never stops requesting tools must hit a hard bound."
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." text))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (tool-use-fixture))
                         (:status 200 :body (tool-use-fixture)))
      (with-test-provider
        (signals c:llm-tool-error
          (llm:ask "loop" :tools '(tool-echo) :max-tool-turns 2))
        (is (= 2 (length (fake-requests d)))
            "Exactly max-tool-turns requests, then stop")))))

(test tool-loop-default-max-turns-is-8
  (is (= 8 llm:*max-tool-turns*)))

(test tool-loop-handles-multiple-tool-calls-in-one-response
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." text))
    (with-fake-driver
        (d (:status 200
            :body "{\"model\":\"m\",\"stop_reason\":\"tool_use\",\"content\":[
                     {\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"tool-echo\",\"input\":{\"text\":\"a\"}},
                     {\"type\":\"tool_use\",\"id\":\"tu_2\",\"name\":\"tool-echo\",\"input\":{\"text\":\"b\"}}]}")
           (:status 200 :body (anthropic-response-fixture)))
      (with-test-provider
        (llm:ask "go" :tools '(tool-echo))
        (let ((body (last-request-body d)))
          (is (= 2 (length (json:jget body "messages" 2 "content")))
              "Both results go in ONE user message")
          (is (string= "a" (json:jget body "messages" 2 "content" 0 "content")))
          (is (string= "b" (json:jget body "messages" 2 "content" 1 "content"))))))))

(test tool-loop-unknown-tool-signals
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." text))
    (with-fake-driver (d (:status 200 :body (tool-use-fixture :name "not-registered")))
      (with-test-provider
        (signals c:llm-tool-error (llm:ask "go" :tools '(tool-echo)))))))

(test tool-loop-without-tools-does-not-loop
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (with-test-provider
      (is (string= "Hello" (llm:ask "hi")))
      (is (= 1 (length (fake-requests d)))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `run-tool-loop` is undefined (it is forward-referenced by
`facade.lisp` from Task 10 but has no definition yet), so every test that passes
`:tools` errors.

- [ ] **Step 3: Write the implementation**

Create `src/tool-loop.lisp`. Note that `*max-tool-turns*` is **already defined
in `facade.lisp`** (Task 10) — do not redefine it here.

```lisp
;;;; tool-loop.lisp -- the bounded automatic tool loop.
;;;;
;;;; The bound is not a nicety: without it a model that keeps requesting tools
;;;; loops forever, burning tokens. MAX-TURNS makes that impossible rather than
;;;; merely unlikely.

(in-package #:cl-llm)

(defun execute-tool-call (call tools)
  "Execute one TOOL-USE-PART, returning a TOOL-RESULT-PART.
A tool that signals produces an error result the model can see and react to,
rather than aborting the whole exchange."
  (let ((tool (find-tool-among call tools)))
    (handler-case
        (make-tool-result-part (part-id call)
                               (princ-to-string (call-tool tool (part-arguments call))))
      (c:llm-tool-error (e)
        (make-tool-result-part (part-id call)
                               (princ-to-string (c:llm-error-underlying e))
                               :errorp t)))))

(defun find-tool-among (call tools)
  "Resolve the tool CALL names, restricted to TOOLS.
A model naming a tool that was not offered is a protocol violation, not
something to paper over."
  (or (find (part-name call) tools :key #'tool-name :test #'string-equal)
      (error 'c:llm-tool-error
             :tool-name (part-name call)
             :underlying "The model requested a tool that was not offered.")))

(defun run-tool-loop (provider conversation tools max-turns)
  "Drive the model/tool exchange to a final answer.
CONVERSATION already ends with the triggering user message. Returns the first
RESPONSE whose stop reason is not :TOOL-USE."
  (loop for turn from 1 to max-turns
        for response = (chat-request provider conversation :tools tools)
        do (add-message conversation (response-message response))
           (let ((calls (response-tool-calls response)))
             (if (and (eq (response-stop-reason response) :tool-use) calls)
                 ;; Every result for this turn goes in ONE user message, which is
                 ;; what the Messages API requires.
                 (add-message conversation
                              (make-message
                               :user
                               (mapcar (lambda (call) (execute-tool-call call tools))
                                       calls)))
                 (return response)))
        finally
           (error 'c:llm-tool-error
                  :tool-name nil
                  :underlying (format nil "The model still requested tools after ~
                                           ~d turns (max-tool-turns). Giving up."
                                      max-turns))))
```

- [ ] **Step 4: Export and wire up the ASDF systems**

`#:*max-tool-turns*` is already exported (Task 10). `cl-llm` src gains
`(:file "tool-loop")` after `streaming`. `cl-llm/tests` gains `(:file "tool-loop")`
at the end.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 9 tool-loop tests green, and every earlier test still green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/facade.lisp src/tool-loop.lisp tests/tool-loop.lisp
git commit -m "feat: bounded automatic tool loop"
```

---

### Task 14: OpenAI-compatible provider

**Files:**
- Create: `src/providers/openai.lisp`
- Modify: `cl-llm.asd` (add `(:file "openai")` to the `providers` module)
- Test: `tests/openai.lisp`

**Interfaces:**
- Consumes: the same protocol GFs as Task 9; `openai-compatible-provider` (Task 8).
- Produces: methods on `encode-request`, `decode-response`, `chat-request`, `stream-request`, `parse-stream-event`, `encode-tool`, `encode-part` for `openai-compatible-provider`.

**Shape differences from Anthropic that this task must handle:**
- The system prompt is a **message** with role `"system"`, not a top-level field.
- Message content is a **plain string**, not a parts array.
- `max_tokens` is optional.
- Tools nest under `{"type":"function","function":{...}}` with `parameters`, not `input_schema`.
- Tool calls come back as `choices[0].message.tool_calls[]` with `function.arguments` as a **JSON string that must be parsed**.
- Tool results are a message with role `"tool"` and a `tool_call_id`.
- Streaming sends `choices[0].delta.content` and terminates with a literal `data: [DONE]`.
- `finish_reason` is `"stop"`, `"length"`, or `"tool_calls"`.

- [ ] **Step 1: Write the failing tests**

Create `tests/openai.lisp`:

```lisp
;;;; tests/openai.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun test-openai-provider ()
  (make-instance 'llm:openai-compatible-provider
                 :base-url "http://localhost:11434/v1" :model "llama3.1"))

(defun openai-response-fixture ()
  "{\"model\":\"llama3.1\",\"choices\":[{\"finish_reason\":\"stop\",
     \"message\":{\"role\":\"assistant\",\"content\":\"Hello\"}}],
     \"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}")

(test openai-encode-system-is-a-message
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :system "be terse"
                                   :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "system" (json:jget body "messages" 0 "role")))
    (is (string= "be terse" (json:jget body "messages" 0 "content")))
    (is (string= "user" (json:jget body "messages" 1 "role")))
    (is (null (nth-value 1 (gethash "system" body)))
        "system must NOT be a top-level field for OpenAI")))

(test openai-encode-content-is-a-plain-string
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "hi" (json:jget body "messages" 0 "content"))
        "OpenAI content is a string, not a parts array")))

(test openai-encode-omits-max-tokens-when-unset
  "Unlike Anthropic, max_tokens is optional here and must be omitted."
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (null (nth-value 1 (gethash "max_tokens" body))))))

(test openai-encode-tool
  (with-clean-registry
    (eval '(llm:deftool tool-weather (city) "Look up weather." city))
    (let* ((p (test-openai-provider))
           (encoded (json:parse (json:to-json
                                 (llm:encode-tool p (llm:find-tool 'tool-weather))))))
      (is (string= "function" (json:jget encoded "type")))
      (is (string= "tool-weather" (json:jget encoded "function" "name")))
      (is (string= "string"
                   (json:jget encoded "function" "parameters" "properties" "city" "type"))))))

(test openai-encode-tool-result-message
  (let* ((p (test-openai-provider))
         (c (llm:make-conversation
             :messages (list (llm:make-message
                              :user (list (llm:make-tool-result-part "tc_1" "22C"))))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "tool" (json:jget body "messages" 0 "role")))
    (is (string= "tc_1" (json:jget body "messages" 0 "tool_call_id")))
    (is (string= "22C" (json:jget body "messages" 0 "content")))))

(test openai-decode-text-response
  (let* ((p (test-openai-provider))
         (r (llm:decode-response p (json:parse (openai-response-fixture)))))
    (is (string= "Hello" (llm:response-text r)))
    (is (eq :end-turn (llm:response-stop-reason r)))
    (is (= 10 (llm:usage-input-tokens (llm:response-usage r))))
    (is (= 3 (llm:usage-output-tokens (llm:response-usage r))))))

(test openai-decode-tool-calls-parses-argument-string
  "OpenAI sends arguments as a JSON STRING that must be parsed."
  (let* ((p (test-openai-provider))
         (payload (json:parse
                   "{\"model\":\"m\",\"choices\":[{\"finish_reason\":\"tool_calls\",
                      \"message\":{\"tool_calls\":[{\"id\":\"tc_1\",\"type\":\"function\",
                        \"function\":{\"name\":\"get-weather\",
                                     \"arguments\":\"{\\\"city\\\":\\\"Oakland\\\"}\"}}]}}]}"))
         (r (llm:decode-response p payload))
         (call (first (llm:response-tool-calls r))))
    (is (eq :tool-use (llm:response-stop-reason r)))
    (is (string= "tc_1" (llm:part-id call)))
    (is (string= "get-weather" (llm:part-name call)))
    (is (string= "Oakland" (gethash "city" (llm:part-arguments call))))))

(test openai-decode-finish-reason-length
  (let* ((p (test-openai-provider))
         (r (llm:decode-response
             p (json:parse "{\"choices\":[{\"finish_reason\":\"length\",
                              \"message\":{\"content\":\"x\"}}]}"))))
    (is (eq :max-tokens (llm:response-stop-reason r)))))

(test openai-chat-request-end-to-end
  (with-fake-driver (d (:status 200 :body (openai-response-fixture)))
    (let ((p (test-openai-provider))
          (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
      (is (string= "Hello" (llm:response-text (llm:chat-request p c))))
      (is (string= "http://localhost:11434/v1/chat/completions"
                   (getf (last-request d) :url))))))

(test openai-streaming
  (with-fake-driver
      (d (:status 200
          :body (format nil "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}~%~%~
                             data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}~%~%~
                             data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}~%~%~
                             data: [DONE]~%~%")))
    (let ((llm:*provider* (test-openai-provider)))
      (llm:with-streamed-response (r "hi")
        (is (string= "Hel" (llm:next-delta r)))
        (is (string= "lo" (llm:next-delta r)))
        (is (null (llm:next-delta r)))))))

(test openai-stream-done-sentinel-terminates
  (let* ((p (test-openai-provider))
         (event (sse:make-sse-event nil "[DONE]")))
    (is (eq :done (llm:parse-stream-event p event)))))

(test openai-tool-loop-end-to-end
  (with-clean-registry
    (eval '(llm:deftool tool-echo (text) "Echo." (format nil "echo:~a" text)))
    (with-fake-driver
        (d (:status 200
            :body "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"tool_calls\":[
                     {\"id\":\"tc_1\",\"type\":\"function\",\"function\":{\"name\":\"tool-echo\",
                      \"arguments\":\"{\\\"text\\\":\\\"hi\\\"}\"}}]}}]}")
           (:status 200 :body (openai-response-fixture)))
      (let ((llm:*provider* (test-openai-provider)))
        (is (string= "Hello" (llm:ask "go" :tools '(tool-echo))))
        (let ((body (last-request-body d)))
          (is (string= "tool" (json:jget body "messages" 2 "role")))
          (is (string= "echo:hi" (json:jget body "messages" 2 "content"))))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — no `encode-request` method for `openai-compatible-provider`.

- [ ] **Step 3: Write the implementation**

Create `src/providers/openai.lisp`:

```lisp
;;;; openai.lisp -- OpenAI-compatible chat completions.
;;;;
;;;; Targets llama.cpp, Ollama, vLLM, and LM Studio. The shape differs from
;;;; Anthropic in ways worth naming: the system prompt is a message rather than
;;;; a field, content is a plain string rather than a parts array, tool
;;;; arguments arrive as a JSON *string* needing a second parse, and the stream
;;;; terminates with a literal [DONE] sentinel rather than a typed event.

(in-package #:cl-llm)

;;; Encoding

(defun openai-encode-message (message)
  "Encode one message. Tool results become role \"tool\" messages, which is why
this cannot simply map over parts."
  (let ((parts (message-content message)))
    (let ((tool-result (find-if (lambda (p) (typep p 'tool-result-part)) parts)))
      (if tool-result
          (json:jobject :role "tool"
                        :tool_call_id (part-tool-use-id tool-result)
                        :content (princ-to-string (part-content tool-result)))
          (let ((tool-uses (remove-if-not (lambda (p) (typep p 'tool-use-part)) parts))
                (text (with-output-to-string (out)
                        (dolist (part parts)
                          (when (typep part 'text-part)
                            (write-string (part-text part) out))))))
            (json:jobject
             :role (string-downcase (symbol-name (message-role message)))
             :content (if (string= text "") nil text)
             :tool_calls (when tool-uses
                           (map 'vector
                                (lambda (part)
                                  (json:jobject
                                   :id (part-id part)
                                   :type "function"
                                   :function (json:jobject
                                              :name (part-name part)
                                              :arguments (json:to-json
                                                          (or (part-arguments part)
                                                              (json:jobject))))))
                                tool-uses))))))))

(defmethod encode-request ((provider openai-compatible-provider) conversation
                           &key stream tools)
  (let* ((parameters (conversation-parameters conversation))
         (system (conversation-system conversation))
         (messages (map 'list #'openai-encode-message
                        (conversation-messages conversation))))
    (json:to-json
     (json:jobject
      :model (model-for provider conversation)
      :messages (coerce (if system
                            (cons (json:jobject :role "system" :content system)
                                  messages)
                            messages)
                        'vector)
      ;; Optional here, unlike Anthropic: omit when unset.
      :max_tokens (getf parameters :max-tokens)
      :temperature (getf parameters :temperature)
      :top_p (getf parameters :top-p)
      :stop (when (getf parameters :stop)
              (coerce (getf parameters :stop) 'vector))
      :tools (when tools
               (map 'vector (lambda (tool) (encode-tool provider tool)) tools))
      :stream (when stream :true)))))

(defmethod encode-tool ((provider openai-compatible-provider) tool)
  (json:jobject :type "function"
                :function (json:jobject :name (tool-name tool)
                                        :description (tool-description tool)
                                        :parameters (tool-schema tool))))

;;; Decoding

(defun openai-stop-reason (string)
  (cond ((null string) nil)
        ((string= string "stop") :end-turn)
        ((string= string "length") :max-tokens)
        ((string= string "tool_calls") :tool-use)
        (t nil)))

(defun openai-decode-tool-call (payload)
  "Decode one tool_call. ARGUMENTS is a JSON string requiring a second parse."
  (let ((arguments (json:jget payload "function" "arguments")))
    (make-tool-use-part
     (json:jget payload "id")
     (json:jget payload "function" "name")
     (if (and arguments (stringp arguments) (string/= arguments ""))
         (handler-case (json:parse arguments)
           (error ()
             (error 'c:llm-parse-error :payload arguments
                    :message "Could not parse tool_call arguments as JSON")))
         (json:jobject)))))

(defmethod decode-response ((provider openai-compatible-provider) payload)
  (let* ((choice (json:jget payload "choices" 0))
         (message (json:jget choice "message"))
         (content (json:jget message "content"))
         (tool-calls (json:jget message "tool_calls"))
         (usage (json:jget payload "usage")))
    (make-instance
     'response
     :content (append
               (when (and content (string/= content ""))
                 (list (make-text-part content)))
               (when tool-calls
                 (map 'list #'openai-decode-tool-call tool-calls)))
     :stop-reason (openai-stop-reason (json:jget choice "finish_reason"))
     :model (json:jget payload "model")
     :usage (when usage
              (make-instance 'usage
                             :input-tokens (json:jget usage "prompt_tokens")
                             :output-tokens (json:jget usage "completion_tokens")))
     :raw payload)))

;;; Requesting

(defmethod chat-request ((provider openai-compatible-provider) conversation &key tools)
  (let ((url (provider-endpoint provider)))
    (multiple-value-bind (body status)
        (request-with-retry url
                            :method :post
                            :headers (provider-headers provider)
                            :content (encode-request provider conversation :tools tools))
      (declare (ignore status))
      (decode-response provider (parse-body-or-signal body url)))))

(defmethod stream-request ((provider openai-compatible-provider) conversation &key tools)
  (request-with-retry (provider-endpoint provider)
                      :method :post
                      :headers (provider-headers provider)
                      :content (encode-request provider conversation
                                               :stream t :tools tools)
                      :stream t))

(defmethod parse-stream-event ((provider openai-compatible-provider) event)
  (let ((data (sse:sse-event-data event)))
    ;; The terminator is a literal sentinel, not a typed event.
    (if (string= data "[DONE]")
        (values :done nil)
        (let* ((payload (handler-case (json:parse data)
                          (error ()
                            (error 'c:llm-parse-error :payload data
                                   :message "Malformed SSE data from the OpenAI-compatible endpoint"))))
               (choice (json:jget payload "choices" 0))
               (delta (json:jget choice "delta"))
               (content (json:jget delta "content"))
               (finish (json:jget choice "finish_reason")))
          (cond
            ((and content (string/= content "")) (values :text content))
            (finish (values :stop-reason (openai-stop-reason finish)))
            (t (values :ignore nil)))))))
```

Note: streamed tool calls on OpenAI-compatible endpoints are decoded only far
enough to terminate cleanly; assembling streamed `tool_calls` deltas is not
implemented, and non-streaming tool use is the supported path there. State this
in the README.

- [ ] **Step 4: Wire up the ASDF systems**

`providers` module components become `((:file "anthropic") (:file "openai"))`.
`cl-llm/tests` gains `(:file "openai")` at the end.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 12 OpenAI tests green, entire suite green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/providers/openai.lisp tests/openai.lisp
git commit -m "feat: OpenAI-compatible provider"
```

---

### Task 15: Live suite, CI, and README

**Files:**
- Create: `live/packages.lisp`, `live/live.lisp`, `.github/workflows/ci.yml`
- Modify: `cl-llm.asd` (add the `cl-llm/live` system), `README.md`

**Interfaces:**
- Consumes: the whole library.
- Produces: ASDF system `cl-llm/live`, gated on `CL_LLM_LIVE`; a CI workflow running the offline suite on SBCL.

- [ ] **Step 1: Add the live system to `cl-llm.asd`**

```lisp
(defsystem "cl-llm/live"
  :description "Live-endpoint tests for cl-llm. Requires CL_LLM_LIVE=1."
  :license "MIT"
  :depends-on ("cl-llm" "fiveam")
  :serial t
  :components ((:module "live"
                :components ((:file "packages")
                             (:file "live"))))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! (find-symbol* :cl-llm-live-suite :cl-llm.live))
               (error "cl-llm live suite failed."))))
```

- [ ] **Step 2: Write the live suite**

Create `live/packages.lisp`:

```lisp
(defpackage #:cl-llm.live
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions))
  (:export #:cl-llm-live-suite))
```

Create `live/live.lisp`:

```lisp
;;;; live.lisp -- tests that hit real endpoints.
;;;;
;;;; Never run by (asdf:test-system :cl-llm). These cost money and need keys, so
;;;; they are gated: contributors without keys are never blocked.

(in-package #:cl-llm.live)

(def-suite cl-llm-live-suite
  :description "Tests against real Anthropic and local endpoints.")

(in-suite cl-llm-live-suite)

(defun live-enabled-p ()
  (let ((value (uiop:getenv "CL_LLM_LIVE")))
    (and value (string/= value "") (string/= value "0"))))

(defun local-base-url ()
  (or (uiop:getenv "CL_LLM_LOCAL_BASE_URL") "http://localhost:11434/v1"))

(defun local-model ()
  (or (uiop:getenv "CL_LLM_LOCAL_MODEL") "llama3.1"))

(test live-anthropic-ask
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (let ((llm:*provider* (make-instance 'llm:anthropic-provider))
            (llm:*max-tokens* 64))
        (let ((text (llm:ask "Reply with exactly the word: pong")))
          (is (stringp text))
          (is (search "pong" (string-downcase text)))))))

(test live-anthropic-streaming
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (let ((llm:*provider* (make-instance 'llm:anthropic-provider))
            (llm:*max-tokens* 64)
            (collected '()))
        (llm:with-streamed-response (r "Count: one two three")
          (llm:do-deltas (delta r) (push delta collected)))
        (is (plusp (length collected)) "At least one delta must arrive"))))

(test live-anthropic-tool-use
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (progn
        (llm:deftool live-add ((a :type integer) (b :type integer))
          "Add two integers together."
          (+ a b))
        (let ((llm:*provider* (make-instance 'llm:anthropic-provider))
              (llm:*max-tokens* 256))
          (let ((text (llm:ask "Use the live-add tool to add 17 and 25. Reply with just the number."
                               :tools '(live-add))))
            (is (search "42" text)))))))

(test live-local-ask
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (let ((llm:*provider* (make-instance 'llm:openai-compatible-provider
                                           :base-url (local-base-url)
                                           :model (local-model))))
        (handler-case
            (is (stringp (llm:ask "Reply with exactly the word: pong")))
          (c:llm-error (e)
            (skip "No local server at ~a: ~a" (local-base-url) e))))))
```

- [ ] **Step 3: Verify the live suite is skipped without the env var**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/live)'
```

Expected: the suite runs and every test **skips**, exiting 0. No network call is
made and no API key is required.

- [ ] **Step 4: Write the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  offline-tests:
    name: Offline suite (SBCL)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install SBCL and Quicklisp
        run: |
          sudo apt-get update
          sudo apt-get install -y sbcl curl
          curl -sSLO https://beta.quicklisp.org/quicklisp.lisp
          sbcl --non-interactive \
               --load quicklisp.lisp \
               --eval '(quicklisp-quickstart:install)'

      - name: Run the offline test suite
        run: |
          sbcl --non-interactive \
               --load ~/quicklisp/setup.lisp \
               --eval '(push (truename ".") asdf:*central-registry*)' \
               --eval '(ql:quickload :cl-llm/tests)' \
               --eval '(asdf:test-system :cl-llm)'
```

The offline suite needs no secrets, so it runs on pull requests from forks.

- [ ] **Step 5: Rewrite the README**

Replace `README.md` with:

````markdown
# cl-llm

A Common Lisp library for interacting with and tuning LLMs.

Supports **Anthropic** and **local / OpenAI-compatible** endpoints (llama.cpp,
Ollama, vLLM, LM Studio). SBCL is the primary target; ECL and Clozure are
supported by construction — the library uses no threads.

## Install

```lisp
(ql:quickload :cl-llm)
```

Set `ANTHROPIC_API_KEY` in your environment for the default provider.

## Use

```lisp
(cl-llm:ask "Explain CLOS in one sentence")
;; => "CLOS is Common Lisp's object system, built on generic functions..."
```

Every keyword has a matching special variable, so a one-liner and a fully
specified call are the same API:

```lisp
(let ((cl-llm:*model* "claude-opus-4-8"))
  (cl-llm:ask "..." :temperature 0.2 :system "Be terse."))
```

### Conversations

```lisp
(let ((c (cl-llm:make-conversation :system "You are terse.")))
  (cl-llm:send c "hi")
  (cl-llm:send c "and again"))
```

### Streaming

Streaming is pull-based and thread-free — `next-delta` reads one event in your
own thread. The stream is a live resource, so scope it:

```lisp
(cl-llm:with-streamed-response (r "Write a haiku")
  (cl-llm:do-deltas (d r)
    (write-string d)
    (force-output)))
```

A streamed response is single-consumer and not restartable.

### Tools

`deftool` defines the whole tool surface in Lisp. It expands to a plain `defun`
plus a registration form, and the tool loop calls your function **in-process** —
so a tool body closes over live database handles, open transactions, and
whatever else an ordinary function would:

```lisp
(cl-llm:deftool find-related (node-id (depth :type integer :default 1))
  "Find nodes related to the given node in the knowledge graph."
  (vivace-graph:with-graph (*graph*)
    (vivace-graph:lookup-related node-id :depth depth)))

(cl-llm:ask "What connects to node n42?" :tools '(find-related))
```

The JSON schema is derived from the lambda list:

| Form                                | Schema                       |
|-------------------------------------|------------------------------|
| `city`                              | required string              |
| `(units :celsius :fahrenheit)`      | required enum                |
| `(depth :type integer)`             | required integer             |
| `(limit :type integer :default 10)` | optional integer, default 10 |
| `(ids :type (list string))`         | required array of strings    |
| `(note :type string :optional t)`   | optional string              |

Types: `string`, `integer`, `number`, `boolean`, `(list <type>)`.

The tool loop runs automatically and is bounded by `*max-tool-turns*` (default
8), so a runaway loop is impossible rather than merely unlikely.

> **Security.** The *model* chooses the arguments. A narrow tool is bounded by
> its schema; a general escape hatch such as `(deftool run-query (sql) ...)`
> grants the model arbitrary execution against your store. Prefer narrow,
> purpose-specific tools, and treat every tool argument as untrusted input.

### Local models

```lisp
(let ((cl-llm:*provider* (make-instance 'cl-llm:openai-compatible-provider
                                        :base-url "http://localhost:11434/v1"
                                        :model "llama3.1")))
  (cl-llm:ask "hi"))
```

### Errors

Everything signals under `cl-llm:llm-error`: `llm-http-error`, `llm-api-error`,
`llm-rate-limit-error`, `llm-auth-error`, `llm-timeout-error`, `llm-parse-error`,
`llm-tool-error`. 429 and 5xx are retried with exponential backoff honoring
`Retry-After`, bounded by `*retries*`. A `retry-request` restart is established
around every request.

## Testing

```sh
sbcl --eval '(asdf:test-system :cl-llm)'                    # offline, no key needed
CL_LLM_LIVE=1 sbcl --eval '(asdf:test-system :cl-llm/live)' # real endpoints
```

## Status and limitations

Under development. Currently **not** implemented:

- Embeddings, RAG, and vector storage
- Hosted fine-tuning jobs
- Local training / LoRA (planned; see the design doc)
- Multimodal input — the content model supports it, the providers do not yet
- Streamed tool calls on OpenAI-compatible endpoints (non-streaming tool use
  works; Anthropic streams tool calls fine)

See `docs/superpowers/specs/2026-07-17-cl-llm-design.md` for the design and the
reasoning behind each non-goal.

## License

MIT
````

- [ ] **Step 6: Run the full offline suite one last time**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS, every test green, exit 0.

- [ ] **Step 7: Commit and push**

```bash
git add cl-llm.asd live/ .github/ README.md
git commit -m "feat: live test suite, CI workflow, and README"
git push origin main
```

---

## Definition of done

- `asdf:test-system :cl-llm` passes offline with no API key set.
- `ask`, `send`, `make-conversation`, `with-streamed-response`, `do-deltas`, and
  `deftool` all work against Anthropic and an OpenAI-compatible endpoint.
- The tool loop is bounded and cannot run away.
- No thread is created anywhere in the library.
- CI is green on `main`.
- Then: Plan 2, the `cl-llm/eval` harness.
