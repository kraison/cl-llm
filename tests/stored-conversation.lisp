;;;; tests/stored-conversation.lisp -- conversations as data (#89).

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun %ann (&rest kv)
  "A string-keyed hash-table from KV, as an annotation or JSON object."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun %canonical-id-p (id)
  (and (eql 0 (search "c-" id))
       (every (lambda (ch) (or (char<= #\a ch #\z) (char<= #\0 ch #\9)
                               (char= ch #\-)))
              id)))

(test conversation-id-canonical-and-distinct
  (let ((ids (loop repeat 1000 collect (llm:make-conversation-id))))
    (is (every #'%canonical-id-p ids))
    (is (= 1000 (length (remove-duplicates ids :test #'string=))))))

(defun %sample-stored-conversation ()
  (let* ((sc (llm:make-stored-conversation
              :owner "ada" :title "T" :system "Be terse." :model "m"
              :parameters '(:temperature 0.2 :max-tokens 100)))
         (c (llm:stored-conversation-conversation sc)))
    (llm:add-message c (llm:make-message :user "hi"))
    (llm:add-message c (llm:make-message
                        :assistant
                        (list (llm:make-text-part "adding")
                              (llm:make-tool-use-part "t1" "add"
                                                      (%ann "a" 1 "b" 2)))))
    (llm:add-message c (llm:make-message
                        :user (list (llm:make-tool-result-part "t1" "3"))))
    (setf (llm:stored-conversation-summary sc) "S"
          (llm:stored-conversation-summarized sc) 2
          (llm:stored-conversation-current-p sc) t
          (llm:stored-conversation-turns sc) (list (%ann "standalone" "x")))
    sc))

(defun %round-trip (sc)
  (llm:stored-conversation-from-json (llm:stored-conversation-to-json sc)))

(test stored-conversation-json-round-trip
  (let* ((sc (%sample-stored-conversation))
         (back (%round-trip sc))
         (c (llm:stored-conversation-conversation back))
         (msgs (llm:conversation-messages c))
         (params (llm:conversation-parameters c)))
    (is (string= (llm:stored-conversation-id sc)
                 (llm:stored-conversation-id back)))
    (is (string= "ada" (llm:stored-conversation-owner back)))
    (is (string= "T" (llm:stored-conversation-title back)))
    (is (= (llm:stored-conversation-created sc)
           (llm:stored-conversation-created back)))
    (is (string= "Be terse." (llm:conversation-system c)))
    (is (string= "m" (llm:conversation-model c)))
    (is (< (abs (- 0.2 (getf params :temperature))) 1e-6))
    (is (eql 100 (getf params :max-tokens)))
    (is (equal '(:user :assistant :user) (mapcar #'llm:message-role msgs)))
    (destructuring-bind (text use) (llm:message-content (second msgs))
      (is (string= "adding" (llm:part-text text)))
      (is (typep use 'llm:tool-use-part))
      (is (string= "t1" (llm:part-id use)))
      (is (string= "add" (llm:part-name use)))
      (is (eql 1 (gethash "a" (llm:part-arguments use)))))
    (let ((result (first (llm:message-content (third msgs)))))
      (is (typep result 'llm:tool-result-part))
      (is (string= "t1" (llm:part-tool-use-id result)))
      (is (string= "3" (llm:part-content result)))
      (is (null (llm:part-error-p result))))
    (is (string= "S" (llm:stored-conversation-summary back)))
    (is (= 2 (llm:stored-conversation-summarized back)))
    (is (eq t (llm:stored-conversation-current-p back)))
    (is (string= "x" (gethash "standalone"
                              (first (llm:stored-conversation-turns back)))))))

(test stored-conversation-non-ascii
  (let* ((text (format nil "Що таке ПФМ-1? «тест» ~a" (code-char #x1F642)))
         (sc (llm:make-stored-conversation :owner "ada")))
    (llm:add-message (llm:stored-conversation-conversation sc)
                     (llm:make-message :user text))
    (is (string= text
                 (llm:part-text
                  (first (llm:message-content
                          (first (llm:conversation-messages
                                  (llm:stored-conversation-conversation
                                   (%round-trip sc)))))))))))

(test stored-conversation-unknown-keys-ignored
  (let* ((object (json:parse (llm:stored-conversation-to-json
                              (llm:make-stored-conversation :owner "ada")))))
    (setf (gethash "future" object) 1)
    (remhash "summary" object)
    (let ((back (llm:stored-conversation-from-json (json:to-json object))))
      (is (string= "ada" (llm:stored-conversation-owner back)))
      (is (null (llm:stored-conversation-summary back))))))

(test stored-conversation-id-must-be-canonical
  ;; An id becomes a file name and an index key: "../x" is refused.
  (let ((object (json:parse (llm:stored-conversation-to-json
                             (llm:make-stored-conversation :owner "ada")))))
    (setf (gethash "id" object) "../x")
    (signals llm:llm-parse-error
      (llm:stored-conversation-from-json (json:to-json object)))))

(test record-turn-appends-pair
  (let* ((sc (llm:make-stored-conversation :owner "ada"))
         (ann (%ann "standalone" "q?"))
         (before (length (llm:conversation-messages
                          (llm:stored-conversation-conversation sc)))))
    (llm:record-turn sc "q" "a" ann)
    (let ((msgs (llm:conversation-messages
                 (llm:stored-conversation-conversation sc))))
      (is (= (+ before 2) (length msgs)))
      (is (equal '(:user :assistant)
                 (mapcar #'llm:message-role (last msgs 2))))
      (is (string= "q" (llm:part-text (first (llm:message-content
                                              (first (last msgs 2))))))))
    (is (eq ann (first (last (llm:stored-conversation-turns sc)))))
    (is (>= (llm:stored-conversation-updated sc)
            (llm:stored-conversation-created sc)))))

;;; Final review (conversations-89-90)

(test stored-conversation-wrong-types-refused
  ;; A typed field of the wrong type is a parse error, not a TYPE-ERROR
  ;; later in a sort or an NTHCDR.
  (dolist (bad '(("updated" . "later") ("summarized" . "two")
                 ("owner" . 7) ("messages" . "none")))
    (let ((object (json:parse (llm:stored-conversation-to-json
                               (llm:make-stored-conversation :owner "ada")))))
      (setf (gethash (car bad) object) (cdr bad))
      (signals llm:llm-parse-error
        (llm:stored-conversation-from-json (json:to-json object))))))

(test stored-conversation-string-stop-round-trips
  (let ((sc (llm:make-stored-conversation :parameters '(:stop "END"))))
    (is (equal "END" (getf (llm:conversation-parameters
                            (llm:stored-conversation-conversation
                             (%round-trip sc)))
                           :stop)))))

(test conversation-id-state-seeded-on-first-use
  ;; A saved core restarts with whatever state was loaded; the state is
  ;; made on first use instead, and again after an image restore.
  (let ((llm::*conversation-id-random* nil))
    (is (%canonical-id-p (llm:make-conversation-id)))
    (is (random-state-p llm::*conversation-id-random*))))
