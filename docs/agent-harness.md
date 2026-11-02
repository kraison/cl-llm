# The agent harness (`cl-llm/harness`)

Run a named persona as a bounded, attributed, guarded run from Lisp
(kraison/cl-llm#85). A resident process launches a run in response to
an event it receives (a message, a schedule, a matched rule) and
accounts for it afterwards. Design:
`docs/superpowers/specs/2026-11-02-agent-harness-and-conversational-rag-design.md`,
§6; this page is the user's view of it.

`cl-llm/harness` depends on `cl-llm` and `bordeaux-threads` only. It
is the one cl-llm system that uses threads: the per-persona
concurrency limit needs a lock. Core `cl-llm` stays thread-free.

## Personas

A persona is what a run is: a system prompt, the tools it may call, a
provider, generation parameters and budgets. Build one in Lisp:

```lisp
(harness:make-persona
 :name "summariser"                 ; [a-z0-9-]+
 :system "Summarise the input in three sentences."
 :tools '("recall" "retrieve")      ; names, or llm:tool objects
 :provider '(:kind :openai-compatible
             :base-url "http://127.0.0.1:8080/v1"
             :model "local"
             :api-key-file "~/.config/llama/key")
 :parameters '(:temperature 0.2 :max-tokens 12000)
 :max-turns 8 :max-seconds 300 :max-run-tokens 60000)
```

`:provider` is either an `llm:provider` object or a description:
`:kind` is `:openai-compatible` (with `:base-url`) or `:anthropic`,
with an optional `:model` and `:api-key-file`. **A persona names a key
file, never a key.** `persona-make-provider` reads the file each time
it builds the provider, so a rotated key is picked up; an unreadable
or empty file is a `persona-error` that names the path and never its
contents. `~/` at the start of the path is the home directory.

### Persona files

The same persona as a file, `summariser.persona`:

```lisp
(:name "summariser"
 :system "Summarise the input in three sentences."
 :tools ("recall" "retrieve")
 :provider (:kind :openai-compatible
            :base-url "http://127.0.0.1:8080/v1"
            :model "local"
            :api-key-file "~/.config/llama/key")
 :parameters (:temperature 0.2 :max-tokens 12000)
 :budgets (:max-turns 8 :max-seconds 300 :max-run-tokens 60000))
```

`load-persona-file` reads exactly one plist with `*read-eval*` off,
into the keyword package, so a `#.` form is a read error and a bare
symbol becomes a keyword. Every key is checked: an unknown one (a
typo such as `:sytem`) is a `persona-error` naming it. `:budgets` takes
`make-persona`'s budget keywords: `:max-turns`, `:max-run-tokens`,
`:max-seconds`, `:max-concurrent`, `:max-queued`,
`:daily-token-budget` and `:daily-run-budget`.

### Finding a persona by name

`find-persona` is a protocol: `(find-persona source name)` returns the
persona or NIL. `make-persona-directory` is the source that ships here:
`<directory>/<name>.persona` files. The name must be `[a-z0-9-]+`
before it becomes a path, and the file's own `:name` must match it. A
store-backed source is a method on `find-persona`, added when a
consumer needs one.

## The run record

`run-persona` returns a `run`, whatever happened. Its readers:

| Reader | What it holds |
|---|---|
| `run-id` | `r-<time>-<counter>-<salt>`, base 36, unique within the host |
| `run-persona-name`, `run-input` | which persona ran, on what |
| `run-producer` | the attribution every claim the run writes carries |
| `run-started`, `run-finished` | universal times |
| `run-elapsed` | seconds, from `*clock*` |
| `run-turns` | model requests made |
| `run-input-tokens`, `run-output-tokens` | summed over every request |
| `run-stop-reason` | how it stopped (below) |
| `run-error` | the condition, when it stopped on an error |
| `run-text` | the final answer's text |
| `run-tool-calls` | oldest first, `(:name :arguments :result :error-p)` |
| `run-response` | the last model response |

`*clock*` is a function returning seconds; tests rebind it to drive the
deadline without waiting.

### Attribution

A run's producer is `<persona>/<host>/<run-id>`, with the host from
`host-principal` (`box.local` becomes `box`). Pass `:producer
"<agent>/<host>"` to `run-persona` to name the principal yourself; the
run id is still appended. Either way the result must be canonical
`[a-z0-9-/]+`, or `run-producer-for` signals `persona-error`.

Every run is its own producer, so every claim a run writes is traceable
to the input that caused it. The memory store's recall reads a
producer ending in `/` as a prefix (#82), so `"summariser/box/"`
answers for every run of that persona on that host.

## Running a persona

```lisp
(harness:run-persona persona input &key conversation producer tools)
;; => a RUN
```

- `input` is the user turn, a string.
- `tools` are `llm:tool` objects the caller offers, such as a subset of
  `agent:make-agent-tools`. The persona's tool names choose among them
  first, then the `deftool` registry. Only the persona's tools reach the
  model. An unknown name stops the run with `:error`.
- `conversation`, when given, is continued: the user turn and the
  replies stay on success and are rolled back on any stop (`llm:send`'s
  rule). It lends its messages only: for the run, the persona's system
  prompt, provider, model and parameters apply, and the conversation's
  own come back afterwards. Without one, the run gets a fresh conversation.
- `producer` names the principal (above).

Every failure is a returned run with a stop reason, never a signalled
condition: a resident process handles a run, it does not unwind from
one. The one exception is an uncanonical `:producer`, an argument
error that signals `persona-error` before anything runs.

### Stop reasons

| Reason | Meaning |
|---|---|
| `:end-turn`, `:max-tokens`, `:stop` | the model's own |
| `:max-turns` | the model still asked for tools after `:max-turns` requests |
| `:deadline` | `:max-seconds` passed |
| `:token-budget` | the run's tokens reached `:max-run-tokens` |
| `:busy` | the persona's concurrency limit and queue were full |
| `:daily-budget` | the persona's day's runs or tokens are spent |
| `:error` | anything else; `run-error` holds the condition |

### How the guards work

The guards wrap what `llm:send` is given, so core's tool loop is
unchanged. The provider is wrapped: before each model request it
checks the deadline and the token budget, and it caps `llm:*timeout*`
at the time left. After each response it adds the reported usage to
the run, counting a response without usage as zero. Each tool is
wrapped with `llm:copy-tool`: the deadline is checked before its body,
and the call is recorded.

- **A tool body is never interrupted.** A thread interrupt inside a
  graph transaction can corrupt a store. So a slow tool overruns the
  deadline by its own duration, and the run stops at the next check. A
  long tool can read `(harness:time-left)`, the seconds remaining or
  NIL, and give up early.
- **One request can outlast the deadline.** Its timeout is capped at
  the time left, but `llm:*retries*` can retry it within that cap.
- **The token budget is checked before a request,** so the request
  that crosses it completes and is counted.

## Per-persona limits

Two personas answering each other is the obvious runaway, so each
persona name has its own limits across every run in the image.

- **Concurrency.** At most `:max-concurrent` runs at once (default 1)
  and `:max-queued` waiting (default 0). A run beyond both returns at
  once with `:busy`. A queued run waits for a slot until its deadline,
  and returns `:deadline` if the deadline passes first.
- **A daily budget.** `:daily-run-budget` caps the runs a persona
  starts per UTC day, and `:daily-token-budget` caps the tokens they
  use. A run that would start past either returns `:daily-budget`
  without calling the model. A run whose tokens push the day past
  its token budget is stopped with `:daily-budget` before its next
  request.

State is kept per persona *name* in the image, so two persona objects
with the same name share it. `(harness:persona-usage name)` returns
the day's tokens and runs, and the runs active and waiting.
`(harness:reset-persona-state)` forgets them, for tests and operators.

**A restart resets the day's counters** (v1). The day is read from
`harness:*wall-clock*`, a function returning universal time, which
tests rebind.

## Accounting (`cl-llm/agent`)

`agent:record-run` writes a run into a memory store as claims, so a
dashboard sees what ran, on what, for how much:

```lisp
(agent:record-run graph run &key (scope (list graph)))
;; => one decision per fact
```

Each fact is an observed belief about the subject `(:run . <run-id>)`,
concluded under the run's own producer and the rule `harness-run`:

| Relation | Object |
|---|---|
| `ran-as` | `(:persona . <name>)` |
| `stopped` | `(:stop-reason . "end-turn")`, and so on |
| `turns` | `(:count . "<n>")` |
| `input-tokens`, `output-tokens` | `(:count . "<n>")` |
| `elapsed-ms` | `(:count . "<ms>")` |
| `started` | `(:instant . "<RFC 3339>")` |

Recall them by the run's subject, or every run of a persona on a host
by producer prefix:

```lisp
(mem:recall graph (cons :run run-id) :producer "summariser/box/")
```

`record-run` owns its transactions, like `mem:conclude`: call it
outside one. It lives in `cl-llm/agent` because it needs the memory
store; `cl-llm/harness` itself has no vivace-graph dependency.
