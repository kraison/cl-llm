;;;; memory/scope.lisp -- a scope: open stores in trust order, most
;;;; trusted first, read under one snapshot per store.  Spec 2026-09-05
;;;; (S6b) SS3.

(in-package #:cl-llm.memory)

(define-condition scope-argument-error (belief-argument-error) ()
  (:documentation "A scope CHECK-SCOPE refuses, or a scope read inside an
open write transaction (SS3).  VALUE is the list of store names, not the
graphs, so the message stays short.")
  (:report (lambda (c s)
             (format s "scope ~s: ~a"
                     (belief-argument-error-value c)
                     (belief-argument-error-reason c)))))

(defun %scope-names (scope)
  (if (listp scope)
      (mapcar (lambda (g)
                (if (typep g 'graph-db::graph) (store-name g) g))
              scope)
      scope))

(defun %scope-error (scope reason)
  (error 'scope-argument-error
         :argument :scope :value (%scope-names scope) :reason reason))

(defun %store-open-p (graph)
  ;; GRAPH-OPEN-P is internal to the engine; it is the slot the engine's
  ;; own registry guard consults (recon E8).
  (and (typep graph 'graph-db::graph) (graph-db::graph-open-p graph)))

(defun check-scope (scope &key write-store)
  "SCOPE itself when it is a non-empty list of distinct open stores with
distinct STORE-NAMEs, WRITE-STORE (when given) among them, and -- for
more than one store -- every store attached to ONE system clock (SS3,
one regime).  A single store needs no clock.  Signals
SCOPE-ARGUMENT-ERROR naming the offending store otherwise."
  (unless (consp scope)
    (%scope-error scope "must be a non-empty list of open stores"))
  (dolist (g scope)
    (unless (%store-open-p g)
      (%scope-error scope (format nil "~a is not an open store"
                                  (if (typep g 'graph-db::graph)
                                      (store-name g)
                                      g)))))
  (loop for (g . rest) on scope
        when (member g rest)
          do (%scope-error scope (format nil "~a appears twice"
                                         (store-name g))))
  (loop for (n . rest) on (%scope-names scope)
        when (member n rest :test #'string=)
          do (%scope-error scope (format nil "two stores are named ~a" n)))
  (when (and write-store (not (member write-store scope)))
    (%scope-error scope "the write store is not in the scope"))
  (when (rest scope)
    (let ((clock (gdb:graph-system-clock (first scope))))
      (dolist (g scope)
        (let ((c (gdb:graph-system-clock g)))
          (cond ((null c)
                 (%scope-error
                  scope (format nil "~a has no system clock; a ~
                                     multi-store scope needs one"
                                (store-name g))))
                ((not (eq c clock))
                 (%scope-error
                  scope (format nil "~a is on a different clock from ~a"
                                (store-name g)
                                (store-name (first scope))))))))))
  scope)

(defun call-with-scope-snapshots (thunk scope)
  "THUNK under one read snapshot per store of SCOPE, nested in scope
order; the engine composes them, with no single instant across stores
(GH #53).  Refused before any engine call inside an open write
transaction: the own-store half would show uncommitted state and the
foreign half would hit the engine's cross-graph refusal (recon C9)."
  (when gdb:*transaction*
    (%scope-error scope "a scope read inside an open transaction"))
  (labels ((nest (stores)
             (if (null stores)
                 (funcall thunk)
                 (gdb:call-with-read-snapshot
                  (lambda () (nest (rest stores)))
                  (first stores)))))
    (nest scope)))

(defmacro with-scope-snapshots ((scope) &body body)
  "BODY under CALL-WITH-SCOPE-SNAPSHOTS of SCOPE."
  `(call-with-scope-snapshots (lambda () ,@body) ,scope))
