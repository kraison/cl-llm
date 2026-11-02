;;;; tests/conversation-store.lisp -- the store protocol and the file
;;;; store (#89).

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defun %call-with-temp-dir (fn)
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "/tmp/cl-llm-conv-~a-~a/"
                      (get-internal-real-time) (random 1000000)))))
    (ensure-directories-exist dir)
    (unwind-protect (funcall fn dir)
      (uiop:delete-directory-tree dir :validate t
                                      :if-does-not-exist :ignore))))

(defmacro with-temp-dir ((var) &body body)
  `(%call-with-temp-dir (lambda (,var) ,@body)))

(defun %age (store sc seconds)
  "Make SC look SECONDS older, so list order does not hang on a tie."
  (decf (llm:stored-conversation-updated sc) seconds)
  (llm:save-conversation store sc))

(test file-store-new-is-current
  (with-temp-dir (dir)
    (let* ((store (llm:make-file-conversation-store dir))
           (first (llm:new-conversation store "ada" :title "one")))
      (%age store first 10)
      (let ((second (llm:new-conversation store "ada" :title "two")))
        (is (string= (llm:stored-conversation-id second)
                     (llm:stored-conversation-id
                      (llm:current-conversation store "ada"))))
        (let ((again (llm:load-conversation
                      store (llm:stored-conversation-id first))))
          (is (string= "one" (llm:stored-conversation-title again)))
          (is (null (llm:stored-conversation-current-p again))))
        (is (equal '("two" "one")
                   (mapcar #'llm:stored-conversation-title
                           (llm:list-conversations store "ada"))))))))

(test file-store-load-owner-scoped
  (with-temp-dir (dir)
    (let* ((store (llm:make-file-conversation-store dir))
           (id (llm:stored-conversation-id
                (llm:new-conversation store "ada"))))
      (is (string= "ada" (llm:stored-conversation-owner
                          (llm:load-conversation store id))))
      (is (null (llm:load-conversation store id :owner "bob")))
      (is (null (llm:load-conversation store "absent")))
      (is (null (llm:list-conversations store "bob"))))))

(test file-store-save-persists-turns
  (with-temp-dir (dir)
    (let* ((store (llm:make-file-conversation-store dir))
           (sc (llm:new-conversation store "ada")))
      (llm:record-turn sc "q" "a" (%ann "standalone" "q?"))
      (llm:save-conversation store sc)
      (let ((back (llm:load-conversation
                   (llm:make-file-conversation-store dir)
                   (llm:stored-conversation-id sc))))
        (is (= 2 (length (llm:conversation-messages
                          (llm:stored-conversation-conversation back)))))
        (is (string= "q?" (gethash "standalone"
                                   (first (llm:stored-conversation-turns
                                           back)))))))))

(test file-store-make-current
  (with-temp-dir (dir)
    (let* ((store (llm:make-file-conversation-store dir))
           (scs (loop repeat 3 collect (llm:new-conversation store "ada"))))
      (llm:make-conversation-current store (first scs))
      (let ((current (remove-if-not #'llm:stored-conversation-current-p
                                    (llm:list-conversations store "ada"))))
        (is (= 1 (length current)))
        (is (string= (llm:stored-conversation-id (first scs))
                     (llm:stored-conversation-id (first current))))))))

(test file-store-skips-a-corrupt-file
  (with-temp-dir (dir)
    (let ((store (llm:make-file-conversation-store dir))
          (warnings 0))
      (llm:new-conversation store "ada")
      (with-open-file (s (merge-pathnames "x.json" dir) :direction :output)
        (write-string "not json" s))
      (let ((listed (handler-bind ((warning (lambda (w)
                                               (incf warnings)
                                               (muffle-warning w))))
                      (llm:list-conversations store "ada"))))
        (is (= 1 (length listed)))
        (is (= 1 warnings))))))

(test file-store-non-ascii
  (with-temp-dir (dir)
    (let* ((store (llm:make-file-conversation-store dir))
           (sc (llm:new-conversation store "ada" :title "Розмова")))
      (llm:record-turn sc "Що таке ПФМ-1?" "Протипіхотна міна.")
      (llm:save-conversation store sc)
      (let ((back (llm:load-conversation
                   (llm:make-file-conversation-store dir)
                   (llm:stored-conversation-id sc))))
        (is (string= "Розмова" (llm:stored-conversation-title back)))
        (is (string= "Що таке ПФМ-1?"
                     (llm:part-text
                      (first (llm:message-content
                              (first (llm:conversation-messages
                                      (llm:stored-conversation-conversation
                                       back))))))))))))
