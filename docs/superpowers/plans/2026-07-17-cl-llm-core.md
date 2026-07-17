# cl-llm Core Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the cl-llm core client — chat, streaming, and tool use against Anthropic and OpenAI-compatible endpoints.

**Architecture:** Five layers, bottom-up: portability wrappers (`cl-llm.json`, `cl-llm.http`, `cl-llm.sse`) isolate Dexador/jzon; a CLOS core defines messages/conversations/responses/tools/providers; generic functions form the provider protocol; two providers implement it; a functional facade (`ask`/`send`) with special variables sits on top. No threads anywhere, so ECL and CCL stay viable.

**Tech Stack:** SBCL (first target), ASDF, Dexador, com.inuoe.jzon, FiveAM, uiop.

**Spec:** `docs/superpowers/specs/2026-07-17-cl-llm-design.md`

**Scope:** This plan covers the core client only. The `cl-llm/eval` harness is Plan 2 and depends on this plan being complete.

## Global Constraints

- **Lisp sources use spaces only, never tabs.** Tab-width-8 assumption for any converted material.
- **No threads anywhere.** No `bordeaux-threads`, no `sb-thread`. This is what keeps ECL (including thread-less builds) and CCL viable.
- SBCL is the only CI target for v1; do not use SBCL-only symbols outside the portability wrappers.
- License: MIT. Test framework: FiveAM.
- Dependencies are limited to: `dexador`, `com.inuoe.jzon`, `uiop`, and `fiveam` (test only). Do not add others.
- Default `*max-tool-turns*` is **8**. Default `*max-tokens*` is **4096** (Anthropic requires it).
- API keys are read from the environment and **must never** appear in condition reports, logs, or fixtures.
- `asdf:test-system :cl-llm` must pass **offline, with no API key set**.

## Verified library facts (do not re-derive)

These were confirmed by evaluation against the installed libraries. Several are counterintuitive; the `cl-llm.json` wrapper exists precisely to contain them.

| Fact | Consequence |
|------|-------------|
| `(jzon:parse "null")` → the symbol **`cl:null`** | Must normalize to `nil` on parse |
| **`(jzon:stringify nil)` → `"false"`** | A nil-valued optional param would emit `"temperature": false`. `jobject` must **omit** nil keys |
| `(jzon:stringify t)` → `"true"` | Use `t`/`nil` only for real booleans |
| `(jzon:stringify :foo)` → `"\"FOO\""` (uppercased) | Never pass keywords as JSON values |
| `jzon:parse` returns `hash-table` (test `equal`, string keys); arrays → `simple-vector` | `jget` handles both |
| `dex:request` signals `dex:http-request-failed` on non-2xx, with readers `dex:response-status`, `dex:response-body`, `dex:response-headers` | Driver catches and returns values; the layer above signals `llm-*` |
| `dex:request` accepts `:want-stream`, `:read-timeout`, `:connect-timeout`, `:force-string` | Streaming and timeouts are supported |

---

### Task 1: Project skeleton and green test harness

**Files:**
- Create: `cl-llm.asd`, `src/packages.lisp`, `LICENSE`, `README.md`
- Test: `tests/packages.lisp`, `tests/suite.lisp`

**Interfaces:**
- Consumes: nothing.
- Produces: ASDF systems `cl-llm` and `cl-llm/tests`; packages `cl-llm.json`, `cl-llm.http`, `cl-llm.sse`, `cl-llm.conditions`, `cl-llm`, `cl-llm.test`; FiveAM suite named `cl-llm-suite`.

- [ ] **Step 1: Write the ASDF system definition**

Create `cl-llm.asd`:

```lisp
;;;; cl-llm.asd

(defsystem "cl-llm"
  :description "Common Lisp library for interacting with and tuning LLMs"
  :author "Kevin Raison"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("dexador" "com.inuoe.jzon" "uiop")
  :serial t
  :components ((:module "src"
                :components ((:file "packages"))))
  :in-order-to ((test-op (test-op "cl-llm/tests"))))

(defsystem "cl-llm/tests"
  :description "Offline test suite for cl-llm"
  :license "MIT"
  :depends-on ("cl-llm" "fiveam")
  :serial t
  :components ((:module "tests"
                :components ((:file "packages")
                             (:file "suite"))))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! (find-symbol* :cl-llm-suite :cl-llm.test))
               (error "cl-llm test suite failed."))))
```

