;;;; tests-agent/harness.lisp -- two on-disk stores per test, and a
;;;; way to call a tool as the model would.

(in-package #:cl-llm.agent/tests)

(def-suite :cl-llm-agent
  :description "cl-llm/agent offline suite (two on-disk stores).")
(in-suite :cl-llm-agent)

;; The second store's families (spec SS2).  :MEMORY-PRIVATE is also
;; declared by tests-memory; a second declaration is the engine's
;; supported idempotent case (kraison/vivace-graph#196).
(mem:define-memory-store :memory-private)

(defun %call-with-stores (fn)
  "Working and private stores on ONE system clock (S6b SS3).  The clock
closes after the stores, in the outer UNWIND-PROTECT (a leaked clock
refuses every later open in this image); the attach is asserted inside
the fixture so a silently unattached store cannot pass vacuously."
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (dirs (list (format nil "/tmp/cl-llm-agent-w-~a/" stamp)
                     (format nil "/tmp/cl-llm-agent-p-~a/" stamp)))
         (cdir (format nil "/tmp/cl-llm-agent-clock-~a/" stamp))
         (gdb:*system-directory* (format nil "/tmp/cl-llm-agent-sys-~a/"
                                         stamp))
         (clock (gdb:open-system-clock cdir)))
    (unwind-protect
         (let ((working (gdb:make-graph :cl-llm-memory (first dirs)
                                        :buffer-pool-size 1000
                                        :system-clock clock))
               (private (gdb:make-graph :memory-private (second dirs)
                                        :buffer-pool-size 1000
                                        :system-clock clock)))
           (unwind-protect
                (progn
                  (is (eq (gdb:graph-system-clock working)
                          (gdb:graph-system-clock private))
                      "fixture: both stores on one clock")
                  (funcall fn working private))
             (ignore-errors (gdb:close-graph working))
             (ignore-errors (gdb:close-graph private))))
      (ignore-errors (gdb:close-system-clock clock))
      (dolist (d (list* cdir gdb:*system-directory* dirs))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))

(defmacro with-stores ((working private) &body body)
  `(%call-with-stores (lambda (,working ,private) ,@body)))

(defparameter +p+ "claude-code/test")
(defparameter +subj+ '(:repo . "cl-llm"))

(defun %ts (s) (local-time:parse-timestring s))

(defun %open-from (s)
  (te:make-interval (te:exact-bound (%ts s)) (te:unknown-bound)
                    :semantics :validity :standing :asserted))

(defun %belief (g relation object &key (start "2026-09-01T08:00:00Z")
                                       (subject +subj+))
  (gdb:with-transaction (:graph g)
    (mem:record-belief g subject relation object
                       :producer +p+ :standing :observed
                       :extent (%open-from start))))

(defun %belief-at (g object-key at)
  "A CI-STATUS belief on +SUBJ+ in G, its validity start AND its
RECORDED-AT both pinned to AT -- a genuine cross-store tie for a
scope-order-tiebreak test.  %ST-NOW is strictly monotonic per image
(GH #308) and RECORD-BELIEF never exposes :RECORDED-AT, so this goes
straight to the raw constructor, which does."
  (gdb:with-transaction (:graph g)
    (mem:make-belief-binary
     :graph g :subject-namespace (car +subj+) :subject-key (cdr +subj+)
     :relation "ci-status" :object-namespace :verdict
     :object-key object-key
     :producer +p+ :standing :observed
     :extent (%open-from "2026-09-01T08:00:00Z")
     :recorded-at at)))

(defun %tool (tools name)
  (or (find name tools :key #'llm:tool-name :test #'string=)
      (error "no tool ~a" name)))

(defun %args (&rest plist)
  "A hash-table of decoded-JSON arguments, as the model sends them."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr do (setf (gethash k h) v))
    h))

(defun %call (tools name &rest plist)
  "Call tool NAME as the model would and parse its JSON result."
  (json:parse (llm:call-tool (%tool tools name) (apply #'%args plist))))
