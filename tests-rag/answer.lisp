;;;; tests-rag/answer.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(defun index-with (texts)
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder))))
    (rag:add-documents index
                       (loop for text in texts for i from 0
                             collect (rag:make-document text :id (format nil "d~a" i)
                                                        :metadata (list :title (format nil "T~a" i)))))
    index))

(test assemble-context-is-numbered-and-cited
  (let* ((index (index-with '("the TM-62 has a pressure fuze")))
         (hits (rag:retrieve index "TM-62 fuze" :k 1))
         (context (rag:assemble-context hits)))
    (is (search "[1]" context) "sources are numbered")
    (is (search "TM-62" context) "the chunk text appears")
    (is (search "T0" context) "the source title appears")))

(test rag-ask-returns-answer-and-hits
  (let ((llm:*provider*
          (llm:make-mock-provider
           :responder (lambda (conversation)
                        (declare (ignore conversation))
                        "The TM-62 uses a pressure fuze [1]."))))
    (let ((index (index-with '("the TM-62 has a pressure fuze"))))
      (multiple-value-bind (answer hits) (rag:rag-ask index "What fuze does the TM-62 use?")
        (is (search "pressure fuze" answer))
        (is (= 1 (length hits)))
        (is (search "TM-62" (rag:chunk-text (rag:hit-chunk (first hits)))))))))

(test rag-ask-prompt-instructs-grounding-and-carries-context
  "The request the model receives must contain the grounding rules and the sources."
  (let* ((seen nil)
         (llm:*provider*
           (llm:make-mock-provider
            :responder (lambda (conversation) (setf seen conversation) "ok")))
         (index (index-with '("the PFM-1 is a scatterable mine"))))
    (rag:rag-ask index "Tell me about the PFM-1")
    (let ((sent (with-output-to-string (s)
                  (dolist (m (llm:conversation-messages seen))
                    (dolist (part (llm:message-content m))
                      (write-string (llm:part-text part) s)))
                  (write-string (or (llm:conversation-system seen) "") s))))
      (is (search "only" (string-downcase sent)) "grounding instruction present")
      (is (search "PFM-1" sent) "retrieved context present"))))

(test rag-ask-composes-caller-system-with-grounding
  (let* ((seen nil)
         (llm:*provider*
           (llm:make-mock-provider
            :responder (lambda (conversation) (setf seen conversation) "ok")))
         (index (index-with '("some content"))))
    (rag:rag-ask index "q" :system "You are a terse EOD assistant.")
    (let ((system (llm:conversation-system seen)))
      (is (search "terse EOD" system) "caller system is included")
      (is (search "only" (string-downcase system)) "grounding is NOT dropped"))))

(test make-retrieval-tool-is-callable
  (let* ((index (index-with '("the TM-62 has a pressure fuze")))
         (tool (rag:make-retrieval-tool index))
         (args (make-hash-table :test 'equal)))
    (setf (gethash "query" args) "TM-62 fuze")
    (is (typep tool 'llm:tool))
    (is (search "TM-62" (llm:call-tool tool args)))))
