;;;; tests-conversation-vivace/store-tests.lisp -- the store protocol on
;;;; a graph, mirroring the file store's tests (tests/conversation-store).

(in-package #:cl-llm.conversation.vivace/tests)
(in-suite :cl-llm-conversation-vivace)

(test graph-store-new-is-current
  (with-graph (g)
    (let* ((store (cv:make-graph-conversation-store g))
           (first (llm:new-conversation store "ada" :title "one")))
      (%age store first 10)
      (let ((second (llm:new-conversation store "ada" :title "two")))
        (is (string= (llm:stored-conversation-id second)
                     (llm:stored-conversation-id
                      (llm:current-conversation store "ada"))))
        (is (null (llm:stored-conversation-current-p
                   (llm:load-conversation
                    store (llm:stored-conversation-id first)))))
        (is (equal '("two" "one")
                   (mapcar #'llm:stored-conversation-title
                           (llm:list-conversations store "ada"))))))))

(test graph-store-load-owner-scoped
  (with-graph (g)
    (let* ((store (cv:make-graph-conversation-store g))
           (id (llm:stored-conversation-id
                (llm:new-conversation store "ada"))))
      (is (string= "ada" (llm:stored-conversation-owner
                          (llm:load-conversation store id))))
      (is (null (llm:load-conversation store id :owner "bob")))
      (is (null (llm:load-conversation store "absent")))
      (is (null (llm:list-conversations store "bob"))))))

(test graph-store-save-persists-turns
  (with-graph (g dir)
    (let* ((store (cv:make-graph-conversation-store g))
           (sc (llm:new-conversation store "ada"))
           (id (llm:stored-conversation-id sc)))
      (llm:record-turn sc "q" "a" (%ann "standalone" "q?"))
      (llm:save-conversation store sc)
      (gdb:close-graph g)
      (let ((reopened (gdb:open-graph +graph-name+ dir
                                      :buffer-pool-size 1000)))
        (unwind-protect
             (let ((back (llm:load-conversation
                          (cv:make-graph-conversation-store reopened) id)))
               (is (= 2 (length (llm:conversation-messages
                                 (llm:stored-conversation-conversation
                                  back)))))
               (is (string= "q?" (gethash "standalone"
                                          (first
                                           (llm:stored-conversation-turns
                                            back))))))
          (gdb:close-graph reopened))))))

(test graph-store-make-current
  (with-graph (g)
    (let* ((store (cv:make-graph-conversation-store g))
           (scs (loop repeat 3 collect (llm:new-conversation store "ada"))))
      (llm:make-conversation-current store (first scs))
      (let ((current (remove-if-not #'llm:stored-conversation-current-p
                                    (llm:list-conversations store "ada"))))
        (is (= 1 (length current)))
        (is (string= (llm:stored-conversation-id (first scs))
                     (llm:stored-conversation-id (first current))))))))

(test graph-store-non-ascii
  (with-graph (g)
    (let* ((store (cv:make-graph-conversation-store g))
           (sc (llm:new-conversation store "ada" :title "Розмова")))
      (llm:record-turn sc "Що таке ПФМ-1?" "Протипіхотна міна.")
      (llm:save-conversation store sc)
      (let ((back (llm:load-conversation
                   store (llm:stored-conversation-id sc))))
        (is (string= "Розмова" (llm:stored-conversation-title back)))
        (is (string= "Що таке ПФМ-1?"
                     (llm:part-text
                      (first (llm:message-content
                              (first (llm:conversation-messages
                                      (llm:stored-conversation-conversation
                                       back))))))))))))

(test graph-store-restores-ambient-graph
  (with-graph (g)
    (let* ((other-dir (%scratch "conv-other"))
           (other (gdb:make-graph :cl-llm-conversations-other other-dir
                                  :buffer-pool-size 1000)))
      (unwind-protect
           (let ((gdb:*graph* other)
                 (store (cv:make-graph-conversation-store g)))
             (let ((sc (llm:new-conversation store "ada")))
               (is (eq other gdb:*graph*))
               (llm:save-conversation store sc)
               (is (eq other gdb:*graph*))
               (llm:load-conversation store (llm:stored-conversation-id sc))
               (llm:list-conversations store "ada")
               (llm:current-conversation store "ada")
               (is (eq other gdb:*graph*))))
        (ignore-errors (gdb:close-graph other))
        (ignore-errors (uiop:delete-directory-tree (pathname other-dir)
                                                   :validate t))))))

(test graph-store-skips-a-corrupt-vertex
  (with-graph (g)
    (let ((store (cv:make-graph-conversation-store g))
          (warnings 0))
      (llm:new-conversation store "ada")
      (let ((gdb:*graph* g))
        (gdb:with-transaction (:graph g)
          (cl-llm.conversation.vivace::make-stored-conversation-vertex
           :cv-id "c-bad" :cv-owner "ada" :cv-updated 0 :cv-current nil
           :cv-json "not json" :graph g)))
      (let ((listed (handler-bind ((warning (lambda (w)
                                               (incf warnings)
                                               (muffle-warning w))))
                      (llm:list-conversations store "ada"))))
        (is (= 1 (length listed)))
        (is (= 1 warnings))))))