- [ ] **Step 2: Write the package definitions**

Create `src/packages.lisp`:

```lisp
;;;; packages.lisp -- package definitions for cl-llm

(defpackage #:cl-llm.conditions
  (:use #:cl)
  (:export #:llm-error
           #:llm-http-error
           #:llm-api-error
           #:llm-rate-limit-error
           #:llm-auth-error
           #:llm-timeout-error
           #:llm-parse-error
           #:llm-tool-error
           #:llm-error-status
           #:llm-error-body
           #:llm-error-url
           #:llm-error-code
           #:llm-error-type
           #:llm-error-message
           #:llm-error-retry-after
           #:llm-error-payload
           #:llm-error-tool-name
           #:llm-error-underlying))

(defpackage #:cl-llm.json
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:parse
           #:to-json
           #:jget
           #:jobject
           #:jarray))

(defpackage #:cl-llm.sse
  (:use #:cl)
  (:export #:sse-event
           #:sse-event-p
           #:make-sse-event
           #:sse-event-type
           #:sse-event-data
           #:read-event))

(defpackage #:cl-llm.http
  (:use #:cl)
  (:local-nicknames (#:c #:cl-llm.conditions))
  (:export #:driver
           #:dexador-driver
           #:*driver*
           #:perform-request
           #:perform-stream-request))

(defpackage #:cl-llm
  (:use #:cl)
  (:local-nicknames (#:json #:cl-llm.json)
                    (#:http #:cl-llm.http)
                    (#:sse #:cl-llm.sse)
                    (#:c #:cl-llm.conditions))
  (:export
   ;; conditions (re-exported from cl-llm.conditions)
   #:llm-error #:llm-http-error #:llm-api-error #:llm-rate-limit-error
   #:llm-auth-error #:llm-timeout-error #:llm-parse-error #:llm-tool-error
   #:llm-error-status #:llm-error-body #:llm-error-url #:llm-error-code
   #:llm-error-type #:llm-error-message #:llm-error-retry-after
   #:llm-error-payload #:llm-error-tool-name #:llm-error-underlying))
```

Note: `cl-llm`'s export list grows in later tasks. Only the conditions are exported now.

- [ ] **Step 3: Write the test packages and suite**

Create `tests/packages.lisp`:

```lisp
;;;; tests/packages.lisp

(defpackage #:cl-llm.test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:json #:cl-llm.json)
                    (#:http #:cl-llm.http)
                    (#:sse #:cl-llm.sse)
                    (#:c #:cl-llm.conditions)
                    (#:llm #:cl-llm))
  (:export #:cl-llm-suite))
```

Create `tests/suite.lisp`:

```lisp
;;;; tests/suite.lisp

(in-package #:cl-llm.test)

(def-suite cl-llm-suite
  :description "All offline tests for cl-llm.")

(in-suite cl-llm-suite)

(test harness-is-wired
  "The suite runs and packages are loadable."
  (is (find-package '#:cl-llm))
  (is (find-package '#:cl-llm.json)))
```

- [ ] **Step 4: Write LICENSE and README**

Create `LICENSE` with the standard MIT text, copyright line: `Copyright (c) 2026 Kevin Raison`.

Create `README.md`:

````markdown
# cl-llm

A Common Lisp library for interacting with and tuning LLMs.

Supports Anthropic and local / OpenAI-compatible endpoints. SBCL is the primary
target; ECL and Clozure are supported by construction (the library uses no
threads).

**Status:** under development. See `docs/superpowers/specs/` for the design.

## Quick start

```lisp
(ql:quickload :cl-llm)
(cl-llm:ask "Explain CLOS in one sentence")
```

## Testing

```sh
sbcl --eval '(asdf:test-system :cl-llm)'     # offline, no API key required
```

## License

MIT
````

