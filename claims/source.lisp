;;;; claims/source.lisp -- claim traversal as a bundle source
;;;; (cl-llm#13 unit 3).
;;;;
;;;; A CLAIM-SOURCE answers COLLECT-EVIDENCE from a graph-db/spacetime
;;;; claim store: endpoint keys recognised in the query resolve to the
;;;; claims touching them, each rendered as one EVIDENCE with the
;;;; claim's own standing -- and a recognised key that yields NOTHING
;;;; becomes a :SEARCHED-EMPTY item, the distinction the bundle's
;;;; standing vocabulary exists to carry (docs/evidence-bundle.md §3).
;;;;
;;;; Domain-neutral by the programme's boundary rule (§5.1): nothing
;;;; here names a tenant's concepts.  What counts as a key in a query
;;;; is the tenant's knowledge, supplied as KEY-EXTRACTOR; this file
;;;; only walks the claim indexes it is handed.

(in-package #:cl-llm.rag.claims)

(defclass claim-source ()
  ((graph :initarg :graph :reader claim-source-graph)
   (claim-class :initarg :claim-class :reader claim-source-class
                :documentation "The tenant's PARENT claim class name --
CLAIMS-TOUCHING takes the parent, so one source covers both arities.")
   (key-extractor :initarg :key-extractor
                  :reader claim-source-key-extractor
                  :documentation "Function of the query string returning
(NAMESPACE . KEY) conses -- the endpoints worth asking about.  This is
where the tenant's vocabulary lives; an extractor that recognises
nothing makes the source contribute nothing.")
   (include-retracted :initarg :include-retracted :initform nil
                      :reader claim-source-include-retracted
                      :documentation "When true, retracted claims are
collected too (#37).")
   (renderer :initarg :renderer :initform #'render-claim
             :reader claim-source-renderer
             :documentation "Function of a claim returning the text a
model reads.  RENDER-CLAIM unless the tenant knows better."))
  (:documentation "Claim traversal as a COLLECT-EVIDENCE source."))

(defun make-claim-source (graph claim-class key-extractor
                          &key renderer include-retracted)
  "A source over GRAPH's CLAIM-CLASS family.  Current claims only unless
INCLUDE-RETRACTED: a corrected belief leaves its retracted predecessor
on the same identity tuple, and RENDER-CLAIM shows no transaction time,
so the model could not tell the two apart (#37; RECALL's default)."
  (make-instance 'claim-source
                 :graph graph :claim-class claim-class
                 :key-extractor key-extractor
                 :include-retracted include-retracted
                 :renderer (or renderer #'render-claim)))

(defun %endpoint (namespace key)
  (format nil "~(~a~):~a" namespace key))

(defun %binary-p (claim)
  "True when CLAIM carries an object endpoint.  Reader-probed rather
than type-probed: the tenant's class names are its own, and a unary
claim's CLAIM-OBJECT-KEY reader does not exist to call."
  (ignore-errors (and (st:claim-object-key claim) t)))

(defun render-claim (claim)
  "CLAIM as one line a model can read: endpoints, relation, producer,
standing, and the validity extent when one is recorded."
  (let ((extent (st:claim-extent claim)))
    (format nil "~a ~(~a~)~@[ ~a~] (~(~a~), ~(~a~)~@[, ~a~])"
            (%endpoint (st:claim-subject-namespace claim)
                       (st:claim-subject-key claim))
            (st:claim-relation claim)
            (and (%binary-p claim)
                 (%endpoint (st:claim-object-namespace claim)
                            (st:claim-object-key claim)))
            (st:claim-producer claim)
            (st:claim-standing claim)
            (and extent (%extent-line extent)))))

(defun %extent-line (extent)
  (let ((start (temporal-extent:bound-earliest
                (temporal-extent:extent-start extent)))
        (end (temporal-extent:bound-latest
              (temporal-extent:extent-end extent))))
    (format nil "~a..~a"
            (if (eq start :unbounded) "?" (%day start))
            (if (eq end :unbounded) "?" (%day end)))))

(defun %day (ts)
  (local-time:format-timestring
   nil ts :format '(:year "-" (:month 2) "-" (:day 2))
   :timezone local-time:+utc-zone+))

(defun %claim-evidence (source claim score)
  "CLAIM as EVIDENCE: the rendered line is the chunk text, the claim's
own standing and confidence ride along, and the validity extent lands
both on the EVIDENCE (for BOUNDED-EVIDENCE) and in the chunk metadata
as a sexp (the §9.5 facet contract, so a chunk-level consumer reads
the same window).  :CLAIM-KEY is the identity key, so a consumer can
cite the claim (agent-tools design §7)."
  (let* ((extent (st:claim-extent claim))
         (text (funcall (claim-source-renderer source) claim)))
    (rag:make-evidence
     :chunk (rag:make-chunk
             text
             :document-id (%claim-doc-id claim)
             :metadata (append
                        (and extent
                             (list :extent (temporal-extent:extent->sexp
                                            extent)))
                        (list :claim-key (st:claim-identity-key claim))))
     :score score
     :method :claim
     :source source
     :confidence (st:claim-confidence claim)
     :extent extent
     :standing (st:claim-standing claim))))

(defun %claim-doc-id (claim)
  "The fusion identity: RRF keys on (DOCUMENT-ID . TEXT), so one claim
reached through two queried endpoints must carry one id."
  (format nil "claim:~a:~(~a~)~@[:~a~]:~(~a~)"
          (%endpoint (st:claim-subject-namespace claim)
                     (st:claim-subject-key claim))
          (st:claim-relation claim)
          (and (%binary-p claim)
               (%endpoint (st:claim-object-namespace claim)
                          (st:claim-object-key claim)))
          (st:claim-producer claim)))

(defun %absence-evidence (source namespace key)
  "The looked-and-found-nothing item (§3): a recognised endpoint with
no claims is a FACT the bundle carries, not an omission.  No extent
and no box, so no bound can exclude it.  SOURCE rides EVIDENCE-SOURCE
and names the store in the document id, so two stores' absences of
the same endpoint fuse to two items, not one (agent-tools design §7)."
  (rag:make-evidence
   :chunk (rag:make-chunk
           (format nil "no claims touch ~a" (%endpoint namespace key))
           :document-id (format nil "claim-absence:~(~a~):~a"
                                (graph-db:graph-name
                                 (claim-source-graph source))
                                (%endpoint namespace key)))
   :score 0d0
   :method :claim
   :source source
   :standing :searched-empty))

(defmethod rag:collect-evidence ((source claim-source) query
                                 &key (k 5) bounds)
  "Claims touching every endpoint KEY-EXTRACTOR recognises in QUERY,
best first, BOUNDS applied and then capped at K (cl-llm#19); then one
:SEARCHED-EMPTY item per recognised endpoint that yielded nothing.
An extractor that recognises nothing returns NIL -- nothing was
consulted, which is :INDETERMINATE territory and not this source's to
assert (§9.2)."
  (let ((keys (funcall (claim-source-key-extractor source) query))
        (seen (make-hash-table :test 'equal))
        (claims '())
        (absences '()))
    (dolist (pair keys)
      (let ((touching (st:claims-touching (claim-source-graph source)
                                          (claim-source-class source)
                                          (car pair) (cdr pair)
                                          :role :either
                                          :current
                                          (not (claim-source-include-retracted
                                                source)))))
        (if touching
            (dolist (claim touching)
              (let ((id (%claim-doc-id claim)))
                (unless (gethash id seen)
                  (setf (gethash id seen) t)
                  (push claim claims))))
            (push (%absence-evidence source (car pair) (cdr pair))
                  absences))))
    ;; Bound first, cap second: every touching claim is already in
    ;; hand, so filling K from in-bounds claims costs nothing extra.
    (let* ((kept (rag:bounded-evidence
                  (loop for claim in (nreverse claims)
                        collect (%claim-evidence source claim 0d0))
                  bounds))
           (top (subseq kept 0 (min k (length kept))))
           (n (length top)))
      (loop for e in top
            for i from 0
            do (setf (rag:evidence-score e) (float (- n i) 1d0)))
      (append top (nreverse absences)))))
