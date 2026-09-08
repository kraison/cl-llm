;;;; memory/vocabulary.lisp -- what a store's beliefs name: namespaces,
;;;; relations, keys and endpoints (#64 SS2).  Two paths fill the same
;;;; struct, chosen by INCLUDE-RETRACTED: the belief walk for the
;;;; :current default, the engine's claim vocabulary API for the rest
;;;; (#68, kraison/vivace-graph#350; cost in vivace-graph#358).

(in-package #:cl-llm.memory)

(defstruct (namespace-entry (:constructor %make-namespace-entry (name)))
  "One namespace as the beliefs use it: claim counts by role, and the
distinct keys with a claim count each."
  name
  (subjects 0)
  (objects 0)
  (keys (make-hash-table :test 'equal)))

(defstruct (vocabulary
            (:constructor %make-vocabulary
                (store &aux (namespaces (make-hash-table :test 'equal))
                            (relations (make-hash-table :test 'equal))))
            (:constructor make-vocabulary
                (&key store
                      (namespaces (make-hash-table :test 'equal))
                      (relations (make-hash-table :test 'equal))
                      endpoints)))
  "What STORE's beliefs name.  NAMESPACES and RELATIONS map a canonical
lowercase name to a NAMESPACE-ENTRY and to a claim count; ENDPOINTS is
every distinct (namespace-keyword . key) in either role."
  store
  namespaces
  relations
  endpoints)

(defun %vocabulary-entry (v namespace)
  "The NAMESPACE-ENTRY for keyword NAMESPACE in V, made on first sight
under its canonical lowercase name.  Both paths make entries here."
  (let ((name (string-downcase (symbol-name namespace))))
    (or (gethash name (vocabulary-namespaces v))
        (setf (gethash name (vocabulary-namespaces v))
              (%make-namespace-entry name)))))

(defun %note-endpoint (v namespace key seen)
  "Record (NAMESPACE . KEY) on V once -- SEEN is the dedup table --
and return NAMESPACE's entry.  Endpoints come out in first-sight
order, whichever path filled them (#68)."
  (let ((entry (%vocabulary-entry v namespace))
        (pair (cons namespace key)))
    (unless (gethash pair seen)
      (setf (gethash pair seen) t)
      (push pair (vocabulary-endpoints v)))
    entry))

(defun %vocabulary-by-walk (v graph current seen)
  "Fill V by walking GRAPH's belief vertices, both arities: one node
resolution per claim, counting claims rather than values.  CURRENT
skips retracted claims."
  (dolist (class '(belief-unary belief-binary))
    (gdb:map-vertices
     (lambda (c)
       (when (or (not current) (st:claim-current-p c))
         (let ((key (st:claim-subject-key c)))
           (let ((e (%note-endpoint v (st:claim-subject-namespace c)
                                    key seen)))
             (incf (namespace-entry-subjects e))
             (incf (gethash key (namespace-entry-keys e) 0))))
         (incf (gethash (st:claim-relation c) (vocabulary-relations v) 0))
         (when (typep c 'belief-binary)
           (let ((key (st:claim-object-key c)))
             (let ((e (%note-endpoint v (st:claim-object-namespace c)
                                      key seen)))
               (incf (namespace-entry-objects e))
               (incf (gethash key (namespace-entry-keys e) 0)))))))
     graph :vertex-type class)))

(defun %vocabulary-from-engine (v graph current seen)
  "Fill V from the engine's claim vocabulary API (vivace-graph#350):
names and counts from index ranges, one resolution per name.  The
engine merges the roles and sums, which is what the walk's per-role
INCF produces."
  (let ((order '()))
    (dolist (role '(:subject :object))
      (loop for (ns . n) in (st:claim-namespaces graph 'belief
                                                 :role role :counts t
                                                 :current current)
            for e = (%vocabulary-entry v ns)
            do (pushnew ns order)
               (if (eq role :subject)
                   (setf (namespace-entry-subjects e) n)
                   (setf (namespace-entry-objects e) n))))
    ;; Namespaces in first-sight order, keys in index order.
    (dolist (ns (reverse order))
      (let ((e (%vocabulary-entry v ns)))
        (loop for (key . n) in (st:claim-keys graph 'belief ns
                                              :counts t :current current)
              do (setf (gethash key (namespace-entry-keys e)) n)
                 (%note-endpoint v ns key seen))))
    (loop for (rel . n) in (st:claim-relations graph 'belief
                                               :counts t :current current)
          do (setf (gethash rel (vocabulary-relations v)) n))))

(defun vocabulary (graph &key include-retracted)
  "What GRAPH's beliefs name -- namespaces and relations with a claim
count each, the keys under every namespace, and every distinct
\(namespace-keyword . key) endpoint -- under the caller's read
snapshot.  Retracted claims are skipped unless INCLUDE-RETRACTED
(RECALL's default).  Returns a VOCABULARY; nothing is cached.

Which path runs, and why.  The default walks the belief vertices:
telling current from retracted needs the node anyway, and the walk
resolves each claim exactly once, where the engine under :CURRENT
resolves it once per index range it appears in -- five, for a binary
belief (vivace-graph#358).  INCLUDE-RETRACTED takes the engine's claim
vocabulary API instead (vivace-graph#350): names and counts come from
index ranges with one resolution per name, so that path is sub-linear
in the store's claims where the walk is linear (#68)."
  (let ((v (%make-vocabulary graph))
        (seen (make-hash-table :test 'equal)))
    (if include-retracted
        (%vocabulary-from-engine v graph nil seen)
        (%vocabulary-by-walk v graph t seen))
    (setf (vocabulary-endpoints v) (nreverse (vocabulary-endpoints v)))
    v))

(defun namespace-keys (vocabulary name)
  "The keys under canonical NAME as (key . count) conses, unordered;
NIL when nothing is filed there."
  (let ((entry (gethash name (vocabulary-namespaces vocabulary)))
        (pairs '()))
    (when entry
      (maphash (lambda (k n) (push (cons k n) pairs))
               (namespace-entry-keys entry)))
    pairs))
