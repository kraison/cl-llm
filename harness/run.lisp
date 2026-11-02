;;;; harness/run.lisp -- the run record and its producer (spec SS6.3,
;;;; SS6.5).  docs/agent-harness.md

(in-package #:cl-llm.harness)

(defvar *clock*
  (lambda ()
    (/ (float (get-internal-real-time) 1d0) internal-time-units-per-second))
  "A function of no arguments returning seconds as a real: the clock the
deadline and RUN-ELAPSED read.  Tests rebind it.")

(defclass run ()
  ((id :initarg :id :reader run-id)
   (persona-name :initarg :persona-name :reader run-persona-name)
   (producer :initarg :producer :reader run-producer)
   (input :initarg :input :reader run-input)
   (started :initarg :started :initform nil :accessor run-started
            :documentation "Universal time.")
   (finished :initarg :finished :initform nil :accessor run-finished
             :documentation "Universal time.")
   (elapsed :initform nil :accessor run-elapsed
            :documentation "Seconds, from *CLOCK*.")
   (turns :initform 0 :accessor run-turns
          :documentation "Model requests made.")
   (input-tokens :initform 0 :accessor run-input-tokens)
   (output-tokens :initform 0 :accessor run-output-tokens)
   (stop-reason :initform nil :accessor run-stop-reason)
   (error :initform nil :accessor run-error)
   (text :initform nil :accessor run-text)
   (tool-calls :initform '() :accessor run-tool-calls
               :documentation "Oldest first: (:name :arguments :result
:error-p) plists.")
   (response :initform nil :accessor run-response
             :documentation "The last model response."))
  (:documentation "What one RUN-PERSONA call did, and how it stopped."))

(defmethod print-object ((r run) stream)
  (print-unreadable-object (r stream :type t)
    (format stream "~a ~a ~s" (run-persona-name r) (run-id r)
            (run-stop-reason r))))

;;; Ids.  A fresh random state per image: the default one repeats in
;;; every process, and two images could then mint the same id.

(defvar *id-lock* (bt:make-lock "cl-llm.harness run ids"))
(defvar *id-counter* 0)
(defvar *id-random* (make-random-state t))

(defun make-run-id ()
  "A run id, canonical [a-z0-9-]+ and unique within the host."
  (multiple-value-bind (counter salt)
      (bt:with-lock-held (*id-lock*)
        (values (incf *id-counter*) (random (expt 36 4) *id-random*)))
    (string-downcase
     (format nil "r-~36r-~36r-~36r" (get-universal-time) counter salt))))

(defun host-principal ()
  "This machine's short name, canonical: box.local becomes box."
  (let* ((name (or (machine-instance) "unknown-host"))
         (short (subseq name 0 (or (position #\. name) (length name))))
         (canon (map 'string (lambda (ch)
                               (if (or (char<= #\a ch #\z)
                                       (char<= #\0 ch #\9))
                                   ch
                                   #\-))
                     (string-downcase short))))
    (if (string= canon "") "unknown-host" canon)))

(defun run-producer-for (persona-name run-id &key producer)
  "<persona>/<host>/<run-id>, or <PRODUCER>/<run-id> when PRODUCER (an
<agent>/<host> string) is given.  Signals PERSONA-ERROR unless it is
canonical [a-z0-9-/]+; the memory store reads <persona>/<host>/ as a
prefix (#82)."
  (let ((result (if producer
                    (format nil "~a/~a" producer run-id)
                    (format nil "~a/~a/~a"
                            persona-name (host-principal) run-id))))
    (unless (canonical-name-p result "/")
      (%persona-error "producer ~s is not canonical [a-z0-9-/]+" result))
    result))
