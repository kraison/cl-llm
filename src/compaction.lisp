;;;; compaction.lisp -- long histories condensed for the model (#89,
;;;; spec SS7.3).  Only what a model reads changes: the stored messages
;;;; stay verbatim.  docs/conversations.md, "Compaction".

(in-package #:cl-llm)

(defvar *chars-per-token* 4
  "Characters per token for ESTIMATE-TOKENS: a rough, model-free rule.")

(defun %part-chars (part)
  (etypecase part
    (text-part (length (part-text part)))
    (tool-use-part (+ (length (part-name part))
                      (length (json:to-json (or (part-arguments part)
                                                (json:jobject))))))
    (tool-result-part (length (princ-to-string (part-content part))))))

(defun estimate-tokens (messages)
  "An estimate of the tokens MESSAGES take: their characters divided by
*CHARS-PER-TOKEN*, rounded up."
  (ceiling (loop for m in messages
                 sum (loop for part in (message-content m)
                           sum (%part-chars part)))
           *chars-per-token*))

(defun %turn-start-p (message)
  "True for a user message of text: a turn's question.  A user message
of tool results belongs to the turn before it."
  (and (eq :user (message-role message))
       (notany (lambda (part) (typep part 'tool-result-part))
               (message-content message))))

(defun %turn-starts (messages from)
  "Indexes of the turn starts in MESSAGES at or after FROM."
  (loop for m in (nthcdr from messages)
        for i from from
        when (%turn-start-p m) collect i))

(defun %model-tokens (sc messages)
  (+ (estimate-tokens (nthcdr (stored-conversation-summarized sc) messages))
     (ceiling (length (or (stored-conversation-summary sc) ""))
              *chars-per-token*)))

(defun compact-conversation (sc &key summarize (budget 6000) (keep-recent 4)
                                     (block 4))
  "While what a model would read of SC estimates over BUDGET tokens,
fold the oldest BLOCK turns not among the last KEEP-RECENT into the
running summary: (funcall SUMMARIZE previous-summary messages) returns
the new summary.  Never splits a turn.  Returns (values SC COMPACTED-P)."
  (let ((messages (conversation-messages
                   (stored-conversation-conversation sc)))
        (compacted nil))
    (loop
      (when (<= (%model-tokens sc messages) budget) (return))
      (let* ((from (stored-conversation-summarized sc))
             (starts (%turn-starts messages from))
             (foldable (- (length starts) keep-recent)))
        (when (<= foldable 0) (return))
        (let* ((end (nth (min block foldable) (append starts
                                                     (list (length messages)))))
               (summary (funcall summarize (stored-conversation-summary sc)
                                 (subseq messages from end))))
          (unless (stringp summary)
            (error 'c:llm-parse-error
                   :payload summary
                   :message "SUMMARIZE returned something not a string"))
          (setf (stored-conversation-summary sc) summary
                (stored-conversation-summarized sc) end
                compacted t))))
    (values sc compacted)))

(defun conversation-for-model (sc &key (system nil system-p))
  "A fresh LLM:CONVERSATION of what a model reads of SC: the messages
after the summarized ones, and SYSTEM (default SC's own) followed by
the running summary.  No provider; SC is unchanged."
  (let* ((c (stored-conversation-conversation sc))
         (base (if system-p system (conversation-system c)))
         (summary (stored-conversation-summary sc)))
    (make-conversation
     :system (if summary
                 (format nil "~@[~a~%~%~]Summary of the earlier ~
                              conversation:~%~a" base summary)
                 base)
     :model (conversation-model c)
     :parameters (copy-list (conversation-parameters c))
     :messages (copy-list (nthcdr (stored-conversation-summarized sc)
                                  (conversation-messages c))))))
