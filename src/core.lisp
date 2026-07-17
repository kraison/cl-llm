;;;; core.lisp -- the provider-independent object model.

(in-package #:cl-llm)

;;; Content parts
;;;
;;; Message content is ALWAYS a list of parts, never a bare string. This costs a
;;; little ceremony now and is what makes images a later addition rather than a
;;; rewrite.

(defclass content-part ()
  ()
  (:documentation "Abstract base for one piece of message content."))

(defclass text-part (content-part)
  ((text :initarg :text :accessor part-text :type string))
  (:documentation "Plain text content."))

(defclass tool-use-part (content-part)
  ((id :initarg :id :accessor part-id)
   (name :initarg :name :accessor part-name)
   (arguments :initarg :arguments :initform nil :accessor part-arguments))
  (:documentation "A model request to call a tool. ARGUMENTS is a hash-table of
decoded JSON arguments, keyed by string."))

(defclass tool-result-part (content-part)
  ((tool-use-id :initarg :tool-use-id :accessor part-tool-use-id)
   (content :initarg :content :accessor part-content)
   (errorp :initarg :errorp :initform nil :accessor part-error-p))
  (:documentation "The result of executing a tool, sent back to the model."))

(defun make-text-part (text)
  (make-instance 'text-part :text text))

(defun make-tool-use-part (id name arguments)
  (make-instance 'tool-use-part :id id :name name :arguments arguments))

(defun make-tool-result-part (tool-use-id content &key errorp)
  (make-instance 'tool-result-part :tool-use-id tool-use-id
                                   :content content :errorp errorp))

;;; Messages

(defclass message ()
  ((role :initarg :role :accessor message-role :type keyword
         :documentation "One of :USER or :ASSISTANT.")
   (content :initarg :content :accessor message-content :type list
            :documentation "A list of CONTENT-PART."))
  (:documentation "One turn in a conversation."))

(defun coerce-content (content)
  "Normalize CONTENT to a list of parts. A string becomes a single text part."
  (etypecase content
    (string (list (make-text-part content)))
    (content-part (list content))
    (list content)))

(defun make-message (role content)
  "Make a message. CONTENT may be a string, one part, or a list of parts."
  (make-instance 'message :role role :content (coerce-content content)))

;;; Conversations

(defclass conversation ()
  ((messages :initarg :messages :initform '() :accessor conversation-messages
             :documentation "Messages in order, oldest first.")
   (system :initarg :system :initform nil :accessor conversation-system)
   (provider :initarg :provider :initform nil :accessor conversation-provider)
   (model :initarg :model :initform nil :accessor conversation-model)
   (parameters :initarg :parameters :initform '() :accessor conversation-parameters
               :documentation "A plist of generation parameters, e.g. (:temperature 0.2)."))
  (:documentation "A multi-turn exchange with a provider."))

(defun make-conversation (&key system provider model messages parameters)
  (make-instance 'conversation :system system :provider provider :model model
                               :messages messages :parameters parameters))

(defun add-message (conversation message)
  "Append MESSAGE to CONVERSATION and return the message."
  (setf (conversation-messages conversation)
        (append (conversation-messages conversation) (list message)))
  message)

;;; Responses

(defclass usage ()
  ((input-tokens :initarg :input-tokens :initform nil :accessor usage-input-tokens)
   (output-tokens :initarg :output-tokens :initform nil :accessor usage-output-tokens))
  (:documentation "Token accounting for one response."))

(defclass response ()
  ((content :initarg :content :initform '() :accessor response-content
            :documentation "A list of CONTENT-PART.")
   (stop-reason :initarg :stop-reason :initform nil :accessor response-stop-reason
                :documentation "One of :END-TURN, :TOOL-USE, :MAX-TOKENS, :STOP, or NIL.")
   (model :initarg :model :initform nil :accessor response-model)
   (usage :initarg :usage :initform nil :accessor response-usage)
   (raw :initarg :raw :initform nil :accessor response-raw
        :documentation "The decoded provider payload, for escape hatches."))
  (:documentation "One assistant reply."))

(defun response-text (response)
  "Concatenate every text part of RESPONSE. Non-text parts are ignored."
  (with-output-to-string (out)
    (dolist (part (response-content response))
      (when (typep part 'text-part)
        (write-string (part-text part) out)))))

(defun response-tool-calls (response)
  "The TOOL-USE-PARTs of RESPONSE, in order."
  (remove-if-not (lambda (part) (typep part 'tool-use-part))
                 (response-content response)))

(defun response-message (response)
  "RESPONSE as an assistant MESSAGE, for appending to a conversation."
  (make-instance 'message :role :assistant :content (response-content response)))
