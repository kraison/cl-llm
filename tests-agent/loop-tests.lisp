;;;; tests-agent/loop-tests.lisp -- the model scripted through the
;;;; mock provider: a whole loop with no network.  Spec SS10.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %tool-use (id name &rest plist)
  (make-instance 'llm:response
                 :content (list (llm:make-tool-use-part
                                 id name (apply #'%args plist)))
                 :stop-reason :tool-use))

(defun %scripted (turns)
  "A provider that answers TURNS in order: each a function of the
conversation returning a RESPONSE or a string."
  (let ((remaining turns))
    (llm:make-mock-provider
     :responder (lambda (conversation)
                  (funcall (pop remaining) conversation)))))

(defun %last-tool-result (conversation)
  "The content of the last tool-result part the model was sent.
Every result of a turn lands in ONE user message appended after the
tool-use assistant message (tool-loop.lisp), so the last message of
CONVERSATION -- as the responder sees it, before its own turn is
appended -- is the one to search.  (LAST MSGS) takes n=1: the final
cons, not a two-message tail."
  (let* ((msgs (llm:conversation-messages conversation))
         (parts (llm:message-content (car (last msgs)))))
    (find-if (lambda (p) (typep p 'llm:tool-result-part)) parts)))

(test a-scripted-loop-recalls-then-concludes-citing-what-it-read
  (with-stores (w p)
    (%belief p "owner" '(:person . "kevin"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (seen-cite nil)
           (provider
             (%scripted
              (list
               (lambda (c) (declare (ignore c))
                 (%tool-use "t1" "recall" "subject-namespace" "repo"
                            "subject-key" "cl-llm"))
               (lambda (c)
                 (let* ((result (%last-tool-result c))
                        (r (json:parse (llm:part-content result)))
                        (cite (json:jget
                               (first (coerce (json:jget r "records")
                                              'list))
                               "cite")))
                   (setf seen-cite cite)
                   (%tool-use "t2" "conclude"
                              "subject-namespace" "repo"
                              "subject-key" "cl-llm"
                              "relation" "releasable"
                              "object-namespace" "verdict"
                              "object-key" "yes"
                              "rule" "owner-says"
                              "evidence" (vector cite))))
               (lambda (c) (declare (ignore c)) "Done."))))
           (text (llm:ask "is it releasable?" :provider provider
                                              :tools tools)))
      (is (string= "Done." text))
      (let* ((ids (mem:decisions-citing w seen-cite :scope (list w p)))
             (rec (mem:trace w (first ids) :scope (list w p))))
        (is (= 1 (length ids)))
        (is (string= seen-cite
                     (mem:cite-record-cite
                      (first (mem:decision-record-evidence rec)))))
        (is (eq :resolved
                (mem:cite-record-state
                 (first (mem:decision-record-evidence rec)))))))))

(test a-tool-error-reaches-the-model-as-an-error-result
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (seen nil)
           (provider
             (%scripted
              (list
               (lambda (c) (declare (ignore c))
                 (%tool-use "t1" "recall" "subject-namespace" "repo"
                            "subject-key" "cl-llm" "at" "not-a-date"))
               (lambda (c)
                 (setf seen (%last-tool-result c))
                 "ok")))))
      (is (string= "ok" (llm:ask "?" :provider provider :tools tools)))
      (is-true (llm:part-error-p seen))
      (is (stringp (llm:part-content seen))))))

(test the-loop-is-bounded-by-max-tool-turns
  (with-stores (w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (provider (llm:make-mock-provider
                      :responder (lambda (c) (declare (ignore c))
                                   (%tool-use "t" "recall"
                                              "subject-namespace" "repo"
                                              "subject-key" "cl-llm")))))
      (signals llm:llm-tool-error
        (llm:ask "loop" :provider provider :tools tools
                        :max-tool-turns 3)))))
