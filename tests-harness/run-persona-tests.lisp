;;;; tests-harness/run-persona-tests.lisp -- run-persona and its per-run
;;;; guards (spec SS6.3-SS6.4), on scripted mock providers.

(in-package #:cl-llm.harness/tests)
(in-suite :cl-llm-harness)

(defun usage (in out)
  (make-instance 'llm:usage :input-tokens in :output-tokens out))

(defun text-response (text &key (in 10) (out 5) (usage t))
  (make-instance 'llm:response
                 :content (list (llm:make-text-part text))
                 :stop-reason :end-turn
                 :usage (and usage (usage in out))))

(defun tool-response (name args-json &key (in 10) (out 5) (id "tu_1"))
  (make-instance 'llm:response
                 :content (list (llm:make-tool-use-part
                                 id name (json:parse args-json)))
                 :stop-reason :tool-use
                 :usage (usage in out)))

(defun scripted (&rest responses)
  "A mock provider answering RESPONSES in order, the last one forever.
Second value: a function returning how many requests it has had."
  (let ((calls 0))
    (values (llm:make-mock-provider
             :responder (lambda (conversation)
                          (declare (ignore conversation))
                          (incf calls)
                          (if (cdr responses) (pop responses) (car responses))))
            (lambda () calls))))

(defun echo-tool ()
  (llm:make-tool 'tool-echo "Echo the text." '(text)
                 (lambda (text) (format nil "echo:~a" text))))

(defun fixed-clock (seconds) (lambda () seconds))

(defun stepping-clock (step)
  "A clock that advances STEP seconds on every reading."
  (let ((now 0)) (lambda () (incf now step))))

(test run-completes-and-records
  (let* ((p (harness:make-persona
             :name "t-basic"
             :provider (scripted (text-response "hello" :in 10 :out 5))))
         (r (harness:run-persona p "hi")))
    (is (eq :end-turn (harness:run-stop-reason r)))
    (is (string= "hello" (harness:run-text r)))
    (is (= 1 (harness:run-turns r)))
    (is (= 10 (harness:run-input-tokens r)))
    (is (= 5 (harness:run-output-tokens r)))
    (is (<= (harness:run-started r) (harness:run-finished r)))
    (is (eql 0 (search "t-basic/" (harness:run-producer r))))))

(test run-records-tool-calls
  (let* ((p (harness:make-persona
             :name "t-tools" :tools (list (echo-tool))
             :provider (scripted (tool-response "tool-echo" "{\"text\":\"hi\"}")
                                 (text-response "done"))))
         (r (harness:run-persona p "go")))
    (is (eq :end-turn (harness:run-stop-reason r)))
    (is (= 1 (length (harness:run-tool-calls r))))
    (let ((call (first (harness:run-tool-calls r))))
      (is (string= "tool-echo" (getf call :name)))
      (is (equal '("hi") (getf call :arguments)))
      (is (string= "echo:hi" (getf call :result)))
      (is (null (getf call :error-p))))))

(test run-max-turns
  (multiple-value-bind (provider calls)
      (scripted (tool-response "tool-echo" "{\"text\":\"again\"}"))
    (let ((r (harness:run-persona
              (harness:make-persona :name "t-turns" :tools (list (echo-tool))
                                    :provider provider :max-turns 2)
              "loop")))
      (is (eq :max-turns (harness:run-stop-reason r)))
      (is (= 2 (harness:run-turns r)))
      (is (= 2 (funcall calls))))))

(test run-token-budget
  (multiple-value-bind (provider calls)
      (scripted (tool-response "tool-echo" "{\"text\":\"a\"}" :in 60 :out 0)
                (tool-response "tool-echo" "{\"text\":\"b\"}" :in 60 :out 0)
                (text-response "never"))
    (let ((r (harness:run-persona
              (harness:make-persona :name "t-tokens" :tools (list (echo-tool))
                                    :provider provider :max-run-tokens 100)
              "spend")))
      (is (eq :token-budget (harness:run-stop-reason r)))
      (is (= 2 (funcall calls)) "a third request was made")
      (is (= 120 (harness:run-input-tokens r))))))

(test run-deadline-before-request
  (multiple-value-bind (provider calls)
      (scripted (tool-response "tool-echo" "{\"text\":\"slow\"}")
                (text-response "late"))
    (let* ((harness:*clock* (stepping-clock 10))
           (r (harness:run-persona
               (harness:make-persona :name "t-deadline"
                                     :tools (list (echo-tool))
                                     :provider provider :max-seconds 15)
               "hurry")))
      (is (eq :deadline (harness:run-stop-reason r)))
      (is (= 1 (funcall calls)) "asked the model again past the deadline"))))

(test run-deadline-before-model-request
  ;; No tools, so only the check before each model request can stop it.
  (multiple-value-bind (provider calls) (scripted (text-response "late"))
    (let* ((harness:*clock* (stepping-clock 10))
           (r (harness:run-persona
               (harness:make-persona :name "t-deadline-2"
                                     :provider provider :max-seconds 5)
               "hurry")))
      (is (eq :deadline (harness:run-stop-reason r)))
      (is (= 0 (funcall calls)) "the model was asked past the deadline"))))

(test run-deadline-before-tool-call
  ;; The model call itself runs past the deadline: the tool must not run.
  (let* ((now 0)
         (ran nil)
         (tool (llm:make-tool 'mark "Mark." '() (lambda () (setf ran t))))
         (provider (llm:make-mock-provider
                    :responder (lambda (c)
                                 (declare (ignore c))
                                 (setf now 100)
                                 (tool-response "mark" "{}"))))
         (harness:*clock* (lambda () now))
         (r (harness:run-persona
             (harness:make-persona :name "t-deadline-3" :tools (list tool)
                                   :provider provider :max-seconds 30)
             "x")))
    (is (eq :deadline (harness:run-stop-reason r)))
    (is (null ran) "the tool ran past the deadline")))

(test run-timeout-follows-deadline
  (let* ((seen nil)
         (provider (llm:make-mock-provider
                    :responder (lambda (c)
                                 (declare (ignore c))
                                 (setf seen llm:*timeout*)
                                 (text-response "ok"))))
         (harness:*clock* (fixed-clock 100))
         (llm:*timeout* 60))
    (harness:run-persona (harness:make-persona :name "t-timeout"
                                               :provider provider
                                               :max-seconds 30)
                         "x")
    (is (and (realp seen) (<= seen 30)) "request timeout was ~s" seen)))

(test run-no-usage-still-completes
  (let ((r (harness:run-persona
            (harness:make-persona
             :name "t-nousage"
             :provider (scripted (text-response "fine" :usage nil)))
            "x")))
    (is (eq :end-turn (harness:run-stop-reason r)))
    (is (= 0 (harness:run-input-tokens r)))
    (is (= 0 (harness:run-output-tokens r)))))

(test run-key-file-error
  (let ((r (harness:run-persona
            (harness:make-persona
             :name "t-nokey"
             :provider '(:kind :openai-compatible :base-url "http://x/v1"
                         :model "m" :api-key-file "/nonexistent/key"))
            "x")))
    (is (eq :error (harness:run-stop-reason r)))
    (is (search "/nonexistent/key" (format nil "~a" (harness:run-error r)))))
  (with-scratch-dir (dir)
    (let* ((key (write-text (merge-pathnames "key" dir) "SEKRIT"))
           (llm:*retries* 0)
           (r (harness:run-persona
               (harness:make-persona
                :name "t-leak"
                :provider (list :kind :openai-compatible
                                :base-url "http://127.0.0.1:9/v1" :model "m"
                                :api-key-file (namestring key)))
               "x")))
      (is (eq :error (harness:run-stop-reason r)))
      (is (null (search "SEKRIT" (format nil "~a ~s" (harness:run-error r)
                                         (harness:run-text r))))))))

(test run-unoffered-tool
  (let* ((c (llm:make-conversation :system "orig"))
         (before (progn (llm:add-message c (llm:make-message :user "q"))
                        (llm:add-message c (llm:make-message :assistant "a"))
                        (copy-list (llm:conversation-messages c))))
         (r (harness:run-persona
             (harness:make-persona
              :name "t-unoffered" :tools (list (echo-tool))
              :provider (scripted (tool-response "nope" "{}")))
             "x" :conversation c)))
    (is (eq :error (harness:run-stop-reason r)))
    (is (equal before (llm:conversation-messages c)))))

(test run-unknown-tool-name
  (let ((r (harness:run-persona
            (harness:make-persona :name "t-unknown" :tools '("no-such-tool")
                                  :provider (scripted (text-response "x")))
            "x")))
    (is (eq :error (harness:run-stop-reason r)))
    (is (search "no-such-tool" (format nil "~a" (harness:run-error r))))))

(test run-continues-supplied-conversation
  (let* ((seen-system nil)
         (other (llm:make-mock-provider :responder (constantly "other")))
         (c (llm:make-conversation :system "orig" :provider other))
         (r (progn
              (llm:add-message c (llm:make-message :user "earlier"))
              (llm:add-message c (llm:make-message :assistant "reply"))
              (harness:run-persona
               (harness:make-persona
                :name "t-borrow" :system "persona system"
                :provider (llm:make-mock-provider
                           :responder (lambda (conv)
                                        (setf seen-system
                                              (llm:conversation-system conv))
                                        (text-response "next"))))
               "later" :conversation c))))
    (is (eq :end-turn (harness:run-stop-reason r)))
    (is (string= "persona system" seen-system))
    (is (= 4 (length (llm:conversation-messages c))))
    (is (string= "orig" (llm:conversation-system c)))
    (is (eq other (llm:conversation-provider c)))))

(test run-tool-sees-time-left
  (let* ((clock-tool (llm:make-tool 'clock "Seconds left." '()
                                    (lambda () (harness:time-left))))
         (harness:*clock* (fixed-clock 100))
         (r (harness:run-persona
             (harness:make-persona
              :name "t-timeleft" :tools (list clock-tool) :max-seconds 60
              :provider (scripted (tool-response "clock" "{}")
                                  (text-response "done")))
             "x"))
         (result (getf (first (harness:run-tool-calls r)) :result))
         (left (let ((*read-eval* nil)) (read-from-string result))))
    (is (and (realp left) (<= left 60)) "time-left was ~s" result)))

(test run-borrowed-conversation-model-is-lent
  ;; Final review: a borrowed conversation's :model must not override
  ;; the persona's provider for the run, and comes back afterwards.
  (let* ((seen :unset)
         (c (llm:make-conversation :model "borrowed-model"))
         (r (harness:run-persona
             (harness:make-persona
              :name "t-model"
              :provider (llm:make-mock-provider
                         :responder (lambda (conv)
                                      (setf seen
                                            (llm:conversation-model conv))
                                      (text-response "ok"))))
             "x" :conversation c)))
    (is (eq :end-turn (harness:run-stop-reason r)))
    (is (null seen) "the run used the conversation's model ~s" seen)
    (is (equal "borrowed-model" (llm:conversation-model c)))))
