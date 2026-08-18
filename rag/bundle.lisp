;;;; rag/bundle.lisp -- the evidence bundle: one ranked artifact from every
;;;; retrieval mode.  Design: docs/superpowers/specs/2026-08-18-evidence-
;;;; bundle-design.md (cl-llm#13 unit 1).

(in-package #:cl-llm.rag)

(defstruct evidence
  "One retrieved item and everything known about where it came from.
STANDING is never NIL: absence carries a reason, so a reader can tell
\"nobody looked\" from \"we looked and found nothing\"."
  (chunk nil)
  (score 0.0d0)
  (method nil)        ; :DENSE :SPARSE :SPATIAL :TEMPORAL :CLAIM
  (source nil)
  (confidence nil)
  (precision nil)
  (extent nil)        ; a TEMPORAL-EXTENT:TEMPORAL-EXTENT, or NIL
  (standing nil))

(defstruct bundle
  "A query and its ranked evidence.  The ORDER of EVIDENCE is the contract:
a reordering is a regression, so nothing may sort it on the way out."
  (query "")
  (evidence nil)
  (modes nil))