- [ ] **Step 5: Run the test suite to verify it passes**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FiveAM prints `Did 2 checks ... Pass: 2 (100%)` and the process exits 0.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/ tests/ LICENSE README.md
git commit -m "feat: project skeleton with green FiveAM harness"
```

---

### Task 2: JSON wrapper (`cl-llm.json`)

**Files:**
- Create: `src/json.lisp`
- Modify: `cl-llm.asd` (add `(:file "json")` after `packages`)
- Test: `tests/json.lisp` (add `(:file "json")` to the `cl-llm/tests` components)

**Interfaces:**
- Consumes: package `cl-llm.json` from Task 1.
- Produces:
  - `(json:parse string-or-stream)` → hash-table/vector/atom, with JSON `null` normalized to `nil`
  - `(json:to-json value &key pretty)` → string
  - `(json:jobject &rest plist)` → hash-table, **omitting nil-valued keys**; keyword keys are downcased with `-` → `_`; string keys pass through verbatim; `:true`/`:false` produce real booleans
  - `(json:jget object &rest keys)` → chained lookup through hash-tables (string keys) and vectors (integer indices), `nil` on any miss
  - `(json:jarray &rest elements)` → simple-vector

- [ ] **Step 1: Write the failing tests**

Create `tests/json.lisp`:

```lisp
;;;; tests/json.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test json-parse-normalizes-null
  "JSON null must read as NIL, not the CL:NULL symbol jzon returns."
  (let ((h (json:parse "{\"a\":null,\"b\":1}")))
    (is (null (gethash "a" h)))
    (is (= 1 (gethash "b" h)))))

(test json-parse-normalizes-nested-null
  "Normalization must reach into nested objects and arrays."
  (let ((h (json:parse "{\"a\":{\"b\":null},\"c\":[null,2]}")))
    (is (null (json:jget h "a" "b")))
    (is (null (json:jget h "c" 0)))
    (is (= 2 (json:jget h "c" 1)))))

(test json-parse-booleans
  (let ((h (json:parse "{\"t\":true,\"f\":false}")))
    (is (eq t (gethash "t" h)))
    (is (null (gethash "f" h)))))

(test jobject-omits-nil-values
  "A nil value must be omitted entirely, NOT emitted as false."
  (let ((s (json:to-json (json:jobject :model "m" :temperature nil))))
    (is (string= "{\"model\":\"m\"}" s))))

(test jobject-converts-keyword-keys
  (let ((s (json:to-json (json:jobject :max-tokens 5))))
    (is (string= "{\"max_tokens\":5}" s))))

(test jobject-passes-string-keys-verbatim
  (let ((s (json:to-json (json:jobject "node-id" "n1"))))
    (is (string= "{\"node-id\":\"n1\"}" s))))

(test jobject-explicit-booleans
  (let ((s (json:to-json (json:jobject :stream :false :echo :true))))
    (is (string= "{\"stream\":false,\"echo\":true}" s))))

(test jget-chains-and-misses
  (let ((h (json:parse "{\"content\":[{\"text\":\"hi\"}]}")))
    (is (string= "hi" (json:jget h "content" 0 "text")))
    (is (null (json:jget h "content" 9 "text")))
    (is (null (json:jget h "nope" "deeper")))))

