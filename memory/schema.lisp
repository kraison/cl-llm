;;;; memory/schema.lisp -- the belief family and the memory-note source.
;;;; Spec: docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md

(in-package #:cl-llm.memory)

(defmacro define-memory-store (graph-name &environment env)
  "Declare the belief and trace families and the memory-note source in
GRAPH-NAME.  Returns GRAPH-NAME.

DEF-CLAIM-CLASSES interns derived class names into *PACKAGE*, so the
inner forms are expanded under this package or a caller elsewhere
mints duplicate classes (kraison/vivace-graph#323)."
  (let ((*package* (symbol-package 'define-memory-store)))
    `(progn
       ,(macroexpand-1 `(st:def-claim-classes belief ,graph-name
                          :temporal t)
                        env)
       ,(macroexpand-1 `(st:def-claim-classes trace ,graph-name) env)
       (st:def-source memory-note ,graph-name
           ((note-name        :type string)
            (note-description :type string)
            (note-type        :type string)
            (note-modified    :type string)
            (note-body        :type string))
         :identity     (:namespace :memory-note :key-slot note-name)
         :space        :none
         :time         (:extent-fn memory-note-validity-extent)
         :attribution  :none
         :sensitivity  (:class :restricted)
         :registration :none
         :indexed-text (:text-fn note-body))
       ',graph-name)))

(define-memory-store :cl-llm-memory)

(defun store-name (graph)
  "GRAPH's name as the string a model sees: downcased (SS5)."
  (string-downcase (symbol-name (gdb:graph-name graph))))

(defun memory-note-validity-extent (note)
  "The :TIME facet's extent-fn: valid from the note's MODIFIED stamp,
open-ended -- supersession is a later capture's job (spec SS7)."
  (te:make-interval
   (te:exact-bound (local-time:parse-timestring (note-modified note)))
   (te:unknown-bound)
   :semantics :validity :standing :asserted))
