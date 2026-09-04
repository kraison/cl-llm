;;;; agent/prolog/query.lisp -- free-text Prolog through the engine's
;;;; guarded runner (graph-db/query), effects off, the operator's
;;;; budgets.  Spec SS8; kraison/vivace-graph#322.

(in-package #:cl-llm.agent.prolog)

(defun %json-cell (value)
  "VALUE as a jzon-writable JSON cell: NIL becomes the symbol NULL, so
CL-LLM.JSON:TO-JSON emits \"null\" rather than \"false\" (src/json.lisp's
header; jzon's WRITE-VALUE treats (EQL NIL) and (EQL NULL) as distinct
atoms).  The runner's :DATA cells give NIL for an unbound variable and
for an empty slot alike, so every NIL cell here is a JSON null, never
false."
  (or value 'null))

(defun %guarded-rows (graph text limit max-inferences timeout)
  "TEXT through the engine's guarded runner against GRAPH; (values
columns rows truncated-p), rows as lists of JSON-shaped cells
(kraison/vivace-graph#322).  The runner owns the screen, the scratch
package, the whitelist, the clamp and the probe; edge functors resolve
in their own package since vivace-graph#329.  No effect policy is
passed because the runner hard-codes :EFFECTS NIL and :SNAPSHOT T --
A-WRITE-EFFECT-GOAL-IS-REFUSED-BY-THE-RUNNER pins that (spec SS8, SS9)."
  (graph-db.query:run-guarded-prolog text graph
                                     :limit limit
                                     :max-inferences max-inferences
                                     :timeout timeout
                                     :format :data))

(defun %find-store (stores store)
  "The graph named STORE in STORES, or the first when STORE is NIL."
  (if store
      (or (find store stores :key #'mem:store-name :test #'string=)
          (error "store ~s is not in this scope" store))
      (first stores)))

(defun make-query-tool (stores &key (max-rows 50) (max-inferences 100000)
                                    (timeout 5))
  "The QUERY tool over STORES (names a model may pass as store; the
first is the default).  Effects off, one snapshot, MAX-INFERENCES and
TIMEOUT (seconds) are the operator's; MAX-ROWS too, further clamped by
the engine's own GRAPH-DB:*QUERY-DEFAULT-LIMIT* (1000, SS8)."
  (llm:make-tool
   "query"
   "Run a read-only Prolog query against one memory store and get rows
back.  Goals are parenthesised forms over the store's own vertex
types and slots, e.g. (is-a ?c belief-binary) (node-slot-value ?c
relation ?r); ?variables become columns, camelCased by the engine
(?valid-from -> validFrom).  No side effects; bounded in inferences,
time and rows.  store names which store (default the first); limit
caps rows."
   '((text :type string)
     (store :type string :optional t)
     (limit :type integer :optional t))
   (lambda (text store limit)
     (let ((graph (%find-store stores store)))
       (multiple-value-bind (columns rows truncated)
           (%guarded-rows graph text (agent:clamp limit max-rows)
                          max-inferences timeout)
         (json:to-json
          (json:jobject
           "store" (mem:store-name graph)
           "columns" (coerce columns 'vector)
           "rows" (map 'vector
                       (lambda (row) (map 'vector #'%json-cell row))
                       rows)
           "truncated" (agent:json-bool truncated))))))))
