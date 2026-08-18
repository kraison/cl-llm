;;;; rag/bundle.lisp -- the evidence bundle: one ranked artifact from every
;;;; retrieval mode.  Design: docs/superpowers/specs/2026-08-18-evidence-
;;;; bundle-design.md (cl-llm#13 unit 1).

(in-package #:cl-llm.rag)

(defstruct evidence
  "One retrieved item and everything known about where it came from.
STANDING defaults to :INDETERMINATE, so absence always carries a reason
rather than reading as NIL-by-omission. An explicit :STANDING NIL is not
refused here -- that is BUNDLE-STANDING-WELL-FORMED's job (a later task)."
  (chunk nil)
  (score 0.0d0)
  (method nil)        ; :DENSE :SPARSE :SPATIAL :TEMPORAL :CLAIM
  (source nil)
  (confidence nil)
  (precision nil)
  (box nil)           ; (min-lon min-lat max-lon max-lat), or NIL
  (extent nil)        ; a TEMPORAL-EXTENT:TEMPORAL-EXTENT, or NIL
  (standing :indeterminate))

(defstruct bundle
  "A query and its ranked evidence.  The ORDER of EVIDENCE is the contract:
a reordering is a regression, so nothing may sort it on the way out."
  (query "")
  (evidence nil)
  (modes nil))

(defgeneric collect-evidence (source query &key k bounds)
  (:documentation "Return a list of EVIDENCE for QUERY, best first.
BOUNDS is the planner's region/window and is accepted by every method; unit
1's sources ignore it (cl-llm#13 unit 2 supplies it)."))

(defclass dense-source ()
  ((embedder :initarg :embedder :reader dense-source-embedder)
   (store :initarg :store :reader dense-source-store))
  (:documentation "Vector retrieval as a bundle source."))

(defun make-dense-source (embedder store)
  (make-instance 'dense-source :embedder embedder :store store))

(defclass sparse-source ()
  ((store :initarg :store :reader sparse-source-store))
  (:documentation "Sparse (BM25) retrieval as a bundle source."))

(defun make-sparse-source (store)
  (make-instance 'sparse-source :store store))

(defun %hit->evidence (hit method)
  "Wrap HIT as EVIDENCE attributed to METHOD.  STANDING is :INDETERMINATE:
no claim has been consulted, which is not the same as having consulted one
and found nothing (that is :SEARCHED-EMPTY, cl-llm#13 unit 3)."
  (make-evidence :chunk (hit-chunk hit)
                 :score (hit-score hit)
                 :method method
                 :standing :indeterminate))

(defmethod collect-evidence ((source dense-source) query &key (k 5) bounds)
  (declare (ignore bounds))
  (mapcar (lambda (h) (%hit->evidence h :dense))
          (store-search (dense-source-store source)
                        (embed (dense-source-embedder source) query)
                        k)))

(defmethod collect-evidence ((source sparse-source) query &key (k 5) bounds)
  (declare (ignore bounds))
  (mapcar (lambda (h) (%hit->evidence h :sparse))
          (sparse-search (sparse-source-store source) query k)))

(defun %evidence->hit (evidence)
  (make-hit (evidence-chunk evidence) (evidence-score evidence)))

(defun fuse (sources query &key (k 5))
  "Collect evidence from each SOURCE and merge it into one ranked BUNDLE.
Ranking is RECIPROCAL-RANK-FUSION over each source's list, which is why the
sources' incomparable native scores never share a scale.  The bundle's
order is the contract; nothing downstream may re-sort it.

The result is truncated to :K, matching RETRIEVE (hybrid.lisp) -- a caller
asking for K never gets back up to 2K (cl-llm#13).  Sources still receive
:K as their own candidate depth."
  (let* ((per-source (mapcar (lambda (s) (collect-evidence s query :k k))
                             sources))
         (by-key (make-hash-table :test 'equal))
         (fused (reciprocal-rank-fusion
                 (mapcar (lambda (evs) (mapcar #'%evidence->hit evs))
                         per-source))))
    ;; RECIPROCAL-RANK-FUSION works on HITs, so map back to the EVIDENCE
    ;; that produced each chunk, preferring the first source that offered
    ;; it.  Key by %CHUNK-KEY, RRF's own identity -- not document-id alone,
    ;; which collapses a document's separate chunks into one (cl-llm#13).
    (loop for evs in per-source
          do (dolist (e evs)
               (let ((key (%chunk-key (evidence-chunk e))))
                 (unless (gethash key by-key)
                   (setf (gethash key by-key) e)))))
    (let ((evidence (loop for h in fused
                          for key = (%chunk-key (hit-chunk h))
                          for e = (gethash key by-key)
                          when e
                            collect (make-evidence
                                     :chunk (evidence-chunk e)
                                     :score (hit-score h)
                                     :method (evidence-method e)
                                     :source (evidence-source e)
                                     :confidence (evidence-confidence e)
                                     :precision (evidence-precision e)
                                     :extent (evidence-extent e)
                                     :standing (evidence-standing e)))))
      (make-bundle
       :query query
       ;; Truncate to :K -- FUSED can hold up to one entry per source, i.e.
       ;; up to 2K before dedup (I3, cl-llm#13).
       :evidence (subseq evidence 0 (min k (length evidence)))
       :modes (remove-duplicates
               (loop for evs in per-source
                     when evs collect (evidence-method (first evs))))))))

(defstruct bounds
  "The scope retrieval runs inside: a region and a window, each with its own
reason.  A bound EXCLUDES ONLY WHAT IS KNOWN TO FALL OUTSIDE IT -- evidence
whose facet is absent is never excluded, or a corpus with no geometry would
empty the moment a region existed (design, cl-llm#13 unit 2)."
  (box nil)                      ; (min-lon min-lat max-lon max-lat), or NIL
  (box-standing :indeterminate)
  (window nil)                   ; a TEMPORAL-EXTENT, or NIL
  (window-standing :indeterminate))

(defun %extent-earliest (e)
  (temporal-extent:bound-earliest (temporal-extent:extent-start e)))

(defun %extent-latest (e)
  (temporal-extent:bound-latest (temporal-extent:extent-end e)))

(defun %union-extents (extents)
  "The enclosing extent of EXTENTS.  An :UNBOUNDED edge swallows everything
past it.  ⚠ Builds an INSTANT when the two edges coincide exactly --
MAKE-INTERVAL signals on equal exact bounds."
  (let* ((lo (if (some (lambda (e) (eq :unbounded (%extent-earliest e)))
                       extents)
                 :unbounded
                 (reduce (lambda (a b) (if (local-time:timestamp< a b) a b))
                         (mapcar #'%extent-earliest extents))))
         (hi (if (some (lambda (e) (eq :unbounded (%extent-latest e)))
                       extents)
                 :unbounded
                 (reduce (lambda (a b) (if (local-time:timestamp< a b) b a))
                         (mapcar #'%extent-latest extents))))
         (start (temporal-extent:make-bound lo lo))
         (end (temporal-extent:make-bound hi hi)))
    (if (eq := (temporal-extent:bound-compare start end))
        (temporal-extent:make-instant start :semantics :validity
                                            :standing :inferred)
        (temporal-extent:make-interval start end :semantics :validity
                                                 :standing :inferred))))

(defun temporal-bound (evidence)
  "Two values: the enclosing TEMPORAL-EXTENT of EVIDENCE's extents, and the
standing saying how it was arrived at -- :INFERRED when derived,
:SEARCHED-EMPTY when nothing carried one, :INDETERMINATE when there was
nothing to look at (design, cl-llm#13 unit 2)."
  (let ((extents (remove nil (mapcar #'evidence-extent evidence))))
    (cond ((null evidence) (values nil :indeterminate))
          ((null extents) (values nil :searched-empty))
          (t (values (%union-extents extents) :inferred)))))

(defun %union-boxes (boxes)
  "The enclosing (MIN-LON MIN-LAT MAX-LON MAX-LAT) of BOXES."
  (list (reduce #'min (mapcar #'first boxes))
        (reduce #'min (mapcar #'second boxes))
        (reduce #'max (mapcar #'third boxes))
        (reduce #'max (mapcar #'fourth boxes))))

(defun spatial-bound (evidence)
  "Two values: the enclosing box of EVIDENCE's boxes, and the standing
saying how it was arrived at.  Same vocabulary as TEMPORAL-BOUND."
  (let ((boxes (remove nil (mapcar #'evidence-box evidence))))
    (cond ((null evidence) (values nil :indeterminate))
          ((null boxes) (values nil :searched-empty))
          (t (values (%union-boxes boxes) :inferred)))))
