;;;; memory/schema.lisp -- the belief family, memory-note and
;;;; memory-banner sources.
;;;; Spec: docs/superpowers/specs/2026-09-01-agent-memory-tenant-design.md

(in-package #:cl-llm.memory)

(defmacro define-memory-store (graph-name)
  "Declare the belief and trace families and the memory-note and
memory-banner sources in GRAPH-NAME.  Returns GRAPH-NAME.  Callable
from any package: DEF-CLAIM-CLASSES derives its class names from the
parent symbol's package (kraison/vivace-graph#323), so BELIEF-BINARY
and friends always live here."
  `(progn
     (st:def-claim-classes belief ,graph-name :temporal t)
     (st:def-claim-classes trace ,graph-name)
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
     (st:def-source memory-banner ,graph-name
         ((bn-key      :type string)
          (bn-note     :type string)
          (bn-position :type integer)
          (bn-kind     :type string)
          (bn-date     :type string)
          (bn-dated-p  :type boolean)
          (bn-link     :type string)
          (bn-text     :type string))
       :identity     (:namespace :banner :key-slot bn-key)
       :space        :none
       :time         (:extent-fn memory-banner-validity-extent)
       :attribution  :none
       :sensitivity  (:class :restricted)
       :registration :none
       :indexed-text (:text-fn bn-text))
     ;; The semantic endpoint index (#78 SS2.5): one vertex per endpoint;
     ;; EMBEDDING holding no conforming vector means lexical-only.  Named
     ;; DEF-INDEX for lookup; deliberately no DEF-UNIQUE (R-a): a
     ;; commit-time unique-constraint violation is not retried by the
     ;; engine, so two connections first-touching one never-indexed
     ;; endpoint would fail one agent's write for a race the index
     ;; itself caused.  Duplicate live vertices for one endpoint are
     ;; benign: TOUCH-ENDPOINTS clears every one INDEX-LOOKUP returns,
     ;; ENDPOINT-VECTOR-OF returns the first, and search dedups hits by
     ;; endpoint (a later task).
     (gdb:def-vertex endpoint-vector ()
       ((ev-namespace :type keyword)
        (ev-key       :type string)
        (ev-model     :type string)
        (embedding    :type (simple-array single-float (*))
                      :vector-index t))
       ,graph-name)
     (gdb:def-index endpoint-vector (ev-namespace ev-key) ,graph-name
       :name ev-endpoint-index)
     ',graph-name))

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

(defun memory-banner-validity-extent (banner)
  "Valid from the banner's date (or the note's stamp), open-ended."
  (te:make-interval
   (te:exact-bound (local-time:parse-timestring (bn-date banner)))
   (te:unknown-bound)
   :semantics :validity :standing :asserted))
