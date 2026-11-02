;;;; tests-harness/run-tests.lisp -- the run record's ids and producer
;;;; (spec SS6.5).

(in-package #:cl-llm.harness/tests)
(in-suite :cl-llm-harness)

(defun all-in-alphabet-p (string alphabet)
  (and (plusp (length string))
       (every (lambda (ch) (find ch alphabet)) string)))

(defparameter +id-alphabet+ "abcdefghijklmnopqrstuvwxyz0123456789-")

(test run-id-canonical-and-distinct
  (let ((ids (loop repeat 1000 collect (harness:make-run-id))))
    (is (every (lambda (id) (all-in-alphabet-p id +id-alphabet+)) ids))
    (is (= 1000 (length (remove-duplicates ids :test #'string=))))))

(test host-principal-canonical
  (let ((host (harness:host-principal)))
    (is (all-in-alphabet-p host +id-alphabet+) "got ~s" host)
    (is (not (find #\. host)))))

(test producer-default-shape
  (is (string= (format nil "echo/~a/r-1" (harness:host-principal))
               (harness:run-producer-for "echo" "r-1"))))

(test producer-prefix-given
  (is (string= "agent/box/r-1"
               (harness:run-producer-for "echo" "r-1"
                                         :producer "agent/box"))))

(test producer-uncanonical-refused
  (signals harness:persona-error
    (harness:run-producer-for "echo" "r-1" :producer "Agent/Box")))
