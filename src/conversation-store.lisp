;;;; conversation-store.lisp -- the store protocol, and a file store
;;;; (#89).  docs/conversations.md, "Stores".

(in-package #:cl-llm)

(defgeneric save-conversation (store sc)
  (:documentation "Write SC to STORE, replacing any earlier version.
Returns SC."))

(defgeneric load-conversation (store id &key owner)
  (:documentation "The stored conversation ID in STORE, or NIL when
there is none, or when OWNER is given and differs."))

(defgeneric list-conversations (store owner)
  (:documentation "OWNER's stored conversations, newest UPDATED first."))

(defgeneric current-conversation (store owner)
  (:documentation "OWNER's current stored conversation, or NIL."))

(defgeneric make-conversation-current (store sc)
  (:documentation "Make SC its owner's current conversation and every
other of theirs not, saving what changed.  Returns SC."))

(defgeneric new-conversation (store owner &key title system parameters
                                               model)
  (:documentation "A fresh stored conversation for OWNER, saved and made
current; the previous current one is kept, no longer current."))

;;; Methods any store gets from the four primitives above.

(defmethod current-conversation (store owner)
  (find-if #'stored-conversation-current-p
           (list-conversations store owner)))

(defmethod make-conversation-current (store sc)
  (let ((id (stored-conversation-id sc)))
    (dolist (other (list-conversations store (stored-conversation-owner sc)))
      (let ((want (string= id (stored-conversation-id other))))
        (unless (eq want (and (stored-conversation-current-p other) t))
          (setf (stored-conversation-current-p other) want)
          (save-conversation store other))))
    (setf (stored-conversation-current-p sc) t)
    (save-conversation store sc)))

(defmethod new-conversation (store owner &key title system parameters
                                              model)
  (let ((sc (make-stored-conversation :owner owner :title title
                                      :system system :model model
                                      :parameters parameters)))
    (save-conversation store sc)
    (make-conversation-current store sc)))

;;; The file store: one <id>.json per conversation.

(defclass file-conversation-store ()
  ((directory :initarg :directory
              :reader file-conversation-store-directory))
  (:documentation "Stored conversations as <id>.json files in one
directory.  For scripts and tests; a server wants a database."))

(defun make-file-conversation-store (directory)
  (let ((dir (uiop:ensure-directory-pathname directory)))
    (ensure-directories-exist dir)
    (make-instance 'file-conversation-store :directory dir)))

(defun %conversation-path (store id &optional (type "json"))
  (merge-pathnames (make-pathname :name id :type type)
                   (file-conversation-store-directory store)))

(defmethod save-conversation ((store file-conversation-store) sc)
  ;; Through a temporary file and a rename, so a crash never leaves
  ;; half a record behind.
  (let ((id (stored-conversation-id sc)))
    (unless (%canonical-id-p id)
      (error 'c:llm-parse-error
             :message (format nil "conversation id ~s is not [a-z0-9-]+"
                              id)))
    (let ((tmp (%conversation-path store id "tmp")))
      (with-open-file (s tmp :direction :output :if-exists :supersede
                             :external-format :utf-8)
        (write-string (stored-conversation-to-json sc) s))
      (uiop:rename-file-overwriting-target tmp (%conversation-path store id))))
  sc)

(defun %read-conversation-file (path)
  (stored-conversation-from-json
   (uiop:read-file-string path :external-format :utf-8)))

(defmethod load-conversation ((store file-conversation-store) id
                              &key owner)
  (when (%canonical-id-p id)          ; never a path from outside
    (let ((path (%conversation-path store id)))
      (when (probe-file path)
        (let ((sc (%read-conversation-file path)))
          (when (or (null owner)
                    (equal owner (stored-conversation-owner sc)))
            sc))))))

(defmethod list-conversations ((store file-conversation-store) owner)
  (let ((found '()))
    (dolist (path (uiop:directory-files
                   (file-conversation-store-directory store) "*.json"))
      (handler-case
          (let ((sc (%read-conversation-file path)))
            (when (equal owner (stored-conversation-owner sc))
              (push sc found)))
        (error (e)
          (warn "skipping unreadable conversation file ~a: ~a" path e))))
    (sort found #'> :key #'stored-conversation-updated)))
