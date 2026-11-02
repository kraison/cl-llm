;;;; harness/persona.lisp -- personas as data (spec SS6.2).
;;;; A persona names a provider and a key FILE, never a key; a persona
;;;; file is read, never evaluated.  docs/agent-harness.md

(in-package #:cl-llm.harness)

(define-condition persona-error (error)
  ((message :initarg :message :reader persona-error-message))
  (:report (lambda (c s) (write-string (persona-error-message c) s)))
  (:documentation "A persona, or the file or key it names, is unusable."))

(defun %persona-error (control &rest args)
  (error 'persona-error :message (apply #'format nil control args)))

(defun canonical-name-p (string &optional (extra ""))
  "True when STRING is non-empty and every char is [a-z0-9-] or in EXTRA."
  (and (stringp string)
       (plusp (length string))
       (every (lambda (ch)
                (or (char<= #\a ch #\z) (char<= #\0 ch #\9)
                    (char= ch #\-) (find ch extra)))
              string)))

(defclass persona ()
  ((name :initarg :name :reader persona-name)
   (system :initarg :system :reader persona-system)
   (tools :initarg :tools :reader persona-tools)
   (provider :initarg :provider :reader persona-provider)
   (parameters :initarg :parameters :reader persona-parameters)
   (max-turns :initarg :max-turns :reader persona-max-turns)
   (max-run-tokens :initarg :max-run-tokens :reader persona-max-run-tokens)
   (max-seconds :initarg :max-seconds :reader persona-max-seconds)
   (max-concurrent :initarg :max-concurrent :reader persona-max-concurrent)
   (max-queued :initarg :max-queued :reader persona-max-queued)
   (daily-token-budget :initarg :daily-token-budget
                       :reader persona-daily-token-budget)
   (daily-run-budget :initarg :daily-run-budget
                     :reader persona-daily-run-budget))
  (:documentation "What a run is: prompt, tools, provider and budgets."))

(defmethod print-object ((p persona) stream)
  (print-unreadable-object (p stream :type t)
    (write-string (persona-name p) stream)))

;;; Validation

(defparameter +parameter-keys+ '(:temperature :max-tokens :top-p :stop))
(defparameter +provider-keys+ '(:kind :base-url :model :api-key-file))
(defparameter +budget-keys+
  '(:max-turns :max-run-tokens :max-seconds :max-concurrent :max-queued
    :daily-token-budget :daily-run-budget))

(defun %check-plist (plist allowed what)
  (unless (and (listp plist) (evenp (length plist)))
    (%persona-error "~a must be a property list, not ~s" what plist))
  (loop for key in plist by #'cddr
        unless (member key allowed)
          do (%persona-error "unknown key ~s in ~a" key what)))

(defun %check-provider (provider)
  (unless (typep provider 'llm:provider)
    (%check-plist provider +provider-keys+ "the provider")
    (destructuring-bind (&key kind base-url model api-key-file) provider
      (unless (member kind '(:openai-compatible :anthropic))
        (%persona-error "provider :kind must be :openai-compatible or ~
                         :anthropic, not ~s" kind))
      (when (and (eq kind :openai-compatible) (not (stringp base-url)))
        (%persona-error "an :openai-compatible provider needs :base-url"))
      (unless (or (null model) (stringp model))
        (%persona-error "provider :model must be a string"))
      (unless (or (null api-key-file) (stringp api-key-file))
        (%persona-error "provider :api-key-file must be a string path")))))

(defun %check-count (value what &key (minimum 1) optional)
  (unless (or (and optional (null value))
              (and (integerp value) (>= value minimum)))
    (%persona-error "~a must be an integer >= ~d~:[~; or NIL~], not ~s"
                    what minimum optional value)))

(defun make-persona (&key name system tools provider parameters
                          (max-turns llm:*max-tool-turns*) max-run-tokens
                          max-seconds (max-concurrent 1) (max-queued 0)
                          daily-token-budget daily-run-budget)
  "A validated PERSONA.  PROVIDER is an LLM:PROVIDER or a description
plist (:kind :openai-compatible|:anthropic :base-url :model
:api-key-file).  TOOLS are tool-name strings or LLM:TOOL objects."
  (unless (canonical-name-p name)
    (%persona-error "persona name must be [a-z0-9-]+, not ~s" name))
  (unless (or (null system) (stringp system))
    (%persona-error "persona :system must be a string"))
  (unless (and (listp tools)
               (every (lambda (tool) (or (stringp tool)
                                         (typep tool 'llm:tool)))
                      tools))
    (%persona-error "persona :tools must be tool names or tools"))
  (unless provider (%persona-error "persona ~a has no provider" name))
  (%check-provider provider)
  (%check-plist parameters +parameter-keys+ "the parameters")
  (%check-count max-turns ":max-turns")
  (%check-count max-run-tokens ":max-run-tokens" :optional t)
  (unless (or (null max-seconds)
              (and (realp max-seconds) (plusp max-seconds)))
    (%persona-error ":max-seconds must be a positive number or NIL"))
  (%check-count max-concurrent ":max-concurrent")
  (%check-count max-queued ":max-queued" :minimum 0)
  (%check-count daily-token-budget ":daily-token-budget" :optional t)
  (%check-count daily-run-budget ":daily-run-budget" :optional t)
  (make-instance 'persona
                 :name name :system system :tools tools :provider provider
                 :parameters parameters :max-turns max-turns
                 :max-run-tokens max-run-tokens :max-seconds max-seconds
                 :max-concurrent max-concurrent :max-queued max-queued
                 :daily-token-budget daily-token-budget
                 :daily-run-budget daily-run-budget))

;;; Providers

(defun %expand-home (path)
  (if (and (>= (length path) 2) (string= "~/" path :end2 2))
      (namestring (merge-pathnames (subseq path 2) (user-homedir-pathname)))
      path))

(defun %read-key-file (path)
  "The trimmed first line of PATH.  The error names PATH, never contents."
  (let ((line (handler-case (uiop:read-file-line (%expand-home path))
                (error ()
                  (%persona-error "cannot read API key file ~a" path)))))
    (let ((key (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
      (when (string= key "")
        (%persona-error "API key file ~a is empty" path))
      key)))

(defun persona-make-provider (persona)
  "PERSONA's provider: the object it holds, or one built from its
description, reading the key file now (so a rotated key is used)."
  (let ((provider (persona-provider persona)))
    (if (typep provider 'llm:provider)
        provider
        (destructuring-bind (&key kind base-url model api-key-file)
            provider
          (let ((key (and api-key-file (%read-key-file api-key-file))))
            (ecase kind
              (:openai-compatible
               (make-instance 'llm:openai-compatible-provider
                              :base-url base-url :model model :api-key key))
              (:anthropic
               (make-instance 'llm:anthropic-provider
                              :model model :api-key key))))))))

;;; Files

(defparameter +file-keys+
  '(:name :system :tools :provider :parameters :budgets))

(defun %read-persona-form (pathname)
  "The one form in PATHNAME, read with *READ-EVAL* off into KEYWORD."
  (handler-case
      (with-open-file (s pathname :external-format :utf-8)
        (with-standard-io-syntax
          (let ((*read-eval* nil)
                (*package* (find-package :keyword))
                (eof (list nil)))
            (let ((form (read s)))
              (unless (eq eof (read s nil eof))
                (%persona-error "~a holds more than one form" pathname))
              form))))
    (persona-error (e) (error e))
    (error (e)
      (%persona-error "cannot read persona file ~a: ~a" pathname e))))

(defun load-persona-file (pathname)
  "The PERSONA in PATHNAME: one plist of :name :system :tools :provider
:parameters and :budgets (MAKE-PERSONA's budget keywords).  Never
evaluates the file."
  (let ((form (%read-persona-form pathname)))
    (%check-plist form +file-keys+ (format nil "persona file ~a" pathname))
    (destructuring-bind (&key name system tools provider parameters budgets)
        form
      (%check-plist budgets +budget-keys+ ":budgets")
      (apply #'make-persona :name name :system system :tools tools
                            :provider provider :parameters parameters
                            budgets))))

;;; Lookup

(defgeneric find-persona (source name)
  (:documentation "The PERSONA named NAME in SOURCE, or NIL."))

(defclass persona-directory ()
  ((directory :initarg :directory :reader persona-directory-pathname))
  (:documentation "Personas as <name>.persona files in one directory."))

(defun make-persona-directory (pathname)
  (make-instance 'persona-directory
                 :directory (uiop:ensure-directory-pathname pathname)))

(defmethod find-persona ((source persona-directory) name)
  ;; Canonical first: NAME may come from outside, and "../x" is a path.
  (unless (canonical-name-p name)
    (%persona-error "persona name must be [a-z0-9-]+, not ~s" name))
  (let ((path (merge-pathnames (make-pathname :name name :type "persona")
                               (persona-directory-pathname source))))
    (when (probe-file path)
      (let ((persona (load-persona-file path)))
        (unless (string= name (persona-name persona))
          (%persona-error "~a names persona ~s" path (persona-name persona)))
        persona))))
