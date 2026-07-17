# cl-llm/eval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `cl-llm/eval` — the dataset × variants × scorers evaluation harness — plus a `mock-provider` in the core for deterministic offline testing.

**Architecture:** A `mock-provider` (a real provider subclass returning scripted responses, no HTTP) goes into the core `cl-llm` package. A separate `cl-llm/eval` ASDF system, package `cl-llm.eval`, builds the grid bottom-up: score → case → scorer → judge → suite → run → report. `run-suite` maps the cross product through a rebindable `*eval-map*` (default serial), calls `ask` per cell, and records a failing call as an error cell rather than aborting.

**Tech Stack:** SBCL, ASDF, com.inuoe.jzon (already a dep, used by the mock's stream path), FiveAM, uiop.

**Spec:** `docs/superpowers/specs/2026-07-17-cl-llm-eval-design.md`

**Scope:** the evaluation harness only. Non-goals (persisted history, regression detection, report export) are out.

## Global Constraints

- **Lisp sources use spaces only, never tabs.** Tab-width-8 for any converted material.
- **No threads.** Eval's concurrency story is the `*eval-map*` seam, not a threading dependency. No `bordeaux-threads`, no `sb-thread`.
- SBCL is the CI target; no SBCL-only symbols anywhere in this plan.
- Dependencies: the core's four (`dexador`, `com.inuoe.jzon`, `uiop`, `fiveam` test-only). `cl-llm/eval` depends on `cl-llm`; `cl-llm/eval/tests` on `cl-llm/eval` + `fiveam`. Add nothing else.
- License: MIT. Test framework: FiveAM.
- `asdf:test-system :cl-llm/eval` must pass **offline, with no API key set**.
- The existing offline suites must stay green: `asdf:test-system :cl-llm` is currently **394 checks**; the mock-provider work adds to it.
- Every `:module` form carries `:serial t` (existing project convention).
- Prefer the **public `llm:` package nickname** in tests over internal nicknames — a Critical bug hid for 8 core tasks because tests used an internal nickname and never exercised the public surface.

## Verified core API (do not re-derive)

Confirmed by evaluation against the loaded `cl-llm`:

| Fact | Use |
|------|-----|
| `chat-request (provider conversation &key tools)` — a generic function | Mock specializes it on `mock-provider` |
| `stream-request (provider conversation &key tools)` — a generic function | Mock specializes it; must return an open character stream of SSE text |
| `ask (prompt &key provider model temperature max-tokens top-p stop system tools max-tool-turns)` | `run-suite` calls this per cell; variant plist supplies the keys |
| `response` slots: `content stop-reason model usage raw` | `(make-instance 'response :content (list part) :stop-reason :end-turn)` |
| `make-text-part`, `response-text`, `make-message`, `response-message` exist | Mock wraps a string; `run-suite` reads `response-text` |
| `parse-stream-event (provider event)` is dispatched per provider | Mock needs its own method for its stream path |
| `cl-llm:llm-error` is a real re-exported condition (core Task 8 fix) | `llm-eval-error` subclasses it |
| `provider` base class has a `base-url` slot with a reader and NO initform | Mock must not read `base-url`; it never does |

---

### Task 1: `mock-provider` in the core

**Files:**
- Create: `src/mock.lisp`, `tests/mock.lisp`
- Modify: `cl-llm.asd` (add `(:file "mock")` to the `cl-llm` src module after `streaming`, and `(:file "mock")` to the `cl-llm/tests` module), `src/packages.lisp` (export three symbols)

**Interfaces:**
- Consumes: `provider`, `chat-request`, `stream-request`, `parse-stream-event`, `response`, `make-text-part`, `make-message`, `json:to-json`/`json:jobject`/`json:jget`, `sse:sse-event-data` — all from `cl-llm`.
- Produces (exported from `cl-llm`):
  - class `mock-provider`
  - `(make-mock-provider &key responder model)` → a `mock-provider`. `responder` is `(conversation) → string-or-response`.
  - reader `mock-provider-responder`
  - method `chat-request` on `mock-provider`: calls the responder; a string result is wrapped in `(make-instance 'response :content (list (make-text-part string)) :stop-reason :end-turn)`; a `response` result is returned as-is.
  - method `stream-request` on `mock-provider`: returns a string-input-stream of a two-event SSE body encoding the responder's text (see code), consumable by the existing streaming machinery.
  - method `parse-stream-event` on `mock-provider`: `[DONE]` → `:done`; else a `{"text":...}` data line → `(values :text <text>)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/mock.lisp`:

```lisp
;;;; tests/mock.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test mock-provider-chat-request-wraps-a-string
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "scripted reply"))))
    (multiple-value-bind (text response) (llm:ask "anything")
      (is (string= "scripted reply" text))
      (is (typep response 'llm:response))
      (is (eq :end-turn (llm:response-stop-reason response))))))

(test mock-provider-responder-sees-the-conversation
  (let* ((seen nil)
         (llm:*provider*
           (llm:make-mock-provider
            :responder (lambda (conversation)
                         (setf seen conversation)
                         "ok"))))
    (llm:ask "the prompt text")
    (is (typep seen 'llm:conversation))
    (is (string= "the prompt text"
                 (llm:part-text
                  (first (llm:message-content
                          (first (llm:conversation-messages seen)))))))))

(test mock-provider-responder-can-return-a-full-response
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (make-instance 'llm:response
                                       :content (list (llm:make-text-part "built"))
                                       :stop-reason :max-tokens)))))
    (multiple-value-bind (text response) (llm:ask "x")
      (is (string= "built" text))
      (is (eq :max-tokens (llm:response-stop-reason response))))))

(test mock-provider-responder-can-signal
  "A responder may signal to simulate an API failure; the signal propagates."
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (error 'llm:llm-api-error :status 500 :message "boom")))))
    (signals llm:llm-api-error (llm:ask "x"))))

(test mock-provider-streaming-yields-the-text
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "streamed hello"))))
    (llm:with-streamed-response (r "hi")
      (let ((collected '()))
        (llm:do-deltas (d r) (push d collected))
        (is (string= "streamed hello"
                     (apply #'concatenate 'string (nreverse collected))))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: FAIL — `llm:make-mock-provider` is undefined.

- [ ] **Step 3: Write the implementation**

Create `src/mock.lisp`:

```lisp
;;;; mock.lisp -- a provider that returns scripted responses with no HTTP.
;;;;
;;;; Placed in the core (not eval) because it makes the whole library testable
;;;; by its users, not only by cl-llm's own suite. The evaluation harness
;;;; consumes it; so can anyone writing tests against cl-llm.

(in-package #:cl-llm)

(defclass mock-provider (provider)
  ((responder :initarg :responder :reader mock-provider-responder
              :documentation "A function of the outgoing CONVERSATION returning
either a string (becomes the assistant text) or a fully-formed RESPONSE."))
  (:documentation "A provider that scripts responses instead of making requests."))

(defun make-mock-provider (&key responder model)
  "Make a mock provider. RESPONDER is (conversation) -> string-or-response.
MODEL is accepted for symmetry with real providers and is otherwise unused."
  (make-instance 'mock-provider :responder responder :model model))

(defun mock-response (result)
  "Normalize a responder RESULT (a string or a RESPONSE) into a RESPONSE."
  (etypecase result
    (response result)
    (string (make-instance 'response
                           :content (list (make-text-part result))
                           :stop-reason :end-turn))))

(defmethod chat-request ((provider mock-provider) conversation &key tools)
  (declare (ignore tools))
  (mock-response (funcall (mock-provider-responder provider) conversation)))

(defmethod stream-request ((provider mock-provider) conversation &key tools)
  (declare (ignore tools))
  ;; Encode the scripted text as a tiny two-event SSE body the mock's own
  ;; PARSE-STREAM-EVENT understands. JSON-encoding the text keeps multi-line
  ;; text from breaking SSE line framing.
  (let* ((response (mock-response
                    (funcall (mock-provider-responder provider) conversation)))
         (text (response-text response)))
    (make-string-input-stream
     (format nil "data: ~a~%~%data: [DONE]~%~%"
             (json:to-json (json:jobject :text text))))))

(defmethod parse-stream-event ((provider mock-provider) event)
  (let ((data (sse:sse-event-data event)))
    (if (string= data "[DONE]")
        (values :done nil)
        (values :text (json:jget (json:parse data) "text")))))
```

- [ ] **Step 4: Wire the ASDF systems and exports**

In `cl-llm.asd`, add `(:file "mock")` to the `cl-llm` system's `src` module **after `streaming`** (and after `tool-loop` if present — order among leaf files after streaming does not matter, but keep it last for clarity), and add `(:file "mock")` to the `cl-llm/tests` module (after `streaming`, before `tool-loop`/`openai` is fine; place it last for clarity).

In `src/packages.lisp`, add to the `cl-llm` package's `:export` list:

```lisp
   #:mock-provider #:make-mock-provider #:mock-provider-responder
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm)'
```

Expected: PASS — all 5 mock tests green; the pre-existing suite still passes.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd src/packages.lisp src/mock.lisp tests/mock.lisp
git commit -m "feat: mock-provider for deterministic offline testing"
```

---

### Task 2: `cl-llm/eval` system skeleton and green harness

**Files:**
- Create: `eval/packages.lisp`, `tests-eval/packages.lisp`, `tests-eval/suite.lisp`
- Modify: `cl-llm.asd` (add the `cl-llm/eval` and `cl-llm/eval/tests` systems)

Note on directory names: the eval **source** lives in `eval/`, the eval **tests** in `tests-eval/` to avoid colliding with the core's `tests/`. An ASDF module containing only `packages.lisp` is loadable, so no placeholder source file is needed — later tasks add their files to the module.

**Interfaces:**
- Consumes: `cl-llm` (the whole package).
- Produces: ASDF systems `cl-llm/eval` and `cl-llm/eval/tests`; package `cl-llm.eval` (empty exports for now, filled by later tasks); package `cl-llm.eval.test`; FiveAM suite `cl-llm-eval-suite`.

- [ ] **Step 1: Write the package for eval**

Create `eval/packages.lisp`:

```lisp
;;;; eval/packages.lisp

(defpackage #:cl-llm.eval
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions))
  (:export
   ;; grows in later tasks
   ))
```

- [ ] **Step 2: Write the eval test harness**

Create `tests-eval/packages.lisp`:

```lisp
;;;; tests-eval/packages.lisp

(defpackage #:cl-llm.eval.test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:eval #:cl-llm.eval)
                    (#:c #:cl-llm.conditions))
  (:export #:cl-llm-eval-suite))
```

Create `tests-eval/suite.lisp`:

```lisp
;;;; tests-eval/suite.lisp

(in-package #:cl-llm.eval.test)

(def-suite cl-llm-eval-suite
  :description "All offline tests for cl-llm/eval.")

(in-suite cl-llm-eval-suite)

(test eval-harness-is-wired
  "The eval suite runs and its packages are loadable."
  (is (find-package '#:cl-llm.eval))
  (is (find-package '#:cl-llm)))
```

- [ ] **Step 3: Add the ASDF systems**

Append to `cl-llm.asd`:

```lisp
(defsystem "cl-llm/eval"
  :description "Evaluation harness for cl-llm: dataset x variants x scorers."
  :license "MIT"
  :depends-on ("cl-llm")
  :serial t
  :components ((:module "eval"
                :serial t
                :components ((:file "packages"))))
  :in-order-to ((test-op (test-op "cl-llm/eval/tests"))))

(defsystem "cl-llm/eval/tests"
  :description "Offline test suite for cl-llm/eval."
  :license "MIT"
  :depends-on ("cl-llm/eval" "fiveam")
  :serial t
  :components ((:module "tests-eval"
                :serial t
                :components ((:file "packages")
                             (:file "suite"))))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run!
                                  (find-symbol* :cl-llm-eval-suite :cl-llm.eval.test))
               (error "cl-llm/eval test suite failed."))))
```

- [ ] **Step 4: Run the eval suite to verify it passes**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: FiveAM prints `Pass: 2 (100%)` and the process exits 0.

- [ ] **Step 5: Commit**

```bash
git add cl-llm.asd eval/ tests-eval/
git commit -m "feat: cl-llm/eval system skeleton with green harness"
```

---

### Task 3: `score` and `llm-eval-error`

**Files:**
- Create: `eval/score.lisp`, add `(:file "score")` to the `cl-llm/eval` eval module (after `packages`)
- Test: `tests-eval/score.lisp` (add `(:file "score")` to the tests-eval module)
- Modify: `eval/packages.lisp` (export `score`, `make-score`, `score-value`, `score-explanation`, `llm-eval-error`; note the constructor is exported as `score` per the spec's `(score value &key explanation)`)

**Interfaces:**
- Consumes: `cl-llm:llm-error`.
- Produces (exported from `cl-llm.eval`):
  - condition `llm-eval-error` (subtype of `cl-llm:llm-error`), with a `message` initarg and reader `eval-error-message`, and a readable report.
  - struct `score` (predicate `score-p`) with readers `score-value`, `score-explanation`.
  - `(score value &key explanation)` → a `score`. A real `value` is **clamped** to `[0,1]`; a non-real signals `llm-eval-error`.

Note: the constructor function is named `score`, distinct from the struct type also named `score` — a function and a type may share a name in CL. Define the struct with `(:constructor %make-score)` and a separate `score` function so the clamping lives in one place.

- [ ] **Step 1: Write the failing tests**

Create `tests-eval/score.lisp`:

```lisp
;;;; tests-eval/score.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(test score-basic
  (let ((s (eval:score 0.8 :explanation "good enough")))
    (is (= 0.8 (eval:score-value s)))
    (is (string= "good enough" (eval:score-explanation s)))))

(test score-explanation-defaults-to-nil
  (is (null (eval:score-explanation (eval:score 1.0)))))

(test score-clamps-above-one
  (is (= 1.0 (eval:score-value (eval:score 1.7)))))

(test score-clamps-below-zero
  (is (= 0.0 (eval:score-value (eval:score -0.5)))))

(test score-keeps-in-range-values
  (is (= 0.0 (eval:score-value (eval:score 0.0))))
  (is (= 0.5 (eval:score-value (eval:score 1/2))))
  (is (= 1.0 (eval:score-value (eval:score 1)))))

(test score-non-real-signals-eval-error
  (signals eval:llm-eval-error (eval:score "not a number"))
  (signals eval:llm-eval-error (eval:score nil)))

(test llm-eval-error-is-an-llm-error
  (is (subtypep 'eval:llm-eval-error 'c:llm-error)))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: FAIL — `eval:score` is undefined.

- [ ] **Step 3: Write the implementation**

Create `eval/score.lisp`:

```lisp
;;;; eval/score.lisp -- the score value type and the harness-error condition.

(in-package #:cl-llm.eval)

(define-condition llm-eval-error (c:llm-error)
  ((message :initarg :message :initform nil :reader eval-error-message))
  (:report (lambda (condition stream)
             (format stream "cl-llm/eval error~@[: ~a~]"
                     (eval-error-message condition))))
  (:documentation "A harness misuse: a bad score value, a missing expected
answer, an unknown suite or scorer, or a malformed variant."))

(defstruct (score (:constructor %make-score (value explanation)))
  "One scorer's verdict: a numeric VALUE in [0,1] and an optional EXPLANATION."
  (value 0.0 :type real)
  (explanation nil :type (or null string)))

(defun score (value &key explanation)
  "Make a SCORE. A real VALUE is clamped to [0,1]; a non-real signals
LLM-EVAL-ERROR (that is a programming mistake, not noisy model output)."
  (unless (realp value)
    (error 'llm-eval-error
           :message (format nil "score value must be a real, got ~s" value)))
  (%make-score (max 0 (min 1 value)) explanation))
```

- [ ] **Step 4: Export and wire up**

In `eval/packages.lisp`, add to the `cl-llm.eval` `:export` list:

```lisp
   #:score #:score-p #:score-value #:score-explanation
   #:llm-eval-error #:eval-error-message
```

In `cl-llm.asd`, the `cl-llm/eval` eval module components become
`packages, score`; `cl-llm/eval/tests` tests-eval module gains
`(:file "score")` after `suite`.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: PASS — all 7 score tests green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd eval/packages.lisp eval/score.lisp tests-eval/score.lisp
git commit -m "feat: eval score type and llm-eval-error"
```

---

### Task 4: `eval-case` and scorers (`defscorer`, `exact-match`)

**Files:**
- Create: `eval/case.lisp`, `eval/scorer.lisp`
- Modify: `cl-llm.asd` (add `case` and `scorer` to the eval module after `score`), `eval/packages.lisp`
- Test: `tests-eval/scorer.lisp`

**Interfaces:**
- Consumes: `score`, `llm-eval-error` (Task 3); `cl-llm:response-text`.
- Produces (exported from `cl-llm.eval`):
  - struct `eval-case` with readers `case-input`, `case-expected`, `case-metadata`; `(make-case input &key expected metadata)`.
  - class/struct `scorer` with readers `scorer-name` (string), `scorer-function`; `*scorers-registry*` (a hash-table, string → scorer, internal).
  - `(register-scorer scorer)`, `(find-scorer designator)` — resolves a `scorer`, a symbol, or a string to a `scorer`; signals `llm-eval-error` if unknown.
  - macro `(defscorer name (case response) &body body)` — defines `name` as a function and registers a scorer. `body` returns a `score`.
  - `(run-scorer scorer case response)` → `score`.
  - built-in scorer `exact-match`: `1.0` when `(response-text response)` `string=` `(case-expected case)`, else `0.0` with an explanation; signals `llm-eval-error` if the case has no `expected`; a `nil` response scores `0.0` with an explanation.

- [ ] **Step 1: Write the failing tests**

Create `tests-eval/scorer.lisp`:

```lisp
;;;; tests-eval/scorer.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(defun response-with-text (text)
  (make-instance 'llm:response :content (list (llm:make-text-part text))))

(test make-case-fields
  (let ((c (eval:make-case "in" :expected "out" :metadata '(:tag 1))))
    (is (string= "in" (eval:case-input c)))
    (is (string= "out" (eval:case-expected c)))
    (is (equal '(:tag 1) (eval:case-metadata c)))))

(test make-case-optional-fields-default-nil
  (let ((c (eval:make-case "in")))
    (is (null (eval:case-expected c)))
    (is (null (eval:case-metadata c)))))

(test exact-match-scores-1-on-match
  (let ((s (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                            (eval:make-case "q" :expected "hello")
                            (response-with-text "hello"))))
    (is (= 1.0 (eval:score-value s)))))

(test exact-match-scores-0-on-mismatch
  (let ((s (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                            (eval:make-case "q" :expected "hello")
                            (response-with-text "goodbye"))))
    (is (= 0.0 (eval:score-value s)))
    (is (stringp (eval:score-explanation s)))))

(test exact-match-requires-expected
  (signals eval:llm-eval-error
    (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                     (eval:make-case "q")
                     (response-with-text "x"))))

(test exact-match-nil-response-scores-0
  (let ((s (eval:run-scorer (eval:find-scorer 'eval:exact-match)
                            (eval:make-case "q" :expected "hello")
                            nil)))
    (is (= 0.0 (eval:score-value s)))))

(test defscorer-defines-and-registers
  (eval:defscorer contains-hi (case response)
    "Score 1.0 if the response text contains 'hi'."
    (declare (ignore case))
    (if (and response (search "hi" (llm:response-text response)))
        (eval:score 1.0)
        (eval:score 0.0 :explanation "no 'hi'")))
  (let ((scorer (eval:find-scorer 'contains-hi)))
    (is (string= "contains-hi" (eval:scorer-name scorer)))
    (is (= 1.0 (eval:score-value
                (eval:run-scorer scorer (eval:make-case "q")
                                 (response-with-text "oh hi there")))))))

(test find-scorer-accepts-symbol-string-object
  (let ((scorer (eval:find-scorer 'eval:exact-match)))
    (is (eq scorer (eval:find-scorer "exact-match")))
    (is (eq scorer (eval:find-scorer scorer)))))

(test find-scorer-unknown-signals
  (signals eval:llm-eval-error (eval:find-scorer 'no-such-scorer)))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: FAIL — `eval:make-case` is undefined.

- [ ] **Step 3: Write `eval/case.lisp`**

```lisp
;;;; eval/case.lisp -- an evaluation case.

(in-package #:cl-llm.eval)

(defstruct (eval-case (:constructor %make-eval-case (input expected metadata)))
  "One evaluation case: an INPUT (usually a prompt string), an optional
EXPECTED reference answer, and optional METADATA (a plist of user tags)."
  (input nil)
  (expected nil)
  (metadata nil :type list))

(defun make-case (input &key expected metadata)
  "Make an EVAL-CASE. A dataset is simply a list of these."
  (%make-eval-case input expected metadata))

(defun case-input (case) (eval-case-input case))
(defun case-expected (case) (eval-case-expected case))
(defun case-metadata (case) (eval-case-metadata case))
```

- [ ] **Step 4: Write `eval/scorer.lisp`**

```lisp
;;;; eval/scorer.lisp -- scorers: named (case response) -> score functions.

(in-package #:cl-llm.eval)

(defclass scorer ()
  ((name :initarg :name :reader scorer-name :type string)
   (function :initarg :function :reader scorer-function))
  (:documentation "A named scoring function of (case response) -> SCORE."))

(defvar *scorers-registry* (make-hash-table :test 'equal)
  "Maps scorer name (string) to SCORER.")

(defun register-scorer (scorer)
  (setf (gethash (scorer-name scorer) *scorers-registry*) scorer))

(defun find-scorer (designator)
  "Resolve DESIGNATOR -- a SCORER, symbol, or string -- to a SCORER."
  (etypecase designator
    (scorer designator)
    ((or symbol string)
     (let ((name (string-downcase (string designator))))
       (or (gethash name *scorers-registry*)
           (error 'llm-eval-error
                  :message (format nil "no scorer named ~s; define it with defscorer"
                                   name)))))))

(defun run-scorer (scorer case response)
  "Run SCORER on CASE and RESPONSE (which may be NIL for an error cell)."
  (funcall (scorer-function scorer) case response))

(defmacro defscorer (name (case response) &body body)
  "Define NAME as a function AND register it as a scorer. BODY returns a SCORE.
CASE is the EVAL-CASE; RESPONSE is the cl-llm RESPONSE, or NIL for an error
cell -- BODY must tolerate a NIL response."
  `(progn
     (defun ,name (,case ,response) ,@body)
     (register-scorer (make-instance 'scorer
                                     :name ,(string-downcase (string name))
                                     :function #',name))
     ',name))

(defscorer exact-match (case response)
  "Score 1.0 when the response text exactly equals the case's expected answer."
  (unless (case-expected case)
    (error 'llm-eval-error
           :message "exact-match needs a case with an :expected answer"))
  (cond
    ((null response) (score 0.0 :explanation "no response (error cell)"))
    ((string= (llm:response-text response) (case-expected case)) (score 1.0))
    (t (score 0.0 :explanation
              (format nil "expected ~s, got ~s"
                      (case-expected case) (llm:response-text response))))))
```

- [ ] **Step 5: Export and wire up**

In `eval/packages.lisp`, add:

```lisp
   #:eval-case #:make-case #:case-input #:case-expected #:case-metadata
   #:scorer #:scorer-name #:scorer-function #:defscorer
   #:register-scorer #:find-scorer #:run-scorer #:exact-match
```

In `cl-llm.asd`, the eval module components become
`packages, score, case, scorer`; tests-eval gains `(:file "scorer")`.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: PASS — all scorer tests green.

- [ ] **Step 7: Commit**

```bash
git add cl-llm.asd eval/packages.lisp eval/case.lisp eval/scorer.lisp tests-eval/scorer.lisp
git commit -m "feat: eval-case and scorers with defscorer and exact-match"
```

---

### Task 5: `defjudge` and the judge-reply parser

**Files:**
- Create: `eval/judge.lisp`
- Modify: `cl-llm.asd` (add `judge` to the eval module after `scorer`), `eval/packages.lisp`
- Test: `tests-eval/judge.lisp`

**Interfaces:**
- Consumes: `score`, `defscorer`/`register-scorer`/`scorer` (Task 4), `cl-llm:ask`.
- Produces (exported from `cl-llm.eval`):
  - `(parse-judge-score text)` → `(values value-or-nil rationale)`: extracts the first number in `text`; a number in `[0,1]` is taken as-is, a number in `(1,100]` is divided by 100; returns `nil` when no number is found. `rationale` is `text` with the leading number stripped.
  - macro `(defjudge name (case response) &body body)` — `body` returns the **judge prompt string**. Expands to a scorer that calls `(ask <prompt>)`, parses the reply, and returns a `score`. An unparseable reply → `(score 0.0 :explanation "unparseable judge output: <first 120 chars>")`. A signalled `llm-error` inside the judge call → `(score 0.0 :explanation <condition>)`, never propagated.

- [ ] **Step 1: Write the failing tests**

Create `tests-eval/judge.lisp`:

```lisp
;;;; tests-eval/judge.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(test parse-judge-score-fraction
  (multiple-value-bind (value rationale) (eval:parse-judge-score "0.8 fluent and clear")
    (is (= 0.8 value))
    (is (search "fluent" rationale))))

(test parse-judge-score-percentage
  (is (= 0.9 (eval:parse-judge-score "90 - strong answer"))))

(test parse-judge-score-hundred
  (is (= 1.0 (eval:parse-judge-score "100"))))

(test parse-judge-score-unparseable
  (is (null (eval:parse-judge-score "no number here"))))

(test defjudge-uses-the-mock-and-scores
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "0.75 the answer is mostly right"))))
    (eval:defjudge judge-quality (case response)
      (declare (ignore response))
      (format nil "Grade the answer to: ~a" (eval:case-input case)))
    (let ((s (eval:run-scorer (eval:find-scorer 'judge-quality)
                              (eval:make-case "2+2?")
                              (response-with-text "4"))))
      (is (= 0.75 (eval:score-value s)))
      (is (search "mostly right" (eval:score-explanation s))))))

(test defjudge-unparseable-reply-scores-0
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "I cannot grade this"))))
    (eval:defjudge judge-garbage (case response)
      (declare (ignore case response))
      "grade it")
    (let ((s (eval:run-scorer (eval:find-scorer 'judge-garbage)
                              (eval:make-case "q")
                              (response-with-text "a"))))
      (is (= 0.0 (eval:score-value s)))
      (is (search "unparseable" (eval:score-explanation s))))))

(test defjudge-swallows-llm-error
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (error 'llm:llm-api-error :status 500 :message "judge down")))))
    (eval:defjudge judge-failing (case response)
      (declare (ignore case response))
      "grade it")
    (let ((s (eval:run-scorer (eval:find-scorer 'judge-failing)
                              (eval:make-case "q")
                              (response-with-text "a"))))
      (is (= 0.0 (eval:score-value s)))
      (is (stringp (eval:score-explanation s))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: FAIL — `eval:parse-judge-score` is undefined.

- [ ] **Step 3: Write the implementation**

Create `eval/judge.lisp`:

```lisp
;;;; eval/judge.lisp -- LLM-as-judge scorers.
;;;;
;;;; A judge is a scorer that itself calls the model. defjudge's BODY returns
;;;; the judge PROMPT (unlike defscorer, whose body returns a SCORE); the
;;;; machinery does the ask + parse. That asymmetry is what makes a judge one
;;;; form instead of ten.

(in-package #:cl-llm.eval)

(defun number-bounds (text)
  "Return (values START END) of the first numeric token in TEXT, or NIL."
  (let ((start (position-if (lambda (ch) (or (digit-char-p ch) (char= ch #\.))) text)))
    (when start
      (let ((end (or (position-if-not
                      (lambda (ch) (or (digit-char-p ch) (char= ch #\.)))
                      text :start start)
                     (length text))))
        (values start end)))))

(defun parse-judge-score (text)
  "Extract a score in [0,1] from a judge's reply TEXT.
Returns (values VALUE RATIONALE). A number in [0,1] is taken as-is; a number in
(1,100] is divided by 100. VALUE is NIL when no number is found."
  (multiple-value-bind (start end) (number-bounds text)
    (if (null start)
        (values nil text)
        (let ((number (ignore-errors (read-from-string (subseq text start end)))))
          (if (realp number)
              (values (max 0 (min 1 (if (> number 1) (/ number 100.0) number)))
                      (string-trim " -:.," (concatenate 'string
                                                        (subseq text 0 start)
                                                        (subseq text end))))
              (values nil text))))))

(defun %split-body-declarations (body)
  "Split a macro BODY into (values DECLARATIONS FORMS): leading (declare ...)
forms, then the rest. Lets DEFJUDGE hoist a body's `(declare (ignore ...))` to
the generated function's head, where an ignore is actually honored."
  (loop for tail on body
        for form = (car tail)
        while (and (consp form) (eq (car form) 'declare))
        collect form into decls
        finally (return (values decls tail))))

(defun %score-judge-reply (prompt)
  "Ask PROMPT, parse a [0,1] score from the reply, and return a SCORE.
An unparseable reply, or a signalled llm-error during the call, yields a 0.0
score with an explanation -- a judge misfire never sinks a run."
  (handler-case
      (let ((reply (llm:ask prompt)))
        (multiple-value-bind (value rationale) (parse-judge-score reply)
          (if value
              (score value :explanation rationale)
              (score 0.0 :explanation
                     (format nil "unparseable judge output: ~a"
                             (subseq reply 0 (min 120 (length reply))))))))
    (c:llm-error (e)
      (score 0.0 :explanation (format nil "judge call failed: ~a" e)))))

(defmacro defjudge (name (case response) &body body)
  "Define an LLM-as-judge scorer NAME. BODY returns the judge PROMPT string.
The scorer calls (ask <prompt>), parses a [0,1] score and rationale from the
reply, and returns a SCORE.

Leading declarations in BODY are hoisted to the generated scorer function's
head, so a body that does not use CASE or RESPONSE may `(declare (ignore ...))`
them without a warning. The remaining forms are pure expressions whose last
value is the prompt."
  (multiple-value-bind (declarations forms) (%split-body-declarations body)
    `(defscorer ,name (,case ,response)
       ,@declarations
       (%score-judge-reply (progn ,@forms)))))
```

Note: the leading `(declare ...)` forms land at the head of the `defun` that
`defscorer` generates, which is where `ignore` is honored; the prompt-computing
`forms` are pure expressions, so wrapping them in `(progn ...)` is legal (a
`declare` inside `progn` would be an error, which is exactly why the split is
needed). This was verified by compiling the expansion — no warning, correct
prompt value.

- [ ] **Step 4: Export and wire up**

In `eval/packages.lisp`, add:

```lisp
   #:defjudge #:parse-judge-score
```

In `cl-llm.asd`, the eval module components become
`packages, score, case, scorer, judge`; `cl-llm/eval/tests` tests-eval module
gains `(:file "judge")`.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: PASS — all judge tests green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd eval/packages.lisp eval/judge.lisp tests-eval/judge.lisp
git commit -m "feat: defjudge and the judge-reply parser"
```

---

### Task 6: variants, `suite`, `defsuite`

**Files:**
- Create: `eval/suite.lisp`
- Modify: `cl-llm.asd` (add `(:file "suite")` to the eval module after `judge`), `eval/packages.lisp`
- Test: `tests-eval/suite.lisp` (extend — it currently only has the harness test)

**Interfaces:**
- Consumes: `find-scorer` (Task 4).
- Produces (exported from `cl-llm.eval`):
  - struct `variant` with readers `variant-label` (string), `variant-args` (plist forwarded to `ask`), `variant-prompt-fn` ((case) → prompt string).
  - `(parse-variant plist)` → a `variant`: strips `:label` and `:prompt-fn` from `plist`; the remainder is `variant-args`; `:prompt-fn` defaults to `#'case-input`; `:label` defaults to a compact rendering of the args.
  - struct `suite` with readers `suite-name` (string), `suite-dataset-fn` (a thunk returning the dataset list), `suite-variants` (list of `variant`), `suite-scorers` (list of `scorer`); `*suites-registry*` (internal), `register-suite`, `(find-suite designator)`.
  - macro `(defsuite name &key dataset variants scorers)` — registers a suite. `dataset` is an unevaluated form wrapped in a thunk (evaluated at run time). `variants` is a list of plists. `scorers` is a list of scorer designators, resolved at define time.

- [ ] **Step 1: Write the failing tests**

Replace `tests-eval/suite.lisp` with (keeping the harness test):

```lisp
;;;; tests-eval/suite.lisp

(in-package #:cl-llm.eval.test)

(def-suite cl-llm-eval-suite
  :description "All offline tests for cl-llm/eval.")

(in-suite cl-llm-eval-suite)

(test eval-harness-is-wired
  (is (find-package '#:cl-llm.eval))
  (is (find-package '#:cl-llm)))

(test parse-variant-splits-args-from-eval-keys
  (let ((v (eval:parse-variant '(:model "m" :temperature 0.2 :label "cold"))))
    (is (string= "cold" (eval:variant-label v)))
    (is (equal '(:model "m" :temperature 0.2) (eval:variant-args v)))))

(test parse-variant-prompt-fn-defaults-to-case-input
  (let ((v (eval:parse-variant '(:model "m"))))
    (is (string= "hi" (funcall (eval:variant-prompt-fn v) (eval:make-case "hi"))))))

(test parse-variant-custom-prompt-fn
  (let ((v (eval:parse-variant
            (list :model "m"
                  :prompt-fn (lambda (c) (format nil "Q: ~a" (eval:case-input c)))))))
    (is (string= "Q: hi" (funcall (eval:variant-prompt-fn v) (eval:make-case "hi"))))
    (is (null (getf (eval:variant-args v) :prompt-fn))
        ":prompt-fn must be stripped from the args forwarded to ask")))

(test parse-variant-label-defaults-to-nonempty-string
  (is (stringp (eval:variant-label (eval:parse-variant '(:model "m" :temperature 0.0))))))

(test defsuite-registers-and-resolves
  (defparameter *suite-cases* (list (eval:make-case "q" :expected "a")))
  (eval:defsuite my-suite
    :dataset *suite-cases*
    :variants ((:model "m" :temperature 0.0))
    :scorers (eval:exact-match))
  (let ((s (eval:find-suite 'my-suite)))
    (is (string= "my-suite" (eval:suite-name s)))
    (is (equal *suite-cases* (funcall (eval:suite-dataset-fn s))))
    (is (= 1 (length (eval:suite-variants s))))
    (is (= 1 (length (eval:suite-scorers s))))
    (is (string= "exact-match" (eval:scorer-name (first (eval:suite-scorers s)))))))

(test defsuite-dataset-is-evaluated-at-run-time
  "The dataset form is re-evaluated each call, so a mutated special is seen."
  (defparameter *dyn-cases* (list (eval:make-case "one")))
  (eval:defsuite dyn-suite
    :dataset *dyn-cases*
    :variants ((:model "m"))
    :scorers (eval:exact-match))
  (let ((s (eval:find-suite 'dyn-suite)))
    (is (= 1 (length (funcall (eval:suite-dataset-fn s)))))
    (setf *dyn-cases* (list (eval:make-case "one") (eval:make-case "two")))
    (is (= 2 (length (funcall (eval:suite-dataset-fn s)))))))

(test find-suite-unknown-signals
  (signals eval:llm-eval-error (eval:find-suite 'no-such-suite)))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: FAIL — `eval:parse-variant` is undefined.

- [ ] **Step 3: Write the implementation**

Create `eval/suite.lisp`:

```lisp
;;;; eval/suite.lisp -- variants and suites.

(in-package #:cl-llm.eval)

;;; Variants

(defstruct (variant (:constructor %make-variant (label args prompt-fn)))
  "One point in the grid: a LABEL, a plist of ARGS forwarded to ASK, and a
PROMPT-FN of (case) -> prompt string."
  (label "" :type string)
  (args nil :type list)
  (prompt-fn nil :type function))

(defun compact-label (args)
  "A short human label from a variant's forwarded ARGS."
  (with-output-to-string (out)
    (loop for (key value) on args by #'cddr
          for first = t then nil
          unless first do (write-string " " out)
          do (format out "~(~a~)=~a" key value))))

(defun parse-variant (plist)
  "Turn a variant PLIST into a VARIANT, stripping the eval-only keys :label and
:prompt-fn from the args forwarded to ASK."
  (let ((args '()) (label nil) (prompt-fn nil))
    (loop for (key value) on plist by #'cddr
          do (case key
               (:label (setf label value))
               (:prompt-fn (setf prompt-fn value))
               (t (setf (getf args key) value))))
    (%make-variant (or label (compact-label args))
                   args
                   (or prompt-fn #'case-input))))

;;; Suites

(defclass suite ()
  ((name :initarg :name :reader suite-name :type string)
   (dataset-fn :initarg :dataset-fn :reader suite-dataset-fn)
   (variants :initarg :variants :reader suite-variants :type list)
   (scorers :initarg :scorers :reader suite-scorers :type list))
  (:documentation "A named dataset x variants x scorers evaluation."))

(defvar *suites-registry* (make-hash-table :test 'equal)
  "Maps suite name (string) to SUITE.")

(defun register-suite (suite)
  (setf (gethash (suite-name suite) *suites-registry*) suite))

(defun find-suite (designator)
  "Resolve DESIGNATOR -- a SUITE, symbol, or string -- to a SUITE."
  (etypecase designator
    (suite designator)
    ((or symbol string)
     (let ((name (string-downcase (string designator))))
       (or (gethash name *suites-registry*)
           (error 'llm-eval-error
                  :message (format nil "no suite named ~s; define it with defsuite"
                                   name)))))))

(defmacro defsuite (name &key dataset variants scorers)
  "Register a suite NAME. DATASET is a form evaluated at run time (so it can
reference a special holding the cases). VARIANTS is a list of plists. SCORERS
is a list of scorer designators, resolved now."
  `(register-suite
    (make-instance 'suite
                   :name ,(string-downcase (string name))
                   :dataset-fn (lambda () ,dataset)
                   :variants (list ,@(mapcar (lambda (v) `(parse-variant (list ,@v)))
                                             variants))
                   :scorers (list ,@(mapcar (lambda (s) `(find-scorer ',s)) scorers)))))
```

- [ ] **Step 4: Export and wire up**

In `eval/packages.lisp`, add:

```lisp
   #:variant #:parse-variant #:variant-label #:variant-args #:variant-prompt-fn
   #:suite #:defsuite #:suite-name #:suite-dataset-fn #:suite-variants
   #:suite-scorers #:register-suite #:find-suite
```

In `cl-llm.asd`, add `(:file "suite")` to the `cl-llm/eval` eval module after
`judge`, so the components are `packages, score, case, scorer, judge, suite`.
No new `tests-eval` file is added — the suite tests extend the existing
`tests-eval/suite.lisp` (already in the tests-eval module from Task 2).

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: PASS — all suite tests green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd eval/packages.lisp eval/suite.lisp tests-eval/suite.lisp
git commit -m "feat: variants, suites, and defsuite"
```

---

### Task 7: `run-suite`, cells, and the result grid

**Files:**
- Create: `eval/run.lisp`
- Modify: `cl-llm.asd` (add `run` to the eval module after `suite`), `eval/packages.lisp`
- Test: `tests-eval/run.lisp`

**Interfaces:**
- Consumes: `find-suite`, `suite-*`, `variant-*` (Task 6); `run-scorer`, `scorer-name` (Task 4); `cl-llm:ask`, `cl-llm:*provider*`, `cl-llm:llm-error`.
- Produces (exported from `cl-llm.eval`):
  - special `*eval-map*` (default a serial `mapcar`-like `(function list) → list`).
  - struct `cell` with readers `cell-case`, `cell-variant-label`, `cell-response`, `cell-scores` (plist scorer-name → score), `cell-error` (a condition or nil).
  - `(run-suite name-or-suite &key provider)` → `suite-result`. Binds `*provider*` to `provider` for the run when given. For each (case × variant) it builds the prompt via the variant's prompt-fn, calls `ask` with the variant args, runs every scorer, and records a `cell`; a signalled `llm-error` becomes an error cell (response/scores nil, condition captured) and the run continues.
  - struct `suite-result` with readers `result-suite`, `result-cells`.
  - `(result-mean result variant-label scorer-name)` → mean `score-value` over non-error cells, or `nil` if none.
  - `(result-error-count result variant-label)` → integer.

- [ ] **Step 1: Write the failing tests**

Create `tests-eval/run.lisp`:

```lisp
;;;; tests-eval/run.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(defun echo-mock ()
  "A mock whose reply is the last user message's text."
  (llm:make-mock-provider
   :responder (lambda (conversation)
                (llm:part-text
                 (first (llm:message-content
                         (car (last (llm:conversation-messages conversation)))))))))

(test run-suite-produces-a-cell-per-case-times-variant
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite grid-suite
      :dataset (list (eval:make-case "a" :expected "a")
                     (eval:make-case "b" :expected "b"))
      :variants ((:model "m" :temperature 0.0)
                 (:model "m" :temperature 1.0))
      :scorers (eval:exact-match))
    (let ((result (eval:run-suite 'grid-suite)))
      (is (= 4 (length (eval:result-cells result)))))))

(test run-suite-scores-exact-match-with-echo
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite echo-suite
      :dataset (list (eval:make-case "hello" :expected "hello"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let ((result (eval:run-suite 'echo-suite)))
      ;; echo returns the prompt, which equals expected -> mean 1.0
      (is (= 1.0 (eval:result-mean result
                                   (eval:variant-label
                                    (first (eval:suite-variants
                                            (eval:find-suite 'echo-suite))))
                                   "exact-match"))))))

(test run-suite-uses-the-variant-prompt-fn
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite promptfn-suite
      :dataset (list (eval:make-case "world" :expected "hi world"))
      :variants ((:model "m"
                  :prompt-fn (lambda (c) (format nil "hi ~a" (eval:case-input c)))))
      :scorers (eval:exact-match))
    (let ((result (eval:run-suite 'promptfn-suite)))
      (is (= 1.0 (eval:result-mean result
                                   (eval:variant-label
                                    (first (eval:suite-variants
                                            (eval:find-suite 'promptfn-suite))))
                                   "exact-match"))))))

(test run-suite-records-error-cells-without-aborting
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (let ((prompt (llm:part-text
                                       (first (llm:message-content
                                               (car (last (llm:conversation-messages
                                                           conversation))))))))
                          (if (string= prompt "boom")
                              (error 'llm:llm-api-error :status 500 :message "down")
                              prompt))))))
    (eval:defsuite mixed-suite
      :dataset (list (eval:make-case "ok" :expected "ok")
                     (eval:make-case "boom" :expected "boom"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let* ((result (eval:run-suite 'mixed-suite))
           (label (eval:variant-label
                   (first (eval:suite-variants (eval:find-suite 'mixed-suite))))))
      (is (= 2 (length (eval:result-cells result))))
      (is (= 1 (eval:result-error-count result label)))
      ;; mean over the ONE non-error cell is 1.0, not NaN
      (is (= 1.0 (eval:result-mean result label "exact-match")))
      (is (find-if #'eval:cell-error (eval:result-cells result))))))

(test run-suite-mean-is-nil-when-all-cells-errored
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        (error 'llm:llm-api-error :status 500 :message "always")))))
    (eval:defsuite all-fail-suite
      :dataset (list (eval:make-case "x" :expected "x"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let* ((result (eval:run-suite 'all-fail-suite))
           (label (eval:variant-label
                   (first (eval:suite-variants (eval:find-suite 'all-fail-suite))))))
      (is (null (eval:result-mean result label "exact-match"))))))

(test run-suite-eval-map-is-used
  "Rebinding *eval-map* changes how the grid is traversed."
  (let ((llm:*provider* (echo-mock))
        (calls 0))
    (eval:defsuite map-suite
      :dataset (list (eval:make-case "a" :expected "a"))
      :variants ((:model "m"))
      :scorers (eval:exact-match))
    (let ((eval:*eval-map* (lambda (fn list) (incf calls) (mapcar fn list))))
      (eval:run-suite 'map-suite))
    (is (plusp calls) "*eval-map* must be the traversal seam")))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: FAIL — `eval:run-suite` is undefined.

- [ ] **Step 3: Write the implementation**

Create `eval/run.lisp`:

```lisp
;;;; eval/run.lisp -- running a suite into a result grid.

(in-package #:cl-llm.eval)

(defvar *eval-map*
  (lambda (function list) (mapcar function list))
  "How RUN-SUITE traverses the (case x variant) grid. Default is a serial
mapcar. Rebind to a parallel map (bordeaux-threads, lparallel, ...) to opt into
concurrency without eval depending on any threading library. Signature:
(function list) -> list.")

(defstruct (cell (:constructor %make-cell (case variant-label response scores error)))
  "One (case, variant) result: the CASE, the VARIANT-LABEL, the RESPONSE (or
NIL), a plist of scorer-name -> SCORE (or NIL for an error cell), and the
captured ERROR condition (or NIL)."
  (case nil)
  (variant-label "" :type string)
  (response nil)
  (scores nil :type list)
  (error nil))

(defstruct (suite-result (:constructor %make-suite-result (suite cells)))
  "The outcome of RUN-SUITE: the SUITE and a list of CELLs."
  (suite nil)
  (cells nil :type list))

(defun run-cell (variant scorers case)
  "Run one CASE through one VARIANT with SCORERS, returning a CELL."
  (let ((prompt (funcall (variant-prompt-fn variant) case)))
    (handler-case
        ;; ASK returns (values text response); we need the RESPONSE object (the
        ;; second value), not the text, since scorers take a response.
        (let ((response (nth-value 1 (apply #'llm:ask prompt (variant-args variant)))))
          (%make-cell case (variant-label variant) response
                      (loop for scorer in scorers
                            collect (scorer-name scorer)
                            collect (run-scorer scorer case response))
                      nil))
      (c:llm-error (e)
        (%make-cell case (variant-label variant) nil nil e)))))

(defun run-suite (name-or-suite &key provider)
  "Run a suite and return a SUITE-RESULT. When PROVIDER is given it is bound to
*PROVIDER* for the whole run. A cell whose ASK call signals an LLM-ERROR is
recorded as an error cell; the run continues."
  (let* ((suite (find-suite name-or-suite))
         (cl-llm:*provider* (or provider cl-llm:*provider*))
         (dataset (funcall (suite-dataset-fn suite)))
         (variants (suite-variants suite))
         (scorers (suite-scorers suite))
         ;; Build the flat grid of (variant . case) pairs, then map over it.
         (pairs (loop for variant in variants
                      nconc (loop for case in dataset
                                  collect (cons variant case)))))
    (%make-suite-result
     suite
     (funcall *eval-map*
              (lambda (pair) (run-cell (car pair) scorers (cdr pair)))
              pairs))))

(defun cell-score (cell scorer-name)
  "The SCORE for SCORER-NAME in CELL, found by STRING= (a plist keyed by
strings cannot use GETF, which compares with EQ). NIL if absent."
  (loop for (name score) on (cell-scores cell) by #'cddr
        when (string= name scorer-name) return score))

(defun result-suite (result) (suite-result-suite result))
(defun result-cells (result) (suite-result-cells result))

(defun result-mean (result variant-label scorer-name)
  "Mean SCORE-VALUE for a (VARIANT-LABEL, SCORER-NAME) pair over non-error
cells, or NIL when there are none."
  (let ((values (loop for cell in (result-cells result)
                      for score = (and (string= (cell-variant-label cell) variant-label)
                                       (null (cell-error cell))
                                       (cell-score cell scorer-name))
                      when score collect (score-value score))))
    (when values
      (/ (reduce #'+ values) (length values)))))

(defun result-error-count (result variant-label)
  "Number of error cells for VARIANT-LABEL."
  (count-if (lambda (cell) (and (string= (cell-variant-label cell) variant-label)
                                (cell-error cell)))
            (result-cells result)))
```

Note: `cell-scores` is a plist keyed by scorer-name **strings**, so lookups use
`string=` via the `cell-score` helper — `getf` compares keys with `eq` and would
silently miss an equal-but-not-`eq` string. Export `cell-score` too, since the
report task (Task 8) reuses it.

- [ ] **Step 4: Export and wire up**

In `eval/packages.lisp`, add:

```lisp
   #:*eval-map* #:run-suite
   #:cell #:cell-case #:cell-variant-label #:cell-response #:cell-scores
   #:cell-error #:cell-score
   #:suite-result #:result-suite #:result-cells #:result-mean #:result-error-count
```

In `cl-llm.asd`, the eval module components become
`packages, score, case, scorer, judge, suite, run`; tests-eval gains `(:file "run")`.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: PASS — all run tests green.

- [ ] **Step 6: Commit**

```bash
git add cl-llm.asd eval/packages.lisp eval/run.lisp tests-eval/run.lisp
git commit -m "feat: run-suite, result cells, and aggregate means"
```

---

### Task 8: display — `print-object` and `report`

**Files:**
- Create: `eval/report.lisp`
- Modify: `cl-llm.asd` (add `report` to the eval module after `run`), `eval/packages.lisp`
- Test: `tests-eval/report.lisp`

**Interfaces:**
- Consumes: `suite-result`, `result-*`, `cell-*`, `suite-*`, `variant-label`, `scorer-name` (Tasks 6–7).
- Produces (exported from `cl-llm.eval`):
  - a `print-object` method for `suite-result` rendering the summary table (variants as rows, scorers as columns, cells = mean, a trailing `errors` column when any cell errored). `—` for a nil mean.
  - `(report result &key (detail nil) (stream *standard-output*))` — prints the summary table and, with `detail`, a per-case breakdown showing each scorer's value and explanation. Returns `result`.

- [ ] **Step 1: Write the failing tests**

Create `tests-eval/report.lisp`:

```lisp
;;;; tests-eval/report.lisp

(in-package #:cl-llm.eval.test)

(in-suite cl-llm-eval-suite)

(defun run-tiny-suite ()
  (let ((llm:*provider* (echo-mock)))
    (eval:defsuite report-suite
      :dataset (list (eval:make-case "hi" :expected "hi")
                     (eval:make-case "yo" :expected "NOPE"))
      :variants ((:model "m" :temperature 0.0 :label "cold"))
      :scorers (eval:exact-match))
    (eval:run-suite 'report-suite)))

(test print-object-renders-a-table
  (let ((text (princ-to-string (run-tiny-suite))))
    (is (search "cold" text) "variant label appears")
    (is (search "exact-match" text) "scorer column appears")))

(test report-returns-the-result
  (let ((result (run-tiny-suite)))
    (is (eq result (eval:report result :stream (make-broadcast-stream))))))

(test report-detail-shows-explanations
  (let* ((result (run-tiny-suite))
         (text (with-output-to-string (s)
                 (eval:report result :detail t :stream s))))
    ;; the mismatching case's explanation mentions the expected value
    (is (search "NOPE" text) "detail shows the expected value from the explanation")))

(test report-summary-shows-mean
  (let* ((result (run-tiny-suite))
         (text (with-output-to-string (s)
                 (eval:report result :stream s))))
    ;; one match out of two -> mean 0.5 appears in some rendering
    (is (or (search "0.5" text) (search "0.50" text)))))

(test print-object-shows-dash-for-nil-mean
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (c) (declare (ignore c))
                        (error 'llm:llm-api-error :status 500 :message "x")))))
    (eval:defsuite dash-suite
      :dataset (list (eval:make-case "x" :expected "x"))
      :variants ((:model "m" :label "v"))
      :scorers (eval:exact-match))
    (let ((text (princ-to-string (eval:run-suite 'dash-suite))))
      (is (search "—" text) "a nil mean renders as an em dash"))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: FAIL — no `print-object` table / `report` undefined.

- [ ] **Step 3: Write the implementation**

Create `eval/report.lisp`:

```lisp
;;;; eval/report.lisp -- text rendering of a suite result.

(in-package #:cl-llm.eval)

(defun variant-labels (result)
  "Distinct variant labels in the RESULT, in first-seen order."
  (let ((seen '()))
    (dolist (cell (result-cells result) (nreverse seen))
      (pushnew (cell-variant-label cell) seen :test #'string=))))

(defun scorer-names (result)
  "The RESULT's suite's scorer names, in order."
  (mapcar #'scorer-name (suite-scorers (result-suite result))))

(defun format-mean (mean)
  (if mean (format nil "~,2f" mean) "—"))

(defun any-errors-p (result)
  (some #'cell-error (result-cells result)))

(defun render-summary (result stream)
  "Render the summary table: variants x scorers, cells = mean."
  (let* ((labels (variant-labels result))
         (scorers (scorer-names result))
         (errors-p (any-errors-p result))
         (label-width (reduce #'max labels :key #'length
                                            :initial-value (length "variant"))))
    (format stream "~&~va" label-width "variant")
    (dolist (name scorers) (format stream "  ~10a" name))
    (when errors-p (format stream "  ~6a" "errors"))
    (terpri stream)
    (dolist (label labels)
      (format stream "~va" label-width label)
      (dolist (name scorers)
        (format stream "  ~10a" (format-mean (result-mean result label name))))
      (when errors-p
        (format stream "  ~6d" (result-error-count result label)))
      (terpri stream))))

(defmethod print-object ((result suite-result) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (result stream :type t)
        (format stream "~a~%" (suite-name (result-suite result)))
        (render-summary result stream))))

(defun render-detail (result stream)
  "Per-case breakdown: each cell's scores and explanations."
  (format stream "~&~%Detail:~%")
  (dolist (cell (result-cells result))
    (format stream "~&[~a] input=~s"
            (cell-variant-label cell) (case-input (cell-case cell)))
    (if (cell-error cell)
        (format stream "  ERROR: ~a~%" (cell-error cell))
        (progn
          (terpri stream)
          (loop for (name score) on (cell-scores cell) by #'cddr
                do (format stream "    ~a: ~,2f~@[  (~a)~]~%"
                           name (score-value score) (score-explanation score)))))))

(defun report (result &key (detail nil) (stream *standard-output*))
  "Print RESULT's summary table to STREAM. With DETAIL, also print a per-case
breakdown including each scorer's explanation. Returns RESULT."
  (render-summary result stream)
  (when detail (render-detail result stream))
  result)
```

- [ ] **Step 4: Export and wire up**

In `eval/packages.lisp`, add:

```lisp
   #:report
```

In `cl-llm.asd`, the eval module components become
`packages, score, case, scorer, judge, suite, run, report`; tests-eval gains
`(:file "report")`.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd /Users/kraison/work/cl-llm && sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(asdf:test-system :cl-llm/eval)'
```

Expected: PASS — all report tests green, entire eval suite green.

- [ ] **Step 6: Update the README and commit**

Add a short "Evaluation" section to `README.md` after the Tools section, showing a `defsuite`/`run-suite`/`report` example and noting `cl-llm/eval` is a separate system tested offline via `mock-provider`. Then:

```bash
git add cl-llm.asd eval/packages.lisp eval/report.lisp tests-eval/report.lisp README.md
git commit -m "feat: eval result table and report; document the harness"
```

---

## Definition of done

- `asdf:test-system :cl-llm/eval` passes offline with no API key.
- `asdf:test-system :cl-llm` still passes (mock-provider added).
- `defsuite` + `run-suite` + `report` work end-to-end against a `mock-provider`,
  covering the cross product, `exact-match`, a custom `defscorer`, a `defjudge`
  (gradeable, unparseable, and failing-call paths), error cells, aggregate
  means (including the all-errored → nil case), and the table + detail report.
- No threads anywhere; `*eval-map*` is the only concurrency seam.
- The core gains a reusable `mock-provider`, exported and documented.
