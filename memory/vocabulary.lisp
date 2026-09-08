;;;; memory/vocabulary.lisp -- what a store's beliefs name: namespaces,
;;;; relations, keys and endpoints (#64 SS2).  The walk moved onto the
;;;; engine's claim vocabulary API (#68, kraison/vivace-graph#350).

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

(defun vocabulary (graph &key include-retracted)
  "What GRAPH's beliefs name -- namespaces and relations with a claim
count each, the keys under every namespace, and every distinct
\(namespace-keyword . key) endpoint -- from the engine's claim
vocabulary API (vivace-graph#350), under the caller's read snapshot.
Retracted claims are skipped unless INCLUDE-RETRACTED (RECALL's
default).  Returns a VOCABULARY; nothing is cached.  Trap, the cost:
the default resolves every claim in each name's index range, so it is
linear in the store's claims; INCLUDE-RETRACTED takes names and counts
from index ranges instead, one resolution per name, so it is
sub-linear in claims."
  (let ((v (%make-vocabulary graph))
        (cur (not include-retracted))
        (order '()))
    (flet ((entry (ns)
             (let ((name (string-downcase (symbol-name ns))))
               (or (gethash name (vocabulary-namespaces v))
                   (progn
                     (push ns order)
                     (setf (gethash name (vocabulary-namespaces v))
                           (%make-namespace-entry name)))))))
      (dolist (role '(:subject :object))
        (loop for (ns . n) in (st:claim-namespaces graph 'belief
                                                   :role role :counts t
                                                   :current cur)
              for e = (entry ns)
              do (if (eq role :subject)
                     (setf (namespace-entry-subjects e) n)
                     (setf (namespace-entry-objects e) n))))
      ;; Namespaces in first-sight order, keys in index order: the
      ;; endpoint list stays stable across calls (#68).
      (dolist (ns (reverse order))
        (let ((e (entry ns)))
          (loop for (key . n) in (st:claim-keys graph 'belief ns
                                                :counts t :current cur)
                do (setf (gethash key (namespace-entry-keys e)) n)
                   (push (cons ns key) (vocabulary-endpoints v))))))
    (loop for (rel . n) in (st:claim-relations graph 'belief
                                               :counts t :current cur)
          do (setf (gethash rel (vocabulary-relations v)) n))
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
