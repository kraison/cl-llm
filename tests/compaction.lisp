;;;; tests/compaction.lisp -- long histories condensed for the model
;;;; (#89; spec SS7.3).

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun %turns-sc (n &key (size 50))
  "A stored conversation of N turns; each question and answer SIZE chars,
the question starting \"Q<i>\"."
  (let ((sc (llm:make-stored-conversation :owner "ada" :system "Sys")))
    (dotimes (i n sc)
      (flet ((pad (prefix)
               (let ((s (make-string size :initial-element #\x)))
                 (replace s (format nil "~a~d " prefix (1+ i)))
                 s)))
        (llm:record-turn sc (pad "Q") (pad "A"))))))

(defun %recording-summarizer ()
  "A SUMMARIZE function returning S1, S2, ...; second value: the list of
(previous-summary messages) it was called with, oldest first."
  (let ((calls '()))
    (values (lambda (previous messages)
              (push (list previous messages) calls)
              (format nil "S~d" (length calls)))
            (lambda () (reverse calls)))))

(defun %messages (sc)
  (llm:conversation-messages (llm:stored-conversation-conversation sc)))

(defun %first-text (message)
  (llm:part-text (first (llm:message-content message))))

(test estimate-tokens-counts-text
  (let ((llm:*chars-per-token* 4))
    (is (= 10 (llm:estimate-tokens
               (list (llm:make-message :user (make-string 40
                                                          :initial-element
                                                          #\a))))))))

(test compaction-under-budget-is-a-no-op
  (multiple-value-bind (summarize calls) (%recording-summarizer)
    (let ((sc (%turns-sc 2)))
      (is (null (nth-value 1 (llm:compact-conversation
                              sc :summarize summarize :budget 1000))))
      (is (null (funcall calls)))
      (is (= 0 (llm:stored-conversation-summarized sc))))))

(test compaction-folds-oldest-block
  (multiple-value-bind (summarize calls) (%recording-summarizer)
    (let ((sc (%turns-sc 6)))
      ;; EQ T, not a bare NTH-VALUE: FiveAM's IS takes the form apart.
      (is (eq t (nth-value 1 (llm:compact-conversation
                              sc :summarize summarize :budget 60
                                 :keep-recent 2 :block 2))))
      (let* ((first-call (first (funcall calls)))
             (folded (second first-call))
             (msgs (%messages sc))
             (cut (llm:stored-conversation-summarized sc)))
        (is (null (first first-call)) "the first fold has no summary yet")
        (is (eql 0 (search "Q1 " (%first-text (first folded)))))
        (is (string= (format nil "S~d" (length (funcall calls)))
                     (llm:stored-conversation-summary sc)))
        (is (eq :user (llm:message-role (nth cut msgs))))
        (is (<= cut (- (length msgs) 4)) "a kept recent turn was folded")
        (is (eql 0 (search "Q5 " (%first-text
                                  (nth (- (length msgs) 4) msgs)))))))))

(test compaction-keeps-recent-and-terminates
  (multiple-value-bind (summarize calls) (%recording-summarizer)
    (let ((sc (%turns-sc 1 :size 10000)))
      (is (null (nth-value 1 (llm:compact-conversation
                              sc :summarize summarize :budget 10
                                 :keep-recent 1))))
      (is (null (funcall calls))))))

(test compaction-folds-tool-turns-whole
  (multiple-value-bind (summarize calls) (%recording-summarizer)
    (declare (ignore calls))
    (let* ((sc (llm:make-stored-conversation :owner "ada"))
           (c (llm:stored-conversation-conversation sc))
           (args (make-hash-table :test #'equal)))
      (llm:add-message c (llm:make-message :user "q1"))
      (llm:add-message c (llm:make-message
                          :assistant (llm:make-tool-use-part "t1" "f" args)))
      (llm:add-message c (llm:make-message
                          :user (llm:make-tool-result-part "t1" "r")))
      (llm:add-message c (llm:make-message :assistant "a1"))
      (llm:add-message c (llm:make-message :user "q2"))
      (llm:add-message c (llm:make-message :assistant "a2"))
      (llm:compact-conversation sc :summarize summarize :budget 1
                                   :keep-recent 1 :block 1)
      (is (= 4 (llm:stored-conversation-summarized sc)))
      (is (string= "q2" (%first-text (nth 4 (%messages sc))))))))

(test compaction-non-string-summary-signals
  (let ((sc (%turns-sc 4)))
    (signals llm:llm-error
      (llm:compact-conversation sc :summarize (constantly nil) :budget 1
                                   :keep-recent 1 :block 1))))

(test conversation-for-model-carries-summary
  (let* ((sc (%turns-sc 3))
         (before (copy-list (%messages sc))))
    (setf (llm:stored-conversation-summary sc) "S"
          (llm:stored-conversation-summarized sc) 2)
    (let* ((c (llm:conversation-for-model sc))
           (system (llm:conversation-system c)))
      (is (search "Sys" system))
      (is (search "Summary of the earlier conversation:" system))
      (is (search "S" system :start2 (search "Summary" system)))
      (is (equal (nthcdr 2 before) (llm:conversation-messages c)))
      (is (null (llm:conversation-provider c))))
    (is (equal before (%messages sc)) "the stored record changed")))
