;;;; tests/core.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test make-message-wraps-string-content-in-a-text-part
  "Content is always a list of parts, never a bare string."
  (let ((m (llm:make-message :user "hi")))
    (is (eq :user (llm:message-role m)))
    (is (= 1 (length (llm:message-content m))))
    (is (typep (first (llm:message-content m)) 'llm:text-part))
    (is (string= "hi" (llm:part-text (first (llm:message-content m)))))))

(test make-message-accepts-a-part-list
  (let* ((part (llm:make-text-part "hi"))
         (m (llm:make-message :user (list part))))
    (is (eq part (first (llm:message-content m))))))

(test conversation-accumulates-messages-in-order
  (let ((c (llm:make-conversation :system "be terse")))
    (is (string= "be terse" (llm:conversation-system c)))
    (is (null (llm:conversation-messages c)))
    (llm:add-message c (llm:make-message :user "one"))
    (llm:add-message c (llm:make-message :assistant "two"))
    (is (= 2 (length (llm:conversation-messages c))))
    (is (eq :user (llm:message-role (first (llm:conversation-messages c)))))
    (is (eq :assistant (llm:message-role (second (llm:conversation-messages c)))))))

(test response-text-concatenates-text-parts-only
  (let ((r (make-instance 'llm:response
                          :content (list (llm:make-text-part "Hello ")
                                         (llm:make-tool-use-part "id1" "f" nil)
                                         (llm:make-text-part "world")))))
    (is (string= "Hello world" (llm:response-text r)))))

(test response-text-of-empty-content-is-empty-string
  (is (string= "" (llm:response-text (make-instance 'llm:response :content nil)))))

(test response-tool-calls-returns-only-tool-use-parts
  (let* ((call (llm:make-tool-use-part "id1" "get-weather" nil))
         (r (make-instance 'llm:response
                           :content (list (llm:make-text-part "x") call))))
    (is (equal (list call) (llm:response-tool-calls r)))))

(test tool-result-part-carries-error-flag
  (let ((p (llm:make-tool-result-part "id1" "boom" :errorp t)))
    (is (string= "id1" (llm:part-tool-use-id p)))
    (is (llm:part-error-p p))))

(test usage-readers
  (let ((u (make-instance 'llm:usage :input-tokens 10 :output-tokens 3)))
    (is (= 10 (llm:usage-input-tokens u)))
    (is (= 3 (llm:usage-output-tokens u)))))