(test jarray-builds-vector
  (is (string= "[1,2]" (json:to-json (json:jarray 1 2)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — the build errors because `src/json.lisp` does not exist yet (after you add it to the `.asd` in Step 3), or `json:parse` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/json.lisp`:

```lisp
;;;; json.lisp -- the only file that knows about jzon.
;;;;
;;;; jzon has three behaviours that will silently corrupt requests if used
;;;; directly, so they are contained here:
;;;;   1. JSON null parses to the symbol CL:NULL, not NIL.
;;;;   2. (stringify nil) emits "false", not "null" -- so a nil-valued optional
;;;;      parameter would be sent as an explicit false.
;;;;   3. Keywords stringify uppercased (:foo => "FOO").

(in-package #:cl-llm.json)

(defun normalize (value)
  "Recursively replace JSON null (the symbol CL:NULL) with NIL.
JSON false also reads as NIL, so the two are indistinguishable after parsing.
That is acceptable for provider responses and is the documented behaviour."
  (cond
    ((eq value 'null) nil)
    ((hash-table-p value)
     (let ((new (make-hash-table :test 'equal :size (hash-table-count value))))
       (maphash (lambda (k v) (setf (gethash k new) (normalize v))) value)
       new))
    ((and (vectorp value) (not (stringp value)))
     (map 'vector #'normalize value))
    (t value)))

(defun parse (input)
  "Parse INPUT (a string or character stream) into hash-tables and vectors.
JSON null is normalized to NIL."
  (normalize (jzon:parse input)))

(defun to-json (value &key pretty)
  "Serialize VALUE to a JSON string."
  (jzon:stringify value :stream nil :pretty pretty))

(defun jkey (key)
  "Convert KEY to a JSON object key.
Strings pass through verbatim. Symbols and keywords are downcased and have
hyphens converted to underscores, so :MAX-TOKENS becomes \"max_tokens\"."
  (if (stringp key)
      key
      (substitute #\_ #\- (string-downcase (string key)))))

(defun jvalue (value)
  "Convert VALUE to something jzon will serialize correctly.
:TRUE and :FALSE become real JSON booleans; every other keyword is an error,
because jzon would silently uppercase it."
  (case value
    (:true t)
    (:false nil)
    (t (if (keywordp value)
           (error "Cannot serialize keyword ~s as a JSON value; jzon would ~
                   uppercase it. Pass a string, or :TRUE/:FALSE for booleans."
                  value)
           value))))

(defun jobject (&rest plist)
  "Build a JSON object from PLIST, OMITTING any key whose value is NIL.
Omission (rather than emitting null) is what optional API parameters require.
Use :TRUE or :FALSE for an explicit boolean."
  (let ((object (make-hash-table :test 'equal)))
    (loop for (key value) on plist by #'cddr
          unless (null value)
            do (setf (gethash (jkey key) object) (jvalue value)))
    object))

(defun jarray (&rest elements)
  "Build a JSON array from ELEMENTS."
  (map 'vector #'jvalue elements))

(defun jget (object &rest keys)
  "Look up a chained path through OBJECT.
String keys index hash-tables; integers index vectors. Returns NIL if any step
misses, so (jget response \"content\" 0 \"text\") is safe on any shape."
  (let ((current object))
    (dolist (key keys current)
      (setf current
            (cond
              ((null current) (return nil))
              ((hash-table-p current) (gethash (jkey key) current))
              ((and (vectorp current) (not (stringp current)) (integerp key))
               (when (< -1 key (length current))
                 (aref current key)))
              (t (return nil)))))))
```

- [ ] **Step 4: Add the files to the ASDF systems**

In `cl-llm.asd`, change the `cl-llm` src module components to:

```lisp
                :components ((:file "packages")
                             (:file "json"))
```

and the `cl-llm/tests` tests module components to:

```lisp
                :components ((:file "packages")
                             (:file "suite")
                             (:file "json"))
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all json tests green, `Pass: 13 (100%)`.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/json.lisp tests/json.lisp
git commit -m "feat: JSON wrapper isolating jzon null/false/keyword gotchas"
```

---

### Task 3: Condition hierarchy

**Files:**
- Create: `src/conditions.lisp`
- Modify: `cl-llm.asd` (add `(:file "conditions")` after `packages`, before `json`)
- Test: `tests/conditions.lisp`

**Interfaces:**
- Consumes: package `cl-llm.conditions` from Task 1.
- Produces: conditions `llm-error`, `llm-http-error` (`llm-error-status`, `llm-error-body`, `llm-error-url`), `llm-api-error` (`llm-error-code`, `llm-error-type`, `llm-error-message`), `llm-rate-limit-error` (`llm-error-retry-after`), `llm-auth-error`, `llm-timeout-error`, `llm-parse-error` (`llm-error-payload`), `llm-tool-error` (`llm-error-tool-name`, `llm-error-underlying`).

- [ ] **Step 1: Write the failing tests**

Create `tests/conditions.lisp`:

```lisp
;;;; tests/conditions.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test conditions-hierarchy
  "Every condition must be reachable as an LLM-ERROR."
  (dolist (type '(c:llm-http-error c:llm-api-error c:llm-rate-limit-error
                  c:llm-auth-error c:llm-timeout-error c:llm-parse-error
                  c:llm-tool-error))
    (is (subtypep type 'c:llm-error)
        "~a should be a subtype of llm-error" type))
  (is (subtypep 'c:llm-rate-limit-error 'c:llm-api-error))
  (is (subtypep 'c:llm-auth-error 'c:llm-api-error))
  (is (subtypep 'c:llm-api-error 'c:llm-http-error)))

(test conditions-readers
  (let ((e (make-condition 'c:llm-rate-limit-error
                           :status 429 :url "https://x/y" :body "{}"
                           :message "slow down" :error-type "rate_limit_error"
                           :retry-after 30)))
    (is (= 429 (c:llm-error-status e)))
    (is (string= "https://x/y" (c:llm-error-url e)))
    (is (string= "slow down" (c:llm-error-message e)))
    (is (= 30 (c:llm-error-retry-after e)))))

(test conditions-report-is-readable-and-leaks-no-secrets
  "The report must be human-readable and must never include headers."
  (let ((text (princ-to-string
               (make-condition 'c:llm-api-error
                               :status 400 :url "https://api.anthropic.com/v1/messages"
                               :message "bad request" :error-type "invalid_request_error"))))
    (is (search "400" text))
    (is (search "bad request" text))
    (is (not (search "sk-ant" text)))))

(test conditions-tool-error
  (let ((e (make-condition 'c:llm-tool-error :tool-name "get-weather"
                                             :underlying "boom")))
    (is (string= "get-weather" (c:llm-error-tool-name e)))
    (is (search "get-weather" (princ-to-string e)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `llm-error` is not a defined condition type.

- [ ] **Step 3: Write the implementation**

Create `src/conditions.lisp`:

```lisp
;;;; conditions.lisp -- the cl-llm condition hierarchy.
;;;;
;;;; Reports must never include request headers: that is where API keys live.

(in-package #:cl-llm.conditions)

(define-condition llm-error (error)
  ()
  (:documentation "Base class for every error signalled by cl-llm."))

(define-condition llm-http-error (llm-error)
  ((status :initarg :status :initform nil :reader llm-error-status)
   (body :initarg :body :initform nil :reader llm-error-body)
   (url :initarg :url :initform nil :reader llm-error-url))
  (:report (lambda (condition stream)
             (format stream "LLM HTTP error~@[ ~a~]~@[ from ~a~]~@[: ~a~]"
                     (llm-error-status condition)
                     (llm-error-url condition)
                     (llm-error-body condition))))
  (:documentation "A transport or status failure. BODY is the raw response."))

(define-condition llm-api-error (llm-http-error)
  ((code :initarg :code :initform nil :reader llm-error-code)
   (error-type :initarg :error-type :initform nil :reader llm-error-type)
   (message :initarg :message :initform nil :reader llm-error-message))
  (:report (lambda (condition stream)
             (format stream "LLM API error~@[ ~a~]~@[ (~a)~]~@[ from ~a~]~@[: ~a~]"
                     (llm-error-status condition)
                     (llm-error-type condition)
                     (llm-error-url condition)
                     (llm-error-message condition))))
  (:documentation "A structured provider-level error, decoded from the body."))

(define-condition llm-rate-limit-error (llm-api-error)
  ((retry-after :initarg :retry-after :initform nil :reader llm-error-retry-after))
  (:documentation "HTTP 429. RETRY-AFTER is seconds, from the header, or NIL."))

(define-condition llm-auth-error (llm-api-error)
  ()
  (:documentation "HTTP 401/403 -- missing or invalid credentials."))

(define-condition llm-timeout-error (llm-error)
  ((url :initarg :url :initform nil :reader llm-error-url))
  (:report (lambda (condition stream)
             (format stream "LLM request timed out~@[ for ~a~]"
                     (llm-error-url condition))))
  (:documentation "The request exceeded the timeout."))

(define-condition llm-parse-error (llm-error)
  ((payload :initarg :payload :initform nil :reader llm-error-payload)
   (message :initarg :message :initform nil :reader llm-error-message))
  (:report (lambda (condition stream)
             (format stream "LLM parse error~@[: ~a~]~@[ in ~s~]"
                     (llm-error-message condition)
                     (llm-error-payload condition))))
  (:documentation "A malformed response body or SSE payload."))

(define-condition llm-tool-error (llm-error)
  ((tool-name :initarg :tool-name :initform nil :reader llm-error-tool-name)
   (underlying :initarg :underlying :initform nil :reader llm-error-underlying))
  (:report (lambda (condition stream)
             (format stream "Tool ~a signalled an error~@[: ~a~]"
                     (llm-error-tool-name condition)
                     (llm-error-underlying condition))))
  (:documentation "A tool function signalled during the tool loop."))
```

- [ ] **Step 4: Add the files to the ASDF systems**

In `cl-llm.asd`, the `cl-llm` src module components become:

```lisp
                :components ((:file "packages")
                             (:file "conditions")
                             (:file "json"))
```

and the tests module components:

```lisp
                :components ((:file "packages")
                             (:file "suite")
                             (:file "json")
                             (:file "conditions"))
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all condition tests green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/conditions.lisp tests/conditions.lisp
git commit -m "feat: condition hierarchy rooted at llm-error"
```

---

### Task 4: SSE parser (`cl-llm.sse`)

**Files:**
- Create: `src/sse.lisp`
- Modify: `cl-llm.asd` (add `(:file "sse")` after `json`)
- Test: `tests/sse.lisp`

**Interfaces:**
- Consumes: package `cl-llm.sse` from Task 1.
- Produces:
  - struct `sse-event` with `sse-event-type` (string or `nil`) and `sse-event-data` (string)
  - `(sse:read-event stream)` → an `sse-event`, or `nil` at end of stream

This is pure parsing over a character stream — no HTTP, no threads. It is fully testable against `with-input-from-string`, which is why it is its own task.

- [ ] **Step 1: Write the failing tests**

Create `tests/sse.lisp`:

```lisp
;;;; tests/sse.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun read-all-events (text)
  (with-input-from-string (s text)
    (loop for event = (sse:read-event s)
          while event
          collect event)))

(test sse-reads-single-event
  (let ((events (read-all-events
                 (format nil "event: content_block_delta~%data: {\"a\":1}~%~%"))))
    (is (= 1 (length events)))
    (is (string= "content_block_delta" (sse:sse-event-type (first events))))
    (is (string= "{\"a\":1}" (sse:sse-event-data (first events))))))

(test sse-reads-multiple-events
  (let ((events (read-all-events
                 (format nil "event: a~%data: 1~%~%event: b~%data: 2~%~%"))))
    (is (= 2 (length events)))
    (is (string= "b" (sse:sse-event-type (second events))))
    (is (string= "2" (sse:sse-event-data (second events))))))

(test sse-joins-multiple-data-lines
  "Per the SSE spec, repeated data: lines are joined with newlines."
  (let ((events (read-all-events (format nil "data: one~%data: two~%~%"))))
    (is (string= (format nil "one~%two") (sse:sse-event-data (first events))))))

(test sse-handles-crlf
  "Servers may send CRLF; the trailing CR must not end up in the data."
  (let ((events (read-all-events
                 (format nil "event: a~C~%data: 1~C~%~C~%" #\Return #\Return #\Return))))
    (is (= 1 (length events)))
    (is (string= "a" (sse:sse-event-type (first events))))
    (is (string= "1" (sse:sse-event-data (first events))))))

(test sse-ignores-comments-and-blank-padding
  (let ((events (read-all-events
                 (format nil "~%: this is a ping comment~%data: 1~%~%"))))
    (is (= 1 (length events)))
    (is (string= "1" (sse:sse-event-data (first events))))))

(test sse-tolerates-missing-space-after-colon
  (let ((events (read-all-events (format nil "event:a~%data:1~%~%"))))
    (is (string= "a" (sse:sse-event-type (first events))))
    (is (string= "1" (sse:sse-event-data (first events))))))

(test sse-event-without-event-field
  "OpenAI-compatible servers send bare data: lines with no event: field."
  (let ((events (read-all-events (format nil "data: [DONE]~%~%"))))
    (is (null (sse:sse-event-type (first events))))
    (is (string= "[DONE]" (sse:sse-event-data (first events))))))

(test sse-returns-nil-at-end-of-stream
  (with-input-from-string (s "")
    (is (null (sse:read-event s)))))

(test sse-final-event-without-trailing-blank-line
  "A truncated final event must still be returned rather than dropped."
  (let ((events (read-all-events (format nil "data: 1~%"))))
    (is (= 1 (length events)))
    (is (string= "1" (sse:sse-event-data (first events))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `sse:read-event` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/sse.lisp`:

```lisp
;;;; sse.lisp -- Server-Sent Events parsing.
;;;;
;;;; Pure parsing over a character stream: no HTTP, no threads. READ-EVENT
;;;; blocks on the stream and returns exactly one event, which is what makes
;;;; the pull-based streaming API possible without threads.

(in-package #:cl-llm.sse)

(defstruct (sse-event (:constructor make-sse-event (type data)))
  "One Server-Sent Event. TYPE is the event: field (a string) or NIL when the
server sent none. DATA is the concatenated data: field content."
  (type nil :type (or null string))
  (data "" :type string))

(defun strip-cr (line)
  "Remove a trailing carriage return left by READ-LINE on CRLF input."
  (let ((length (length line)))
    (if (and (plusp length) (char= #\Return (char line (1- length))))
        (subseq line 0 (1- length))
        line)))

(defun field-value (line prefix-length)
  "Extract a field value from LINE, skipping PREFIX-LENGTH characters and one
optional leading space."
  (let ((value (subseq line prefix-length)))
    (if (and (plusp (length value)) (char= #\Space (char value 0)))
        (subseq value 1)
        value)))

(defun prefixp (prefix line)
  (and (>= (length line) (length prefix))
       (string= prefix line :end2 (length prefix))))

(defun read-event (stream)
  "Read one Server-Sent Event from STREAM, blocking until it is complete.
Returns an SSE-EVENT, or NIL at end of stream. Blank lines before an event and
lines beginning with a colon (comments, used as keep-alive pings) are ignored."
  (let ((event-type nil)
        (data-lines '())
        (started nil))
    (flet ((finish ()
             (make-sse-event
              event-type
              (format nil "~{~a~^~%~}" (nreverse data-lines)))))
      (loop
        (let ((line (read-line stream nil nil)))
          (cond
            ;; End of stream: emit a truncated final event rather than lose it.
            ((null line)
             (return (when started (finish))))
            (t
             (let ((line (strip-cr line)))
               (cond
                 ((string= line "")
                  (when started (return (finish))))
                 ((prefixp ":" line))          ; comment / ping -- ignore
                 ((prefixp "data:" line)
                  (setf started t)
                  (push (field-value line 5) data-lines))
                 ((prefixp "event:" line)
                  (setf started t)
                  (setf event-type (field-value line 6)))
                 (t))))))))))          ; unknown field -- ignore per spec
```

- [ ] **Step 4: Add the files to the ASDF systems**

In `cl-llm.asd`, the `cl-llm` src module components become:

```lisp
                :components ((:file "packages")
                             (:file "conditions")
                             (:file "json")
                             (:file "sse"))
```

and the tests module gains `(:file "sse")` after `"conditions"`.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 9 SSE tests green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/sse.lisp tests/sse.lisp
git commit -m "feat: thread-free SSE parser"
```

---

## Remaining tasks

Tasks 5–15 are specified in the continuation document:
`docs/superpowers/plans/2026-07-17-cl-llm-core-part-2.md`

- Task 5: HTTP driver protocol + Dexador driver + fake driver
- Task 6: Retry, backoff, and the `retry-request` restart
- Task 7: Core CLOS objects (content parts, message, conversation, response, usage)
- Task 8: Provider classes and protocol generic functions
- Task 9: Anthropic provider — encode/decode, `chat-request`
- Task 10: Facade — `ask`, `send`, `make-conversation`, special variables
- Task 11: Streaming — `streamed-response`, `next-delta`, `with-streamed-response`, `do-deltas`
- Task 12: `deftool` and typed lambda-list schema derivation
- Task 13: Bounded tool loop
- Task 14: OpenAI-compatible provider
- Task 15: Live suite (`cl-llm/live`), CI, and README
