# cl-llm Core Client Implementation Plan — Part 2 (Tasks 5–9)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Continuation of:** `docs/superpowers/plans/2026-07-17-cl-llm-core.md` (Tasks 1–4).
**Global Constraints and verified library facts:** see that document. They apply to every task here.
**Continues in:** `docs/superpowers/plans/2026-07-17-cl-llm-core-part-3.md` (Tasks 10–15).

---

### Task 5: HTTP driver protocol, Dexador driver, and fake driver

**Files:**
- Create: `src/http.lisp`
- Modify: `cl-llm.asd` (add `(:file "http")` after `sse`)
- Test: `tests/fake-driver.lisp`, `tests/http.lisp`

**Interfaces:**
- Consumes: `cl-llm.conditions` (Task 3), package `cl-llm.http` (Task 1).
- Produces:
  - class `http:driver` (abstract), `http:dexador-driver`, special `http:*driver*`
  - `(http:perform-request driver url &key method headers content timeout)` → `(values body-string status headers-alist)`. **Does not signal on non-2xx** — it returns the status for the layer above to interpret. Signals `llm-timeout-error` on timeout.
  - `(http:perform-stream-request driver url &key method headers content timeout)` → `(values character-stream status headers-alist)`. Same non-signalling contract.
  - test-only: `cl-llm.test::fake-driver` with `fake-requests` and `enqueue-response`.

The driver deliberately stays dumb: it performs one request and reports what came back. Status interpretation and retry live in Task 6. That split is what lets the fake driver be a trivial stub.

- [ ] **Step 1: Write the fake driver (test support)**

Create `tests/fake-driver.lisp`:

