;;;; agent/prolog/query.lisp -- free-text Prolog through the engine's
;;;; guard, effects off, the operator's budgets.  Spec SS8.

(in-package #:cl-llm.agent.prolog)

(defun %guarded-rows (graph text limit max-inferences timeout)
  "Read, guard and run TEXT against GRAPH; (values columns rows
truncated-p).  Every symbol below is the GUI's #279 pipeline and the
DSL runner, all internal: kraison/vivace-graph#322 asks for an
exported RUN-GUARDED-PROLOG in a web-free subsystem, at which point
this body becomes one call.

:PACKAGE is GRAPH-DB itself, not (%SCHEMA-PACKAGE GRAPH): RUN-QUERY-
GOALS binds it around EVAL, and COMPILE-CALL's MAKE-FUNCTOR-SYMBOL
re-interns each goal head's bare name into whatever *PACKAGE* is at
that point, discarding the head's own home package -- so a global
functor (IS-A/2, NODE-SLOT-VALUE/3) only resolves back to its
registry entry when the interning package already has that exact
symbol, i.e. is GRAPH-DB or :USEs it.  CL-LLM.MEMORY does neither
(deliberately -- it :SHADOWs TRACE against CL:TRACE and stays plain
:USE CL rather than pull in GRAPH-DB's namespace too), so
%SCHEMA-PACKAGE here resolves to CL-LLM.MEMORY and every free-text
global-functor goal head 404s as \"unknown Prolog functor\".  GRAPH-DB
is correct for every schema this tool serves: DEF-CLAIM-CLASSES
(memory/schema.lisp) declares vertex types only, never a DEF-EDGE, so
there is no schema-owned edge functor whose resolution needs the
schema's own package."
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

(defun make-query-tool (stores &key (max-rows 50) (max-inferences 100000)
                                    (timeout 5))
  "The QUERY tool over STORES (names a model may pass as store; the
first is the default).  Effects off, one snapshot, MAX-INFERENCES and
TIMEOUT (seconds) and MAX-ROWS are the operator's (SS8)."
  (llm:make-tool
   "query"
   "Run a read-only Prolog query against one memory store and get rows
back.  Goals are parenthesised forms over the store's own vertex
types and slots, e.g. (is-a ?c belief-binary) (node-slot-value ?c
relation ?r); ?variables become columns.  No side effects; bounded in
inferences, time and rows.  store names which store (default the
first); limit caps rows."
   '((text :type string)
     (store :type string :optional t)
     (limit :type integer :optional t))
   (lambda (text store limit)
     (let ((graph (if store
                       (or (find store stores :key #'mem:store-name
                                 :test #'string=)
                           (error "store ~s is not in this scope" store))
                       (first stores))))
       (multiple-value-bind (columns rows truncated)
           (%guarded-rows graph text (agent:clamp limit max-rows)
                          max-inferences timeout)
         (json:to-json
          (json:jobject
           "store" (mem:store-name graph)
           "columns" (coerce columns 'vector)
           "rows" (map 'vector
                       (lambda (row)
                         (map 'vector (lambda (c) (gethash c row)) columns))
                       rows)
           "truncated" (agent:json-bool truncated))))))))
