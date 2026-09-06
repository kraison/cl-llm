;;;; agent/taxonomy-tool.lisp -- list-taxonomy: what the memory in
;;;; scope names, so a read starts from a spelling the store holds,
;;;; not a guess (#64 SS3).

(in-package #:cl-llm.agent)

(defun %scope-vocabularies (scope store)
  "(graph . vocabulary) per store in scope order -- or for STORE (a
store name) alone -- under the scope snapshot."
  (let ((stores (if store
                    (list (find-store scope store))
                    (scope-stores scope))))
    (mem:with-scope-snapshots ((scope-stores scope))
      (mapcar (lambda (g) (cons g (mem:vocabulary g))) stores))))

(defun %namespace-total (entry)
  (+ (mem:namespace-entry-subjects entry)
     (mem:namespace-entry-objects entry)))

(defun %namespace-json (entry cap)
  (let ((keys (sort (loop for k being the hash-keys
                            of (mem:namespace-entry-keys entry)
                          collect k)
                    #'string<)))
    (json:jobject
     "name" (mem:namespace-entry-name entry)
     "subjects" (mem:namespace-entry-subjects entry)
     "objects" (mem:namespace-entry-objects entry)
     "keys" (length keys)
     "sample" (coerce (subseq keys 0 (min cap (length keys))) 'vector))))

(defun %count-desc-then-name (count name)
  "A predicate over (COUNT . NAME)-shaped pairs: count descending, then
name ascending."
  (lambda (a b)
    (let ((ca (funcall count a)) (cb (funcall count b)))
      (or (> ca cb)
          (and (= ca cb) (string< (funcall name a) (funcall name b)))))))

(defun %store-taxonomy-json (graph vocabulary cap)
  (let ((entries (loop for e being the hash-values
                         of (mem:vocabulary-namespaces vocabulary)
                       collect e))
        (relations (loop for name being the hash-keys
                           of (mem:vocabulary-relations vocabulary)
                             using (hash-value n)
                         collect (cons name n))))
    (json:jobject
     "store" (mem:store-name graph)
     "namespaces" (map 'vector (lambda (e) (%namespace-json e cap))
                       (sort entries
                             (%count-desc-then-name
                              #'%namespace-total
                              #'mem:namespace-entry-name)))
     "relations" (map 'vector
                      (lambda (r) (json:jobject "name" (car r)
                                                "claims" (cdr r)))
                      (sort relations
                            (%count-desc-then-name #'cdr #'car))))))

(defun %namespace-keys-json (scope namespace store limit)
  "The keys under NAMESPACE across the scope, each naming its store:
claims descending, then key, then scope order (SS3)."
  (let* ((name (%standing (%keyword namespace)))
         (cap (clamp limit (scope-max-rows scope)))
         (rows '()))
    (loop for (g . v) in (%scope-vocabularies scope store)
          for pos from 0
          do (loop for (key . n) in (mem:namespace-keys v name)
                   do (push (list key n g pos) rows)))
    (setf rows (sort rows
                     (lambda (a b)
                       (destructuring-bind (ka na ga pa) a
                         (declare (ignore ga))
                         (destructuring-bind (kb nb gb pb) b
                           (declare (ignore gb))
                           (or (> na nb)
                               (and (= na nb)
                                    (or (string< ka kb)
                                        (and (string= ka kb)
                                             (< pa pb))))))))))
    (let ((shown (subseq rows 0 (min cap (length rows)))))
      (json:to-json
       (json:jobject
        "namespace" name
        "keys" (map 'vector
                    (lambda (r)
                      (json:jobject "key" (first r)
                                    "store" (mem:store-name (third r))
                                    "claims" (second r)))
                    shown)
        "truncated" (%bool (> (length rows) cap)))))))

(defun %taxonomy-tool (scope)
  (llm:make-tool
   "list-taxonomy"
   "Discover what this memory holds before an exact read.  Without
namespace: every store's namespaces (subject and object claim counts,
distinct key count, a sample of keys) and relations (with counts).
With namespace: the keys under it across the memory in scope, each
naming its store, most-cited first.  Every name is the canonical
lowercase spelling recall and retrieve take.  Never conclude absence
from a guessed key: look here first.  store restricts to one store;
limit caps keys (clamped to the operator's max-rows; truncated says
more existed)."
   '((namespace :type string :optional t)
     (store :type string :optional t)
     (limit :type integer :optional t))
   (lambda (namespace store limit)
     (if namespace
         (%namespace-keys-json scope namespace store limit)
         (json:to-json
          (json:jobject
           "stores" (map 'vector
                         (lambda (pair)
                           (%store-taxonomy-json (car pair) (cdr pair)
                                                 (scope-max-rows scope)))
                         (%scope-vocabularies scope store))))))))
