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
  "One claim source per store in scope, each recognising exactly
ENDPOINTS; the store rides on the source object for rendering."
  (mapcar (lambda (g)
            (claims:make-claim-source
             g 'mem:belief (lambda (q) (declare (ignore q)) endpoints)))
          (scope-stores scope)))

(defun %source-store (scope evidence)
  "The store an evidence item came from: the claim source it was
collected by, else NIL for the operator's sources."
  (let ((src (rag:evidence-source evidence)))
    (and (typep src 'claims:claim-source)
         (find (claims:claim-source-graph src) (scope-stores scope)))))

(defun %evidence-cite (evidence)
  (let ((key (getf (rag:chunk-metadata (rag:evidence-chunk evidence))
                    :claim-key)))
    (and key (format nil "cl-llm.memory::belief|~a" key))))

(defun %evidence-json (scope e)
  (let* ((store (%source-store scope e))
         (cite (%evidence-cite e)))
    (when (and cite store) (note-cite scope cite store))
    (json:jobject
     "method" (%standing (rag:evidence-method e))
     "source" (let ((s (rag:evidence-source e)))
                (and s (not (typep s 'claims:claim-source))
                     (princ-to-string s)))
     "store" (and store (mem:store-name store))
     "text" (rag:chunk-text (rag:evidence-chunk e))
     "cite" cite
     "standing" (%standing (rag:evidence-standing e))
     "confidence" (rag:evidence-confidence e)
     "valid-from" (%from (rag:evidence-extent e))
     "valid-to" (%to (rag:evidence-extent e)))))

(defun %bounds-json (b)
  (json:jobject
   "window" (let ((w (rag:bounds-window b)))
              (json:jobject "from" (%from w) "to" (%to w)
                            "standing" (%standing
                                        (rag:bounds-window-standing b))))
   "box" (let ((box (rag:bounds-box b)))
           (and box (coerce box 'vector)))
   "box-standing" (%standing (rag:bounds-box-standing b))))

(defun %window (from to)
  (and (or from to)
       (te:make-interval
        (if from (te:exact-bound (%parse-iso from)) (te:unknown-bound))
        (if to (te:exact-bound (%parse-iso to)) (te:unknown-bound))
        :semantics :validity :standing :asserted)))

(defun %seed (scope query endpoints k)
  "A first fusion with no bounds: the seed PLAN-BOUNDS derives from."
  (rag:fuse (append (%claim-sources scope endpoints) (scope-sources scope))
            query :k k))

(defun %retrieve-tool (scope)
  (llm:make-tool
   "retrieve"
   "Retrieve evidence for a query across the memory in scope: claims
touching the named endpoints (\"namespace:key\"), plus any other
sources configured, fused into one ranked list.  from/to (RFC 3339)
scope retrieval to a validity window; otherwise a window is derived
from what the query first finds and applied.  Each claim item carries
its cite for use as evidence in conclude.  truncated compares the
returned count to k, so a page that exactly fills k reads as
truncated even when nothing more exists."
   '((query :type string)
     (endpoints :type (list string) :optional t)
     (from :type string :optional t) (to :type string :optional t)
     (k :type integer :optional t))
   (lambda (query endpoints from to k)
     (let* ((k (clamp k (scope-k scope)))
            (eps (%endpoints endpoints))
            (sources (append (%claim-sources scope eps)
                              (scope-sources scope)))
            (seed (%seed scope query eps k))
            (bounds (rag:plan-bounds (rag:bundle-evidence seed)
                                      :window (%window from to)))
            (bundle (rag:fuse sources query :k k :bounds bounds))
            (evidence (rag:bundle-evidence bundle)))
       (json:to-json
        (json:jobject
         "query" query
         "modes" (map 'vector #'%standing (rag:bundle-modes bundle))
         "bounds" (%bounds-json bounds)
         "evidence" (map 'vector (lambda (e) (%evidence-json scope e))
                         evidence)
         ;; Cheaper than re-fusing at K+1 (controller ruling): an
         ;; exactly-full page reads as truncated too.
         "truncated" (%bool (>= (length evidence) k))))))))

(defun %plan-bounds-tool (scope)
  (llm:make-tool
   "plan-bounds"
   "Derive the validity window and region the evidence for a query
implies, without retrieving inside it: the planner's bound as a
callable, each half with its own standing."
   '((query :type string)
     (endpoints :type (list string) :optional t)
     (k :type integer :optional t))
   (lambda (query endpoints k)
     (let* ((k (clamp k (scope-k scope)))
            (seed (%seed scope query (%endpoints endpoints) k)))
       (json:to-json (%bounds-json
                      (rag:plan-bounds (rag:bundle-evidence seed))))))))
