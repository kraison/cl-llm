;;;; stored-conversation.lisp -- a conversation kept as data (#89).
;;;; The provider is never stored; reading JSON interns no symbol but
;;;; the four parameter keys.  docs/conversations.md

(in-package #:cl-llm)

(defclass stored-conversation ()
  ((id :initarg :id :accessor stored-conversation-id)
   (owner :initarg :owner :initform nil :accessor stored-conversation-owner)
   (title :initarg :title :initform nil :accessor stored-conversation-title)
   (created :initarg :created :accessor stored-conversation-created
            :documentation "Universal time.")
   (updated :initarg :updated :accessor stored-conversation-updated
            :documentation "Universal time.")
   (conversation :initarg :conversation
                 :accessor stored-conversation-conversation)
   (summary :initarg :summary :initform nil
            :accessor stored-conversation-summary
            :documentation "The running summary of the folded messages.")
   (summarized :initarg :summarized :initform 0
               :accessor stored-conversation-summarized
               :documentation "How many leading messages SUMMARY covers.")
   (turns :initarg :turns :initform '() :accessor stored-conversation-turns
          :documentation "One annotation (an EQUAL hash-table) per turn,
oldest first.")
   (current-p :initarg :current-p :initform nil
              :accessor stored-conversation-current-p))
  (:documentation "A conversation with what a store needs to keep it."))

(defmethod print-object ((sc stored-conversation) stream)
  (print-unreadable-object (sc stream :type t)
    (format stream "~a ~@[~a~]" (stored-conversation-id sc)
            (stored-conversation-owner sc))))

;;; Ids.  The random state is made on first use, and again after an
;;; image restore: one made at load would repeat in every process
;;; started from a saved core.

(defvar *conversation-id-counter* 0)
(defvar *conversation-id-random* nil)

(uiop:register-image-restore-hook
 (lambda () (setf *conversation-id-random* nil)) nil)

(defun make-conversation-id ()
  "A conversation id, canonical [a-z0-9-]+: it becomes a file name and
an index key.  Unique within an image; across images and threads, with
high probability (a 36^10 random salt; core takes no lock)."
  (let ((state (or *conversation-id-random*
                   (setf *conversation-id-random* (make-random-state t)))))
    (string-downcase
     (format nil "c-~36r-~36r-~36r" (get-universal-time)
             (incf *conversation-id-counter*)
             (random (expt 36 10) state)))))

(defun %canonical-id-p (id)
  (and (stringp id) (plusp (length id))
       (every (lambda (ch) (or (char<= #\a ch #\z) (char<= #\0 ch #\9)
                               (char= ch #\-)))
              id)))

(defun make-stored-conversation (&key owner title system parameters model
                                      (id (make-conversation-id)))
  "A fresh, empty STORED-CONVERSATION, created and updated now."
  (let ((now (get-universal-time)))
    (make-instance 'stored-conversation
                   :id id :owner owner :title title
                   :created now :updated now
                   :conversation (make-conversation
                                  :system system :model model
                                  :parameters (copy-list parameters)))))

(defun record-turn (sc question answer &optional
                                         (annotation
                                          (make-hash-table :test #'equal)))
  "Append the user QUESTION and the assistant ANSWER to SC's
conversation, and ANNOTATION to its turns.  Returns SC."
  (let ((c (stored-conversation-conversation sc)))
    (add-message c (make-message :user question))
    (add-message c (make-message :assistant answer)))
  (setf (stored-conversation-turns sc)
        (append (stored-conversation-turns sc) (list annotation))
        (stored-conversation-updated sc) (get-universal-time))
  sc)

;;; JSON

(defun %object (&rest kv)
  "A JSON object from KV; a NIL value is JSON null, not omitted, and
:FALSE is JSON false (jzon writes NIL as false)."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr
          do (setf (gethash k h) (cond ((null v) 'null)
                                       ((eq v :false) nil)
                                       (t v))))
    h))

(defun %part->json (part)
  (etypecase part
    (text-part (%object "type" "text" "text" (part-text part)))
    (tool-use-part
     (%object "type" "tool-use" "id" (part-id part) "name" (part-name part)
              "arguments" (or (part-arguments part)
                              (make-hash-table :test #'equal))))
    (tool-result-part
     (%object "type" "tool-result" "tool-use-id" (part-tool-use-id part)
              "content" (princ-to-string (part-content part))
              "error" (if (part-error-p part) t :false)))))

(defun %message->json (message)
  (%object "role" (string-downcase (symbol-name (message-role message)))
           "content" (map 'vector #'%part->json (message-content message))))

(defparameter +parameter-keys+
  '(("temperature" . :temperature) ("max-tokens" . :max-tokens)
    ("top-p" . :top-p) ("stop" . :stop)))

(defun %parameters->json (plist)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (name . key) in +parameter-keys+
          for value = (getf plist key)
          when value
            do (setf (gethash name h)
                     (if (listp value) (coerce value 'vector) value)))
    h))

(defun stored-conversation-to-json (sc)
  "SC as a JSON string (docs/conversations.md, \"The JSON\")."
  (let ((c (stored-conversation-conversation sc)))
    (json:to-json
     (%object "version" 1
              "id" (stored-conversation-id sc)
              "owner" (stored-conversation-owner sc)
              "title" (stored-conversation-title sc)
              "created" (stored-conversation-created sc)
              "updated" (stored-conversation-updated sc)
              "current" (if (stored-conversation-current-p sc) t :false)
              "system" (conversation-system c)
              "model" (conversation-model c)
              "parameters" (%parameters->json (conversation-parameters c))
              "summary" (stored-conversation-summary sc)
              "summarized" (stored-conversation-summarized sc)
              "messages" (map 'vector #'%message->json
                              (conversation-messages c))
              "turns" (coerce (stored-conversation-turns sc) 'vector)))))

(defun %bad-json (control &rest args)
  (error 'c:llm-parse-error
         :message (apply #'format nil control args)))

(defun %typed (object key predicate what &optional default)
  "OBJECT's KEY when it satisfies PREDICATE, DEFAULT when absent or
null; anything else signals LLM-PARSE-ERROR naming KEY."
  (let ((value (and (hash-table-p object) (gethash key object))))
    (cond ((null value) default)
          ((funcall predicate value) value)
          (t (%bad-json "~s must be ~a, not ~s" key what value)))))

(defun %array-p (v) (and (vectorp v) (not (stringp v))))
(defun %count-p (v) (and (integerp v) (>= v 0)))

(defun %json->part (object)
  (unless (hash-table-p object) (%bad-json "a message part must be an object"))
  (let ((type (json:jget object "type")))
    (cond ((equal type "text")
           (make-text-part (%typed object "text" #'stringp "a string" "")))
          ((equal type "tool-use")
           (make-tool-use-part (%typed object "id" #'stringp "a string")
                               (%typed object "name" #'stringp "a string")
                               (%typed object "arguments" #'hash-table-p
                                       "an object"
                                       (make-hash-table :test #'equal))))
          ((equal type "tool-result")
           (make-tool-result-part
            (%typed object "tool-use-id" #'stringp "a string")
            (%typed object "content" #'stringp "a string" "")
            :errorp (json:jget object "error")))
          (t (%bad-json "unknown message part type ~s" type)))))

(defun %json->message (object)
  (unless (hash-table-p object) (%bad-json "a message must be an object"))
  (let ((role (json:jget object "role")))
    (make-message (cond ((equal role "user") :user)
                        ((equal role "assistant") :assistant)
                        (t (%bad-json "unknown message role ~s" role)))
                  (map 'list #'%json->part
                       (%typed object "content" #'%array-p "an array"
                               #())))))

(defun %json->parameters (object)
  ;; A string :STOP stays a string: it is a vector too.
  (loop for (name . key) in +parameter-keys+
        for value = (and (hash-table-p object) (json:jget object name))
        when value
          append (list key (if (%array-p value)
                               (coerce value 'list)
                               value))))

(defun stored-conversation-from-json (string)
  "The STORED-CONVERSATION STRING encodes.  Unknown keys are ignored and
missing optional ones default; a non-canonical id, or a malformed
message, signals LLM-PARSE-ERROR."
  (let* ((object (handler-case (json:parse string)
                   (error (e) (%bad-json "not JSON: ~a" e))))
         (id (and (hash-table-p object) (json:jget object "id"))))
    (unless (%canonical-id-p id)
      (%bad-json "stored conversation id ~s is not [a-z0-9-]+" id))
    (flet ((str (key) (%typed object key #'stringp "a string or null"))
           (count* (key) (%typed object key #'%count-p "a count" 0)))
      (let ((turns (coerce (%typed object "turns" #'%array-p "an array" #())
                           'list)))
        (unless (every #'hash-table-p turns)
          (%bad-json "every turn annotation must be an object"))
        (make-instance
         'stored-conversation
         :id id :owner (str "owner") :title (str "title")
         :created (count* "created") :updated (count* "updated")
         :current-p (and (gethash "current" object) t)
         :summary (str "summary") :summarized (count* "summarized")
         :turns turns
         :conversation (make-conversation
                        :system (str "system") :model (str "model")
                        :parameters (%json->parameters
                                     (%typed object "parameters"
                                             #'hash-table-p "an object"))
                        :messages (map 'list #'%json->message
                                       (%typed object "messages" #'%array-p
                                               "an array" #()))))))))
