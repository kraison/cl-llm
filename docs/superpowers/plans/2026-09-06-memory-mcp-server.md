# The Memory as Its Own MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** cl-llm's agent-memory tools are served to any MCP client from this repo, in a solo stdio process or from a listener inside the memory image, with a shutdown that leaves the store clean.

**Architecture:** A new system `cl-llm/agent/mcp` on the `cl-mcp` protocol library: `make-memory-server` turns the tool objects from `make-agent-tools` into `cl-mcp` tool registrations (schema converted, arguments converted back, refusals as `isError`); a config layer maps the environment to a scope opened on one clock and closed bounded; an identity layer reads a principals file and a hello line; a listener runs one server per accepted connection. Two scripts (solo server, stdio relay) and the memory image use them.

**Tech Stack:** Common Lisp (SBCL), `cl-mcp` (+ `yason`, `bordeaux-threads`, `opsis/conditions`), `usocket`, vivace-graph `experiment` >= cde8a23, FiveAM.

**Spec:** `docs/superpowers/specs/2026-09-06-memory-mcp-server-design.md` (amended 0d890f9). Verified facts and the corrections the spec was amended for: `docs/superpowers/notes/2026-09-06-memory-mcp-engine-api-facts.md` (§C, §S). Authority: spec > this plan's rulings > the recon note > task text.

## Global Constraints

- Worktree: `/home/raison/work/cl-llm/.worktrees/memory-mcp` (branch `feat/memory-mcp` from `main` 93ff6d0). Never build, edit or commit in `/home/raison/work/cl-llm` or `/home/raison/work/vivace-graph-v3`; never `cd` into them. The engine is a clean clone at `/tmp/claude-1000/-home-raison-work-cl-llm/8235f26d-9ab1-4573-b1ef-c3408365e71c/scratchpad/vg-experiment` (`experiment` cde8a23); `cl-mcp` is `/home/raison/work/cl-mcp` (read-only); `opsis` is `~/quicklisp/local-projects/opsis/`.
- Lisp: spaces only, never tabs; hard 80-column limit on every line of `.lisp` and `.asd` files, docstrings and comments included; terse comments pointing at the spec (`SS5`), the recon (`recon C3`) or #57. Shell scripts: 80 columns where practical.
- Never run `pkill`, `pgrep -f`, or `kill` on anything you did not start in the current test; the tests in Task 4 signal only their own child processes. One SBCL build at a time in this worktree.
- Suites, foreground, one at a time, with the registry lines first in every run:

  ```
  cd /home/raison/work/cl-llm/.worktrees/memory-mcp
  sbcl --dynamic-space-size 4096 --non-interactive \
    --eval '(push #p"/tmp/claude-1000/-home-raison-work-cl-llm/8235f26d-9ab1-4573-b1ef-c3408365e71c/scratchpad/vg-experiment/" asdf:*central-registry*)' \
    --eval '(push #p"/home/raison/work/cl-mcp/" asdf:*central-registry*)' \
    --eval '(push #p"/home/raison/work/cl-llm/.worktrees/memory-mcp/" asdf:*central-registry*)' \
    --eval '(ql:quickload :cl-llm/agent/mcp/tests :silent t)' \
    --eval '(asdf:test-system :cl-llm/agent/mcp)'
  ```

  Then `:cl-llm/memory/tests` + `(asdf:test-system :cl-llm/memory)` and `:cl-llm/agent/tests` + `(asdf:test-system :cl-llm/agent)` (baselines at 93ff6d0: memory 453, agent 269, 0 failures). Read `Did N checks.` and record the counts. One test alone: the same registry and quickload lines, then `--eval '(fiveam:run! (quote cl-llm.agent.mcp/tests::TEST-NAME))'`.
