;;;; agent/scope.lisp -- what a tool set may see and write, and the
;;;; caps.  Spec 2026-09-03 SS2, SS5.

(in-package #:cl-llm.agent)

(define-condition scope-error (error)
  ((reason :initarg :reason :reader scope-error-reason))
  (:report (lambda (c s) (format s "~a" (scope-error-reason c)))))

(defun %scope-error (fmt &rest args)
  (error 'scope-error :reason (apply #'format nil fmt args)))

;; GRAPH-P and the GRAPH class are graph-db internals, not exported.
(defun %graph-p (x)
  (typep x 'graph-db::graph))

(defstruct (scope (:constructor %make-scope))
  "STORES readable in order; WRITE-STORE one of them; PRODUCER the
canonical agent name; SOURCES extra COLLECT-EVIDENCE sources; K and
MAX-ROWS the caps; CITES the cite -> store map of results already
returned (SS6)."
  stores write-store producer sources k max-rows
  (cites (make-hash-table :test 'equal)))

(defun make-scope (stores &key write-store producer sources
                                (k 5) (max-rows 50))
  (unless (and (consp stores) (every #'%graph-p stores))
    (%scope-error "STORES must be a non-empty list of open graphs"))
  (let ((write (or write-store (first stores))))
    (unless (member write stores)
      (%scope-error "the write store must be one of the readable stores"))
    (unless (st:canonical-producer-p producer)
      (%scope-error "PRODUCER is required: a canonical string ~
                     \"<agent>/<host>\""))
    (%make-scope :stores stores :write-store write :producer producer
                 :sources sources :k k :max-rows max-rows)))

(defun find-store (scope name)
  "The graph NAME (a store-name string) denotes in SCOPE, or a
SCOPE-ERROR the model can read."
  (or (find name (scope-stores scope) :key #'mem:store-name
            :test #'string=)
      (%scope-error "store ~s is not in this scope" name)))

(defun note-cite (scope cite graph)
  (setf (gethash cite (scope-cites scope)) graph))

(defun cite-store (scope cite)
  "The store CITE was returned from, else the first store in scope
holding it, else NIL (SS6)."
  (or (gethash cite (scope-cites scope))
      (multiple-value-bind (family ns key) (mem:split-cite cite)
        (dolist (g (scope-stores scope) nil)
          (when (find cite (st:claims-touching g family ns key
                                               :role :subject)
                      :key #'mem:claim-cite :test #'string=)
            (note-cite scope cite g)
            (return g))))))

(defun clamp (n cap)
  "N clamped to CAP; NIL or non-positive means CAP."
  (if (and (integerp n) (plusp n)) (min n cap) cap))
