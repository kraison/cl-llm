;;;; tests-rag-chat/options-tests.lisp -- :turns history, carry-forward
;;;; and compaction inside the turn (spec SS8.2 step 3, SS7.3).

(in-package #:cl-llm.rag.chat/tests)
(in-suite :cl-llm-rag-chat)

(defun sequenced-retriever (&rest hit-lists)
  "A RETRIEVE function answering each call with the next of HIT-LISTS."
  (lambda (query k)
    (declare (ignore query k))
    (pop hit-lists)))

(defun options-chat (&key (history :questions) carry-forward carry-filter
                          (retrieve (retriever (hit "d1" "x")))
                          (history-budget 6000) (rewrite "standalone?")
                          (summary "SUMMARY-TEXT"))
  "Values: chat, answer log, rewrite log, compaction log."
  (harness:reset-persona-state)
  (multiple-value-bind (answer-provider answer-log) (recorder "the answer")
    (multiple-value-bind (rewrite-provider rewrite-log) (recorder rewrite)
      (multiple-value-bind (compact-provider compact-log) (recorder summary)
        (values (chat:make-rag-chat
                 :answer-persona (persona "t-answer" answer-provider)
                 :rewrite-persona (persona "t-rewrite" rewrite-provider)
                 :compaction-persona (persona "t-compact" compact-provider)
                 :retrieve retrieve :history history
                 :carry-forward carry-forward :carry-filter carry-filter
                 :history-budget history-budget)
                answer-log rewrite-log compact-log)))))

(test turns-history-shows-answers
  (multiple-value-bind (chat answer-log) (options-chat :history :turns)
    (chat:rag-chat-turn chat (sc-with-turn) "how is it powered?")
    (let ((request (first (funcall answer-log))))
      (is (search "ANSWER-ONE" (getf request :all))
          "the earlier answer did not reach the answer model")
      (is (not (search "ANSWER-ONE" (getf request :user)))
          "the earlier pair came inside the user text, not as messages"))))

(defun two-turns (chat)
  "Run two turns of CHAT on a fresh conversation; the second's answer
request (the last one logged) is what the tests read."
  (let ((sc (llm:make-stored-conversation :owner "ada")))
    (chat:rag-chat-turn chat sc "first question")
    (chat:rag-chat-turn chat sc "second question")
    sc))

(defun keeps-marked (standalone hits)
  (declare (ignore standalone))
  (remove-if-not (lambda (h) (search "keep" (rag:chunk-text (rag:hit-chunk h))))
                 hits))

(test carry-forward-goes-through-the-filter
  (multiple-value-bind (chat answer-log)
      (options-chat :carry-forward t :carry-filter #'keeps-marked
                    :retrieve (sequenced-retriever
                               (list (hit "doc-a" "keep: TEXT-A"))
                               (list (hit "doc-b" "TEXT-B"))))
    (two-turns chat)
    (let ((user (getf (car (last (funcall answer-log))) :user)))
      (is (search "TEXT-A" user) "the kept hit was not carried")
      (is (search "TEXT-B" user))
      (is (= 1 (count-matches "TEXT-A" user)) "a carried hit appears twice")))
  (multiple-value-bind (chat answer-log)
      (options-chat :carry-forward t :carry-filter (constantly '())
                    :retrieve (sequenced-retriever
                               (list (hit "doc-a" "keep: TEXT-A"))
                               (list (hit "doc-b" "TEXT-B"))))
    (two-turns chat)
    (let ((user (getf (car (last (funcall answer-log))) :user)))
      (is (not (search "TEXT-A" user)) "a filtered-out hit was carried")
      (is (search "TEXT-B" user)))))

(test carry-forward-off-by-default
  (multiple-value-bind (chat answer-log)
      (options-chat :retrieve (sequenced-retriever
                               (list (hit "doc-a" "keep: TEXT-A"))
                               (list (hit "doc-b" "TEXT-B"))))
    (let ((sc (two-turns chat)))
      (let ((user (getf (car (last (funcall answer-log))) :user)))
        (is (not (search "TEXT-A" user)))
        (is (search "TEXT-B" user)))
      (is (every (lambda (ann)
                   (every (lambda (source) (null (gethash "text" source)))
                          (gethash "sources" ann)))
                 (llm:stored-conversation-turns sc))
          "sources stored their text without carry-forward"))))

(test turn-compacts-long-history
  (multiple-value-bind (chat answer-log rewrite-log compact-log)
      (options-chat :history-budget 20)
    (declare (ignore answer-log))
    (let ((sc (llm:make-stored-conversation :owner "ada")))
      (dotimes (i 6)
        (llm:record-turn sc (format nil "question number ~d about pumps" i)
                         (format nil "answer number ~d about pumps" i)))
      (let ((turn (chat:rag-chat-turn chat sc "and the next one?")))
        (is (eq :end-turn (chat:rag-turn-stop-reason turn)))
        (is (plusp (length (funcall compact-log))) "nothing was compacted")
        (is (string= "SUMMARY-TEXT" (llm:stored-conversation-summary sc)))
        (is (search "SUMMARY-TEXT"
                    (getf (first (funcall rewrite-log)) :all)))))))

;;; Final review (conversations-89-90)

(test rewrite-reply-with-surrounding-newlines-kept-whole
  (dolist (reply (list (format nil "~%How is device X powered?~%")
                       (format nil "  How is device X powered?~%")
                       (format nil "~%~%How is device X powered?~%more")))
    (multiple-value-bind (chat answer-log rewrite-log queries)
        (chat-with :rewrite reply)
      (declare (ignore answer-log rewrite-log))
      (chat:rag-chat-turn chat (sc-with-turn) "how is it powered?")
      (is (equal '("How is device X powered?") (funcall queries))
          "reply ~s searched as ~s" reply (funcall queries)))))

(test questions-history-skips-summarized-turns
  ;; The answer prompt must not grow without bound: folded questions
  ;; are in the summary, which the answer model does not see.
  (multiple-value-bind (chat answer-log) (chat-with)
    (let ((sc (sc-with-turn)))
      (llm:record-turn sc "SECOND-QUESTION" "second answer")
      (setf (llm:stored-conversation-summary sc) "SUMMARY-X"
            (llm:stored-conversation-summarized sc) 2)
      (chat:rag-chat-turn chat sc "third?")
      (let ((user (getf (first (funcall answer-log)) :user)))
        (is (search "SECOND-QUESTION" user))
        (is (not (search "Tell me about device X" user)))
        (is (not (search "SUMMARY-X" user)))))))

(test failing-filter-fails-turn
  (multiple-value-bind (chat)
      (options-chat :carry-forward t
                    :carry-filter (lambda (q hits)
                                    (declare (ignore q hits))
                                    (error "filter bug"))
                    :retrieve (sequenced-retriever
                               (list (hit "doc-a" "A"))
                               (list (hit "doc-b" "B"))))
    (let ((sc (llm:make-stored-conversation :owner "ada")))
      (chat:rag-chat-turn chat sc "first")
      (let* ((before (snapshot sc))
             (turn (chat:rag-chat-turn chat sc "second")))
        (is (eq :error (chat:rag-turn-stop-reason turn)))
        (is (equal before (snapshot sc)))))))

(test turn-annotation-records-timing
  (multiple-value-bind (chat) (chat-with)
    (let ((sc (llm:make-stored-conversation)))
      (chat:rag-chat-turn chat sc "q")
      (let ((run (gethash "run" (first (llm:stored-conversation-turns sc)))))
        (is (realp (gethash "elapsed" run)))))))