- Test package `cl-llm.agent.mcp/tests` (Task 1 creates it) imports `with-stores`, `%belief`, `+p+`, `+subj+` from `cl-llm.agent/tests` (internal symbols; `:import-from` takes them). `with-stores (w p)` gives two clocked stores, `w` named `:cl-llm-memory`, `p` named `:memory-private`, each fixture use adding 2 checks.
- `cl-mcp` decodes objects as string-keyed alists, arrays as lists, `null`/`false` as NIL (recon E1); `required` must be a LIST (recon C1); a handler's second value `t` is `isError` (recon E3); `read-message`/`write-message` live in `cl-mcp.transport`; a test playing client uses `cl-mcp.json-rpc:make-request` + `cl-mcp.client:encode-request` to write and `cl-mcp.client:parse-client-message` to read (recon C6). Read `/home/raison/work/cl-mcp/src/client/protocol.lisp` for the response accessors before writing `%rpc`.
- Every negative test names its mechanism in its docstring and has a control in the same test. Existing tests keep passing; `tests-memory/golden/` unchanged.
- Docs travel with code (Task 5). Nothing is pushed without Kevin. Commit trailers, both lines, on every commit:

  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU
  ```

- Close #57 by hand with the merge SHA; a merge never auto-closes.

## Rulings taken while planning

1. **The child process finds its systems through `CL_LLM_ASDF_REGISTRY`**, a colon-separated list of directories the solo script pushes onto `asdf:*central-registry*` before loading. The tests set it from `asdf:system-source-directory` of the systems the test image loaded, so the child builds against the same engine and library as the test, on this host and in CI alike. Without it the child would load whatever Quicklisp's local-projects holds. Cost if wrong: one environment variable.
2. **The query tool is reached by name**, `(uiop:symbol-call :cl-llm.agent.prolog :make-query-tool ...)`, so `cl-llm/agent/mcp` does not depend on `cl-llm/agent/prolog`; the scripts quickload it when `CL_LLM_MEMORY_QUERY_TOOL=1`. Cost: one clear error when it is asked for and not loaded.
3. **`close-graph :snapshot-p nil` in the memory image too** (spec §6 covers both modes); a backup is a separate operation. Cost: none for the store; an operator wanting a snapshot on stop runs one.
4. **The solo round-trip test sets the environment in the test image** with `(setf (uiop:getenv ...))` and restores it, because `cl-mcp/client` passes none (recon C13).

## File Structure

| file | responsibility |
|---|---|
| `agent/mcp/packages.lisp` (new) | the package, nicknames, exports |
| `agent/mcp/config.lisp` (new) | `env`, `parse-scope`, `declare-store-schemas`, `open-scope`, `close-scope` |
| `agent/mcp/adapter.lisp` (new) | `%schema-alist`, `%array-parameters`, `%arguments-table`, `%handler`, `register-llm-tool`, `make-memory-server` |
| `agent/mcp/identity.lisp` (new) | `read-principals`, `loopback-p`, `check-bind`, `hello-line-p`, `parse-hello`, `resolve-identity` |
| `agent/mcp/listener.lisp` (new) | `listener` struct, `start-listener`, `stop-listener`, `%accept-loop`, `%serve-connection` |
| `cl-llm.asd` | `cl-llm/agent/mcp`, `cl-llm/agent/mcp/tests` with the test-op link |
| `tests-agent-mcp/{packages,harness,config-tests,adapter-tests,identity-tests,listener-tests,process-tests}.lisp` (new) | the suite |
| `scripts/memory-mcp.lisp`, `scripts/run-memory-mcp.sh` (new) | solo mode |
| `scripts/memory-mcp-client.lisp` (new) | the stdio relay |
| `scripts/memory-image.lisp`, `scripts/run-memory.sh` | the listener, bounded `stop`, the corrected citation |
| `.github/workflows/test.yml`, `docs/ci.md`, `docs/agent-memory.md`, `README.md` | CI clones and the suite; the docs section |

---

### Task 1: The system, the config layer, and the two unproven facts

**Files:**
- Create: `agent/mcp/packages.lisp`, `agent/mcp/config.lisp`
- Create: `tests-agent-mcp/packages.lisp`, `tests-agent-mcp/harness.lisp`, `tests-agent-mcp/config-tests.lisp`
- Modify: `cl-llm.asd` (two new systems after `cl-llm/agent/prolog/tests`)

**Interfaces:**
- Consumes: `mem:define-memory-store` (macro, unevaluated name), `gdb:make-graph`/`gdb:open-graph` with `:system-clock`, `gdb:open-system-clock`, `gdb:close-graph :snapshot-p`, `gdb:close-system-clock`.
- Produces: package `cl-llm.agent.mcp`; `env (name &optional default)`; `parse-scope (spec) => ((keyword . dir-string) ...)`; `declare-store-schemas (names)`; `open-scope (&key spec write clock-dir system-dir buffer-pool) => (values stores write-store clock)`; `close-scope (stores clock)`; the test harness `with-scratch-root ((root) &body)` and `%sub`.

- [ ] **Step 1: The package, the systems, and the failing tests**

Create `agent/mcp/packages.lisp`:

```lisp
;;;; agent/mcp/packages.lisp -- the memory as its own MCP server (#57).

(defpackage #:cl-llm.agent.mcp
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:c #:cl-llm.conditions)
                    (#:agent #:cl-llm.agent)
                    (#:mem #:cl-llm.memory)
                    (#:gdb #:graph-db)
                    (#:st #:graph-db.spacetime)
                    (#:mcp #:cl-mcp)
                    (#:mcp.tools #:cl-mcp.tools))
  (:export
   ;; config
   #:env #:parse-scope #:declare-store-schemas #:open-scope #:close-scope
   ;; adapter
   #:make-memory-server #:register-llm-tool
   ;; identity
   #:read-principals #:loopback-p #:check-bind #:hello-line-p
   #:parse-hello #:resolve-identity
   ;; listener
   #:listener #:start-listener #:stop-listener #:listener-port
   #:listener-thread))
```

Create `agent/mcp/config.lisp` with only the package line for now (the RED run needs the file to exist):

```lisp
;;;; agent/mcp/config.lisp -- the environment to a scope on one clock,
;;;; and the bounded close.  Spec SS4, SS6; recon C2, C11.

(in-package #:cl-llm.agent.mcp)
```

In `cl-llm.asd`, after the `cl-llm/agent/prolog/tests` system, add:

```lisp
(defsystem "cl-llm/agent/mcp"
  :description "The agent memory as its own MCP server (#57)."
  :license "MIT"
  ;; cl-mcp brings yason, bordeaux-threads and opsis/conditions; none
  ;; is in the Quicklisp dist (docs/ci.md).
  :depends-on ("cl-llm/agent" "cl-mcp" "usocket")
  :serial t
  :pathname "agent/mcp/"
  :components ((:file "packages")
               (:file "config")
               (:file "adapter")
               (:file "identity")
               (:file "listener"))
  :in-order-to ((test-op (test-op "cl-llm/agent/mcp/tests"))))

(defsystem "cl-llm/agent/mcp/tests"
  :description "The MCP adapter, the listener, and the solo process."
  :license "MIT"
  :depends-on ("cl-llm/agent/mcp" "cl-llm/agent/prolog"
               "cl-llm/agent/tests" "cl-mcp/client" "fiveam")
  :serial t
  :pathname "tests-agent-mcp/"
  :components ((:file "packages")
               (:file "harness")
               (:file "config-tests")
               (:file "adapter-tests")
               (:file "identity-tests")
               (:file "listener-tests")
               (:file "process-tests"))
  :perform (test-op (op c)
             (unless (symbol-call :fiveam :run! :cl-llm-agent-mcp)
               (error "cl-llm/agent/mcp suite failed."))))
```

Until Tasks 2 to 4 create them, `adapter`, `identity`, `listener` and the four later test files must exist as package-line-only files so the systems load: create `agent/mcp/adapter.lisp`, `agent/mcp/identity.lisp`, `agent/mcp/listener.lisp` each containing the header comment and `(in-package #:cl-llm.agent.mcp)`, and `tests-agent-mcp/adapter-tests.lisp`, `identity-tests.lisp`, `listener-tests.lisp`, `process-tests.lisp` each containing `(in-package #:cl-llm.agent.mcp/tests)` and `(in-suite :cl-llm-agent-mcp)`.

Create `tests-agent-mcp/packages.lisp`:

```lisp
;;;; tests-agent-mcp/packages.lisp

(defpackage #:cl-llm.agent.mcp/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:mcp #:cl-llm.agent.mcp)
                    (#:agent #:cl-llm.agent)
                    (#:mem #:cl-llm.memory)
                    (#:gdb #:graph-db)
                    (#:st #:graph-db.spacetime)
                    (#:json #:cl-llm.json)
                    (#:mcp.tools #:cl-mcp.tools)
                    (#:client #:cl-mcp.client))
  ;; The clocked two-store fixture and its helpers (tests-agent/harness).
  (:import-from #:cl-llm.agent/tests
                #:with-stores #:%belief #:+p+ #:+subj+))
```

Create `tests-agent-mcp/harness.lisp`:

```lisp
;;;; tests-agent-mcp/harness.lisp -- scratch directories per test.

(in-package #:cl-llm.agent.mcp/tests)

(def-suite :cl-llm-agent-mcp
  :description "cl-llm/agent/mcp offline suite (on-disk stores).")
(in-suite :cl-llm-agent-mcp)

(defun %fresh-root ()
  (format nil "/tmp/cl-llm-mcp-~a-~a/" (get-internal-real-time)
          (random 1000000)))

(defmacro with-scratch-root ((root) &body body)
  "ROOT bound to a fresh directory namestring (trailing slash); deleted
after BODY.  Stores, the clock and the system directory live under it."
  `(let ((,root (%fresh-root)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       (pathname ,root) :validate t
                       :if-does-not-exist :ignore)))))

(defun %sub (root name)
  "ROOT/NAME/ as a namestring with a trailing slash."
  (concatenate 'string root name))

(defun %dirty-p (dir)
  (probe-file (concatenate 'string dir ".dirty")))

(defun %open (root spec &optional write)
  "OPEN-SCOPE under ROOT with the test's clock and system dirs."
  (mcp:open-scope :spec spec :write write
                  :clock-dir (%sub root "clock/")
                  :system-dir (%sub root "sys/")
                  :buffer-pool 1000))
```

Create `tests-agent-mcp/config-tests.lisp`:

```lisp
;;;; tests-agent-mcp/config-tests.lisp -- the environment to a scope,
;;;; and the bounded close.  Spec SS4, SS6.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(test parse-scope-reads-names-and-dirs-in-order
  "SS4: \"name=dir,name=dir\" in trust order; a malformed entry signals."
  (let ((scope (mcp:parse-scope "private=/tmp/p, working=/tmp/w")))
    (is (equal '(:private :working) (mapcar #'car scope)))
    (is (string= "/tmp/p/" (cdr (first scope))) "trailing slash added")
    (is (string= "/tmp/w/" (cdr (second scope)))))
  (signals error (mcp:parse-scope "nodir"))
  (signals error (mcp:parse-scope "=/tmp/x"))
  (is (null (mcp:parse-scope "")) "control: empty is empty"))

(test a-runtime-declared-store-name-opens
  "recon C11: DEFINE-MEMORY-STORE evaluated at run time for a name the
image never declared lets that store open and hold a belief.  The
control is the library's own :cl-llm-memory in the same scope, and
CHECK-SCOPE accepting the pair proves they share the clock."
  (with-scratch-root (root)
    (let ((spec (list (cons :memory-third (%sub root "third/"))
                      (cons :cl-llm-memory (%sub root "main/")))))
      (multiple-value-bind (stores write clock) (%open root spec)
        (unwind-protect
             (progn
               (is (= 2 (length stores)))
               (is (eq write (second stores)) "default write: the last")
               (is (eq :memory-third (gdb:graph-name (first stores))))
               (gdb:with-transaction (:graph (first stores))
                 (mem:record-belief (first stores) '(:repo . "x") "owner"
                                    '(:person . "k")
                                    :producer +p+ :standing :observed))
               (is (= 1 (length (mem:recall (first stores)
                                            '(:repo . "x")))))
               (is (eq stores (mem:check-scope stores :write-store write))
                   "one clock across the scope"))
          (mcp:close-scope stores clock))))))

(test open-scope-names-the-write-store
  (with-scratch-root (root)
    (let ((spec (list (cons :memory-third (%sub root "a/"))
                      (cons :cl-llm-memory (%sub root "b/")))))
      (multiple-value-bind (stores write clock)
          (%open root spec "memory-third")
        (is (eq (first stores) write))
        (mcp:close-scope stores clock))
      (signals error (%open root spec "no-such-store")))))

(test the-shutdown-closes-every-store-with-graph-bound
  "recon C2: CLOSE-SCOPE over two stores binds *GRAPH* per store and
skips the snapshot; both .dirty markers are gone afterwards and both
stores reopen without recovery.  The control is the markers' presence
while the stores are open.  Idempotent: a second CLOSE-SCOPE is a no-op."
  (with-scratch-root (root)
    (let ((spec (list (cons :memory-third (%sub root "a/"))
                      (cons :cl-llm-memory (%sub root "b/")))))
      (multiple-value-bind (stores write clock) (%open root spec)
        (declare (ignore write))
        (is (every (lambda (e) (%dirty-p (cdr e))) spec)
            "control: dirty while open")
        (mcp:close-scope stores clock)
        (is (notany (lambda (e) (%dirty-p (cdr e))) spec))
        (finishes (mcp:close-scope stores clock)))
      (multiple-value-bind (stores write clock) (%open root spec)
        (declare (ignore write))
        (is (= 2 (length stores)) "reopens clean")
        (mcp:close-scope stores clock)))))
```

- [ ] **Step 2: Run the RED test**

Run the one-test command for `a-runtime-declared-store-name-opens`.
Expected: FAIL with an undefined function `OPEN-SCOPE` (or the reader complaining the symbol is not external — the export exists, the function does not; either is the expected red). If instead the systems do not load, fix the `.asd` or the stub files, not the tests.

- [ ] **Step 3: Write `config.lisp`**

Replace `agent/mcp/config.lisp` with:

```lisp
;;;; agent/mcp/config.lisp -- the environment to a scope on one clock,
;;;; and the bounded close.  Spec SS4, SS6; recon C2, C11.

(in-package #:cl-llm.agent.mcp)

(defun env (name &optional default)
  "The environment variable NAME, or DEFAULT when unset or empty."
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun %dir (string)
  (namestring (uiop:ensure-directory-pathname string)))

(defun parse-scope (spec)
  "SPEC \"name=dir,name=dir\" -> ((keyword . dir) ...) in the given
order -- trust order, most trusted first (SS4).  Dirs get a trailing
slash.  Signals on an entry without a name or a dir."
  (loop for entry in (uiop:split-string spec :separator ",")
        for trimmed = (string-trim " " entry)
        unless (zerop (length trimmed))
          collect (let ((at (position #\= trimmed)))
                    (unless (and at (plusp at) (< (1+ at) (length trimmed)))
                      (error "malformed scope entry ~s; want name=dir"
                             trimmed))
                    (cons (intern (string-upcase (subseq trimmed 0 at))
                                  :keyword)
                          (%dir (subseq trimmed (1+ at)))))))

(defun declare-store-schemas (names)
  "DEFINE-MEMORY-STORE for each of NAMES.  The macro takes an
unevaluated name, so this is an EVAL per name; redeclaring a declared
name is the engine's idempotent case (vivace-graph#196; recon C11)."
  (dolist (name names names)
    (eval `(mem:define-memory-store ,name))))

(defun %open-store (name dir clock pool)
  ;; The memory image's own rule: open when the schema file exists.
  (if (probe-file (concatenate 'string dir "schema.dat"))
      (gdb:open-graph name dir :buffer-pool-size pool :system-clock clock)
      (gdb:make-graph name dir :buffer-pool-size pool :system-clock clock)))

(defun open-scope (&key spec write clock-dir system-dir (buffer-pool 2000))
  "Open the clock at CLOCK-DIR, then every store of SPEC (PARSE-SCOPE's
list) attached to it, under SYSTEM-DIR.  => (values STORES WRITE-STORE
CLOCK).  WRITE names the write store (a string, case-insensitive),
default the last entry.  STORE-NOT-CLOSED-CLEANLY-ERROR and
SYSTEM-CLOCK-IN-USE propagate for the caller to report (SS7); the
process exits on them, which releases the clock's lock."
  (setf gdb:*system-directory* (%dir system-dir))
  (declare-store-schemas (mapcar #'car spec))
  (let* ((clock (gdb:open-system-clock (%dir clock-dir)))
         (stores (mapcar (lambda (e)
                           (%open-store (car e) (cdr e) clock buffer-pool))
                         spec))
         (write-store
           (if write
               (or (find write stores :key #'gdb:graph-name
                                      :test #'string-equal)
                   (error "write store ~a is not in the scope" write))
               (car (last stores)))))
    (values stores write-store clock)))

(defun close-scope (stores clock)
  "Close every store, each with *GRAPH* bound to it and without the
snapshot -- unbounded work before the .dirty marker clears (recon C2)
-- then the clock.  Never signals; a closed store is skipped."
  (dolist (g stores)
    (ignore-errors
     (let ((gdb:*graph* g))
       (gdb:close-graph g :snapshot-p nil))))
  (when clock
    (ignore-errors (gdb:close-system-clock clock)))
  nil)
```

- [ ] **Step 4: Run the four config tests, then the suite**

Run the one-test command for each of the four tests. Expected: PASS. If `a-runtime-declared-store-name-opens` fails because the runtime `define-memory-store` does not register the store (the engine refuses or `open-graph` cannot find the schema), STOP and report NEEDS_CONTEXT with the exact error: the fallback is a fixed allow-list of declared names and a startup refusal (spec §4), which the controller rules on.
Run the `cl-llm/agent/mcp` suite. Expected: green; record `Did N checks.`.

- [ ] **Step 5: Commit**

```bash
git add cl-llm.asd agent/mcp tests-agent-mcp
git commit -m "feat(agent/mcp): the system, the environment to a scope, the bounded close (#57)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 2: The adapter

**Files:**
- Modify: `agent/mcp/adapter.lisp` (replace the stub), `tests-agent-mcp/adapter-tests.lisp` (replace the stub)

**Interfaces:**
- Consumes: `llm:tool-name`, `llm:tool-description`, `llm:tool-schema` (nested `equal` hash tables, `required` a vector), `llm:call-tool` (hash table of arguments; arrays as vectors), `c:llm-tool-error`; `agent:make-agent-tools`; `mcp:make-server`, `mcp:register-tool (server name &key description schema handler)`; `cl-mcp.tools:call-tool (registry name args)`, `get-tool`, `tool-input-schema`.
- Produces: `make-memory-server (stores &key write-store producer sources (k 5) (max-rows 50) query-tool (name "cl-llm-memory") (version "0.1")) => cl-mcp server`; `register-llm-tool (server tool)`; the internal `%schema-alist`, `%array-parameters`, `%arguments-table`, `%handler`.

- [ ] **Step 1: Write the failing tests**

Replace `tests-agent-mcp/adapter-tests.lisp` with:

```lisp
;;;; tests-agent-mcp/adapter-tests.lisp -- cl-llm tools as cl-mcp tools.
;;;; Spec SS3; recon C1, E1, E2.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defun %registry (server)
  ;; The registry slot is internal to cl-mcp; the tests read it.
  (cl-mcp::mcp-server-tools server))

(defun %text (content)
  "The text of the first content block."
  (cdr (assoc "text" (first content) :test #'string=)))

(defun %schema-of (server name)
  (mcp.tools:tool-input-schema (mcp.tools:get-tool (%registry server) name)))

(test every-agent-tool-registers-with-a-string-keyed-schema
  "SS3: one MCP tool per cl-llm tool, in cl-mcp's alist form."
  (with-stores (w p)
    (let* ((server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (names (mapcar #'mcp.tools:tool-name
                          (mcp.tools:list-tools (%registry server)))))
      (is (= 8 (length names)))
      (dolist (n '("recall" "trace" "decisions-citing" "conclude"
                   "conclude-absence" "retract" "retrieve" "plan-bounds"))
        (is (member n names :test #'string=) n))
      (let ((schema (%schema-of server "recall")))
        (is (string= "object" (cdr (assoc "type" schema :test #'string=))))
        (is (listp (cdr (assoc "required" schema :test #'string=))))
        (is (assoc "properties" schema :test #'string=)))
      (is (null (mcp.tools:get-tool (%registry server) "query"))
          "control: no query tool unless asked"))))

(test a-required-list-validates-and-a-vector-does-not
  "recon C1: the registered schema carries REQUIRED as a list, so
cl-mcp's validator accepts a complete call; the same schema with
REQUIRED as a vector makes the validator signal a TYPE-ERROR on every
call -- the control that proves the coercion is load-bearing."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let* ((server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (registry (%registry server))
           (args '(("subject-namespace" . "repo")
                   ("subject-key" . "cl-llm"))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool registry "recall" args)
        (is (null error-p))
        (is (= 1 (length (json:jget (json:parse (%text content))
                                    "records")))))
      (let* ((schema (%schema-of server "recall"))
             (broken (mapcar (lambda (pair)
                               (if (string= (car pair) "required")
                                   (cons "required"
                                         (coerce (cdr pair) 'vector))
                                   pair))
                             schema)))
        (mcp.tools:register-tool registry "recall-v" "" broken
                                 (lambda (a) (declare (ignore a)) "x"))
        (signals type-error (mcp.tools:call-tool registry "recall-v" args)
          "control: a vector REQUIRED breaks every call")))))

(test a-list-valued-array-argument-reaches-the-tool-as-a-vector
  "recon E2: cl-mcp decodes a JSON array as a list; the tools read
arrays with ACROSS.  CONCLUDE's EVIDENCE arrives as a list and the
conclusion still cites it; the control is the same call with no
evidence, which needs no conversion."
  (with-stores (w p)
    (let* ((cite (mem:claim-cite (%belief w "ci-status" '(:verdict . "green"))))
           (server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (registry (%registry server)))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool
           registry "conclude"
           `(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
             ("relation" . "releasable")
             ("object-namespace" . "verdict") ("object-key" . "yes")
             ("rule" . "r") ("evidence" ,cite)))
        (is (null error-p))
        (let* ((out (json:parse (%text content)))
               (id (json:jget out "id"))
               (rec (mem:trace w id)))
          (is (string= "concluded" (json:jget out "outcome")))
          (is (string= cite (mem:cite-record-cite
                             (first (mem:decision-record-evidence rec)))))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool
           registry "conclude"
           '(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
             ("relation" . "other") ("object-namespace" . "v")
             ("object-key" . "1") ("rule" . "r")))
        (is (null error-p) "control: no evidence, no conversion")
        (is (string= "concluded"
                     (json:jget (json:parse (%text content)) "outcome")))))))

(test a-refusal-is-text-with-the-error-flag
  "SS3: an LLM-TOOL-ERROR -- here a bad standing -- becomes a text
block with isError; the message is the in-process loop's.  The control
is the same call with a valid standing."
  (with-stores (w p)
    (let* ((server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (registry (%registry server))
           (base '(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
                   ("relation" . "x") ("object-namespace" . "v")
                   ("object-key" . "1") ("rule" . "r"))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool registry "conclude"
                               (cons '("standing" . "bogus") base))
        (is (eq t error-p))
        (is (search "standing must be one of" (%text content))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool registry "conclude"
                               (cons '("standing" . "observed") base))
        (declare (ignore content))
        (is (null error-p) "control")))))

(test the-query-tool-joins-only-when-asked
  "SS3 (recon C9): :QUERY-TOOL T appends the guarded query tool over the
store list; it is absent otherwise."
  (with-stores (w p)
    (let ((with (mcp:make-memory-server (list w p) :write-store w
                                                    :producer +p+
                                                    :query-tool t))
          (without (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+)))
      (is (mcp.tools:get-tool (%registry with) "query"))
      (is (null (mcp.tools:get-tool (%registry without) "query"))
          "control"))))
```

(`mcp.tools:list-tools`, `tool-name`, `tool-input-schema`, `get-tool` are in `cl-mcp.tools`; if one is not exported, use `cl-mcp.tools::` and say so in the report. `json:jget` reads a parsed hash table.)

- [ ] **Step 2: Run one RED test**

Run the one-test command for `every-agent-tool-registers-with-a-string-keyed-schema`. Expected: FAIL, `MAKE-MEMORY-SERVER` undefined.

- [ ] **Step 3: Write `adapter.lisp`**

Replace `agent/mcp/adapter.lisp` with:

```lisp
;;;; agent/mcp/adapter.lisp -- each cl-llm tool as a cl-mcp tool.
;;;; Spec SS3; recon C1, C9, C12, E1, E2, E3.

(in-package #:cl-llm.agent.mcp)

(defun %schema-alist (schema)
  "cl-llm's JSON Schema -- nested EQUAL hash tables and vectors -- as the
string-keyed alist cl-mcp encodes and validates.  \"required\" becomes
a LIST: cl-mcp validates it with DOLIST, and a vector would turn every
call into an internal error while tools/list looked right (recon C1)."
  (cond ((hash-table-p schema)
         (loop for key being the hash-keys of schema using (hash-value v)
               collect (cons key (if (string= key "required")
                                     (coerce v 'list)
                                     (%schema-alist v)))))
        ((and (vectorp schema) (not (stringp schema)))
         (map 'vector #'%schema-alist schema))
        (t schema)))

(defun %array-parameters (tool)
  "The names of TOOL's array-typed parameters, from its schema."
  (let ((props (gethash "properties" (llm:tool-schema tool))))
    (when props
      (loop for name being the hash-keys of props using (hash-value spec)
            when (equal (gethash "type" spec) "array")
              collect name))))

(defun %arguments-table (arguments array-names)
  "cl-mcp's decoded ARGUMENTS -- a string-keyed alist; arrays are lists,
null and false are NIL, a JSON float is a double so an integer cap sent
as 5.0 falls back to the configured cap (recon E1, C12) -- as the EQUAL
hash table CALL-TOOL takes, with ARRAY-NAMES' values as vectors: the
tools read arrays with ACROSS (recon E2)."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (pair arguments table)
      (let ((name (car pair)) (value (cdr pair)))
        (setf (gethash name table)
              (if (and (member name array-names :test #'string=)
                       (listp value))
                  (coerce value 'vector)
                  value))))))

(defun %handler (tool)
  "The cl-mcp handler for TOOL: the tool's JSON text on success; on an
LLM-TOOL-ERROR -- a refusal or a bad argument, what the in-process loop
shows the model -- its message with the error flag, cl-mcp's isError.
Other conditions propagate to RUN-SERVER's loop (SS7)."
  (let ((arrays (%array-parameters tool)))
    (lambda (arguments)
      (handler-case
          (values (llm:call-tool tool (%arguments-table arguments arrays))
                  nil)
        (c:llm-tool-error (e) (values (princ-to-string e) t))))))

(defun register-llm-tool (server tool)
  "Register the cl-llm TOOL on the cl-mcp SERVER."
  (mcp:register-tool server (llm:tool-name tool)
                     :description (llm:tool-description tool)
                     :schema (%schema-alist (llm:tool-schema tool))
                     :handler (%handler tool)))

(defun %query-tool (stores max-rows)
  ;; Reached by name so this system does not depend on
  ;; cl-llm/agent/prolog; the scripts load it on request (ruling 2).
  (unless (find-package "CL-LLM.AGENT.PROLOG")
    (error "the query tool needs cl-llm/agent/prolog loaded"))
  (uiop:symbol-call :cl-llm.agent.prolog :make-query-tool stores
                    :max-rows max-rows))

(defun make-memory-server (stores &key write-store producer sources
                                       (k 5) (max-rows 50) query-tool
                                       (name "cl-llm-memory")
                                       (version "0.1"))
  "A cl-mcp server with one MCP tool per agent tool over STORES (trust
order) writing to WRITE-STORE as PRODUCER, caps K and MAX-ROWS, SOURCES
added to the planner -- MAKE-AGENT-TOOLS' arguments, so every bound is
fixed here and the model chooses arguments only.  QUERY-TOOL adds the
guarded Prolog tool over the store list (scope-blind, recon C9).  One
server per connection: cl-mcp keeps the output stream in it (recon
C10)."
  (let ((server (mcp:make-server :name name :version version)))
    (dolist (tool (agent:make-agent-tools stores :write-store write-store
                                                 :producer producer
                                                 :sources sources
                                                 :k k :max-rows max-rows))
      (register-llm-tool server tool))
    (when query-tool
      (register-llm-tool server (%query-tool stores max-rows)))
    server))
```

(Verify the prolog package's name in `agent/prolog/packages.lisp` and the `make-query-tool` keyword arguments before relying on `%query-tool`; adjust the `symbol-call` if the name differs and say so.)

- [ ] **Step 4: Run the five adapter tests, then the suite**

Expected: each PASSES; suite green, count recorded.

- [ ] **Step 5: Commit**

```bash
git add agent/mcp/adapter.lisp tests-agent-mcp/adapter-tests.lisp
git commit -m "feat(agent/mcp): make-memory-server -- each agent tool as a cl-mcp tool (#57)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 3: Identity and the listener

**Files:**
- Modify: `agent/mcp/identity.lisp`, `agent/mcp/listener.lisp`, `tests-agent-mcp/identity-tests.lisp`, `tests-agent-mcp/listener-tests.lisp` (replace the stubs)

**Interfaces:**
- Consumes: `make-memory-server` (Task 2); `usocket:socket-listen`, `socket-accept`, `wait-for-input`, `socket-stream`, `get-peer-address`, `get-local-port`, `socket-close`; `bt:make-thread`, `join-thread`, `thread-alive-p`; `mcp:run-server`; `yason:parse ... :object-as :alist`; `st:canonical-producer-p`.
- Produces: `read-principals (path) => (("producer" . "secret") ...) or NIL`; `loopback-p (address)`; `check-bind (address principals)`; `hello-line-p (line)`; `parse-hello (line) => (values principal secret)`; `resolve-identity (provider line peer default principals) => producer or :refused`; the `listener` struct with `listener-port`, `listener-thread`; `start-listener (&key bind port stores write-store provider principals-path default-producer query-tool) => listener`; `stop-listener (listener)`.

- [ ] **Step 1: Write the failing tests**

Replace `tests-agent-mcp/identity-tests.lisp` with:

```lisp
;;;; tests-agent-mcp/identity-tests.lisp -- principals, the hello, the
;;;; bind rule.  Spec SS5.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defun %write-principals (root entries)
  (let ((path (concatenate 'string root "principals.sexp")))
    (ensure-directories-exist path)
    (with-open-file (s path :direction :output :if-exists :supersede)
      (prin1 entries s))
    path))

(defun %hello (principal secret)
  (format nil "{\"cl-llm-memory\": {\"principal\": ~s, \"secret\": ~s}}"
          principal secret))

(test principals-are-canonical-producers-with-secrets
  "SS5: the file is ((producer . secret) ...); a non-canonical producer
or a non-string secret is refused; a missing file is NIL."
  (with-scratch-root (root)
    (is (equal '(("claude-code/laptop" . "s1"))
               (mcp:read-principals
                (%write-principals root '(("claude-code/laptop" . "s1"))))))
    (signals error
      (mcp:read-principals (%write-principals root '(("Bad Name" . "s")))))
    (signals error
      (mcp:read-principals (%write-principals root '(("a/b" . 42)))))
    (is (null (mcp:read-principals (%sub root "absent.sexp"))))))

(test a-hello-line-parses-and-other-lines-do-not
  (multiple-value-bind (principal secret)
      (mcp:parse-hello (%hello "claude-code/laptop" "s1"))
    (is (string= "claude-code/laptop" principal))
    (is (string= "s1" secret)))
  (is (mcp:hello-line-p (%hello "a/b" "c")))
  (is (not (mcp:hello-line-p
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"))
      "control: a JSON-RPC line is not a hello")
  (is (not (mcp:hello-line-p "not json"))))

(test resolve-identity-under-the-secret-provider
  "SS5: a matching hello names its principal; a wrong secret, a hello
for an unknown principal, and no hello off loopback are refused; no
hello on loopback is the default."
  (let ((principals '(("claude-code/laptop" . "s1")))
        (lo #(127 0 0 1))
        (far #(10 0 0 7)))
    (is (string= "claude-code/laptop"
                 (mcp:resolve-identity
                  :secret (%hello "claude-code/laptop" "s1")
                  far "default/host" principals)))
    (is (eq :refused (mcp:resolve-identity
                      :secret (%hello "claude-code/laptop" "wrong")
                      lo "default/host" principals)))
    (is (eq :refused (mcp:resolve-identity
                      :secret (%hello "nobody/here" "s1")
                      lo "default/host" principals)))
    (is (string= "default/host"
                 (mcp:resolve-identity :secret nil lo "default/host"
                                       principals))
        "no hello on loopback: the default")
    (is (eq :refused (mcp:resolve-identity :secret nil far "default/host"
                                           principals))
        "no hello off loopback: refused")))

(test a-non-loopback-bind-needs-principals
  "SS5: the configuration validator refuses an open listener with the
default identity; loopback needs nothing, and principals unlock any
address."
  (signals error (mcp:check-bind "0.0.0.0" nil))
  (is (string= "0.0.0.0" (mcp:check-bind "0.0.0.0" '(("a/b" . "s")))))
  (is (string= "127.0.0.1" (mcp:check-bind "127.0.0.1" nil)) "control"))
```

Replace `tests-agent-mcp/listener-tests.lisp` with:

```lisp
;;;; tests-agent-mcp/listener-tests.lisp -- one server per connection
;;;; over an ephemeral loopback port.  Spec SS5, SS6; recon C3, C6, C10.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defmacro with-listener ((var w p &rest args) &body body)
  `(let ((,var (mcp:start-listener :bind "127.0.0.1" :port 0
                                   :stores (list ,w ,p) :write-store ,w
                                   :default-producer +p+ ,@args)))
     (unwind-protect (progn ,@body)
       (mcp:stop-listener ,var))))

(defun %connect (port &optional hello)
  "=> (values socket stream), HELLO sent first when given."
  (let* ((socket (usocket:socket-connect "127.0.0.1" port
                                         :element-type 'character))
         (stream (usocket:socket-stream socket)))
    (when hello
      (write-string hello stream) (write-char #\Newline stream)
      (force-output stream))
    (values socket stream)))

(defvar *rpc-id* 0)

(defun %rpc (stream method &optional params)
  "Send one request, read one response line; => the parsed response
(a JSON-RPC-RESPONSE struct; RESPONSE-RESULT is a string-keyed alist)."
  (write-string (client:encode-request
                 (cl-mcp.json-rpc:make-request :id (incf *rpc-id*)
                                               :method method
                                               :params params))
                stream)
  (write-char #\Newline stream)
  (force-output stream)
  (client:parse-client-message (read-line stream)))

(defun %initialize (stream)
  (%rpc stream "initialize"
        '(("protocolVersion" . "2025-06-18")
          ("clientInfo" . (("name" . "test") ("version" . "0")))
          ("capabilities" . nil))))

(defun %call (stream name args)
  "The tool's text result, or (values text t) on isError."
  (let* ((response (%rpc stream "tools/call"
                         `(("name" . ,name) ("arguments" . ,args))))
         (result (cl-mcp.json-rpc:response-result response))
         (content (cdr (assoc "content" result :test #'string=)))
         (text (cdr (assoc "text" (first content) :test #'string=))))
    (values text (cdr (assoc "isError" result :test #'string=)))))

(defun %conclude-args (relation)
  `(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
    ("relation" . ,relation) ("object-namespace" . "v")
    ("object-key" . "1") ("rule" . "r")))

(test a-known-secret-writes-under-its-principal
  "SS5: a hello with a known secret sets the connection's producer; the
decision it writes carries it.  The control is a connection with no
hello, which writes under the image's default."
  (with-stores (w p)
    (with-scratch-root (root)
      (let ((path (%write-principals
                   root '(("claude-code/tester" . "s1")))))
        (with-listener (l w p :principals-path path)
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l)
                        (%hello "claude-code/tester" "s1"))
            (%initialize stream)
            (let ((id (json:jget (json:parse
                                  (%call stream "conclude"
                                         (%conclude-args "a")))
                                 "id")))
              (is (string= "claude-code/tester"
                           (mem:decision-record-producer (mem:trace w id)))))
            (usocket:socket-close socket))
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l))
            (%initialize stream)
            (let ((id (json:jget (json:parse
                                  (%call stream "conclude"
                                         (%conclude-args "b")))
                                 "id")))
              (is (string= +p+ (mem:decision-record-producer (mem:trace w id)))
                  "control: no hello on loopback, the default"))
            (usocket:socket-close socket)))))))

(test a-refused-hello-closes-before-initialize
  "SS5: a wrong secret closes the connection with no handshake -- the
next read is EOF, not a response.  The control is the right secret on
the same listener."
  (with-stores (w p)
    (with-scratch-root (root)
      (let ((path (%write-principals
                   root '(("claude-code/tester" . "s1")))))
        (with-listener (l w p :principals-path path)
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l)
                        (%hello "claude-code/tester" "wrong"))
            (is (eq :eof (read-line stream nil :eof)))
            (usocket:socket-close socket))
          (multiple-value-bind (socket stream)
              (%connect (mcp:listener-port l)
                        (%hello "claude-code/tester" "s1"))
            (is (cl-mcp.json-rpc:response-result (%initialize stream))
                "control")
            (usocket:socket-close socket)))))))

(test two-connections-see-each-others-commits
  "SS5: concurrent connections are concurrent transactions on one
image; B recalls what A concluded."
  (with-stores (w p)
    (with-listener (l w p)
      (multiple-value-bind (sa sta) (%connect (mcp:listener-port l))
        (multiple-value-bind (sb stb) (%connect (mcp:listener-port l))
          (%initialize sta) (%initialize stb)
          (%call sta "conclude" (%conclude-args "shared"))
          (let ((rows (json:jget (json:parse
                                  (%call stb "recall"
                                         '(("subject-namespace" . "repo")
                                           ("subject-key" . "cl-llm"))))
                                 "records")))
            (is (= 1 (length rows))))
          (usocket:socket-close sb))
        (usocket:socket-close sa)))))

(test stop-ends-the-accept-loop
  "recon C3: closing a listening socket does not wake a parked accept,
so STOP sets a flag the polling loop reads; afterwards the thread is
gone and a connect is refused.  The control is a connect before STOP."
  (with-stores (w p)
    (let ((l (mcp:start-listener :bind "127.0.0.1" :port 0
                                 :stores (list w p) :write-store w
                                 :default-producer +p+)))
      (multiple-value-bind (socket stream) (%connect (mcp:listener-port l))
        (is (cl-mcp.json-rpc:response-result (%initialize stream))
            "control: accepting before stop")
        (usocket:socket-close socket))
      (let ((thread (mcp:listener-thread l)))
        (mcp:stop-listener l)
        (is (not (bt:thread-alive-p thread)))
        (signals error (usocket:socket-connect "127.0.0.1"
                                               (mcp:listener-port l)))
        (finishes (mcp:stop-listener l) "idempotent")))))
```

(`cl-mcp.json-rpc:make-request`, `response-result` and `response-error` are exported from `cl-mcp.json-rpc`; a result is a string-keyed alist; `encode-request` returns the JSON with no trailing newline, so the `write-char` stays.)

- [ ] **Step 2: Run one RED test**

Run the one-test command for `a-hello-line-parses-and-other-lines-do-not`. Expected: FAIL, `PARSE-HELLO` undefined.

- [ ] **Step 3: Write `identity.lisp` and `listener.lisp`**

Replace `agent/mcp/identity.lisp` with:

```lisp
;;;; agent/mcp/identity.lisp -- who a connection writes as.  Spec SS5.

(in-package #:cl-llm.agent.mcp)

(defun read-principals (path)
  "((producer . secret) ...) from PATH, each producer canonical; NIL
when PATH does not exist; signals on a malformed entry."
  (when (probe-file path)
    (let ((entries (with-open-file (s path)
                     (let ((*read-eval* nil)) (read s nil nil)))))
      (dolist (e entries entries)
        (unless (and (consp e) (stringp (car e)) (stringp (cdr e))
                     (st:canonical-producer-p (car e)))
          (error "malformed principals entry ~s" e))))))

(defun %address-string (address)
  (if (stringp address)
      address
      (format nil "~{~a~^.~}" (coerce address 'list))))

(defun loopback-p (address)
  "ADDRESS -- a usocket address vector or a string -- is loopback."
  (let ((s (%address-string address)))
    (or (string= s "localhost") (string= s "::1")
        (and (>= (length s) 4) (string= "127." (subseq s 0 4))))))

(defun check-bind (address principals)
  "ADDRESS when it is loopback or PRINCIPALS is non-NIL (SS5): an open
listener with the default identity cannot exist."
  (unless (or (loopback-p address) principals)
    (error "binding ~a needs a principals file; none is configured"
           address))
  address)

(defun %hello-object (line)
  (let ((object (ignore-errors (yason:parse line :object-as :alist))))
    (and (consp object)
         (assoc "cl-llm-memory" object :test #'string=))))

(defun hello-line-p (line)
  "LINE is a hello (SS5), well-formed or not."
  (and (%hello-object line) t))

(defun parse-hello (line)
  "=> (values PRINCIPAL SECRET) from a hello LINE; NIL otherwise."
  (let ((hello (cdr (%hello-object line))))
    (when (consp hello)
      (values (cdr (assoc "principal" hello :test #'string=))
              (cdr (assoc "secret" hello :test #'string=))))))

(defun %tailscale-node (peer)
  ;; claude-code/<node> from `tailscale whois`; NIL when it cannot say.
  (ignore-errors
   (let* ((json (uiop:run-program
                 (list "tailscale" "whois" "--json" (%address-string peer))
                 :output :string :error-output nil))
          (node (cdr (assoc "Node" (yason:parse json :object-as :alist)
                            :test #'string=)))
          (name (cdr (assoc "ComputedName" node :test #'string=))))
     (and (stringp name) (plusp (length name))
          (format nil "claude-code/~(~a~)" name)))))

(defun resolve-identity (provider line peer default principals)
  "The producer for a connection, or :REFUSED (SS5).  :SECRET -- a hello
LINE matching PRINCIPALS names it; no hello on a loopback PEER is
DEFAULT; anything else is refused.  :TAILSCALE -- the peer's node."
  (ecase provider
    (:secret
     (multiple-value-bind (principal secret) (and line (parse-hello line))
       (cond ((and (stringp principal) (stringp secret))
              (let ((entry (assoc principal principals :test #'string=)))
                (if (and entry (string= (cdr entry) secret))
                    principal
                    :refused)))
             (line :refused)
             ((loopback-p peer) default)
             (t :refused))))
    (:tailscale (or (%tailscale-node peer) :refused))))
```

Replace `agent/mcp/listener.lisp` with:

```lisp
;;;; agent/mcp/listener.lisp -- one cl-mcp server per accepted
;;;; connection, in the memory image.  Spec SS5, SS6; recon C3, C10.

(in-package #:cl-llm.agent.mcp)

(defstruct listener
  socket thread (stopping nil) port stores write-store
  (provider :secret) principals-path default-producer query-tool)

(defun start-listener (&key (bind "127.0.0.1") (port 0) stores write-store
                            (provider :secret) principals-path
                            default-producer query-tool)
  "Listen on BIND:PORT (0 for an ephemeral port; LISTENER-PORT reads it
back) and serve each connection its own server over STORES.  Refuses a
non-loopback BIND without principals (SS5)."
  (check-bind bind (and principals-path (read-principals principals-path)))
  (let* ((socket (usocket:socket-listen bind port :reuse-address t
                                                  :element-type 'character))
         (listener (make-listener :socket socket
                                  :port (usocket:get-local-port socket)
                                  :stores stores :write-store write-store
                                  :provider provider
                                  :principals-path principals-path
                                  :default-producer default-producer
                                  :query-tool query-tool)))
    (setf (listener-thread listener)
          (bt:make-thread (lambda () (%accept-loop listener))
                          :name "cl-llm memory mcp listener"))
    listener))

(defun stop-listener (listener)
  "Set STOPPING, join the accept thread, then close the socket: a parked
accept does not wake on close (recon C3), so the loop polls.  Live
connections are not drained (SS9).  Idempotent; never signals."
  (setf (listener-stopping listener) t)
  (let ((thread (listener-thread listener)))
    (when (and thread (bt:thread-alive-p thread))
      (ignore-errors (bt:join-thread thread))))
  (setf (listener-thread listener) nil)
  (when (listener-socket listener)
    (ignore-errors (usocket:socket-close (listener-socket listener)))
    (setf (listener-socket listener) nil))
  listener)

(defun %accept-loop (listener)
  (loop until (listener-stopping listener)
        do (when (usocket:wait-for-input (listener-socket listener)
                                         :timeout 0.5 :ready-only t)
             (let ((socket (ignore-errors
                            (usocket:socket-accept
                             (listener-socket listener)
                             :element-type 'character))))
               (when socket
                 (bt:make-thread
                  (lambda () (%serve-connection listener socket))
                  :name "cl-llm memory mcp connection"))))))

(defun %serve-connection (listener socket)
  "Read the first line; a hello is consumed, any other line is replayed
ahead of the socket (with its newline: READ-LINE runs across a
concatenated stream's boundary, recon E3).  A refused identity closes
the socket before any handshake."
  (let* ((stream (usocket:socket-stream socket))
         (peer (usocket:get-peer-address socket))
         (line (read-line stream nil nil)))
    (unwind-protect
         (when line
           (let* ((hello-p (hello-line-p line))
                  (principals (and (listener-principals-path listener)
                                   (read-principals
                                    (listener-principals-path listener))))
                  (producer (resolve-identity (listener-provider listener)
                                              (and hello-p line) peer
                                              (listener-default-producer
                                               listener)
                                              principals)))
             (if (eq producer :refused)
                 (format *error-output* "~&memory mcp: refused ~a~%"
                         (%address-string peer))
                 (let ((server (make-memory-server
                                (listener-stores listener)
                                :write-store (listener-write-store listener)
                                :producer producer
                                :query-tool (listener-query-tool listener)))
                       (input (if hello-p
                                  stream
                                  (make-concatenated-stream
                                   (make-string-input-stream
                                    (concatenate 'string line
                                                 (string #\Newline)))
                                   stream))))
                   (mcp:run-server server :input input :output stream)))))
      (ignore-errors (usocket:socket-close socket)))))
```

- [ ] **Step 4: Run the eight new tests, then the suite**

Expected: each PASSES; suite green; count recorded. A test that hangs is a defect: the tests must never wait on a read that cannot return (check `stop-ends-the-accept-loop` joins within a second).

- [ ] **Step 5: Commit**

```bash
git add agent/mcp/identity.lisp agent/mcp/listener.lisp \
        tests-agent-mcp/identity-tests.lisp tests-agent-mcp/listener-tests.lisp
git commit -m "feat(agent/mcp): principals and the hello; one server per connection (#57)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 4: The solo server, the relay, the memory image, and the process tests

**Files:**
- Create: `scripts/memory-mcp.lisp`, `scripts/run-memory-mcp.sh`, `scripts/memory-mcp-client.lisp`
- Modify: `scripts/memory-image.lisp`, `scripts/run-memory.sh`
- Modify: `tests-agent-mcp/process-tests.lisp` (replace the stub)

**Interfaces:**
- Consumes: everything from Tasks 1 to 3; `cl-mcp.client:make-client`, `connect`, `list-tools`, `call-tool`, `disconnect`, the internal `cl-mcp.client::client-process`; `sb-ext:run-program`, `process-kill`, `process-wait`, `process-exit-code`.
- Produces: the three scripts; the image's `CL_LLM_MEMORY_MCP_PORT`/`_BIND`/`_PRINCIPALS`/`_IDENTITY`/`_QUERY_TOOL` handling; `run-memory.sh` exporting `_CLOCK`.

- [ ] **Step 1: Write the failing process tests**

Replace `tests-agent-mcp/process-tests.lisp` with:

```lisp
;;;; tests-agent-mcp/process-tests.lisp -- the solo server as a child
;;;; process: round trip, the double-hold refusal, SIGTERM.  Spec SS4,
;;;; SS6; recon C7, C8, E5.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defun %script (name)
  (namestring (asdf:system-relative-pathname :cl-llm
                                             (concatenate 'string
                                                          "scripts/" name))))

(defun %registry-env ()
  "CL_LLM_ASDF_REGISTRY naming the trees this image loaded, so the
child builds against the same engine and libraries (ruling 1)."
  (format nil "CL_LLM_ASDF_REGISTRY=~{~a~^:~}"
          (mapcar (lambda (s) (namestring (asdf:system-source-directory s)))
                  '(:cl-llm :graph-db :cl-mcp :opsis :cl-temporal-extent))))

(defun %solo-env (root)
  (list (format nil "CL_LLM_MEMORY_STORE=~a" (%sub root "store/"))
        (format nil "CL_LLM_MEMORY_SYSTEM=~a" (%sub root "sys/"))
        (format nil "CL_LLM_MEMORY_CLOCK=~a" (%sub root "clock/"))
        "CL_LLM_MEMORY_PRODUCER=claude-code/test"
        "LC_ALL=C.UTF-8"
        (%registry-env)))

(defun %launch-solo (root)
  "The solo server as a child, stdin/stdout/stderr as streams."
  (sb-ext:run-program (%script "run-memory-mcp.sh") '()
                      :environment (append (%solo-env root)
                                           (sb-ext:posix-environ))
                      :input :stream :output :stream :error :stream
                      :wait nil))

(defun %child-rpc (process method &optional params)
  (let ((in (sb-ext:process-input process))
        (out (sb-ext:process-output process)))
    (write-string (client:encode-request
                   (cl-mcp.json-rpc:make-request :id (incf *rpc-id*)
                                                 :method method
                                                 :params params))
                  in)
    (write-char #\Newline in)
    (force-output in)
    (client:parse-client-message (read-line out))))

(defun %wait (process &key (grace 15))
  "Wait up to GRACE seconds for PROCESS to exit; => exit code or NIL."
  (loop repeat (* 10 grace)
        while (sb-ext:process-alive-p process)
        do (sleep 0.1))
  (unless (sb-ext:process-alive-p process)
    (sb-ext:process-wait process)
    (sb-ext:process-exit-code process)))

(defun %stderr (process)
  (let ((s (sb-ext:process-error process)))
    (with-output-to-string (o)
      (loop for line = (read-line s nil nil) while line
            do (write-line line o)))))

(defmacro with-solo-env ((root) &body body)
  "The solo variables set in THIS image for cl-mcp/client's child, which
inherits the environment (recon C13), restored afterwards."
  `(let ((saved (mapcar (lambda (e) (cons (subseq e 0 (position #\= e))
                                          (uiop:getenv
                                           (subseq e 0 (position #\= e)))))
                        (%solo-env ,root))))
     (unwind-protect
          (progn
            (dolist (e (%solo-env ,root))
              (let ((at (position #\= e)))
                (setf (uiop:getenv (subseq e 0 at)) (subseq e (1+ at)))))
            ,@body)
       (dolist (pair saved)
         (setf (uiop:getenv (car pair)) (or (cdr pair) ""))))))

(test the-solo-server-round-trips-and-leaves-the-store-clean
  "SS4, SS6: cl-mcp/client spawns the solo server; tools list, a
conclude, a recall; then EOF, then the child exits and the store has no
.dirty marker and reopens clean.  DISCONNECT does not wait (recon C8),
so the process handle is captured first."
  (with-scratch-root (root)
    (with-solo-env (root)
      (let ((c (client:make-client
                :command (list (%script "run-memory-mcp.sh")))))
        (client:connect c)
        (let ((process (cl-mcp.client::client-process c)))
          (is (= 8 (length (client:list-tools c))))
          (let* ((out (client:call-tool
                       c "conclude"
                       '(("subject-namespace" . "repo")
                         ("subject-key" . "cl-llm") ("relation" . "a")
                         ("object-namespace" . "v") ("object-key" . "1")
                         ("rule" . "r"))))
                 (text (cdr (assoc "text" (first (getf out :content))
                                   :test #'string=))))
            (is (string= "concluded" (json:jget (json:parse text) "outcome"))))
          (let* ((out (client:call-tool
                       c "recall" '(("subject-namespace" . "repo")
                                    ("subject-key" . "cl-llm"))))
                 (text (cdr (assoc "text" (first (getf out :content))
                                   :test #'string=))))
            (is (= 1 (length (json:jget (json:parse text) "records")))))
          (client:disconnect c)
          (uiop:wait-process process)
          (is (not (%dirty-p (%sub root "store/"))) "clean after EOF")
          (let ((g (gdb:open-graph :cl-llm-memory (%sub root "store/")
                                   :buffer-pool-size 1000)))
            (is (= 1 (length (mem:recall g '(:repo . "cl-llm"))))
                "reopens clean and holds the decision's belief")
            (let ((gdb:*graph* g)) (gdb:close-graph g :snapshot-p nil))))))))

(test a-second-solo-server-on-a-held-store-refuses
  "SS4: while one solo server holds the store, a second exits non-zero
with the image's message and never answers a request.  The control is
the first server answering initialize."
  (with-scratch-root (root)
    (let ((first (%launch-solo root)))
      (unwind-protect
           (progn
             (is (%child-rpc first "initialize"
                             '(("protocolVersion" . "2025-06-18")
                               ("clientInfo" . (("name" . "t")
                                                ("version" . "0")))))
                 "control: the first server answers")
             (let ((second (%launch-solo root)))
               (is (eql 1 (%wait second)))
               (is (search "Another image may hold the store"
                           (%stderr second)))))
        (close (sb-ext:process-input first))
        (is (eql 0 (%wait first)))
        (is (not (%dirty-p (%sub root "store/"))))))))

(test sigterm-leaves-the-store-clean
  "SS6 (recon E5): SIGTERM to the solo server mid-session runs the exit
hook; the store has no .dirty marker and reopens.  The control is the
marker's presence while the server runs."
  (with-scratch-root (root)
    (let ((process (%launch-solo root)))
      (%child-rpc process "initialize"
                  '(("protocolVersion" . "2025-06-18")
                    ("clientInfo" . (("name" . "t") ("version" . "0")))))
      (is (%dirty-p (%sub root "store/")) "control: dirty while held")
      (sb-ext:process-kill process sb-unix:sigterm)
      (is (eql 0 (%wait process)))
      (is (not (%dirty-p (%sub root "store/"))))
      (let ((g (gdb:open-graph :cl-llm-memory (%sub root "store/")
                               :buffer-pool-size 1000)))
        (is (gdb::graph-open-p g))
        (let ((gdb:*graph* g)) (gdb:close-graph g :snapshot-p nil))))))
```

(The `initialize` params shape and `getf out :content` follow recon E4; verify against `src/client/client.lisp`. `gdb::graph-open-p` is internal.)

- [ ] **Step 2: Run one RED test**

Run the one-test command for `sigterm-leaves-the-store-clean`. Expected: FAIL because the script does not exist (run-program signals, or the child exits non-zero).

- [ ] **Step 3: The solo script and its wrapper**

Create `scripts/run-memory-mcp.sh` (mode 755):

```sh
#!/bin/sh
# The cl-llm memory as a stdio MCP server, one process per client
# session: `claude mcp add --scope user memory -- <this script>`.
# docs/agent-memory.md, "The memory as an MCP server".
#
# graph-db stores are single-process: if a memory image (or another
# session's solo server) holds the store, this exits 1 with a message
# on stderr and never starts the handshake.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"

export CL_LLM_MEMORY_STORE="${CL_LLM_MEMORY_STORE:-$HOME/.cl-llm-memory/working/}"
export CL_LLM_MEMORY_SYSTEM="${CL_LLM_MEMORY_SYSTEM:-$HOME/.cl-llm-memory/system/}"
export CL_LLM_MEMORY_CLOCK="${CL_LLM_MEMORY_CLOCK:-$HOME/.cl-llm-memory/clock/}"
export CL_LLM_MEMORY_GRAPH="${CL_LLM_MEMORY_GRAPH:-cl-llm-memory}"
export CL_LLM_MEMORY_PRODUCER="${CL_LLM_MEMORY_PRODUCER:-claude-code/$(hostname -s)}"
export CL_LLM_MEMORY_BUFFER_POOL="${CL_LLM_MEMORY_BUFFER_POOL:-2000}"
export CL_LLM_MEMORY_SCOPE="${CL_LLM_MEMORY_SCOPE:-}"
export CL_LLM_MEMORY_WRITE="${CL_LLM_MEMORY_WRITE:-}"
export CL_LLM_MEMORY_QUERY_TOOL="${CL_LLM_MEMORY_QUERY_TOOL:-}"
# The tested tree is this checkout unless the caller names others.
export CL_LLM_ASDF_REGISTRY="${CL_LLM_ASDF_REGISTRY:-$REPO/}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

exec sbcl --dynamic-space-size "${CL_LLM_MEMORY_HEAP_MB:-4096}" \
     --script "$REPO/scripts/memory-mcp.lisp"
```

Create `scripts/memory-mcp.lisp`:

```lisp
;;;; scripts/memory-mcp.lisp -- the memory as a stdio MCP server, the
;;;; solo mode: one process per client session, launched by the client.
;;;; Run through scripts/run-memory-mcp.sh; docs/agent-memory.md, "The
;;;; memory as an MCP server".  stdout carries JSON-RPC only: everything
;;;; else goes to stderr.

;; --script skips the userinit, so Quicklisp is loaded by hand (the
;; same dance as cl-mcp-server/run-server.lisp).
(let ((*standard-output* *error-output*)
      (*trace-output* *error-output*))
  (require :asdf)
  (flet ((try (path) (when (probe-file path) (load path) t)))
    (let ((home (user-homedir-pathname)))
      (or (try (merge-pathnames "quicklisp/setup.lisp" home))
          (try (merge-pathnames ".quicklisp/setup.lisp" home))
          (try #p"/usr/local/share/quicklisp/setup.lisp"))))
  ;; CL_LLM_ASDF_REGISTRY: colon-separated trees, first on the registry,
  ;; so the child builds what its launcher built (plan ruling 1).
  (let ((registry (uiop:getenv "CL_LLM_ASDF_REGISTRY")))
    (when (and registry (plusp (length registry)))
      (dolist (dir (reverse (uiop:split-string registry :separator ":")))
        (when (plusp (length dir))
          (push (uiop:ensure-directory-pathname dir)
                asdf:*central-registry*)))))
  (funcall (intern "QUICKLOAD" "QL") :cl-llm/agent/mcp :silent t)
  (when (equal (uiop:getenv "CL_LLM_MEMORY_QUERY_TOOL") "1")
    (funcall (intern "QUICKLOAD" "QL") :cl-llm/agent/prolog :silent t)))

(defpackage #:cl-llm.memory-mcp
  (:use #:cl)
  (:local-nicknames (#:mcp #:cl-llm.agent.mcp) (#:gdb #:graph-db)))

(in-package #:cl-llm.memory-mcp)

(defvar *stores* nil)
(defvar *clock* nil)

(defun %home (relative)
  (namestring (merge-pathnames relative (user-homedir-pathname))))

(defun %dir (s) (namestring (uiop:ensure-directory-pathname s)))

(defun stop ()
  "Close every store, then the clock; never signals; idempotent.  The
exit hook, so SIGTERM leaves no .dirty marker (SS6)."
  (when (or *stores* *clock*)
    (mcp:close-scope *stores* *clock*)
    (setf *stores* nil *clock* nil)))

(defun start ()
  "Open the scope and build the server; => the cl-mcp server."
  (let* ((scope (mcp:env "CL_LLM_MEMORY_SCOPE"))
         (spec (if scope
                   (mcp:parse-scope scope)
                   (list (cons (intern (string-upcase
                                        (mcp:env "CL_LLM_MEMORY_GRAPH"
                                                 "cl-llm-memory"))
                                       :keyword)
                               (%dir (mcp:env
                                      "CL_LLM_MEMORY_STORE"
                                      (%home
                                       ".cl-llm-memory/working/")))))))
         (producer (mcp:env "CL_LLM_MEMORY_PRODUCER"
                            (format nil "claude-code/~(~a~)"
                                    (machine-instance)))))
    (multiple-value-bind (stores write-store clock)
        (mcp:open-scope
         :spec spec :write (mcp:env "CL_LLM_MEMORY_WRITE")
         :clock-dir (%dir (mcp:env "CL_LLM_MEMORY_CLOCK"
                                   (%home ".cl-llm-memory/clock/")))
         :system-dir (%dir (mcp:env "CL_LLM_MEMORY_SYSTEM"
                                    (%home ".cl-llm-memory/system/")))
         :buffer-pool (parse-integer
                       (mcp:env "CL_LLM_MEMORY_BUFFER_POOL" "2000")))
      (setf *stores* stores *clock* clock)
      (mcp:make-memory-server
       stores :write-store write-store :producer producer
       :query-tool (equal (mcp:env "CL_LLM_MEMORY_QUERY_TOOL") "1")))))

(defun %die (control &rest args)
  (apply #'format *error-output* control args)
  (finish-output *error-output*)
  (sb-ext:exit :code 1 :abort t))

(let ((server
        (handler-case (start)
          (gdb:store-not-closed-cleanly-error (c)
            (%die "~&memory mcp: ~A~%Another image may hold the store.  ~
                   If none does, delete its .dirty marker and start ~
                   again.~%" c))
          (gdb:system-clock-in-use (c)
            (%die "~&memory mcp: ~A~%Another image holds the clock at ~
                   that location.~%" c))
          (error (c)
            (%die "~&memory mcp: ~A~%" c)))))
  ;; Only once the scope is open: a refusal above exits with no hook.
  (push #'stop sb-ext:*exit-hooks*)
  (cl-mcp:run-server server :input *standard-input*
                            :output *standard-output*)
  (stop)
  (sb-ext:exit :code 0))
```

- [ ] **Step 4: The relay**

Create `scripts/memory-mcp-client.lisp`:

```lisp
;;;; scripts/memory-mcp-client.lisp -- a stdio relay to the memory
;;;; image's MCP listener: `claude mcp add memory -- sbcl --script
;;;; <this> --port 4009 [--host H] [--principal claude-code/laptop]`.
;;;; The principal's secret comes from ~/.cl-llm-memory/client.sexp,
;;;; (("<producer>" . "<secret>") ...), so the command line carries
;;;; none.  Exits when either side closes.  docs/agent-memory.md.

(let ((*standard-output* *error-output*))
  (require :asdf)
  (flet ((try (path) (when (probe-file path) (load path) t)))
    (let ((home (user-homedir-pathname)))
      (or (try (merge-pathnames "quicklisp/setup.lisp" home))
          (try (merge-pathnames ".quicklisp/setup.lisp" home)))))
  (funcall (intern "QUICKLOAD" "QL") '(:usocket :bordeaux-threads)
           :silent t))

(defpackage #:cl-llm.memory-mcp-client (:use #:cl))
(in-package #:cl-llm.memory-mcp-client)

(defun %option (name default)
  (let ((tail (member name sb-ext:*posix-argv* :test #'string=)))
    (if (and tail (cdr tail)) (second tail) default)))

(defun %secret (principal)
  (let ((path (merge-pathnames ".cl-llm-memory/client.sexp"
                               (user-homedir-pathname))))
    (unless (probe-file path)
      (error "no ~a to look up ~a in" path principal))
    (let ((entries (with-open-file (s path)
                     (let ((*read-eval* nil)) (read s nil nil)))))
      (or (cdr (assoc principal entries :test #'string=))
          (error "no secret for ~a in ~a" principal path)))))

(defun %pump (from to done)
  (bt:make-thread
   (lambda ()
     (unwind-protect
          (loop for line = (read-line from nil nil)
                while line
                do (write-line line to) (force-output to))
       (funcall done)))))

(let* ((host (%option "--host" "127.0.0.1"))
       (port (parse-integer (%option "--port" "4009")))
       (principal (%option "--principal" nil))
       (socket (usocket:socket-connect host port :element-type 'character))
       (stream (usocket:socket-stream socket))
       (lock (bt:make-lock))
       (finished nil))
  (when principal
    (format stream "{\"cl-llm-memory\": {\"principal\": ~s, ~
                    \"secret\": ~s}}~%"
            principal (%secret principal))
    (force-output stream))
  (flet ((done () (bt:with-lock-held (lock) (setf finished t))))
    (%pump *standard-input* stream #'done)
    (%pump stream *standard-output* #'done)
    (loop until (bt:with-lock-held (lock) finished) do (sleep 0.1))
    (ignore-errors (usocket:socket-close socket))
    (sb-ext:exit :code 0 :abort t)))
```

- [ ] **Step 5: The memory image**

In `scripts/memory-image.lisp`: change the quickload to `(ql:quickload '(:cl-llm/agent/mcp :swank) :silent t)` and, when `CL_LLM_MEMORY_QUERY_TOOL` is `"1"`, also `:cl-llm/agent/prolog`; add `(#:mcp #:cl-llm.agent.mcp)` to the package's local nicknames; add `(defvar *listener* nil "The MCP listener, or NIL when CL_LLM_MEMORY_MCP_PORT is empty.")` after `*clock*`; in `start`, after `(setf gdb:*graph* *graph*)`, add:

```lisp
    (let ((port (%env "CL_LLM_MEMORY_MCP_PORT" "4009")))
      (when (plusp (length port))
        (setf *listener*
              (mcp:start-listener
               :bind (%env "CL_LLM_MEMORY_MCP_BIND" "127.0.0.1")
               :port (parse-integer port)
               :stores (list *graph*) :write-store *graph*
               :provider (intern (string-upcase
                                  (%env "CL_LLM_MEMORY_IDENTITY" "secret"))
                                 :keyword)
               :principals-path (%env "CL_LLM_MEMORY_PRINCIPALS"
                                      (%home ".cl-llm-memory/principals.sexp"))
               :default-producer *producer*
               :query-tool (equal (%env "CL_LLM_MEMORY_QUERY_TOOL") "1")))))
```

and print the listener in the banner (`"; mcp ~A:~A"` with bind and port, or `"; mcp off"`). Replace `stop` with:

```lisp
(defun stop ()
  "Stop the listener, close the store without a snapshot (unbounded work
before the .dirty marker clears; a backup is a separate operation), then
the clock; never signals.  The exit hook: SBCL runs *EXIT-HOOKS* on
SIGTERM (measured in docs/superpowers/notes/2026-09-06-memory-mcp-
engine-api-facts.md E5), so a stop from the shell or systemd leaves no
.dirty marker."
  (when *listener*
    (mcp:stop-listener *listener*)
    (setf *listener* nil))
  (when *graph*
    (ignore-errors (let ((gdb:*graph* *graph*))
                     (gdb:close-graph *graph* :snapshot-p nil)))
    (setf *graph* nil gdb:*graph* nil))
  (when *clock*
    (ignore-errors (gdb:close-system-clock *clock*))
    (setf *clock* nil)))
```

In `scripts/run-memory.sh` add the exports for `CL_LLM_MEMORY_CLOCK` (default `$HOME/.cl-llm-memory/clock/`), `CL_LLM_MEMORY_MCP_PORT` (`4009`), `CL_LLM_MEMORY_MCP_BIND` (`127.0.0.1`), `CL_LLM_MEMORY_PRINCIPALS` (`$HOME/.cl-llm-memory/principals.sexp`), `CL_LLM_MEMORY_IDENTITY` (`secret`), `CL_LLM_MEMORY_QUERY_TOOL` (empty), and `LC_ALL` (`C.UTF-8`), and update its header comment to mention the listener. Verify the image parses without loading it: with `:cl-llm/agent/mcp` quickloaded, `(let ((*package* (find-package :cl-user))) (with-open-file (s "scripts/memory-image.lisp") (loop for form = (read s nil :eof) until (eq form :eof))))` — adjust `*package*` if a form needs the script's own package.

- [ ] **Step 6: Run the three process tests, then all three suites**

Run the one-test command for each process test. Expected: PASS. If `the-solo-server-round-trips-and-leaves-the-store-clean` fails inside `connect` with a handshake timeout, read the child's stderr by launching it with `%launch-solo` and `%stderr` — the likeliest cause is a load error in the child (a system not found through `CL_LLM_ASDF_REGISTRY`); fix the registry list, not the test. Run `cl-llm/agent/mcp`, then memory, then agent. Expected: green; counts recorded.

- [ ] **Step 7: Commit**

```bash
git add scripts/memory-mcp.lisp scripts/run-memory-mcp.sh \
        scripts/memory-mcp-client.lisp scripts/memory-image.lisp \
        scripts/run-memory.sh tests-agent-mcp/process-tests.lisp
git commit -m "feat(scripts): the solo MCP server, the relay, the listener in the image, a bounded stop (#57)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

### Task 5: CI and the docs

**Files:**
- Modify: `.github/workflows/test.yml`, `docs/ci.md`, `docs/agent-memory.md`, `README.md`

- [ ] **Step 1: CI**

In `.github/workflows/test.yml`, change the engine-deps loop so each spec carries an owner, and add the two clones:

```yaml
          for spec in "kraison vivace-graph experiment" \
                      "kraison cl-temporal-extent master" \
                      "kraison cl-mcp main" \
                      "quasi opsis main"; do
            set -- $spec
            if [ -d ~/ci-deps-cl-llm/$2/.git ]; then
              git -C ~/ci-deps-cl-llm/$2 fetch -q origin
              git -C ~/ci-deps-cl-llm/$2 checkout -qf origin/$3
            else
              git clone -q -b $3 https://github.com/$1/$2 \
                ~/ci-deps-cl-llm/$2
            fi
            echo "$2 @ $(git -C ~/ci-deps-cl-llm/$2 rev-parse --short HEAD)"
          done
```

Add two `(list :directory (merge-pathnames "ci-deps-cl-llm/cl-mcp/" (user-homedir-pathname)))` and `... "ci-deps-cl-llm/opsis/" ...` entries to the `initialize-source-registry` form; add `:cl-llm/agent/mcp/tests` to the quickload list and `--eval '(asdf:test-system :cl-llm/agent/mcp)'` at the end of the chain; set `CL_LLM_ASDF_REGISTRY` for the step to `$PWD/:$HOME/ci-deps-cl-llm/vivace-graph/:$HOME/ci-deps-cl-llm/cl-temporal-extent/:$HOME/ci-deps-cl-llm/cl-mcp/:$HOME/ci-deps-cl-llm/opsis/` (an `env:` on the step) so the process tests' children build the same trees. Update the file's header comment.

In `docs/ci.md`: the suite list gains agent/mcp; the clone list gains `cl-mcp` (kraison) and `opsis` (quasi); the process tests spawn the solo server as a child that builds through `CL_LLM_ASDF_REGISTRY`; replace the stale sentence saying the agent/prolog suite quickloads `graph-db/gui` and web dependencies with: the guard runs on `graph-db/query` (#44).

- [ ] **Step 2: The docs**

In `docs/agent-memory.md`, immediately after "Running a memory image" (before "## What this is not"), add:

```markdown
## The memory as an MCP server

The agent tools reach any MCP client from this repo, without
cl-mcp-server or the blackboard: `cl-llm/agent/mcp` registers each
tool from `make-agent-tools` on a `cl-mcp` server, the schema converted
to `cl-mcp`'s form, the decoded arguments converted back, a refusal
returned as text with `isError`. The scope -- stores in trust order,
the write store, the producer, the caps -- is configuration; no tool
takes a store, so the model names subjects and never stores, as
`docs/agent-tools.md` promises.

### Solo: one process per session

```
claude mcp add --scope user memory -- /path/to/cl-llm/scripts/run-memory-mcp.sh
```

The client launches `scripts/memory-mcp.lisp` through the wrapper. It
reads the memory image's variables (the table above, plus
`CL_LLM_MEMORY_CLOCK`), opens the clock and then the store on it, and
serves stdin/stdout; every other byte goes to stderr. A multi-store
scope is `CL_LLM_MEMORY_SCOPE=private=/dir,working=/dir` in trust
order with `CL_LLM_MEMORY_WRITE` naming the write store (default the
last); `CL_LLM_MEMORY_QUERY_TOOL=1` adds the guarded Prolog tool. The
child builds from the trees in `CL_LLM_ASDF_REGISTRY` (default: the
checkout the script lives in). A store the memory image, or another
session's solo server, already holds makes it exit 1 with "Another
image may hold the store" before any handshake: graph-db stores have
one holder, and there is no mode that lets two processes open one.

### In the image: a listener, many sessions

The memory image listens on `CL_LLM_MEMORY_MCP_PORT` (default 4009,
empty to disable) at `CL_LLM_MEMORY_MCP_BIND` (default loopback). Each
connection gets its own server and its own producer. A client connects
through the relay:

```
claude mcp add --scope user memory -- sbcl --script \
  /path/to/cl-llm/scripts/memory-mcp-client.lisp --port 4009 \
  --principal claude-code/laptop
```

or through `socat STDIO TCP:127.0.0.1:4009` without a principal.

**Identity.** With nothing configured, a loopback connection writes as
the image's producer. Named principals are a file,
`CL_LLM_MEMORY_PRINCIPALS` (default `~/.cl-llm-memory/principals.sexp`):

```lisp
(("claude-code/laptop" . "a-long-random-secret")
 ("hermes/laptop"      . "another"))
```

The relay sends one hello line before any JSON-RPC, naming its
principal and the secret it reads from `~/.cl-llm-memory/client.sexp`
(same shape); a match sets the connection's producer, a mismatch closes
the connection before the handshake, and a connection from off
loopback with no hello is refused. Binding to any non-loopback address
with no principals file is refused at startup. `CL_LLM_MEMORY_IDENTITY=
tailscale` swaps the provider for the peer's tailnet node
(`claude-code/<node>`), for hosts on one tailnet; it is off by default.

### Shutdown

Both modes close the store on EOF, on SIGTERM (SBCL runs its exit
hooks on SIGTERM), and on normal exit, in one idempotent `stop`: the
listener first, then each store with `*graph*` bound and without the
snapshot `close-graph` takes by default -- that snapshot is unbounded
work before the `.dirty` marker clears, and a backup is a separate
operation -- then the clock. Claude Code sends a spawned stdio server
SIGTERM and then SIGKILL after an undocumented grace period, sends no
MCP-level goodbye, and never respawns a crashed stdio server; whether
concurrent sessions share a user-scoped stdio server is undocumented,
and the solo mode assumes they do not, which is why a held store is
refused rather than shared. SIGKILL leaves at worst a `.dirty` marker
for the write-ahead log to recover on the next open.
```

Add `CL_LLM_MEMORY_CLOCK` to the variable table in "Running a memory image", and in `README.md` add one sentence under the agent-memory pointer: the memory serves any MCP client, see `docs/agent-memory.md` "The memory as an MCP server".

- [ ] **Step 3: Run the three suites**

`cl-llm/agent/mcp`, memory, agent; record counts. Verify `.github/workflows/test.yml` parses (`python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))"`).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test.yml docs/ci.md docs/agent-memory.md README.md
git commit -m "ci,docs: the agent/mcp suite with cl-mcp and opsis; the memory as an MCP server (#57)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeVU44qpXuW4oUz7hnDMNU"
```

---

## After the tasks (controller)

1. Final whole-branch review on the most capable model; one fix wave; one scoped re-review.
2. A manual check on this host: `claude mcp add` the solo server against a scratch store from a real Claude Code session, call `recall`, exit, confirm no `.dirty`. Kevin does this or authorises it.
3. Comment on #57; Kevin decides the push and the PR against `main`. CI needs the two new clones to succeed on the runner.
