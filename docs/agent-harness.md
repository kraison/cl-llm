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
`host-principal` (`thoth.local` becomes `thoth`). Pass `:producer
"<agent>/<host>"` to `run-persona` to name the principal yourself; the
run id is still appended. Either way the result must be canonical
`[a-z0-9-/]+`, or `run-producer-for` signals `persona-error`.

Every run is its own producer, so every claim a run writes is traceable
to the input that caused it. The memory store's recall reads a
producer ending in `/` as a prefix (#82), so `"summariser/thoth/"`
answers for every run of that persona on that host.
