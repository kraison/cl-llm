;;;; memory/vocabulary.lisp -- what a store's beliefs name: namespaces,
;;;; relations, keys and endpoints, from one walk per call (#64 SS2).
;;;; kraison/vivace-graph#350 is the engine index that replaces the
;;;; walk behind VOCABULARY's signature.

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

(defun %note-endpoint (v namespace key role seen)
  "Count NAMESPACE/KEY under ROLE (:SUBJECT or :OBJECT) in V and record
the endpoint once; SEEN is the dedup table."
  (let* ((name (string-downcase (symbol-name namespace)))
         (entry (or (gethash name (vocabulary-namespaces v))
                    (setf (gethash name (vocabulary-namespaces v))
                          (%make-namespace-entry name)))))
    (if (eq role :subject)
        (incf (namespace-entry-subjects entry))
        (incf (namespace-entry-objects entry)))
    (incf (gethash key (namespace-entry-keys entry) 0))
    (let ((pair (cons namespace key)))
      (unless (gethash pair seen)
        (setf (gethash pair seen) t)
        (push pair (vocabulary-endpoints v))))))

(defun vocabulary (graph &key include-retracted)
  "One walk of GRAPH's belief vertices, both arities, under the
caller's read snapshot.  Retracted claims are skipped unless
INCLUDE-RETRACTED (RECALL's default).  Linear in the store's beliefs;
nothing is cached.  Returns a VOCABULARY."
  (let ((v (%make-vocabulary graph))
        (seen (make-hash-table :test 'equal)))
    (dolist (class '(belief-unary belief-binary))
      (gdb:map-vertices
       (lambda (c)
         (when (or include-retracted (st:claim-current-p c))
           (%note-endpoint v (st:claim-subject-namespace c)
                           (st:claim-subject-key c) :subject seen)
           (incf (gethash (st:claim-relation c) (vocabulary-relations v) 0))
           (when (typep c 'belief-binary)
             (%note-endpoint v (st:claim-object-namespace c)
                             (st:claim-object-key c) :object seen))))
       graph :vertex-type class))
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
