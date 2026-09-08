;;;; memory/vocabulary.lisp -- what a store's beliefs name: namespaces,
;;;; relations, keys and endpoints (#64 SS2), from the engine's claim
;;;; vocabulary API on both paths: names and counts come from the
;;;; family's count indexes (#68 -> #70, kraison/vivace-graph#350/#361).

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
under its canonical lowercase name."
  (let ((name (string-downcase (symbol-name namespace))))
    (or (gethash name (vocabulary-namespaces v))
        (setf (gethash name (vocabulary-namespaces v))
              (%make-namespace-entry name)))))

(defun %note-endpoint (v namespace key seen)
  "Record (NAMESPACE . KEY) on V once -- SEEN is the dedup table --
and return NAMESPACE's entry.  Endpoints come out in first-sight
order (#68)."
  (let ((entry (%vocabulary-entry v namespace))
        (pair (cons namespace key)))
    (unless (gethash pair seen)
      (setf (gethash pair seen) t)
      (push pair (vocabulary-endpoints v)))
    entry))

(defun %vocabulary-from-engine (v graph current seen)
  "Fill V from the engine's claim vocabulary API (vivace-graph#350):
names and counts from the family's count indexes (vivace-graph#361).
Queried per role, so a namespace in both roles gets its subject and
object counts separately."
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

Cost: names and counts come from the family's count indexes on both
paths (vivace-graph#361), sub-linear in the store's claims and
resolving no node -- once the engine has built the maps, which a fresh
graph's first count query does by one scan (#70).  Trap: inside a
GDB:WITH-AS-OF extent the counters have no history, so the engine
falls back to a walk that resolves nodes (vivace-graph#350)."
  (let ((v (%make-vocabulary graph))
        (seen (make-hash-table :test 'equal)))
    (%vocabulary-from-engine v graph (not include-retracted) seen)
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
