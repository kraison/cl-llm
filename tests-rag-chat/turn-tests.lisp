;;;; tests-rag-chat/turn-tests.lisp -- the conversational turn (spec
;;;; SS8.2), with mock models.

(in-package #:cl-llm.rag.chat/tests)
(in-suite :cl-llm-rag-chat)

(defun chat-with (&key (answer "the answer") rewrite
                       (hits (list (hit "d1" "x"))) (history :questions))
  "A rag-chat on recording mocks.  Values: chat, answer log, rewrite log,
queries."
  (harness:reset-persona-state)
  (multiple-value-bind (answer-provider answer-log) (recorder answer)
    (multiple-value-bind (rewrite-provider rewrite-log)
        (recorder (or rewrite "standalone?"))
      (multiple-value-bind (retrieve queries) (apply #'retriever hits)
        (values (chat:make-rag-chat
                 :answer-persona (persona "t-answer" answer-provider
                                          :system "PERSONA-SYSTEM")
                 :rewrite-persona (persona "t-rewrite" rewrite-provider)
                 :retrieve retrieve :history history)
                answer-log rewrite-log queries)))))

(test first-turn-skips-rewrite
  (multiple-value-bind (chat answer-log rewrite-log queries) (chat-with)
    (declare (ignore answer-log))
    (let* ((sc (llm:make-stored-conversation :owner "ada"))
           (turn (chat:rag-chat-turn chat sc "What is device X?")))
      (is (eq :end-turn (chat:rag-turn-stop-reason turn)))
      (is (null (funcall rewrite-log)) "the first question was rewritten")
      (is (equal '("What is device X?") (funcall queries)))
      (is (string= "What is device X?" (chat:rag-turn-standalone turn)))
      (is (= 1 (length (llm:stored-conversation-turns sc)))))))

(test follow-up-is-rewritten
  (multiple-value-bind (chat answer-log rewrite-log queries)
      (chat-with :rewrite "How is device X powered?")
    (let ((turn (chat:rag-chat-turn chat (sc-with-turn)
                                    "how is it powered?")))
      (is (eq :end-turn (chat:rag-turn-stop-reason turn)))
      (is (= 1 (length (funcall rewrite-log))))
      (is (search "Tell me about device X"
                  (getf (first (funcall rewrite-log)) :all)))
      (is (equal '("How is device X powered?") (funcall queries)))
      (is (string= "How is device X powered?"
                   (chat:rag-turn-standalone turn)))
      (is (search "How is device X powered?"
                  (getf (first (funcall answer-log)) :user))))))

(test questions-history-hides-answers
  (multiple-value-bind (chat answer-log) (chat-with)
    (chat:rag-chat-turn chat (sc-with-turn) "how is it powered?")
    (let ((request (first (funcall answer-log))))
      (is (not (search "ANSWER-ONE" (getf request :system))))
      (is (not (search "ANSWER-ONE" (getf request :all))))
      (is (search "Tell me about device X" (getf request :user))))))

(test grounding-instructions-composed
  (multiple-value-bind (chat answer-log) (chat-with)
    (chat:rag-chat-turn chat (llm:make-stored-conversation) "q")
    (let ((system (getf (first (funcall answer-log)) :system)))
      (is (search "PERSONA-SYSTEM" system))
      (is (search rag:*grounding-instructions* system)))))

(test empty-retrieval-still-answers
  (multiple-value-bind (chat answer-log) (chat-with :hits '())
    (let* ((sc (llm:make-stored-conversation))
           (turn (chat:rag-chat-turn chat sc "q")))
      (is (eq :end-turn (chat:rag-turn-stop-reason turn)))
      (is (= 1 (length (funcall answer-log))))
      (is (null (chat:rag-turn-hits turn)))
      (is (= 1 (length (llm:stored-conversation-turns sc)))))))

(test failed-rewrite-fails-turn
  (multiple-value-bind (chat answer-log rewrite-log queries)
      (chat-with :rewrite "   ")
    (declare (ignore rewrite-log))
    (let* ((sc (sc-with-turn))
           (before (snapshot sc))
           (turn (chat:rag-chat-turn chat sc "how is it powered?")))
      (is (not (eq :end-turn (chat:rag-turn-stop-reason turn))))
      (is (null (funcall queries)) "retrieved after a failed rewrite")
      (is (null (funcall answer-log)))
      (is (equal before (snapshot sc))))))

(test failed-answer-leaves-sc-unchanged
  (multiple-value-bind (chat)
      (chat-with :answer (lambda (c)
                           (declare (ignore c))
                           (make-instance
                            'llm:response
                            :content (list (llm:make-tool-use-part
                                            "t1" "nope"
                                            (make-hash-table :test #'equal)))
                            :stop-reason :tool-use)))
    (let* ((sc (sc-with-turn))
           (before (snapshot sc))
           (turn (chat:rag-chat-turn chat sc "how is it powered?")))
      ;; No tools offered, so core returns the tool request as-is: the
      ;; turn reports the answer run's own stop reason.
      (is (eq :tool-use (chat:rag-turn-stop-reason turn)))
      (is (eq (harness:run-stop-reason
               (getf (chat:rag-turn-runs turn) :answer))
              (chat:rag-turn-stop-reason turn)))
      (is (equal before (snapshot sc))))))

(test turn-annotation-recorded
  (multiple-value-bind (chat)
      (chat-with :rewrite "How is device X powered?"
                 :hits (list (hit "doc-a" "a") (hit "doc-b" "b")))
    (let* ((sc (sc-with-turn))
           (turn (chat:rag-chat-turn chat sc "how is it powered?"))
           (ann (car (last (llm:stored-conversation-turns sc)))))
      (is (eq :end-turn (chat:rag-turn-stop-reason turn)))
      (is (string= "How is device X powered?" (gethash "standalone" ann)))
      (is (equal '("doc-a" "doc-b")
                 (map 'list (lambda (s) (gethash "document-id" s))
                      (gethash "sources" ann))))
      (is (string= "end-turn" (gethash "stop" (gethash "run" ann)))))))

(test turn-saves-to-store
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "/tmp/cl-llm-rag-chat-~a-~a/"
                      (get-internal-real-time) (random 1000000)))))
    (unwind-protect
         (let* ((store (llm:make-file-conversation-store dir))
                (sc (llm:new-conversation store "ada"))
                (chat (chat-with)))
           (chat:rag-chat-turn chat sc "q" :store store)
           (is (= 2 (length (llm:conversation-messages
                             (llm:stored-conversation-conversation
                              (llm:load-conversation
                               store (llm:stored-conversation-id sc))))))))
      (uiop:delete-directory-tree dir :validate t
                                      :if-does-not-exist :ignore))))
