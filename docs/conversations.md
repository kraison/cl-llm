# Conversations: kept, compacted, and asked about

A conversation that outlives the image, and a RAG turn that understands
a follow-up (kraison/cl-llm#89, #90). Design:
`docs/superpowers/specs/2026-11-02-agent-harness-and-conversational-rag-design.md`,
§7 and §8; this page is the user's view of it.

## Stored conversations (core `cl-llm`)

A `stored-conversation` is an `llm:conversation` plus what a store
needs to keep it:

| Accessor | Holds |
|---|---|
| `stored-conversation-id` | `c-<time>-<counter>-<salt>`, canonical `[a-z0-9-]+` |
| `stored-conversation-owner`, `-title` | strings, or NIL |
| `stored-conversation-created`, `-updated` | universal times |
| `stored-conversation-conversation` | the `llm:conversation`: system, model, parameters, messages |
| `stored-conversation-summary`, `-summarized` | the running summary, and how many leading messages it covers (Compaction, below) |
| `stored-conversation-turns` | one annotation per turn, oldest first: an `equal` hash-table with string keys |
| `stored-conversation-current-p` | whether this is its owner's current conversation |

```lisp
(let ((sc (llm:make-stored-conversation :owner "ada" :system "Be terse.")))
  (llm:record-turn sc "What is CLOS?" "Common Lisp's object system.")
  (llm:stored-conversation-to-json sc))
```

`record-turn` appends a user question and an assistant answer, and the
turn's annotation, and sets `updated`. A consumer puts whatever it
wants to remember about a turn in the annotation; the conversational
turn (below) records the standalone question and the sources there.

### The JSON

`stored-conversation-to-json` and `stored-conversation-from-json`
convert to and from one JSON object:

```json
{"version": 1, "id": "c-...", "owner": "ada", "title": null,
 "created": 3971000000, "updated": 3971000060, "current": true,
 "system": "Be terse.", "model": null,
 "parameters": {"temperature": 0.2, "max-tokens": 4000},
 "summary": null, "summarized": 0,
 "messages": [
   {"role": "user", "content": [{"type": "text", "text": "..."}]},
   {"role": "assistant", "content": [
     {"type": "text", "text": "..."},
     {"type": "tool-use", "id": "t1", "name": "add",
      "arguments": {"a": 1, "b": 2}}]},
   {"role": "user", "content": [
     {"type": "tool-result", "tool-use-id": "t1", "content": "3",
      "error": false}]}],
 "turns": [{"standalone": "..."}]}
```

- **The provider is never stored,** nor any key: a conversation names
  no connection. The caller supplies one when it continues the
  conversation.
- **Reading interns nothing** but the four parameter keys
  (`:temperature`, `:max-tokens`, `:top-p`, `:stop`). Annotations stay
  string-keyed hash-tables.
- **Unknown keys are ignored** and missing optional ones default, so an
  older reader takes a newer record.
- **An id that is not `[a-z0-9-]+` is refused** with `llm-parse-error`:
  an id becomes a file name and an index key.
- A float parameter comes back as a double-float.

## Stores

A store keeps an owner's conversations. The protocol is six generic
functions; a store implements the first three plus `list-conversations`
and inherits the rest:

| Function | Does |
|---|---|
| `(save-conversation store sc)` | write SC, replacing any earlier version |
| `(load-conversation store id &key owner)` | SC, or NIL when absent **or when OWNER differs** |
| `(list-conversations store owner)` | OWNER's conversations, newest `updated` first |
| `(current-conversation store owner)` | OWNER's current one, or NIL |
| `(make-conversation-current store sc)` | SC current, the owner's others not |
| `(new-conversation store owner &key title system parameters model)` | a fresh one, saved and made current |

Starting afresh never deletes anything: the previous conversation is
kept, no longer current, and can be loaded and continued. Pass
`:owner` to `load-conversation` whenever the id comes from outside, so
someone else's conversation answers as not found.

### The file store (core)

```lisp
(defvar *store* (llm:make-file-conversation-store "~/conversations/"))
(llm:new-conversation *store* "ada" :system "Be terse.")
```

One `<id>.json` per conversation in one directory, written through a
temporary file and a rename so a crash never leaves half a record.
Listing reads every `*.json`; a file that does not parse is skipped
with a `warning`. It reads every file to list one owner's, so it suits
scripts and tests. A server wants the graph store.
