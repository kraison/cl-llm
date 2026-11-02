;;;; tests-harness/state-tests.lisp -- concurrency and daily budgets per
;;;; persona (spec SS6.4).  Real threads: every test releases and joins
;;;; its threads in an UNWIND-PROTECT.

(in-package #:cl-llm.harness/tests)
(in-suite :cl-llm-harness)

(defun blocking-provider (entered gate)
  "A provider that signals ENTERED, then waits on GATE, then answers."
  (llm:make-mock-provider
   :responder (lambda (c)
                (declare (ignore c))
                (bt:signal-semaphore entered)
                (bt:wait-on-semaphore gate :timeout 30)
                (text-response "held"))))

(defun wait-until (predicate &key (timeout 10))
  "Poll PREDICATE until true or TIMEOUT seconds pass; its last value."
  (loop with end = (+ (get-internal-real-time)
                      (* timeout internal-time-units-per-second))
        for value = (funcall predicate)
        until (or value (> (get-internal-real-time) end))
        do (sleep 0.01)
        finally (return value)))

(defun waiting-count (name)
  (nth-value 3 (harness:persona-usage name)))

(test busy-when-full
  (harness:reset-persona-state)
  (let* ((entered (bt:make-semaphore)) (gate (bt:make-semaphore))
         (holder (harness:make-persona
                  :name "t-busy" :provider (blocking-provider entered gate)))
         (second (harness:make-persona
                  :name "t-busy" :provider (scripted (text-response "2"))))
         (thread (bt:make-thread
                  (lambda () (harness:run-persona holder "first")))))
    (unwind-protect
         (progn
           (is (bt:wait-on-semaphore entered :timeout 10))
           (is (eq :busy (harness:run-stop-reason
                          (harness:run-persona second "second")))))
      (bt:signal-semaphore gate)
      (is (eq :end-turn (harness:run-stop-reason (bt:join-thread thread)))))))

(test queued-run-proceeds
  (harness:reset-persona-state)
  (let* ((entered (bt:make-semaphore)) (gate (bt:make-semaphore))
         (holder (harness:make-persona
                  :name "t-queue" :max-queued 1
                  :provider (blocking-provider entered gate)))
         (second (harness:make-persona
                  :name "t-queue" :max-queued 1
                  :provider (scripted (text-response "2"))))
         (first-thread (bt:make-thread
                        (lambda () (harness:run-persona holder "first"))))
         (second-thread nil))
    (unwind-protect
         (progn
           (is (bt:wait-on-semaphore entered :timeout 10))
           (setf second-thread
                 (bt:make-thread
                  (lambda () (harness:run-persona second "second"))))
           (is (eql 1 (wait-until (lambda ()
                                    (let ((n (waiting-count "t-queue")))
                                      (and (= n 1) n)))))
               "the second run never queued"))
      (bt:signal-semaphore gate)
      (bt:join-thread first-thread)
      (when second-thread
        (is (eq :end-turn (harness:run-stop-reason
                           (bt:join-thread second-thread))))))))

(test deadline-while-queued
  (harness:reset-persona-state)
  (let* ((entered (bt:make-semaphore)) (gate (bt:make-semaphore))
         (holder (harness:make-persona
                  :name "t-queue-late" :max-queued 1
                  :provider (blocking-provider entered gate)))
         (late (harness:make-persona
                :name "t-queue-late" :max-queued 1 :max-seconds 1
                :provider (scripted (text-response "2"))))
         (thread (bt:make-thread
                  (lambda () (harness:run-persona holder "first")))))
    (unwind-protect
         (progn
           (is (bt:wait-on-semaphore entered :timeout 10))
           (let* ((start (get-internal-real-time))
                  (r (harness:run-persona late "second"))
                  (seconds (/ (- (get-internal-real-time) start)
                              internal-time-units-per-second)))
             (is (eq :deadline (harness:run-stop-reason r)))
             (is (< seconds 3) "waited ~,1f s in the queue" seconds)))
      (bt:signal-semaphore gate)
      (bt:join-thread thread))))

(test daily-run-budget
  (harness:reset-persona-state)
  (multiple-value-bind (provider calls) (scripted (text-response "ok"))
    (let ((p (harness:make-persona :name "t-day-runs" :provider provider
                                   :daily-run-budget 2)))
      (harness:run-persona p "1")
      (harness:run-persona p "2")
      (is (eq :daily-budget
              (harness:run-stop-reason (harness:run-persona p "3"))))
      (is (= 2 (funcall calls))))))

(test daily-budget-rolls-over
  (harness:reset-persona-state)
  (let* ((now (* 86400 20000))
         (harness:*wall-clock* (lambda () now))
         (p (harness:make-persona :name "t-day-roll"
                                  :provider (scripted (text-response "ok"))
                                  :daily-run-budget 1)))
    (harness:run-persona p "1")
    (is (eq :daily-budget
            (harness:run-stop-reason (harness:run-persona p "2"))))
    (incf now 86400)
    (is (eq :end-turn
            (harness:run-stop-reason (harness:run-persona p "3"))))))

(test daily-token-budget
  (harness:reset-persona-state)
  (let ((p (harness:make-persona
            :name "t-day-tokens" :daily-token-budget 50
            :provider (scripted (text-response "big" :in 40 :out 20)))))
    (is (eq :end-turn (harness:run-stop-reason (harness:run-persona p "1"))))
    (is (eq :daily-budget
            (harness:run-stop-reason (harness:run-persona p "2"))))))
