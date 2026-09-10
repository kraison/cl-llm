;;;; agent/scope.lisp -- what a tool set may see and write, and the
;;;; caps.  Spec 2026-09-03 SS2, SS5.

(in-package #:cl-llm.agent)

(define-condition scope-error (error)
  ((reason :initarg :reason :reader scope-error-reason))
  (:report (lambda (c s) (format s "~a" (scope-error-reason c)))))

(defun %scope-error (fmt &rest args)
  (error 'scope-error :reason (apply #'format nil fmt args)))

(defstruct (scope (:constructor %make-scope))
  "STORES readable in order; WRITE-STORE one of them; PRODUCER the
canonical agent name; SOURCES extra COLLECT-EVIDENCE sources; K and
MAX-ROWS the caps; EMBEDDER the ENDPOINT-EMBEDDER the planner routes
through, or NIL for lexical only (#78 R2); CITES the cite -> store map
of results already returned (SS6)."
  stores write-store producer sources k max-rows embedder
  (cites (make-hash-table :test 'equal)))

(defun make-scope (stores &key write-store producer sources
                                (k 5) (max-rows 50) embedder)
  (let ((write (or write-store (first (and (consp stores) stores)))))
    ;; The store-list checks live in the memory layer (S6b SS3); the
    ;; message is re-signalled as the model-readable SCOPE-ERROR.
    (handler-case (mem:check-scope stores :write-store write)
      (mem:scope-argument-error (c)
        (%scope-error "~a" (princ-to-string c))))
    (unless (st:canonical-producer-p producer)
      (%scope-error "PRODUCER is required: a canonical string ~
                     \"<agent>/<host>\""))
    (unless (and (integerp k) (plusp k))
      (%scope-error "K must be a positive integer, not ~s" k))
    (unless (and (integerp max-rows) (plusp max-rows))
      (%scope-error "MAX-ROWS must be a positive integer, not ~s"
                    max-rows))
    ;; A bare RAG:EMBEDDER would silently disable the dense route: the
    ;; model name and the floor are what the index needs (#78 R3).
    (unless (or (null embedder) (endpoint-embedder-p embedder))
      (%scope-error "EMBEDDER must be an ENDPOINT-EMBEDDER ~
                     (MAKE-ENDPOINT-EMBEDDER), not ~s" embedder))
    (%make-scope :stores stores :write-store write :producer producer
                 :sources sources :k k :max-rows max-rows
                 :embedder embedder)))

(defun find-store (scope name)
  "The graph NAME (a store-name string) denotes in SCOPE, or a
SCOPE-ERROR the model can read."
  (or (find name (scope-stores scope) :key #'mem:store-name
            :test #'string=)
      (%scope-error "store ~s is not in this scope" name)))

(defun note-cite (scope cite graph)
  "Remember GRAPH as the store CITE was returned from -- first wins, so
the cache agrees with CITE-STORE's first-in-scope scan whatever order
the tools ran in (S6b SS6, #48)."
  (unless (nth-value 1 (gethash cite (scope-cites scope)))
    (setf (gethash cite (scope-cites scope)) graph)))

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
