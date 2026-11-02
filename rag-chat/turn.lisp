;;;; rag-chat/turn.lisp -- one conversational RAG turn: rewrite,
;;;; retrieve, answer, each model call a harness run (spec SS8.2).
;;;; Under :QUESTIONS the answer model sees earlier questions only --
;;;; never an earlier answer, nor the summary that condenses them.
;;;; docs/conversations.md, "The conversational turn".

(in-package #:cl-llm.rag.chat)

(defparameter *rewrite-instructions*
  "Rewrite the user's last question as one standalone search query. Use
the conversation so far to resolve pronouns and references, and name the
subject explicitly. Reply with the query only: no preamble, no quotes,
no answer."
  "The rewrite persona's system prompt, unless the caller gives one.")

(defparameter *summary-instructions*
  "Summarise the conversation below for whoever continues it: the
subjects asked about, what was established, and any question left open.
Under 200 words. Reply with the summary only."
  "The compaction persona's system prompt, unless the caller gives one.")

(defclass rag-chat ()
  ((answer-persona :initarg :answer-persona :reader chat-answer-persona)
   (rewrite-persona :initarg :rewrite-persona :reader chat-rewrite-persona)
   (compaction-persona :initarg :compaction-persona
                       :reader chat-compaction-persona)
   (retrieve :initarg :retrieve :reader chat-retrieve)
   (k :initarg :k :reader chat-k)
   (assemble :initarg :assemble :reader chat-assemble)
   (history :initarg :history :reader chat-history)
   (carry-forward :initarg :carry-forward :reader chat-carry-forward)
   (carry-filter :initarg :carry-filter :reader chat-carry-filter)
   (history-budget :initarg :history-budget :reader chat-history-budget)
   (keep-recent :initarg :keep-recent :reader chat-keep-recent))
  (:documentation "How a conversational turn is run: its three personas,
its retrieval, and what the answer model sees of history."))

(defun %persona-like (base &key (name (harness:persona-name base))
                                (system (harness:persona-system base))
                                (tools (harness:persona-tools base)))
  "A persona like BASE -- provider, parameters, budgets -- with NAME,
SYSTEM and TOOLS replaced.  The same name shares BASE's limits."
  (harness:make-persona
   :name name :system system :tools tools
   :provider (harness:persona-provider base)
   :parameters (harness:persona-parameters base)
   :max-turns (harness:persona-max-turns base)
   :max-run-tokens (harness:persona-max-run-tokens base)
   :max-seconds (harness:persona-max-seconds base)
   :max-concurrent (harness:persona-max-concurrent base)
   :max-queued (harness:persona-max-queued base)
   :daily-token-budget (harness:persona-daily-token-budget base)
   :daily-run-budget (harness:persona-daily-run-budget base)))

(defun %derived (base suffix system)
  (%persona-like base :name (format nil "~a-~a" (harness:persona-name base)
                                    suffix)
                      :system system :tools '()))

(defun make-rag-chat (&key answer-persona retrieve (k 5)
                           (assemble #'rag:assemble-context)
                           rewrite-persona compaction-persona
                           (history :questions) carry-forward carry-filter
                           (history-budget 6000) (keep-recent 4))
  "A RAG-CHAT.  RETRIEVE is a function of (query k) returning RAG:HITs;
ASSEMBLE turns hits into the numbered context.  The rewrite and
compaction personas default to the answer persona's provider and
budgets.  HISTORY is :QUESTIONS (the default) or :TURNS."
  (check-type answer-persona harness:persona)
  (check-type retrieve function)
  (check-type history (member :questions :turns))
  (make-instance
   'rag-chat
   :answer-persona answer-persona :retrieve retrieve :k k
   :assemble assemble :history history
   :rewrite-persona (or rewrite-persona
                        (%derived answer-persona "rewrite"
                                  *rewrite-instructions*))
   :compaction-persona (or compaction-persona
                           (%derived answer-persona "compact"
                                     *summary-instructions*))
   :carry-forward carry-forward
   :carry-filter (or carry-filter (constantly '()))
   :history-budget history-budget :keep-recent keep-recent))

(defclass rag-turn ()
  ((answer :initform nil :accessor rag-turn-answer)
   (hits :initform '() :accessor rag-turn-hits)
   (standalone :initform nil :accessor rag-turn-standalone)
   (stop-reason :initform nil :accessor rag-turn-stop-reason
                :documentation ":END-TURN on success, else the failing
run's stop reason, or :ERROR.")
   (error :initform nil :accessor rag-turn-error)
   (runs :initform (list :rewrite nil :answer nil :compaction nil)
         :accessor rag-turn-runs
         :documentation "The harness runs made, by step."))
  (:documentation "What one RAG-CHAT-TURN did."))

;;; History, as each model sees it

(defun %text (message)
  (format nil "~{~a~}" (loop for part in (llm:message-content message)
                             when (typep part 'llm:text-part)
                               collect (llm:part-text part))))

(defun %question-p (message)
  (and (eq :user (llm:message-role message))
       (every (lambda (part) (typep part 'llm:text-part))
              (llm:message-content message))))

(defun %questions (sc)
  "SC's earlier questions as (as-asked . standalone-or-NIL), oldest
first; the I-th question pairs with the I-th turn annotation."
  (let ((annotations (llm:stored-conversation-turns sc)))
    (loop for m in (llm:conversation-messages
                    (llm:stored-conversation-conversation sc))
          when (%question-p m)
            collect (let ((ann (pop annotations)))
                      (cons (%text m)
                            (and (hash-table-p ann)
                                 (gethash "standalone" ann)))))))

(defun %history-text (sc)
  "What the rewrite model reads: the summary, then the unsummarized
turns, questions and answers, as text."
  (let ((c (llm:conversation-for-model sc :system nil)))
    (with-output-to-string (out)
      (when (llm:conversation-system c)
        (format out "~a~%~%" (llm:conversation-system c)))
      (dolist (m (llm:conversation-messages c))
        (let ((text (%text m)))
          (when (plusp (length text))
            (format out "~:[Assistant~;User~]: ~a~%"
                    (eq :user (llm:message-role m)) text)))))))

(defun %answer-input (chat sc question standalone context)
  (with-output-to-string (out)
    (when (eq :questions (chat-history chat))
      (let ((earlier (%questions sc)))
        (when earlier
          (format out "EARLIER QUESTIONS IN THIS CONVERSATION:~%")
          (loop for (asked . searched) in earlier
                for i from 1
                do (format out "~d. ~a~@[ (searched as: ~a)~]~%" i asked
                           (and searched (string/= searched asked)
                                searched)))
          (terpri out))))
    (format out "SOURCES:~%~a~%QUESTION: ~a~%" context question)
    (unless (string= standalone question)
      (format out "STANDALONE: ~a~%" standalone))))

(defun %grounded (persona)
  "PERSONA with its system prompt composed WITH the grounding
instructions, never replaced by them (rag-ask's rule)."
  (%persona-like persona
                 :system (format nil "~@[~a~%~%~]~a"
                                 (harness:persona-system persona)
                                 rag:*grounding-instructions*)))

(defun %clean-query (text)
  "The rewrite's first line, trimmed of whitespace and quotes."
  (let* ((text (or text ""))
         (line (subseq text 0 (or (position #\Newline
                                            (string-left-trim
                                             '(#\Space #\Newline #\Tab) text))
                                  (length text)))))
    (string-trim '(#\Space #\Tab #\Newline #\Return #\" #\')
                 (string-left-trim '(#\Space #\Newline #\Tab)
                                   (if (string= line "") text line)))))

;;; Recording

(defun %annotation (standalone hits run)
  (let ((ann (make-hash-table :test #'equal)))
    (setf (gethash "standalone" ann) standalone
          (gethash "sources" ann)
          (map 'vector (lambda (hit)
                         (let ((c (rag:hit-chunk hit)))
                           (json:jobject
                            "document-id" (rag:chunk-document-id c)
                            "title" (getf (rag:chunk-metadata c) :title))))
               hits)
          (gethash "run" ann)
          (json:jobject "id" (harness:run-id run)
                        "stop" (string-downcase
                                (symbol-name (harness:run-stop-reason run)))
                        "input-tokens" (harness:run-input-tokens run)
                        "output-tokens" (harness:run-output-tokens run)))
    ann))

(defun %snapshot (sc)
  (list (llm:conversation-messages (llm:stored-conversation-conversation sc))
        (llm:stored-conversation-turns sc)
        (llm:stored-conversation-summary sc)
        (llm:stored-conversation-summarized sc)
        (llm:stored-conversation-updated sc)))

(defun %restore (sc snapshot)
  (destructuring-bind (messages turns summary summarized updated) snapshot
    (setf (llm:conversation-messages (llm:stored-conversation-conversation sc))
          messages
          (llm:stored-conversation-turns sc) turns
          (llm:stored-conversation-summary sc) summary
          (llm:stored-conversation-summarized sc) summarized
          (llm:stored-conversation-updated sc) updated)))

(defun %ok-p (run)
  (member (harness:run-stop-reason run) '(:end-turn :stop)))

;;; The turn

(defun rag-chat-turn (chat sc question &key store)
  "Run one turn of CHAT on the stored conversation SC: rewrite QUESTION
into a standalone one when SC has earlier turns, retrieve with it, and
answer.  On success the turn is recorded on SC, and saved to STORE when
given; otherwise SC is left as it was.  Returns a RAG-TURN; never
signals."
  (let ((turn (make-instance 'rag-turn))
        (snapshot (%snapshot sc)))
    (block run
      (flet ((fail (stop &optional error)
               (%restore sc snapshot)
               (setf (rag-turn-stop-reason turn) (or stop :error)
                     (rag-turn-error turn) error)
               (return-from run))
             (note (step run)
               (setf (getf (rag-turn-runs turn) step) run)
               run))
        (let ((standalone question))
          (when (%questions sc)
            (let ((r (note :rewrite
                           (harness:run-persona
                            (chat-rewrite-persona chat)
                            (format nil "~a~%Question: ~a"
                                    (%history-text sc) question)))))
              (unless (%ok-p r)
                (fail (harness:run-stop-reason r) (harness:run-error r)))
              (setf standalone (%clean-query (harness:run-text r)))
              (when (string= standalone "")
                (fail :error "the rewrite model returned no query"))))
          (setf (rag-turn-standalone turn) standalone)
          (let ((hits (handler-case
                          (funcall (chat-retrieve chat) standalone
                                   (chat-k chat))
                        (error (e) (fail :error e)))))
            (setf (rag-turn-hits turn) hits)
            (let ((r (note :answer
                           (harness:run-persona
                            (%grounded (chat-answer-persona chat))
                            (%answer-input chat sc question standalone
                                           (funcall (chat-assemble chat)
                                                    hits))))))
              (unless (%ok-p r)
                (fail (harness:run-stop-reason r) (harness:run-error r)))
              (setf (rag-turn-answer turn) (harness:run-text r))
              (llm:record-turn sc question (harness:run-text r)
                               (%annotation standalone hits r))
              (when store
                (handler-case (llm:save-conversation store sc)
                  (error (e) (fail :error e))))
              (setf (rag-turn-stop-reason turn) :end-turn))))))
    turn))
