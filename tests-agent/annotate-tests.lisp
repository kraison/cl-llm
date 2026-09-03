;;;; tests-agent/annotate-tests.lisp -- the model pass, scripted.
;;;; Banners spec SS5, SS7.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %banner-dir ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/fixtures/banners/"))

(defun %annotates-cite-for (g name position)
  "The cite of NAME's ANNOTATES belief whose subject is
\"<name>#<position>\", computed independently of the production code
under test (finding 1, #14 unit 3 final review)."
  (let ((key (format nil "~a#~a" name position)))
    (mem:claim-cite
     (find-if (lambda (c)
                (and (string= "annotates" (st:claim-relation c))
                     (string= key (st:claim-subject-key c))))
              (st:claims-touching g 'mem:belief :memory-note name
                                  :role :object)))))

(test annotation-tools-are-exactly-three
  (with-stores (w p)
    (is (equal '("recall" "retrieve" "conclude")
               (mapcar #'llm:tool-name
                       (agent:annotation-tools (list w p) :producer +p+))))))

(defun %note-name-from-prompt (text)
  "NAME from the first turn's user prompt \"note: <name>\\n...\"."
  (let ((start (+ 6 (search "note: " text))))
    (subseq text start (position #\Newline text :start start))))

(defun %banner-key-from-prompt (text)
  "The literal banner:<name>#<n> that %BANNER-BLOCK embeds in the user
prompt -- the mock's own way to tell which of a note's banners this
ASK concerns, matching retrieve's rendered subject endpoint (finding
1, #14 unit 3 final review)."
  (let* ((start (search "banner:" text))
         (end (position-if (lambda (c) (member c '(#\Space #\Newline)))
                           text :start start)))
    (subseq text start end)))

(defun %retrieve-annotates-cite (result key)
  "The evidence item's cite in a retrieve tool RESULT whose rendered
TEXT begins with KEY (\"banner:<name>#<n>\") followed by \" annotates\",
read from what the mock actually received back -- not a value computed
on the side.  Picking by KEY, not merely by |annotates| in the cite,
is the fix under test: a note with two prose banners returns two
ANNOTATES items and only one is this ASK's own (finding 1, #14 unit 3
final review)."
  (let* ((r (json:parse (llm:part-content result)))
         (ev (coerce (json:jget r "evidence") 'list))
         (prefix (format nil "~a annotates" key))
         (ann (find-if (lambda (e)
                         (let ((text (json:jget e "text")))
                           (and text (eql 0 (search prefix text)))))
                       ev)))
    (json:jget ann "cite")))

(test annotate-banners-records-one-decision-per-prose-banner
  "SS7: the model is scripted to do what the prompt asks; the pass
wires the scope, the producer and the evidence.  Simplified per Task 3
controller ruling 2: the responder counts turns instead of inspecting
JSON shape -- turn 1 retrieves the note, turn 2 concludes citing what
retrieve returned (read back from the mock's own tool-result), turn 3
says done.  Finding 1 (#14 unit 3 final review): TWO's two prose
banners each get their own ASK and cite their own banner, not an
arbitrary one."
  (with-stores (w p)
    (mem:capture-memory-dir w (%banner-dir) :producer "capture/test")
    (let* ((name nil) (key nil)
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
                         (setf key (%banner-key-from-prompt text))
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
                                 (%last-tool-result c) key))))
                    (t "done"))))))
           (results (agent:annotate-banners (list w p) (%banner-dir)
                                            :provider provider
                                            :producer "claude-code/agent"
                                            :model-name "mock")))
      ;; update, correction, stale, two#1, two#2 -- one ASK per prose
      ;; banner, not per note (finding 1, #14 unit 3 final review).
      (is (equal '(("correction" . 1) ("stale" . 1) ("two" . 1)
                   ("two" . 2) ("update" . 1))
                 (sort (mapcar #'car results)
                       (lambda (a b)
                         (or (string< (car a) (car b))
                             (and (string= (car a) (car b))
                                  (< (cdr a) (cdr b))))))))
      (is (every #'cdr results) "every candidate got a decision")
      (let* ((id1 (cdr (assoc (cons "two" 1) results :test #'equal)))
             (id2 (cdr (assoc (cons "two" 2) results :test #'equal)))
             (rec1 (mem:trace w id1 :scope (list w p)))
             (rec2 (mem:trace w id2 :scope (list w p)))
             (cite1 (mem:cite-record-cite
                     (first (mem:decision-record-evidence rec1))))
             (cite2 (mem:cite-record-cite
                     (first (mem:decision-record-evidence rec2)))))
        (is (string= (%annotates-cite-for w "two" 1) cite1)
            "TWO#1's decision cites TWO#1's own banner")
        (is (string= (%annotates-cite-for w "two" 2) cite2)
            "TWO#2's decision cites TWO#2's own banner")
        (is (string/= cite1 cite2)
            "the two decisions cite different banners, not an arbitrary one"))
      (let* ((id (cdr (assoc (cons "correction" 1) results :test #'equal)))
             (rec (mem:trace w id :scope (list w p))))
        (is (string= "claude-code/agent" (mem:decision-record-producer rec)))
        (is (string= "read-banner" (mem:decision-record-rule rec)))
        (is (string= "mock" (mem:decision-record-rule-version rec)))
        (is (string= (%annotates-cite-for w "correction" 1)
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
      (is (= 5 (length results))
          "correction, stale, two#1, two#2, update -- one per banner")
      (is (every (lambda (r) (null (cdr r))) results))
      (is (null (st:claims-by-producer w 'mem:trace "claude-code/agent"))
          "control: nothing was written"))))
