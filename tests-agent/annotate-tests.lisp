;;;; tests-agent/annotate-tests.lisp -- the model pass, scripted.
;;;; Banners spec SS5, SS7.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %banner-dir ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/fixtures/banners/"))

(defun %annotates-cite (g name)
  "The cite of NAME's first ANNOTATES belief."
  (mem:claim-cite
   (first (remove "annotates"
                  (st:claims-touching g 'mem:belief :memory-note name
                                      :role :object)
                  :key #'st:claim-relation :test-not #'string=))))

(test annotation-tools-are-exactly-three
  (with-stores (w p)
    (is (equal '("recall" "retrieve" "conclude")
               (mapcar #'llm:tool-name
                       (agent:annotation-tools (list w p) :producer +p+))))))

(defun %note-name-from-prompt (text)
  "NAME from the first turn's user prompt \"note: <name>\\n...\"."
  (let ((start (+ 6 (search "note: " text))))
    (subseq text start (position #\Newline text :start start))))

(defun %retrieve-annotates-cite (result)
  "The ANNOTATES item's cite in a retrieve tool RESULT, read from what
the mock actually received back -- not a value computed on the side."
  (let* ((r (json:parse (llm:part-content result)))
         (ev (coerce (json:jget r "evidence") 'list))
         (ann (find-if (lambda (e)
                         (search "|annotates|" (or (json:jget e "cite") "")))
                       ev)))
    (json:jget ann "cite")))

(test annotate-banners-records-one-decision-per-prose-banner
  "SS7: the model is scripted to do what the prompt asks; the pass
wires the scope, the producer and the evidence.  Simplified per Task 3
controller ruling 2: the responder counts turns instead of inspecting
JSON shape -- turn 1 retrieves the note, turn 2 concludes citing what
retrieve returned (read back from the mock's own tool-result), turn 3
says done."
  (with-stores (w p)
    (mem:capture-memory-dir w (%banner-dir) :producer "capture/test")
    (let* ((name nil)
           (provider
             (llm:make-mock-provider
              :responder
              (lambda (c)
                (let ((msgs (llm:conversation-messages c)))
                  (case (length msgs)
                    (1 (let ((text (llm:part-text
                                    (first (llm:message-content
                                            (car (last msgs)))))))
                         (setf name (%note-name-from-prompt text))
                         ;; Pins the controller fix: the banner's own
                         ;; text rides the user prompt, not a tool
                         ;; result (Task 3 review, ruling 1).
                         (when (string= name "correction")
                           (is (search "OVERTURNED for on-device" text)
                               "the prompt carries the banner's text")))
                       (%tool-use "t1" "retrieve" "query" name
                                  "endpoints"
                                  (vector (format nil "memory-note:~a"
                                                  name))))
                    (3 (%tool-use
                        "t2" "conclude"
                        "subject-namespace" "memory-note"
                        "subject-key" name
                        "relation" "overturns"
                        "object-namespace" "proposition"
                        "object-key" "the old theory"
                        "rule" "read-banner" "rule-version" "mock"
                        "evidence"
                        (vector (%retrieve-annotates-cite
                                 (%last-tool-result c)))))
                    (t "done"))))))
           (results (agent:annotate-banners (list w p) (%banner-dir)
                                            :provider provider
                                            :producer "claude-code/agent"
                                            :model-name "mock")))
      ;; update, correction, stale, two -- not superseded, not plain
      (is (equal '("correction" "stale" "two" "update")
                 (sort (mapcar #'car results) #'string<)))
      (is (every #'cdr results) "every candidate got a decision")
      (let* ((id (cdr (assoc "correction" results :test #'string=)))
             (rec (mem:trace w id :scope (list w p))))
        (is (string= "claude-code/agent" (mem:decision-record-producer rec)))
        (is (string= "read-banner" (mem:decision-record-rule rec)))
        (is (string= "mock" (mem:decision-record-rule-version rec)))
        (is (string= (%annotates-cite w "correction")
                     (mem:cite-record-cite
                      (first (mem:decision-record-evidence rec)))))
        (is (eq :resolved (mem:cite-record-state
                           (first (mem:decision-record-evidence rec)))))))))

(test annotate-banners-reports-a-declined-note-as-nil
  (with-stores (w p)
    (mem:capture-memory-dir w (%banner-dir) :producer "capture/test")
    (let* ((provider (llm:make-mock-provider
                      :responder (lambda (c) (declare (ignore c)) "no")))
           (results (agent:annotate-banners (list w p) (%banner-dir)
                                            :provider provider
                                            :producer "claude-code/agent")))
      (is (= 4 (length results)))
      (is (every (lambda (r) (null (cdr r))) results))
      (is (null (st:claims-by-producer w 'mem:trace "claude-code/agent"))
          "control: nothing was written"))))
