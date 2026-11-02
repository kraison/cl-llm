;;;; tests-rag-chat/suite.lisp -- recording mock models and retrievers.

(in-package #:cl-llm.rag.chat/tests)

(def-suite :cl-llm-rag-chat
  :description "cl-llm/rag/chat offline suite (mock models).")
(in-suite :cl-llm-rag-chat)

(defun %text (message)
  (format nil "~{~a~}"
          (loop for part in (llm:message-content message)
                when (typep part 'llm:text-part)
                  collect (llm:part-text part))))

(defun recorder (&rest replies)
  "A mock provider answering REPLIES in order (the last forever); each a
string or a function of the conversation.  Second value: a function
returning the requests seen, oldest first, as plists of :system, :user
(the last message's text) and :all (every message's text, joined)."
  (let ((log '()) (n 0))
    (values
     (llm:make-mock-provider
      :responder (lambda (c)
                   (let ((msgs (llm:conversation-messages c)))
                     (push (list :system (or (llm:conversation-system c) "")
                                 :user (%text (car (last msgs)))
                                 :all (format nil "~{~a~%~}"
                                              (mapcar #'%text msgs)))
                           log))
                   (let ((reply (nth (min n (1- (length replies))) replies)))
                     (incf n)
                     (if (functionp reply) (funcall reply c) reply))))
     (lambda () (reverse log)))))

(defun hit (id text &key (title id))
  (rag:make-hit (rag:make-chunk text :document-id id
                                     :metadata (list :title title))
                0.9))

(defun retriever (&rest hits)
  "A RETRIEVE function returning HITS; second value: the queries seen."
  (let ((queries '()))
    (values (lambda (query k)
              (declare (ignore k))
              (push query queries)
              hits)
            (lambda () (reverse queries)))))

(defun persona (name provider &rest keys)
  (apply #'harness:make-persona :name name :provider provider keys))

(defun sc-with-turn ()
  "A stored conversation with one earlier turn about device X."
  (let ((sc (llm:make-stored-conversation :owner "ada"))
        (ann (make-hash-table :test #'equal)))
    (setf (gethash "standalone" ann) "Tell me about device X")
    (llm:record-turn sc "Tell me about device X"
                     "ANSWER-ONE: device X is a pump." ann)
    sc))

(defun snapshot (sc)
  "What a failed turn must leave unchanged."
  (list (copy-list (llm:conversation-messages
                    (llm:stored-conversation-conversation sc)))
        (copy-list (llm:stored-conversation-turns sc))
        (llm:stored-conversation-summary sc)
        (llm:stored-conversation-summarized sc)))

(defun count-matches (needle haystack)
  (loop with start = 0
        for at = (search needle haystack :start2 start)
        while at
        count t
        do (setf start (1+ at))))
