;;;; memory/schema.lisp -- the belief family and the memory-note source.
;;;; Spec: docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md

(in-package #:cl-llm.memory)

;; :TEMPORAL T: the validity start joins the identity tuple and live
;; claims on one base tuple must be disjoint in validity, so a belief
;; can hold, lapse and hold again (spec SS3; kraison/vivace-graph#296).
(st:def-claim-classes belief :cl-llm-memory :temporal t)

;; The dogfood source: one node per memory file.  Map-less, private,
;; text-indexed so the corpus can later be a RAG chunk source (spec SS7).
(st:def-source memory-note :cl-llm-memory
    ((note-name        :type string)
     (note-description :type string)
     (note-type        :type string)
     (note-modified    :type string)   ; RFC3339 UTC, as captured
     (note-body        :type string))
  :identity     (:namespace :memory-note :key-slot note-name)
  :space        :none
  :time         (:extent-fn memory-note-validity-extent)
  :attribution  :none
  ;; :NONE here would mean MOST restricted, not "n/a" (resolve.lisp).
  :sensitivity  (:class :restricted)
  :registration :none
  :indexed-text (:text-fn note-body))

(defun memory-note-validity-extent (note)
  "The :TIME facet's extent-fn: valid from the note's MODIFIED stamp,
open-ended -- supersession is a later capture's job (spec SS7)."
  (te:make-interval
   (te:exact-bound (local-time:parse-timestring (note-modified note)))
   (te:unknown-bound)
   :semantics :validity :standing :asserted))
