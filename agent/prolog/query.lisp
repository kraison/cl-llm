;;;; agent/prolog/query.lisp -- free-text Prolog through the engine's
;;;; guard, effects off, the operator's budgets.  Spec SS8.

(in-package #:cl-llm.agent.prolog)

(defun %json-cell (value)
  "VALUE as a jzon-writable JSON cell: NIL becomes the symbol NULL, so
CL-LLM.JSON:TO-JSON emits \"null\" rather than \"false\" (src/json.lisp's
header; jzon's WRITE-VALUE treats (EQL NIL) and (EQL NULL) as distinct
atoms).  An unbound query variable or an empty slot parses to NIL from
the engine's own JSON, and the two cases are indistinguishable once
parsed, so every NIL cell here is a JSON null, never false."
  (or value 'null))

(defun %guarded-rows (graph text limit max-inferences timeout)
  "Read, guard and run TEXT against GRAPH; (values columns rows
truncated-p).  :PACKAGE is GRAPH-DB, not the schema package: the
runner re-interns heads there and CL-LLM.MEMORY does not use GRAPH-DB
(kraison/vivace-graph#322); a store with edge types is refused below.
No effect policy is passed because RUN-QUERY-GOALS hard-codes
:EFFECTS NIL and :SNAPSHOT T -- the test
A-WRITE-EFFECT-GOAL-IS-REFUSED-BY-THE-RUNNER pins that (spec SS8, SS9)."
  (when (graph-db.gui::%schema-type-names graph :edge)
    (error "store ~a declares edge types; free-text queries over them ~
wait on kraison/vivace-graph#322" (mem:store-name graph)))
  (let ((scratch (graph-db.gui::%make-scratch-package)))
    (unwind-protect
         (multiple-value-bind (vars goals)
             (graph-db.gui::%read-guarded-forms
              text scratch (graph-db.gui::%guard-context graph scratch))
           (let* ((cap (min limit graph-db::*query-default-limit*))
                  (probe (if (< cap graph-db::*query-default-limit*)
                             (1+ cap) cap))
                  (json-string
                    (let ((graph-db::*query-default-max-inferences*
                            max-inferences)
                          (graph-db::*query-default-timeout* timeout))
                      (graph-db::run-query-goals
                       vars goals graph
                       :package (find-package :graph-db)
                       :limit probe :format :json)))
                  (columns (mapcar #'graph-db::%query-var-field vars))
                  (rows (coerce (json:parse json-string) 'list))
                  (truncated (if (> probe cap) (> (length rows) cap)
                                 (>= (length rows) cap))))
             (values columns
                     (subseq rows 0 (min cap (length rows)))
                     truncated)))
      (delete-package scratch))))

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
                       (lambda (row)
                         (map 'vector
                              (lambda (c) (%json-cell (gethash c row)))
                              columns))
                       rows)
           "truncated" (agent:json-bool truncated))))))))
