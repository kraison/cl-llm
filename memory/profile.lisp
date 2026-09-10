;;;; memory/profile.lisp -- an endpoint's active profile: the text the
;;;; semantic index embeds, and the touch that clears its vector when a
;;;; write changes it (#78 SS2, SS4.2).

(in-package #:cl-llm.memory)

(defparameter *profile-cap* 32
  "Belief lines a profile keeps, newest validity first (SS2.2).")

(defun current-beliefs (graph namespace key)
  "GRAPH's beliefs on (NAMESPACE . KEY) in either role that are
current in recall's sense -- not retracted, validity open -- newest
validity first.  Trap: an absence is an instant and never open."
  (sort (remove-if-not #'%open-p
                       (st:claims-touching graph 'belief namespace key
                                           :role :either :current t))
        (lambda (a b) (local-time:timestamp> (%start-instant a)
                                             (%start-instant b)))))

(defun %endpoint-words (namespace key)
  (format nil "~(~a~) ~a" namespace (substitute #\Space #\- key)))

(defun %profile-line (claim)
  "CLAIM in RENDER-CLAIM's shape (the memory does not depend on
cl-llm/rag): ns:key relation [ns:key] (producer, standing, valid from
DATE)."
  (let* ((start (%start-instant claim))
         (date (local-time:format-timestring
                nil start :format '(:year "-" (:month 2) "-" (:day 2))))
         (object (and (typep claim 'belief-binary)
                      (format nil " ~(~a~):~a"
                              (st:claim-object-namespace claim)
                              (st:claim-object-key claim)))))
    (format nil "~(~a~):~a ~a~a (~a, ~(~a~), valid from ~a)"
            (st:claim-subject-namespace claim) (st:claim-subject-key claim)
            (st:claim-relation claim) (or object "")
            (st:claim-producer claim) (st:claim-standing claim) date)))

(defun endpoint-profile (graph namespace key &key (cap *profile-cap*))
  "The profile text of (NAMESPACE . KEY) in GRAPH under the caller's
snapshot: the endpoint as words, then one line per current belief, the
subject role first, at most CAP lines.  NIL when nothing is current."
  (let ((claims (current-beliefs graph namespace key)))
    (when claims
      (let ((subject
              (remove-if-not
               (lambda (c)
                 (and (eq namespace (st:claim-subject-namespace c))
                      (string= key (st:claim-subject-key c))))
               claims))
            (object
              (remove-if
               (lambda (c)
                 (and (eq namespace (st:claim-subject-namespace c))
                      (string= key (st:claim-subject-key c))))
               claims)))
        (let ((lines (append subject object)))
          (format nil "~a~%~{~a~^~%~}" (%endpoint-words namespace key)
                  (mapcar #'%profile-line
                          (subseq lines 0 (min cap (length lines))))))))))

(defun endpoint-vector-of (graph namespace key)
  "The ENDPOINT-VECTOR vertex of (NAMESPACE . KEY) in GRAPH, or NIL."
  (find-if-not #'gdb:deleted-p
               (gdb:index-lookup graph 'endpoint-vector
                                 '(ev-namespace ev-key)
                                 (list namespace key))))

(defun endpoint-vector-value (vertex)
  "VERTEX's embedding when it is a conforming vector, else NIL --
unbound and NIL both mean no vector (E2)."
  (let ((v (and (slot-boundp vertex 'embedding)
                (slot-value vertex 'embedding))))
    (and (typep v '(simple-array single-float (*))) v)))

(defun endpoint-dirty-p (graph namespace key &optional model)
  "True when the endpoint has a current belief and no vector, or a
vector from another MODEL (SS4.1)."
  (and (current-beliefs graph namespace key)
       (let ((ev (endpoint-vector-of graph namespace key)))
         (or (null ev)
             (null (endpoint-vector-value ev))
             (and model (string/= model (ev-model ev)))))
       t))

(defvar *touched-in-transaction* (make-hash-table :test 'eq :weakness :key)
  "GDB:*TRANSACTION* -> set of (NAMESPACE . KEY) TOUCH-ENDPOINTS has
already handled this commit.  INDEX-LOOKUP does not see a sibling
write's own uncommitted vertex, so two touches of one endpoint within
one transaction would otherwise create two live vertices and fail the
unique constraint at commit -- hit by %ASSERT-FROM-FILE's correction
path, which retracts then re-records the same endpoint (#78 SS4.2).
Weak on the transaction so entries die with it.")

(defun %already-touched-p (endpoint)
  (let ((set (and gdb:*transaction*
                  (gethash gdb:*transaction* *touched-in-transaction*))))
    (and set (gethash endpoint set))))

(defun %mark-touched (endpoint)
  (when gdb:*transaction*
    (let ((set (or (gethash gdb:*transaction* *touched-in-transaction*)
                   (setf (gethash gdb:*transaction* *touched-in-transaction*)
                         (make-hash-table :test 'equal)))))
      (setf (gethash endpoint set) t))))

(defun touch-endpoints (graph endpoints)
  "Clear the vector of every (NAMESPACE . KEY) in ENDPOINTS, creating
the vertex when absent; each once per transaction.  Must run inside
the caller's transaction (SS4.2).  Never embeds."
  (dolist (ep (remove-duplicates endpoints :test #'equal))
    (unless (%already-touched-p ep)
      (%mark-touched ep)
      (let ((ev (endpoint-vector-of graph (car ep) (cdr ep))))
        (if ev
            (when (endpoint-vector-value ev)
              (let ((c (gdb:copy ev)))
                (setf (embedding c) nil (ev-model c) "")
                (gdb:save c)))
            (make-endpoint-vector :graph graph
                                  :ev-namespace (car ep) :ev-key (cdr ep)
                                  :ev-model ""))))))
