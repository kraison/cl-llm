# cl-llm/eval Design

**Date:** 2026-07-17
**Status:** Approved
**Relationship:** Plan 2, following the core client (Plan 1). Concretizes §9 of
`2026-07-17-cl-llm-design.md`.

## 1. Purpose

`cl-llm/eval` is the "tune by measuring" loop: define a dataset, define
variants (model/prompt/parameter combinations), define scorers, run the cross
product, and get a comparable table. It exists so that choosing a model, a
system prompt, or a temperature is an experiment with numbers rather than a
guess.

It is a **separate ASDF system** (`cl-llm/eval`) that depends on `cl-llm`. A
user who never evaluates never loads it.

## 2. Scope

### In scope

- A `dataset × variants × scorers` grid with `defsuite` / `run-suite`.
- Scorers returning a numeric score plus optional explanation: `exact-match`,
  arbitrary predicates (`defscorer`), and LLM-as-judge (`defjudge`).
- Prompt/system shaping as a tunable axis (via a variant's `:prompt-fn`).
- Serial execution with a pluggable map seam for opt-in concurrency.
- Error cells: a failing call is recorded, not fatal to the run.
- A text result table plus a per-case detail report.
- A `mock-provider` (in the **core** package) for deterministic offline tests.

### Explicit non-goals (deferred, as in the core spec §9)

- Persisted run history.
- Baseline regression detection (comparing a run to a stored baseline).
- Report export (HTML/CSV/JSON/file output). Output is text to a stream.

## 3. The `mock-provider` (lives in core `cl-llm`, not eval)

A real `provider` subclass whose request methods return scripted responses with
no HTTP. It is placed in the **core** package because it makes the whole library
testable by its users, not only by cl-llm's own suite; eval merely consumes it.

```lisp
(make-mock-provider :responder (lambda (conversation) "scripted reply text"))
```

- `(make-mock-provider &key responder model)` — `responder` is a function of the
  outgoing `conversation` returning either a string (becomes the assistant text)
  or a fully-formed `response` (for scripting tool calls / stop reasons / usage).
- Methods on `chat-request` and `stream-request` specialize `mock-provider`:
  `chat-request` calls `responder` and wraps a string result in a `response`;
  `stream-request` yields the text as a single-chunk stream so the streaming
  machinery still exercises. Neither touches the HTTP layer.
- No API key, no network, fully deterministic.

Exported from `cl-llm`: `mock-provider`, `make-mock-provider`,
`mock-provider-responder`.

## 4. Core objects (package `cl-llm.eval`)

### Cases and datasets

```lisp
(make-case input &key expected metadata) ; => eval-case
```

- `eval-case` struct: `case-input` (any object; usually a string prompt),
  `case-expected` (optional; the reference answer for exact-match/judge),
  `case-metadata` (optional plist for user tags).
- A **dataset** is simply a list of `eval-case`s. No wrapper type.

### Scores

```lisp
(score value &key explanation) ; => score, value a real in [0,1]
```

- `score` struct: `score-value`, `score-explanation` (string or nil).
- A real value is **clamped** to `[0,1]` at construction (silently — a judge
  parsing "8/10" or replying "1.2" should be robust, not fatal). A non-real
  value signals `llm-eval-error` (that is a programming mistake, not noisy
  model output).

### Scorers

```lisp
(defscorer name (case response) &body body) ; body returns a SCORE
```

- Registers a `scorer` (name + function) in `*scorers-registry*`, and defines
  `name` as an ordinary function too (the `deftool` pattern: nothing hidden).
- `case` is a lexical parameter (locally shadowing `cl:case`; intentional and
  scoped). `response` is the `cl-llm:response` from the call, or `nil` for an
  error cell — a scorer must tolerate `nil` (helpers make this easy).
- Built in: `exact-match` — `1.0` when `(response-text response)` equals
  `(case-expected case)` (string=), else `0.0` with an explanation. Signals
  `llm-eval-error` if the case has no `expected`.

### LLM-as-judge

```lisp
(defjudge name (case response) &body body) ; body returns the JUDGE PROMPT string
```

- Expands to a scorer that: builds the judge prompt from `body`, calls
  `(ask prompt)` under the ambient `*provider*`/`*model*`, parses a
  `0.0–1.0` score and reasoning from the judge's reply, and returns that as a
  `score`.
- Parsing: the judge is instructed to answer with a leading number in `[0,1]`
  (or `0–100`, normalized) followed by a rationale; a small tolerant parser
  extracts it. An unparseable reply yields `(score 0.0 :explanation
  "unparseable judge output: <first 120 chars>")` — a judge misfire never sinks
  the run.
- The judge call is itself subject to the same error handling as any cell; a
  signalled `llm-error` inside a judge yields a `0.0` score with the condition
  in the explanation, not a propagated signal.

### Variants

- A **variant** is a plist of `ask` keyword arguments (`:model`, `:temperature`,
  `:system`, `:top-p`, `:stop`, `:tools`, `:max-tokens`), plus two eval-only
  keys:
  - `:label` — a short string naming the variant in the table (defaults to a
    compact rendering of the distinguishing params).
  - `:prompt-fn` — `(case) → prompt-string`. Defaults to `#'case-input`, so by
    default the case input is the prompt. This is what makes prompt engineering
    and system prompts tunable axes, not just sampling params.
- The eval-only keys are stripped before the remaining plist is applied to
  `ask`.

### Suites

```lisp
(defsuite name
  :dataset  dataset-form
  :variants (variant-plist ...)
  :scorers  (scorer-designator ...))   ; names or scorer objects
```

- Registers a `suite` in `*suites-registry*`. `dataset-form` is evaluated at
  `run-suite` time (so it can reference a special holding the cases).

## 5. Running

```lisp
(run-suite name-or-suite &key provider) ; => suite-result
```

- If `:provider` is given, it is bound to `*provider*` for the whole run, so it
  is the default for both variant calls and judge calls; a variant may still
  carry its own `:provider` to override for that variant's cells.
- Computes the `cases × variants` cross product. For each cell:
  1. Build the prompt via the variant's `:prompt-fn`.
  2. Call `ask` with the prompt and the variant's forwarded args.
  3. On success, run every scorer on `(case, response)`, collecting scores.
  4. On a signalled `llm-error`, record an **error cell**: `response` nil,
     `scores` nil, the condition captured. The run continues.
- Iteration goes through `*eval-map*` (default: a serial `mapcar`). Rebinding it
  to a parallel map (bordeaux-threads, lparallel, etc.) opts into concurrency
  without eval depending on any threading library. `*eval-map*` has the
  signature of `mapcar` restricted to one sequence: `(function list) → list`.

### `suite-result`

- Holds: the suite, and a list of `cell`s. Each `cell`: its `eval-case`, its
  variant label, the `response` (or nil), a plist of `scorer-name → score` (or
  nil for an error cell), and an `error` slot (the captured condition or nil).
- Computes on demand: mean `score-value` per `(variant, scorer)` over
  non-error cells, and an error count per variant. When a `(variant, scorer)`
  pair has **no** non-error cells to average, its mean is `nil` and renders as
  `—` (no division by zero).

## 6. Display

- `suite-result` has a `print-object` rendering the **summary table**: one row
  per variant, one column per scorer, each cell the mean score across the
  dataset; a trailing column shows the error count when any cell errored.
- `(report result &key (detail nil) (stream *standard-output*))` prints the
  summary table and, when `detail` is true, a per-case breakdown: for each case
  and variant, the score from each scorer and its explanation (the judge's
  reasoning is the payoff of running a judge at all). Pure text; no file output.

## 7. Errors

Condition hierarchy rooted at `cl-llm:llm-error` (reused), adding one:

- `llm-eval-error` (subtype of `llm-error`) — a harness misuse: a scorer given a
  case with no `expected` where it needs one, a non-real score value, an
  unknown suite/scorer name, or a malformed variant plist. (An out-of-range but
  real score value is clamped, per §4, not signalled.)

Model-call failures during a run are **not** signalled — they become error
cells. `llm-eval-error` is for programming/definition mistakes, surfaced
immediately.

## 8. Architecture

`cl-llm/eval` file layout (each file one responsibility):

```
  eval/packages.lisp   package cl-llm.eval
  eval/score.lisp      score struct, clamp, llm-eval-error
  eval/case.lisp       eval-case struct, make-case
  eval/scorer.lisp     scorer, defscorer, exact-match, registry
  eval/judge.lisp      defjudge, judge-reply parser
  eval/suite.lisp      variant handling, suite, defsuite, registry
  eval/run.lisp        *eval-map*, run-suite, cell, suite-result
  eval/report.lisp     print-object, report, table rendering
```

The `mock-provider` is core work: `src/mock.lisp` in the `cl-llm` system,
exported from `cl-llm`.

## 9. Testing

- **`cl-llm/eval/tests`** (FiveAM, MIT) — binds `*provider*` to a
  `mock-provider` and runs real suites offline: the cross-product shape,
  `exact-match`, a custom `defscorer`, a `defjudge` (with the mock scripted to
  return a gradeable reply, and a second case scripted to return garbage to
  exercise the unparseable path), error cells (mock scripted to signal), the
  aggregate means, and the report table.
- **Core** gains `mock-provider` tests in `cl-llm/tests`: `chat-request` and
  `stream-request` against a scripted responder, string-vs-`response` return.
- No test makes a network call or needs an API key.

Framework: **FiveAM**. License: **MIT**. Lisp sources: spaces only, never tabs.
No threads in eval itself (the map seam is the concurrency story). SBCL first;
nothing implementation-specific, so ECL/Clozure remain viable.