```lisp
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
    (values (make-string-input-stream body) status response-headers)))

(defmacro with-fake-driver ((var &rest responses) &body body)
  "Bind HTTP:*DRIVER* to a fresh fake-driver named VAR, pre-loaded with RESPONSES.
Each response is an argument list for ENQUEUE-RESPONSE."
  `(let ((,var (make-instance 'fake-driver)))
     ,@(mapcar (lambda (response) `(enqueue-response ,var ,@response)) responses)
     (let ((http:*driver* ,var))
       ,@body)))
```

- [ ] **Step 2: Write the failing tests**

Create `tests/http.lisp`:

```lisp
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `http:driver` and `http:perform-request` are undefined.

- [ ] **Step 4: Write the implementation**

Create `src/http.lisp`:

```lisp
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
```

Note: `dex:http-request-failed` on a streaming request has already consumed the
body, so the error path returns a string body for both methods. Callers must
check the status before reading the stream.

- [ ] **Step 5: Add the files to the ASDF systems**

`cl-llm` src components become `packages, conditions, json, sse, http`.
`cl-llm/tests` tests components become `packages, suite, json, conditions, sse, fake-driver, http` — `fake-driver` must precede `http`.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all http tests green.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd src/http.lisp tests/fake-driver.lisp tests/http.lisp
git commit -m "feat: HTTP driver protocol with dexador and fake drivers"
```

---

### Task 6: Retry, backoff, and the `retry-request` restart

**Files:**
- Create: `src/retry.lisp`
- Modify: `cl-llm.asd` (add `(:file "retry")` after `http`), `src/packages.lisp` (add exports to `cl-llm`)
- Test: `tests/retry.lisp`

**Interfaces:**
- Consumes: `http:perform-request` (Task 5), conditions (Task 3).
- Produces (all in package `cl-llm`, internal unless noted):
  - `cl-llm::*retries*` (default 3), `cl-llm::*timeout*` (default 60), `cl-llm::*sleep-function*` (default `#'sleep`, bound in tests to avoid real delays)
  - `(cl-llm::request-with-retry url &key method headers content timeout retries stream)` → `(values body-or-stream status headers)`; signals the right `llm-*` condition on a non-retryable status, retries retryable ones, and establishes a `retry-request` restart
  - `(cl-llm::backoff-delay attempt retry-after)` → seconds
  - `(cl-llm::signal-http-error status body url)` → always signals

**Retry policy (exact):** retry on status 429 and 500–599. Do not retry 4xx other than 429. Delay is `(min 60 (* 2^(attempt-1) 1))` seconds — 1, 2, 4, 8… — unless a `Retry-After` header is present, which wins verbatim. After `retries` exhausted, signal the condition for the final status.

- [ ] **Step 1: Write the failing tests**

Create `tests/retry.lisp`:

```lisp
;;;; tests/retry.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defmacro without-sleeping ((&optional (delays (gensym))) &body body)
  "Run BODY with sleeping stubbed out, collecting requested delays into DELAYS."
  `(let* ((,delays '()))
     (let ((cl-llm::*sleep-function*
             (lambda (seconds) (push seconds ,delays))))
       ,@body)
     (nreverse ,delays)))

(test retry-succeeds-without-retrying
  (with-fake-driver (d (:status 200 :body "{\"ok\":true}"))
    (multiple-value-bind (body status) (cl-llm::request-with-retry "https://x")
      (is (string= "{\"ok\":true}" body))
      (is (= 200 status))
      (is (= 1 (length (fake-requests d)))))))

(test retry-retries-429-then-succeeds
  (with-fake-driver (d (:status 429 :body "{}") (:status 200 :body "{\"ok\":true}"))
    (let ((delays (without-sleeping (ds)
                    (is (= 200 (nth-value 1 (cl-llm::request-with-retry "https://x")))))))
      (is (= 2 (length (fake-requests d))))
      (is (equal '(1) delays) "First backoff must be 1 second"))))

(test retry-honors-retry-after-header
  (with-fake-driver (d (:status 429 :headers (("retry-after" . "7")) :body "{}")
                       (:status 200 :body "{}"))
    (let ((delays (without-sleeping (ds) (cl-llm::request-with-retry "https://x"))))
      (is (equal '(7) delays) "Retry-After must win over computed backoff"))))

(test retry-backoff-is-exponential
  (with-fake-driver (d (:status 500 :body "{}") (:status 500 :body "{}")
                       (:status 500 :body "{}") (:status 200 :body "{}"))
    (let ((delays (without-sleeping (ds)
                    (let ((cl-llm::*retries* 5))
                      (cl-llm::request-with-retry "https://x")))))
      (is (equal '(1 2 4) delays)))))

(test retry-gives-up-and-signals-rate-limit
  (with-fake-driver (d (:status 429 :body "{}") (:status 429 :body "{}")
                       (:status 429 :body "{}") (:status 429 :body "{}"))
    (without-sleeping (ds)
      (signals c:llm-rate-limit-error
        (cl-llm::request-with-retry "https://x")))))

(test retry-does-not-retry-400
  (with-fake-driver (d (:status 400 :body "{\"error\":{\"message\":\"bad\"}}"))
    (signals c:llm-api-error (cl-llm::request-with-retry "https://x"))
    (is (= 1 (length (fake-requests d))) "400 must not be retried")))

(test retry-401-signals-auth-error
  (with-fake-driver (d (:status 401 :body "{\"error\":{\"message\":\"nope\"}}"))
    (signals c:llm-auth-error (cl-llm::request-with-retry "https://x"))
    (is (= 1 (length (fake-requests d))))))

(test retry-error-carries-status-and-message
  (with-fake-driver (d (:status 400 :body "{\"error\":{\"message\":\"bad thing\",\"type\":\"invalid_request_error\"}}"))
    (handler-case (cl-llm::request-with-retry "https://x")
      (c:llm-api-error (e)
        (is (= 400 (c:llm-error-status e)))
        (is (string= "bad thing" (c:llm-error-message e)))
        (is (string= "invalid_request_error" (c:llm-error-type e)))))))

(test retry-request-restart-is-available
  "The debugger must offer a way to retry a failed request."
  (with-fake-driver (d (:status 400 :body "{}") (:status 200 :body "{\"ok\":true}"))
    (handler-bind ((c:llm-api-error
                     (lambda (e)
                       (declare (ignore e))
                       (let ((restart (find-restart 'cl-llm::retry-request)))
                         (is restart "retry-request restart must be established")
                         (invoke-restart restart)))))
      (is (= 200 (nth-value 1 (cl-llm::request-with-retry "https://x")))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `cl-llm::request-with-retry` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/retry.lisp`:

```lisp
;;;; retry.lisp -- status interpretation, backoff, and the retry-request restart.

(in-package #:cl-llm)

(defvar *retries* 3
  "How many times to retry a retryable request before signalling.")

(defvar *timeout* 60
  "Per-request timeout in seconds.")

(defvar *sleep-function* #'sleep
  "Called to wait between retries. Bound in tests so they do not actually sleep.")

(defun header-value (headers name)
  "Look up NAME in HEADERS, an alist of lowercase string keys."
  (cdr (assoc name headers :test #'string-equal)))

(defun retryable-status-p (status)
  (or (eql status 429) (and (integerp status) (<= 500 status 599))))

(defun backoff-delay (attempt retry-after)
  "Seconds to wait before ATTEMPT (1-based). A server RETRY-AFTER wins verbatim."
  (or retry-after
      (min 60 (expt 2 (1- attempt)))))

(defun parse-retry-after (headers)
  (let ((value (header-value headers "retry-after")))
    (when value
      (ignore-errors (parse-integer value :junk-allowed t)))))

(defun decode-error-body (body)
  "Pull (values MESSAGE TYPE CODE) out of an error BODY.
Handles both the Anthropic and OpenAI shapes, which both nest under \"error\".
Returns all NIL if the body is not JSON at all."
  (let ((payload (ignore-errors (json:parse body))))
    (if payload
        (values (json:jget payload "error" "message")
                (json:jget payload "error" "type")
                (json:jget payload "error" "code"))
        (values nil nil nil))))

(defun signal-http-error (status body url &optional headers)
  "Signal the most specific condition for STATUS. Always signals."
  (multiple-value-bind (message type code) (decode-error-body body)
    (let ((arguments (list :status status :body body :url url
                           :message message :error-type type :code code)))
      (cond
        ((eql status 429)
         (apply #'error 'c:llm-rate-limit-error
                :retry-after (parse-retry-after headers) arguments))
        ((or (eql status 401) (eql status 403))
         (apply #'error 'c:llm-auth-error arguments))
        ((and (integerp status) (<= 400 status 599))
         (apply #'error 'c:llm-api-error arguments))
        (t (error 'c:llm-http-error :status status :body body :url url))))))

(defun request-with-retry (url &key (method :post) headers content
                                    (timeout *timeout*) (retries *retries*)
                                    stream)
  "Perform a request, retrying retryable failures with exponential backoff.
Returns (values BODY-OR-STREAM STATUS HEADERS) on success and signals an
LLM-ERROR otherwise. When STREAM is true the first value is an open character
stream. A RETRY-REQUEST restart is established around the whole operation."
  (let ((attempt 0))
    (loop
      (incf attempt)
      (restart-case
          (multiple-value-bind (body status response-headers)
              (if stream
                  (http:perform-stream-request http:*driver* url
                                               :method method :headers headers
                                               :content content :timeout timeout)
                  (http:perform-request http:*driver* url
                                        :method method :headers headers
                                        :content content :timeout timeout))
            (cond
              ((and (integerp status) (<= 200 status 299))
               (return (values body status response-headers)))
              ((and (retryable-status-p status) (< attempt (1+ retries)))
               ;; A streaming request that failed returns a body, not a stream;
               ;; nothing to close.
               (funcall *sleep-function*
                        (backoff-delay attempt (parse-retry-after response-headers)))) 
              (t
               (signal-http-error status
                                  (if (streamp body) "" body)
                                  url
                                  response-headers))))
        (retry-request ()
          :report "Retry this LLM request."
          (setf attempt 0))))))
```

- [ ] **Step 4: Export the tunables**

In `src/packages.lisp`, add to the `cl-llm` package's `:export` list:

```lisp
   #:*retries*
   #:*timeout*
```

- [ ] **Step 5: Add the files to the ASDF systems**

`cl-llm` src components become `packages, conditions, json, sse, http, retry`.
`cl-llm/tests` gains `(:file "retry")` at the end.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 9 retry tests green. No test may take longer than a few milliseconds; if the suite hangs, `*sleep-function*` is not being bound.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/retry.lisp tests/retry.lisp
git commit -m "feat: retry with exponential backoff and retry-request restart"
```

---

### Task 7: Core CLOS objects

**Files:**
- Create: `src/core.lisp`
- Modify: `cl-llm.asd` (add `(:file "core")` after `retry`), `src/packages.lisp`
- Test: `tests/core.lisp`

**Interfaces:**
- Consumes: nothing beyond the packages.
- Produces (exported from `cl-llm`):
  - `content-part` (abstract); `text-part` (`part-text`); `tool-use-part` (`part-id`, `part-name`, `part-arguments`); `tool-result-part` (`part-tool-use-id`, `part-content`, `part-error-p`)
  - `(make-text-part text)`, `(make-tool-use-part id name arguments)`, `(make-tool-result-part tool-use-id content &key errorp)`
  - `message` (`message-role`, `message-content`); `(make-message role content)` where a string content is wrapped into `(list text-part)`
  - `conversation` (`conversation-messages`, `conversation-system`, `conversation-provider`, `conversation-model`, `conversation-parameters`); `(make-conversation &key system provider model messages &allow-other-keys)`; `(add-message conversation message)`
  - `usage` (`usage-input-tokens`, `usage-output-tokens`)
  - `response` (`response-content`, `response-stop-reason`, `response-model`, `response-usage`, `response-raw`); `(response-text response)` → concatenated text parts; `(response-tool-calls response)` → list of `tool-use-part`

- [ ] **Step 1: Write the failing tests**

Create `tests/core.lisp`:

```lisp
;;;; tests/core.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test make-message-wraps-string-content-in-a-text-part
  "Content is always a list of parts, never a bare string."
  (let ((m (llm:make-message :user "hi")))
    (is (eq :user (llm:message-role m)))
    (is (= 1 (length (llm:message-content m))))
    (is (typep (first (llm:message-content m)) 'llm:text-part))
    (is (string= "hi" (llm:part-text (first (llm:message-content m)))))))

(test make-message-accepts-a-part-list
  (let* ((part (llm:make-text-part "hi"))
         (m (llm:make-message :user (list part))))
    (is (eq part (first (llm:message-content m))))))

(test conversation-accumulates-messages-in-order
  (let ((c (llm:make-conversation :system "be terse")))
    (is (string= "be terse" (llm:conversation-system c)))
    (is (null (llm:conversation-messages c)))
    (llm:add-message c (llm:make-message :user "one"))
    (llm:add-message c (llm:make-message :assistant "two"))
    (is (= 2 (length (llm:conversation-messages c))))
    (is (eq :user (llm:message-role (first (llm:conversation-messages c)))))
    (is (eq :assistant (llm:message-role (second (llm:conversation-messages c)))))))

(test response-text-concatenates-text-parts-only
  (let ((r (make-instance 'llm:response
                          :content (list (llm:make-text-part "Hello ")
                                         (llm:make-tool-use-part "id1" "f" nil)
                                         (llm:make-text-part "world")))))
    (is (string= "Hello world" (llm:response-text r)))))

(test response-text-of-empty-content-is-empty-string
  (is (string= "" (llm:response-text (make-instance 'llm:response :content nil)))))

(test response-tool-calls-returns-only-tool-use-parts
  (let* ((call (llm:make-tool-use-part "id1" "get-weather" nil))
         (r (make-instance 'llm:response
                           :content (list (llm:make-text-part "x") call))))
    (is (equal (list call) (llm:response-tool-calls r)))))

(test tool-result-part-carries-error-flag
  (let ((p (llm:make-tool-result-part "id1" "boom" :errorp t)))
    (is (string= "id1" (llm:part-tool-use-id p)))
    (is (llm:part-error-p p))))

(test usage-readers
  (let ((u (make-instance 'llm:usage :input-tokens 10 :output-tokens 3)))
    (is (= 10 (llm:usage-input-tokens u)))
    (is (= 3 (llm:usage-output-tokens u)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `llm:make-message` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/core.lisp`:

```lisp
;;;; core.lisp -- the provider-independent object model.

(in-package #:cl-llm)

;;; Content parts
;;;
;;; Message content is ALWAYS a list of parts, never a bare string. This costs a
;;; little ceremony now and is what makes images a later addition rather than a
;;; rewrite.

(defclass content-part ()
  ()
  (:documentation "Abstract base for one piece of message content."))

(defclass text-part (content-part)
  ((text :initarg :text :accessor part-text :type string))
  (:documentation "Plain text content."))

(defclass tool-use-part (content-part)
  ((id :initarg :id :accessor part-id)
   (name :initarg :name :accessor part-name)
   (arguments :initarg :arguments :initform nil :accessor part-arguments))
  (:documentation "A model request to call a tool. ARGUMENTS is a hash-table of
decoded JSON arguments, keyed by string."))

(defclass tool-result-part (content-part)
  ((tool-use-id :initarg :tool-use-id :accessor part-tool-use-id)
   (content :initarg :content :accessor part-content)
   (errorp :initarg :errorp :initform nil :accessor part-error-p))
  (:documentation "The result of executing a tool, sent back to the model."))

(defun make-text-part (text)
  (make-instance 'text-part :text text))

(defun make-tool-use-part (id name arguments)
  (make-instance 'tool-use-part :id id :name name :arguments arguments))

(defun make-tool-result-part (tool-use-id content &key errorp)
  (make-instance 'tool-result-part :tool-use-id tool-use-id
                                   :content content :errorp errorp))

;;; Messages

(defclass message ()
  ((role :initarg :role :accessor message-role :type keyword
         :documentation "One of :USER or :ASSISTANT.")
   (content :initarg :content :accessor message-content :type list
            :documentation "A list of CONTENT-PART."))
  (:documentation "One turn in a conversation."))

(defun coerce-content (content)
  "Normalize CONTENT to a list of parts. A string becomes a single text part."
  (etypecase content
    (string (list (make-text-part content)))
    (content-part (list content))
    (list content)))

(defun make-message (role content)
  "Make a message. CONTENT may be a string, one part, or a list of parts."
  (make-instance 'message :role role :content (coerce-content content)))

;;; Conversations

(defclass conversation ()
  ((messages :initarg :messages :initform '() :accessor conversation-messages
             :documentation "Messages in order, oldest first.")
   (system :initarg :system :initform nil :accessor conversation-system)
   (provider :initarg :provider :initform nil :accessor conversation-provider)
   (model :initarg :model :initform nil :accessor conversation-model)
   (parameters :initarg :parameters :initform '() :accessor conversation-parameters
               :documentation "A plist of generation parameters, e.g. (:temperature 0.2)."))
  (:documentation "A multi-turn exchange with a provider."))

(defun make-conversation (&key system provider model messages parameters)
  (make-instance 'conversation :system system :provider provider :model model
                               :messages messages :parameters parameters))

(defun add-message (conversation message)
  "Append MESSAGE to CONVERSATION and return the message."
  (setf (conversation-messages conversation)
        (append (conversation-messages conversation) (list message)))
  message)

;;; Responses

(defclass usage ()
  ((input-tokens :initarg :input-tokens :initform nil :accessor usage-input-tokens)
   (output-tokens :initarg :output-tokens :initform nil :accessor usage-output-tokens))
  (:documentation "Token accounting for one response."))

(defclass response ()
  ((content :initarg :content :initform '() :accessor response-content
            :documentation "A list of CONTENT-PART.")
   (stop-reason :initarg :stop-reason :initform nil :accessor response-stop-reason
                :documentation "One of :END-TURN, :TOOL-USE, :MAX-TOKENS, :STOP, or NIL.")
   (model :initarg :model :initform nil :accessor response-model)
   (usage :initarg :usage :initform nil :accessor response-usage)
   (raw :initarg :raw :initform nil :accessor response-raw
        :documentation "The decoded provider payload, for escape hatches."))
  (:documentation "One assistant reply."))

(defun response-text (response)
  "Concatenate every text part of RESPONSE. Non-text parts are ignored."
  (with-output-to-string (out)
    (dolist (part (response-content response))
      (when (typep part 'text-part)
        (write-string (part-text part) out)))))

(defun response-tool-calls (response)
  "The TOOL-USE-PARTs of RESPONSE, in order."
  (remove-if-not (lambda (part) (typep part 'tool-use-part))
                 (response-content response)))

(defun response-message (response)
  "RESPONSE as an assistant MESSAGE, for appending to a conversation."
  (make-instance 'message :role :assistant :content (response-content response)))
```

- [ ] **Step 4: Export the new symbols**

In `src/packages.lisp`, add to the `cl-llm` package's `:export` list:

```lisp
   ;; content parts
   #:content-part #:text-part #:tool-use-part #:tool-result-part
   #:part-text #:part-id #:part-name #:part-arguments
   #:part-tool-use-id #:part-content #:part-error-p
   #:make-text-part #:make-tool-use-part #:make-tool-result-part
   ;; messages and conversations
   #:message #:make-message #:message-role #:message-content
   #:conversation #:make-conversation #:add-message
   #:conversation-messages #:conversation-system #:conversation-provider
   #:conversation-model #:conversation-parameters
   ;; responses
   #:response #:response-content #:response-stop-reason #:response-model
   #:response-usage #:response-raw #:response-text #:response-tool-calls
   #:response-message
   #:usage #:usage-input-tokens #:usage-output-tokens
```

- [ ] **Step 5: Add the files to the ASDF systems**

`cl-llm` src components become `packages, conditions, json, sse, http, retry, core`.
`cl-llm/tests` gains `(:file "core")` at the end.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 8 core tests green.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/core.lisp tests/core.lisp
git commit -m "feat: core CLOS object model"
```

---

### Task 8: Provider classes and protocol generic functions

**Files:**
- Create: `src/protocol.lisp`
- Modify: `cl-llm.asd` (add `(:file "protocol")` after `core`), `src/packages.lisp`
- Test: `tests/protocol.lisp`

**Interfaces:**
- Consumes: `core.lisp` (Task 7), conditions (Task 3).
- Produces (exported from `cl-llm`):
  - `provider` (abstract, slot reader `provider-model`), `anthropic-provider` (initargs `:api-key`, `:base-url`, `:model`; base-url defaults to `"https://api.anthropic.com"`), `openai-compatible-provider` (initargs `:api-key`, `:base-url`, `:model`; **`:base-url` is required**)
  - `(provider-default-model provider)` → string
  - `(provider-api-key provider)` → string; resolves from the `:api-key` initarg, else the environment, else signals `llm-auth-error`
  - `(provider-endpoint provider &key stream)` → URL string
  - `(provider-headers provider)` → alist
  - `(encode-request provider conversation &key stream tools)` → JSON string
  - `(decode-response provider payload)` → `response`
  - `(parse-stream-event provider event)` → `(values kind value)`
  - `(chat-request provider conversation &key tools)` → `response`
  - `(stream-request provider conversation &key tools)` → `(values stream)`

`provider-api-key` reads `ANTHROPIC_API_KEY` for `anthropic-provider` and `OPENAI_API_KEY` for `openai-compatible-provider`, and returns `nil` rather than signalling for `openai-compatible-provider` (local servers need no key).

- [ ] **Step 1: Write the failing tests**

Create `tests/protocol.lisp`:

```lisp
;;;; tests/protocol.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test provider-hierarchy
  (is (subtypep 'llm:anthropic-provider 'llm:provider))
  (is (subtypep 'llm:openai-compatible-provider 'llm:provider)))

(test anthropic-default-model-and-endpoint
  (let ((p (make-instance 'llm:anthropic-provider)))
    (is (string= "claude-opus-4-8" (llm:provider-default-model p)))
    (is (string= "https://api.anthropic.com/v1/messages" (llm:provider-endpoint p)))))

(test anthropic-base-url-is-overridable
  (let ((p (make-instance 'llm:anthropic-provider :base-url "http://localhost:8080")))
    (is (string= "http://localhost:8080/v1/messages" (llm:provider-endpoint p)))))

(test provider-model-slot-overrides-default
  (let ((p (make-instance 'llm:anthropic-provider :model "claude-haiku-4-5-20251001")))
    (is (string= "claude-haiku-4-5-20251001" (llm:provider-model p)))))

(test openai-compatible-endpoint
  (let ((p (make-instance 'llm:openai-compatible-provider
                          :base-url "http://localhost:11434/v1" :model "llama3.1")))
    (is (string= "http://localhost:11434/v1/chat/completions" (llm:provider-endpoint p)))
    (is (string= "llama3.1" (llm:provider-default-model p)))))

(test openai-compatible-requires-base-url
  (signals error (make-instance 'llm:openai-compatible-provider)))

(test anthropic-api-key-from-explicit-initarg
  (let ((p (make-instance 'llm:anthropic-provider :api-key "sk-test")))
    (is (string= "sk-test" (llm:provider-api-key p)))))

(test anthropic-missing-api-key-signals-auth-error
  "With no initarg and no environment variable, asking for the key must fail
loudly rather than send an unauthenticated request."
  (let ((p (make-instance 'llm:anthropic-provider))
        (cl-llm::*getenv-function* (constantly nil)))
    (signals c:llm-auth-error (llm:provider-api-key p))))

(test anthropic-api-key-from-environment
  (let ((p (make-instance 'llm:anthropic-provider))
        (cl-llm::*getenv-function*
          (lambda (name) (when (string= name "ANTHROPIC_API_KEY") "sk-env"))))
    (is (string= "sk-env" (llm:provider-api-key p)))))

(test openai-compatible-api-key-is-optional
  "A local server needs no key; requiring one would break the primary use case."
  (let ((p (make-instance 'llm:openai-compatible-provider :base-url "http://x/v1"))
        (cl-llm::*getenv-function* (constantly nil)))
    (is (null (llm:provider-api-key p)))))

(test anthropic-headers-carry-key-and-version
  (let* ((p (make-instance 'llm:anthropic-provider :api-key "sk-test"))
         (headers (llm:provider-headers p)))
    (is (string= "sk-test" (cdr (assoc "x-api-key" headers :test #'string-equal))))
    (is (string= "2023-06-01" (cdr (assoc "anthropic-version" headers :test #'string-equal))))
    (is (string= "application/json"
                 (cdr (assoc "content-type" headers :test #'string-equal))))))

(test openai-compatible-headers-omit-auth-without-key
  (let* ((p (make-instance 'llm:openai-compatible-provider :base-url "http://x/v1"))
         (cl-llm::*getenv-function* (constantly nil)))
    (is (null (assoc "authorization" (llm:provider-headers p) :test #'string-equal)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `llm:provider` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/protocol.lisp`:

```lisp
;;;; protocol.lisp -- provider classes and the generic functions each backend
;;;; must implement.

(in-package #:cl-llm)

(defvar *getenv-function* (lambda (name) (uiop:getenv name))
  "Indirection over the environment so tests need not mutate the real one.")

(defclass provider ()
  ((model :initarg :model :initform nil :reader provider-model
          :documentation "Model to use, or NIL to defer to PROVIDER-DEFAULT-MODEL.")
   (api-key :initarg :api-key :initform nil :reader provider-api-key-slot)
   (base-url :initarg :base-url :reader provider-base-url))
  (:documentation "Abstract base for an LLM backend."))

(defgeneric provider-default-model (provider)
  (:documentation "The model to use when none was specified."))

(defgeneric provider-endpoint (provider &key stream)
  (:documentation "The full URL to POST to."))

(defgeneric provider-headers (provider)
  (:documentation "Request headers as an alist. Never log the result: it
contains credentials."))

(defgeneric provider-api-key (provider)
  (:documentation "Resolve the API key from the initarg, then the environment.
Signals LLM-AUTH-ERROR if one is required and absent."))

(defgeneric encode-request (provider conversation &key stream tools)
  (:documentation "Encode CONVERSATION as a JSON request body string."))

(defgeneric decode-response (provider payload)
  (:documentation "Decode a parsed JSON PAYLOAD into a RESPONSE."))

(defgeneric parse-stream-event (provider event)
  (:documentation "Interpret one SSE-EVENT. Returns (values KIND VALUE) where
KIND is one of :TEXT (VALUE is a string delta), :TOOL-USE-START (VALUE is a
TOOL-USE-PART), :TOOL-ARGUMENTS (VALUE is a partial JSON string), :STOP-REASON
(VALUE is a keyword), :USAGE (VALUE is a USAGE), :DONE, or :IGNORE."))

(defgeneric model-for (provider conversation)
  (:documentation "The model to use for CONVERSATION on PROVIDER."))

(defmethod model-for ((provider provider) conversation)
  (or (and conversation (conversation-model conversation))
      (provider-model provider)
      (provider-default-model provider)))

;;; Anthropic

(defclass anthropic-provider (provider)
  ((base-url :initarg :base-url :initform "https://api.anthropic.com"
             :reader provider-base-url)
   (api-version :initarg :api-version :initform "2023-06-01"
                :reader provider-api-version))
  (:documentation "The Anthropic Messages API."))

(defmethod provider-default-model ((provider anthropic-provider))
  "claude-opus-4-8")

(defmethod provider-endpoint ((provider anthropic-provider) &key stream)
  (declare (ignore stream))
  (concatenate 'string (provider-base-url provider) "/v1/messages"))

(defmethod provider-api-key ((provider anthropic-provider))
  (or (provider-api-key-slot provider)
      (funcall *getenv-function* "ANTHROPIC_API_KEY")
      (error 'c:llm-auth-error
             :status nil
             :message "No Anthropic API key. Pass :api-key or set ANTHROPIC_API_KEY.")))

(defmethod provider-headers ((provider anthropic-provider))
  (list (cons "content-type" "application/json")
        (cons "x-api-key" (provider-api-key provider))
        (cons "anthropic-version" (provider-api-version provider))))

;;; OpenAI-compatible (llama.cpp, Ollama, vLLM, LM Studio)

(defclass openai-compatible-provider (provider)
  ((base-url :initarg :base-url :reader provider-base-url
             :initform (error "openai-compatible-provider requires :base-url, ~
                               e.g. \"http://localhost:11434/v1\".")))
  (:documentation "Any endpoint speaking the OpenAI chat-completions API."))

(defmethod provider-default-model ((provider openai-compatible-provider))
  (or (provider-model provider)
      (error 'c:llm-api-error
             :message "openai-compatible-provider has no model; pass :model.")))

(defmethod provider-endpoint ((provider openai-compatible-provider) &key stream)
  (declare (ignore stream))
  (concatenate 'string (provider-base-url provider) "/chat/completions"))

(defmethod provider-api-key ((provider openai-compatible-provider))
  "Optional: local servers accept any key or none."
  (or (provider-api-key-slot provider)
      (funcall *getenv-function* "OPENAI_API_KEY")))

(defmethod provider-headers ((provider openai-compatible-provider))
  (let ((key (provider-api-key provider)))
    (append (list (cons "content-type" "application/json"))
            (when key
              (list (cons "authorization" (concatenate 'string "Bearer " key)))))))
```

- [ ] **Step 4: Export the new symbols**

In `src/packages.lisp`, add to the `cl-llm` package's `:export` list:

```lisp
   ;; providers and protocol
   #:provider #:anthropic-provider #:openai-compatible-provider
   #:provider-model #:provider-default-model #:provider-endpoint
   #:provider-headers #:provider-api-key #:provider-base-url
   #:encode-request #:decode-response #:parse-stream-event
   #:chat-request #:stream-request
```

- [ ] **Step 5: Add the files to the ASDF systems**

`cl-llm` src components become `packages, conditions, json, sse, http, retry, core, protocol`.
`cl-llm/tests` gains `(:file "protocol")` at the end.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 12 protocol tests green.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/protocol.lisp tests/protocol.lisp
git commit -m "feat: provider classes and protocol generic functions"
```

---

### Task 9: Anthropic provider — encode, decode, and `chat-request`

**Files:**
- Create: `src/providers/anthropic.lisp`
- Modify: `cl-llm.asd` (add a `providers` module after `protocol`), `src/packages.lisp` (export `*max-tokens*`)
- Test: `tests/anthropic.lisp`

**Interfaces:**
- Consumes: `encode-request`/`decode-response`/`chat-request` GFs (Task 8), `request-with-retry` (Task 6), core objects (Task 7), `json:jobject`/`jget` (Task 2).
- Produces: methods on `encode-request`, `decode-response`, `chat-request` specialized on `anthropic-provider`; special `cl-llm:*max-tokens*` (default 4096).

**Anthropic request shape:**
```json
{"model":"...","max_tokens":4096,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}],
 "system":"...","temperature":0.2,"tools":[...],"stream":true}
```
`max_tokens` is **required** by the API. `system` is a top-level field, not a message.

**Anthropic response shape:**
```json
{"id":"msg_1","model":"claude-opus-4-8","stop_reason":"end_turn",
 "content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"tu_1","name":"f","input":{"a":1}}],
 "usage":{"input_tokens":10,"output_tokens":3}}
```

- [ ] **Step 1: Write the failing tests**

Create `tests/anthropic.lisp`:

```lisp
;;;; tests/anthropic.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun test-anthropic-provider ()
  (make-instance 'llm:anthropic-provider :api-key "sk-test"))

(defun anthropic-response-fixture ()
  "{\"id\":\"msg_1\",\"model\":\"claude-opus-4-8\",\"stop_reason\":\"end_turn\",
    \"content\":[{\"type\":\"text\",\"text\":\"Hello\"}],
    \"usage\":{\"input_tokens\":10,\"output_tokens\":3}}")

(test anthropic-encode-basic-request
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "claude-opus-4-8" (json:jget body "model")))
    (is (= 4096 (json:jget body "max_tokens")) "max_tokens is required by Anthropic")
    (is (string= "user" (json:jget body "messages" 0 "role")))
    (is (string= "text" (json:jget body "messages" 0 "content" 0 "type")))
    (is (string= "hi" (json:jget body "messages" 0 "content" 0 "text")))))

(test anthropic-encode-omits-unset-optional-parameters
  "An unset temperature must be ABSENT, not false -- this is the jzon nil trap."
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (null (nth-value 1 (gethash "temperature" body)))
        "temperature must not appear at all")
    (is (null (nth-value 1 (gethash "system" body))))
    (is (null (nth-value 1 (gethash "tools" body))))))

(test anthropic-encode-system-is-top-level
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :system "be terse"
                                   :messages (list (llm:make-message :user "hi"))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "be terse" (json:jget body "system")))))

(test anthropic-encode-parameters
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))
                                   :parameters '(:temperature 0.2 :max-tokens 100)))
         (body (json:parse (llm:encode-request p c))))
    (is (= 0.2d0 (json:jget body "temperature")))
    (is (= 100 (json:jget body "max_tokens")))))

(test anthropic-encode-stream-flag
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
    (is (eq t (json:jget (json:parse (llm:encode-request p c :stream t)) "stream")))
    (is (null (nth-value 1 (gethash "stream" (json:parse (llm:encode-request p c)))))
        "stream must be omitted, not false, for non-streaming requests")))

(test anthropic-encode-tool-result-message
  (let* ((p (test-anthropic-provider))
         (c (llm:make-conversation
             :messages (list (llm:make-message
                              :user (list (llm:make-tool-result-part "tu_1" "22C"))))))
         (body (json:parse (llm:encode-request p c))))
    (is (string= "tool_result" (json:jget body "messages" 0 "content" 0 "type")))
    (is (string= "tu_1" (json:jget body "messages" 0 "content" 0 "tool_use_id")))
    (is (string= "22C" (json:jget body "messages" 0 "content" 0 "content")))))

(test anthropic-decode-text-response
  (let* ((p (test-anthropic-provider))
         (r (llm:decode-response p (json:parse (anthropic-response-fixture)))))
    (is (string= "Hello" (llm:response-text r)))
    (is (eq :end-turn (llm:response-stop-reason r)))
    (is (string= "claude-opus-4-8" (llm:response-model r)))
    (is (= 10 (llm:usage-input-tokens (llm:response-usage r))))
    (is (= 3 (llm:usage-output-tokens (llm:response-usage r))))))

(test anthropic-decode-tool-use-response
  (let* ((p (test-anthropic-provider))
         (payload (json:parse
                   "{\"model\":\"m\",\"stop_reason\":\"tool_use\",\"content\":[
                      {\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"get-weather\",
                       \"input\":{\"city\":\"Oakland\"}}]}"))
         (r (llm:decode-response p payload))
         (call (first (llm:response-tool-calls r))))
    (is (eq :tool-use (llm:response-stop-reason r)))
    (is (string= "tu_1" (llm:part-id call)))
    (is (string= "get-weather" (llm:part-name call)))
    (is (string= "Oakland" (gethash "city" (llm:part-arguments call))))))

(test anthropic-decode-unknown-stop-reason-is-nil
  (let* ((p (test-anthropic-provider))
         (r (llm:decode-response p (json:parse "{\"content\":[],\"stop_reason\":\"weird\"}"))))
    (is (null (llm:response-stop-reason r)))))

(test anthropic-chat-request-end-to-end
  (with-fake-driver (d (:status 200 :body (anthropic-response-fixture)))
    (let* ((p (test-anthropic-provider))
           (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
           (r (llm:chat-request p c)))
      (is (string= "Hello" (llm:response-text r)))
      (is (string= "https://api.anthropic.com/v1/messages"
                   (getf (last-request d) :url)))
      (is (string= "sk-test"
                   (cdr (assoc "x-api-key" (getf (last-request d) :headers)
                               :test #'string-equal)))))))

(test anthropic-chat-request-signals-on-api-error
  (with-fake-driver (d (:status 400 :body "{\"error\":{\"message\":\"bad\",\"type\":\"invalid_request_error\"}}"))
    (let ((p (test-anthropic-provider))
          (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
      (signals c:llm-api-error (llm:chat-request p c)))))

(test anthropic-chat-request-signals-parse-error-on-garbage
  (with-fake-driver (d (:status 200 :body "not json at all"))
    (let ((p (test-anthropic-provider))
          (c (llm:make-conversation :messages (list (llm:make-message :user "hi")))))
      (signals c:llm-parse-error (llm:chat-request p c)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — no `encode-request` method for `anthropic-provider`.

- [ ] **Step 3: Write the implementation**

Create `src/providers/anthropic.lisp`:

```lisp
;;;; anthropic.lisp -- the Anthropic Messages API.

(in-package #:cl-llm)

(defvar *max-tokens* 4096
  "Default max_tokens. Anthropic requires this field, so it has a real default
rather than being omitted.")

;;; Encoding

(defgeneric encode-part (provider part)
  (:documentation "Encode one content part as a JSON object."))

(defmethod encode-part ((provider anthropic-provider) (part text-part))
  (json:jobject :type "text" :text (part-text part)))

(defmethod encode-part ((provider anthropic-provider) (part tool-use-part))
  (json:jobject :type "tool_use"
                :id (part-id part)
                :name (part-name part)
                :input (or (part-arguments part) (json:jobject))))

(defmethod encode-part ((provider anthropic-provider) (part tool-result-part))
  (json:jobject :type "tool_result"
                :tool_use_id (part-tool-use-id part)
                :content (part-content part)
                :is_error (if (part-error-p part) :true nil)))

(defun encode-message (provider message)
  (json:jobject :role (string-downcase (symbol-name (message-role message)))
                :content (map 'vector
                              (lambda (part) (encode-part provider part))
                              (message-content message))))

(defmethod encode-request ((provider anthropic-provider) conversation
                           &key stream tools)
  (let ((parameters (conversation-parameters conversation)))
    (json:to-json
     (json:jobject
      :model (model-for provider conversation)
      :max_tokens (or (getf parameters :max-tokens) *max-tokens*)
      :messages (map 'vector
                     (lambda (message) (encode-message provider message))
                     (conversation-messages conversation))
      :system (conversation-system conversation)
      :temperature (getf parameters :temperature)
      :top_p (getf parameters :top-p)
      :stop_sequences (when (getf parameters :stop)
                        (coerce (getf parameters :stop) 'vector))
      :tools (when tools
               (map 'vector (lambda (tool) (encode-tool provider tool)) tools))
      ;; Omitted entirely when false: jzon would emit "stream":false for NIL.
      :stream (when stream :true)))))

;;; Decoding

(defun anthropic-stop-reason (string)
  (cond ((null string) nil)
        ((string= string "end_turn") :end-turn)
        ((string= string "tool_use") :tool-use)
        ((string= string "max_tokens") :max-tokens)
        ((string= string "stop_sequence") :stop)
        (t nil)))

(defun decode-part (payload)
  (let ((type (json:jget payload "type")))
    (cond
      ((equal type "text")
       (make-text-part (or (json:jget payload "text") "")))
      ((equal type "tool_use")
       (make-tool-use-part (json:jget payload "id")
                           (json:jget payload "name")
                           (json:jget payload "input")))
      (t nil))))

(defun decode-usage (payload)
  (let ((usage (json:jget payload "usage")))
    (when usage
      (make-instance 'usage
                     :input-tokens (json:jget usage "input_tokens")
                     :output-tokens (json:jget usage "output_tokens")))))

(defmethod decode-response ((provider anthropic-provider) payload)
  (make-instance 'response
                 :content (remove nil (map 'list #'decode-part
                                           (or (json:jget payload "content") #())))
                 :stop-reason (anthropic-stop-reason (json:jget payload "stop_reason"))
                 :model (json:jget payload "model")
                 :usage (decode-usage payload)
                 :raw payload))

;;; Requesting

(defun parse-body-or-signal (body url)
  "Parse BODY as JSON, signalling LLM-PARSE-ERROR rather than letting a jzon
condition escape as something the caller cannot handle generically."
  (handler-case (json:parse body)
    (c:llm-error (e) (error e))
    (error ()
      (error 'c:llm-parse-error
             :payload (if (> (length body) 200) (subseq body 0 200) body)
             :message (format nil "Could not parse the response from ~a as JSON" url)))))

(defmethod chat-request ((provider anthropic-provider) conversation &key tools)
  (let ((url (provider-endpoint provider)))
    (multiple-value-bind (body status)
        (request-with-retry url
                            :method :post
                            :headers (provider-headers provider)
                            :content (encode-request provider conversation
                                                     :tools tools))
      (declare (ignore status))
      (decode-response provider (parse-body-or-signal body url)))))
```

`encode-tool` is defined in Task 12; until then `:tools` is always `nil`, so
the `(when tools ...)` branch never runs and the file compiles with a
style-warning for the undefined function. That is expected.

- [ ] **Step 4: Add the module and export `*max-tokens*`**

In `cl-llm.asd`, after the `src` module's `(:file "protocol")`, the `src` module components become:

```lisp
                :components ((:file "packages")
                             (:file "conditions")
                             (:file "json")
                             (:file "sse")
                             (:file "http")
                             (:file "retry")
                             (:file "core")
                             (:file "protocol")
                             (:module "providers"
                              :components ((:file "anthropic"))))
```

In `src/packages.lisp`, add `#:*max-tokens*` to the `cl-llm` `:export` list.
`cl-llm/tests` gains `(:file "anthropic")` at the end.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 12 Anthropic tests green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/providers/anthropic.lisp tests/anthropic.lisp
git commit -m "feat: Anthropic provider with encode, decode, and chat-request"
```

---

Continue with Tasks 10–15 in `docs/superpowers/plans/2026-07-17-cl-llm-core-part-3.md`.
