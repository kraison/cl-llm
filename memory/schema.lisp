;;;; memory/schema.lisp -- the belief family and the memory-note source.
;;;; Spec: docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md

(in-package #:cl-llm.memory)

(defmacro define-memory-store (graph-name)
  "Declare the belief and trace families and the memory-note source in
GRAPH-NAME.  A family's indexes and constraints are per graph name
(spec 2026-09-03 SS2), so every store an agent scope may read needs
this once; the class names are shared, which is the engine's model
(kraison/vivace-graph#167, #196).

:TEMPORAL T on BELIEF: the validity start joins the identity tuple
and live claims on one base tuple must be disjoint in validity, so a
belief can hold, lapse and hold again (spec SS3; vg#296).  TRACE is
not temporal: identity is (producer subject object relation), and two
cites of one claim collapse to one EVIDENCE claim.  MEMORY-NOTE is the
dogfood source, one node per memory file -- map-less, private,
text-indexed so the corpus can later be a RAG chunk source (SS7).
:NONE on :SENSITIVITY would mean MOST restricted, not \"n/a\"
(resolve.lisp).

DEF-CLAIM-CLASSES derives BELIEF-BINARY/TRACE-BINARY etc by INTERNing
into *PACKAGE* -- unqualified, so a caller in another package (a test
file, an agent's own package) would mint a SECOND, distinct class of
the same print name and silently steal *CLAIM-FAMILIES*'s entry for
the shared parent symbol (found expanding this macro from
tests-memory/store-tests.lisp, #14 unit 2).  Expanding here, under
this package, keeps the class identity single regardless of the
caller's *PACKAGE* -- only DEF-VERTEX/DEF-INDEX/etc, which take
already-interned symbols, are left for ordinary top-level expansion."
  (let ((*package* (find-package "CL-LLM.MEMORY")))
    `(progn
       ,(macroexpand-1 `(st:def-claim-classes belief ,graph-name
                          :temporal t))
       ,(macroexpand-1 `(st:def-claim-classes trace ,graph-name))
       ,(macroexpand-1
         `(st:def-source memory-note ,graph-name
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
            :indexed-text (:text-fn note-body)))
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
