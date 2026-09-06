;;;; agent/planner-tools.lisp -- retrieve and plan-bounds over the
;;;; planner.  Spec SS7.

(in-package #:cl-llm.agent)

(defun %endpoints (strings)
  "\"namespace:key\" strings as (namespace . key), split at the first
colon (namespaces are canonical [a-z0-9-])."
  (loop for s across (or strings #())
        for i = (position #\: s)
        unless i do (error "endpoint ~s is not namespace:key" s)
        collect (cons (%keyword (subseq s 0 i)) (subseq s (1+ i)))))

(defun %claim-sources (scope endpoints)
  "One claim source per store in scope.  Each recognises ENDPOINTS
first, never displaced, then what its own vocabulary finds in the
query, the union capped at twice the scope's k (SS4.2, #64).  The
vocabularies are walked once here, under the scope snapshot; the
store rides on the source object for rendering."
  (let* ((cap (* 2 (scope-k scope)))
         (stores (scope-stores scope))
         (extractors (mem:with-scope-snapshots (stores)
                       (mapcar (lambda (g)
                                 (make-key-extractor (mem:vocabulary g)
                                                     :cap cap))
                               stores))))
    (mapcar (lambda (g extract)
              (claims:make-claim-source
               g 'mem:belief
               (lambda (query)
                 (let ((all (remove-duplicates
                             (append endpoints (funcall extract query))
                             :test #'equal :from-end t)))
                   (subseq all 0 (min cap (length all)))))))
            stores extractors)))

(defun %consulted (claim-sources query)
  "The \"namespace:key\" strings CLAIM-SOURCES will consult for QUERY,
in consultation order, each once."
  (let ((seen '()))
    (dolist (src claim-sources (nreverse seen))
      (dolist (ep (funcall (claims:claim-source-key-extractor src) query))
        (let ((name (%endpoint-name ep)))
          (unless (member name seen :test #'string=)
            (push name seen)))))))

(defun %check-consulted (scope consulted query)
  "Nothing consulted and no operator source is a refusal, never an
empty bundle a caller could read as nothing recorded (SS4.2, R3)."
  (when (and (null consulted) (null (scope-sources scope)))
    (error "no endpoint recognised in ~s: name endpoints, or call ~
list-taxonomy to see what this memory holds" query)))

(defun %source-store (scope evidence)
  "The store an evidence item came from: the claim source it was
collected by, else NIL for the operator's sources."
  (let ((src (rag:evidence-source evidence)))
    (and (typep src 'claims:claim-source)
         (find (claims:claim-source-graph src) (scope-stores scope)))))

(defun %evidence-cite (evidence)
  "The cite for EVIDENCE, or NIL: only a claim source over MEM:BELIEF
carries a citeable claim key -- an operator source over another
family must not borrow the belief cite prefix."
  (let ((src (rag:evidence-source evidence)))
    (and (typep src 'claims:claim-source)
         (eq (claims:claim-source-class src) 'mem:belief)
         (let ((key (getf (rag:chunk-metadata
                           (rag:evidence-chunk evidence))
                          :claim-key)))
           (and key (format nil "cl-llm.memory::belief|~a" key))))))

(defun %evidence-json (scope e)
  (let* ((store (%source-store scope e))
         (cite (%evidence-cite e)))
    (json:jobject
     "method" (%standing (rag:evidence-method e))
     "source" (let ((s (rag:evidence-source e)))
                (and s (not (typep s 'claims:claim-source))
                     (string-downcase (symbol-name (type-of s)))))
     "store" (and store (mem:store-name store))
     "text" (rag:chunk-text (rag:evidence-chunk e))
     "cite" cite
     "standing" (%standing (rag:evidence-standing e))
     "confidence" (rag:evidence-confidence e)
     "valid-from" (%from (rag:evidence-extent e))
     "valid-to" (%to (rag:evidence-extent e)))))

(defun %bounds-json (b &optional (endpoints nil endpoints-p))
  "The bounds object; with ENDPOINTS (a vector, possibly empty) the
consulted endpoints ride along -- PLAN-BOUNDS's own result (SS4.2)."
  (apply #'json:jobject
         "window" (let ((w (rag:bounds-window b)))
                    (json:jobject "from" (%from w) "to" (%to w)
                                  "standing" (%standing
                                              (rag:bounds-window-standing b))))
         "box" (let ((box (rag:bounds-box b)))
                 (and box (coerce box 'vector)))
         "box-standing" (%standing (rag:bounds-box-standing b))
         (and endpoints-p (list "endpoints" endpoints))))

(defun %window (from to)
  (and (or from to)
       (te:make-interval
        (if from (te:exact-bound (%parse-iso from)) (te:unknown-bound))
        (if to (te:exact-bound (%parse-iso to)) (te:unknown-bound))
        :semantics :validity :standing :asserted)))

(defun %seed (sources query k)
  "A first fusion with no bounds: the seed PLAN-BOUNDS derives from."
  (rag:fuse sources query :k k))

(defun %retrieve-tool (scope)
  (llm:make-tool
   "retrieve"
   "Retrieve evidence for a query across the memory in scope: claims
touching the endpoints the query names -- by key token, from what the
stores hold -- plus any \"namespace:key\" endpoints given, plus any
other sources configured, fused into one ranked list.  endpoints in
the result lists what was consulted; a query that names nothing and
lists nothing is an error, and list-taxonomy shows what to name.
from/to (RFC 3339) scope retrieval to a validity window; otherwise a
window is derived from what the query first finds and applied.  Each
claim item carries its cite for use as evidence in conclude.
truncated is true when more evidence existed past k, as in recall."
   '((query :type string)
     (endpoints :type (list string) :optional t)
     (from :type string :optional t) (to :type string :optional t)
     (k :type integer :optional t))
   (lambda (query endpoints from to k)
     (let* ((k (clamp k (scope-k scope)))
            (eps (%endpoints endpoints))
            (claim-sources (%claim-sources scope eps))
            (consulted (%consulted claim-sources query))
            (sources (append claim-sources (scope-sources scope))))
       (%check-consulted scope consulted query)
       (let* ((seed (%seed sources query k))
              (bounds (rag:plan-bounds (rag:bundle-evidence seed)
                                       :window (%window from to)))
              ;; Fuse one past the cap and cut, so TRUNCATED means more
              ;; existed -- RECALL's rule (spec SS5, #14 unit 2 final
              ;; review); an exactly-full page is not truncated.
              (bundle (rag:fuse sources query :k (1+ k) :bounds bounds))
              (fused (rag:bundle-evidence bundle))
              (evidence (subseq fused 0 (min k (length fused)))))
         ;; Seed the cache in SCOPE order, not ranking order: first-wins
         ;; must mean first-in-scope (S6b SS6, #48).
         (dolist (g (scope-stores scope))
           (dolist (e evidence)
             (let ((cite (%evidence-cite e)))
               (when (and cite (eq g (%source-store scope e)))
                 (note-cite scope cite g)))))
         (json:to-json
          (json:jobject
           "query" query
           "endpoints" (coerce consulted 'vector)
           "modes" (map 'vector #'%standing (rag:bundle-modes bundle))
           "bounds" (%bounds-json bounds)
           "evidence" (map 'vector (lambda (e) (%evidence-json scope e))
                           evidence)
           "truncated" (%bool (> (length fused) k)))))))))

(defun %plan-bounds-tool (scope)
  (llm:make-tool
   "plan-bounds"
   "Derive the validity window and region the evidence for a query
implies, without retrieving inside it: the planner's bound as a
callable, each half with its own standing.  Endpoints come from the
query as in retrieve, and endpoints in the result lists them."
   '((query :type string)
     (endpoints :type (list string) :optional t)
     (k :type integer :optional t))
   (lambda (query endpoints k)
     (let* ((k (clamp k (scope-k scope)))
            (claim-sources (%claim-sources scope (%endpoints endpoints)))
            (consulted (%consulted claim-sources query))
            (sources (append claim-sources (scope-sources scope))))
       (%check-consulted scope consulted query)
       (json:to-json
        (%bounds-json (rag:plan-bounds
                       (rag:bundle-evidence (%seed sources query k)))
                      (coerce consulted 'vector)))))))
