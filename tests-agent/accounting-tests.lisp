;;;; tests-agent/accounting-tests.lisp -- a harness run recorded as
;;;; claims (#85; docs/agent-harness.md, "Accounting").

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %mock-run (name &key (in 12) (out 3))
  "A harness run of a mock persona NAME that ends :END-TURN."
  (harness:reset-persona-state name)
  (harness:run-persona
   (harness:make-persona
    :name name
    :provider (llm:make-mock-provider
               :responder (lambda (c)
                            (declare (ignore c))
                            (make-instance
                             'llm:response
                             :content (list (llm:make-text-part "ok"))
                             :stop-reason :end-turn
                             :usage (make-instance 'llm:usage
                                                   :input-tokens in
                                                   :output-tokens out)))))
   "count"))

(test record-run-is-recallable
  (with-stores (w p)
    (declare (ignore p))
    (let* ((run (%mock-run "t-acct"))
           (decisions (agent:record-run w run)))
      (is (eq :end-turn (harness:run-stop-reason run)))
      (is (plusp (length decisions)))
      (is (every (lambda (d) (eq :concluded (mem:decision-outcome d)))
                 decisions))
      (let ((facts
              (mapcar (lambda (r)
                        (let ((c (mem:belief-record-claim r)))
                          (list (st:claim-relation c)
                                (st:claim-object-key c))))
                      (mem:recall w (cons :run (harness:run-id run))
                                  :producer
                                  (format nil "t-acct/~a/"
                                          (harness:host-principal))))))
        (is (member '("ran-as" "t-acct") facts :test #'equal))
        (is (member '("stopped" "end-turn") facts :test #'equal))
        (is (member '("input-tokens" "12") facts :test #'equal))
        (is (member '("output-tokens" "3") facts :test #'equal))
        (is (find "elapsed-ms" facts :key #'first :test #'string=))
        (is (find "started" facts :key #'first :test #'string=))))))
