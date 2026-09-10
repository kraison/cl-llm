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

(defun %endpoint-vectors-of (graph namespace key)
  "Every live ENDPOINT-VECTOR of (NAMESPACE . KEY) in GRAPH.
INDEX-LOOKUP already excludes deleted nodes (graph-db index.lisp's
INDEX-LOOKUP filters on (NOT (DELETED-P NODE)) per id); no DEF-UNIQUE
(R-a) means this can be more than one vertex."
  (gdb:index-lookup graph 'endpoint-vector '(ev-namespace ev-key)
                    (list namespace key)))

(defun endpoint-vector-of (graph namespace key)
  "The first live ENDPOINT-VECTOR of (NAMESPACE . KEY) in GRAPH, or
NIL.  Trap: this reads committed state only (R-c) -- a caller that
looks this up and then creates inside one transaction can make a
duplicate the way TOUCH-ENDPOINTS could before its per-transaction
guard; any other look-up-then-create writer must guard itself the
same way."
  (first (%endpoint-vectors-of graph namespace key)))

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

;; #-SBCL: a plain, unsynchronized table -- SBCL is this project's only
;; target (the cl-mcp REPL, CI, the memory image), so weak/synchronized
;; hash tables outside it are untested rather than deliberately absent.
(defvar *touched-in-transaction*
  (make-hash-table :test 'eq
                   #+sbcl :weakness #+sbcl :key
                   #+sbcl :synchronized #+sbcl t)
  "GDB:*TRANSACTION* -> set of (GRAPH . (NAMESPACE . KEY))
TOUCH-ENDPOINTS has already handled this commit, keyed on the store
too so touching two graphs in one transaction is not cross-skipped
(R-b).  INDEX-LOOKUP does not see a sibling write's own uncommitted
vertex, so two touches of one endpoint within one transaction would
otherwise both create a vertex -- harmless now (R-a) but wasteful,
and the guard also fixes %ASSERT-FROM-FILE's correction path, which
retracts then re-records the same endpoint in one transaction (#78
SS4.2).  SYNCHRONIZED because one thread per MCP connection can hold
concurrent transactions, so this GLOBAL table needs a lock even
though distinct transactions never share a key; WEAKNESS :KEY so
entries die with their transaction.")

(defun %already-touched-p (graph endpoint)
  (let ((set (and gdb:*transaction*
                  (gethash gdb:*transaction* *touched-in-transaction*))))
    (and set (gethash (cons graph endpoint) set))))

(defun %mark-touched (graph endpoint)
  (when gdb:*transaction*
    (let ((set (or (gethash gdb:*transaction* *touched-in-transaction*)
                   (setf (gethash gdb:*transaction* *touched-in-transaction*)
                         (make-hash-table :test 'equal)))))
      (setf (gethash (cons graph endpoint) set) t))))

(defun touch-endpoints (graph endpoints)
  "Clear the vector of every live ENDPOINT-VECTOR of every (NAMESPACE
. KEY) in ENDPOINTS, creating one when none exists; each endpoint
handled once per transaction per GRAPH.  Every live vertex is COPY'd
and SAVE'd even when it already holds no vector: GDB:SAVE records a
TX-UPDATE unconditionally, and that write set entry is the only thing
a concurrent drain's commit validates against.  Without it a
create-only writer -- a first belief, no supersession, whose own
claims are all creates -- is invisible to the drain's validation and
leaves a stale vector nothing re-embeds (#78 SS4.3 step 2).  A
never-indexed endpoint touched from two transactions can end up with
more than one live vertex -- benign (R-a): every live one found here
is cleared, not just the first.  Must run inside the caller's
transaction (SS4.2).  Never embeds."
  (dolist (ep (remove-duplicates endpoints :test #'equal))
    (unless (%already-touched-p graph ep)
      (%mark-touched graph ep)
      (let ((evs (%endpoint-vectors-of graph (car ep) (cdr ep))))
        (if evs
            (dolist (ev evs)
              (let ((c (gdb:copy ev)))
                (setf (embedding c) nil (ev-model c) "")
                (gdb:save c)))
            (make-endpoint-vector :graph graph
                                  :ev-namespace (car ep) :ev-key (cdr ep)
                                  :ev-model ""))))))
