;;;; agent/annotate.lisp -- the tool surface's first consumer: a model
;;;; reads a note's prose banner and records what it overturns.
;;;; Banners spec SS5.

(in-package #:cl-llm.agent)

(defparameter +annotation-tool-names+ '("recall" "retrieve" "conclude"))

(defun annotation-tools (stores &key producer)
  "The three tools ANNOTATE-BANNERS offers, over STORES as PRODUCER."
  (let ((all (make-agent-tools stores :producer producer)))
    (mapcar (lambda (name)
              (find name all :key #'llm:tool-name :test #'string=))
            +annotation-tool-names+)))

(defparameter *annotation-instructions*
  "You are annotating one banner of one note in an agent's memory. The
banner's own text is below, in this prompt, under the note line --
read it there, not through a tool. Call retrieve with query the
note's name and endpoints [\"memory-note:<name>\"] only: the evidence
item whose text begins with banner:<name>#<n> is this banner's own
belief, and its cite is what you cite. Then call conclude once:
subject-namespace memory-note, subject-key <name>, relation
overturns, object-namespace proposition, object-key one sentence
stating what the banner overturns, standing inferred, rule
read-banner, rule-version <model>, evidence [that cite]. Then reply
done. If the banner overturns nothing you can state, reply no."
  "The system prompt; <name>, <n> and <model> are filled per banner
call, and the banner text itself rides the user turn, not this prompt
-- retrieve's claim renderer emits a one-line summary, not banner
prose (SS5).  One ASK per banner, not per note, so <n> disambiguates a
note with more than one prose banner (finding 1, #14 unit 3 final
review).")

(defun %prose-banner-p (banner)
  (member (mem:banner-kind banner) '(:update :correction :stale)))

(defun %candidate-notes (dir)
  "(name . banners) for every note in DIR with a prose-target banner."
  (loop for path in (uiop:directory-files dir "*.md")
        for name = (pathname-name path)
        unless (string= "MEMORY" name)
          append (multiple-value-bind (fm body) (mem:read-frontmatter path)
                   (let ((bs (remove-if-not #'%prose-banner-p
                                            (mem:scan-banners body))))
                     (and bs (list (cons (or (getf fm :name) name) bs)))))))

(defun %newest-decision-by (graph cite producer scope since)
  "The newest decision citing CITE that PRODUCER made at or after SINCE."
  (loop for id in (mem:decisions-citing graph cite :scope scope)
        for rec = (mem:trace graph id :scope scope)
        when (and (string= producer (mem:decision-record-producer rec))
                  (not (local-time:timestamp< (mem:decision-record-at rec)
                                              since)))
          return id))

(defun %banner-date-string (banner)
  "BANNER's own date, RFC 3339, or \"undated\" (controller fix, Task 3
review): the prompt must carry a date even when the banner has none."
  (let ((d (mem:banner-date banner)))
    (if d
        (local-time:format-rfc3339-timestring nil d
                                              :timezone local-time:+utc-zone+)
        "undated")))

(defun %banner-block (name banner)
  "One BANNER verbatim, for the user prompt: its identity
banner:<name>#<n>, kind, date, then its text -- the identity literally
echoes the ANNOTATES claim's subject key, so the model can match it
against retrieve's rendered text (finding 1, #14 unit 3 final
review)."
  (format nil "banner banner:~a#~a (~a, ~a):~%~a"
          name (mem:banner-position banner)
          (string-downcase (symbol-name (mem:banner-kind banner)))
          (%banner-date-string banner)
          (mem:banner-text banner)))

(defun %annotate-prompt (name banner)
  "The user turn: NAME, then BANNER's own identity, kind, date and text
verbatim, so the model reads the banner's own words here rather than
through retrieve, whose claim renderer cannot supply them (controller
fix, Task 3 review; one BANNER per ASK, finding 1, #14 unit 3 final
review)."
  (format nil "note: ~a~%~%~a~%~%Annotate this banner."
          name (%banner-block name banner)))

(defun %candidate-banners (dir)
  "(name . banner) pairs, one per prose-target banner in DIR, name
order then position -- one ASK per banner, not per note, so a note
with two prose banners cites each unambiguously (finding 1, #14 unit 3
final review)."
  (loop for (name . banners) in (sort (%candidate-notes dir)
                                      #'string< :key #'car)
        append (mapcar (lambda (b) (cons name b)) banners)))

(defun %banner-annotates-cite (graph name position)
  "The cite of the ANNOTATES belief whose subject is the banner
\"<name>#<position>\" (banners spec SS4), or NIL when capture wrote no
such banner (finding 1, #14 unit 3 final review).  Current only -- a
corrected banner leaves a retracted claim at the same key."
  (let* ((key (format nil "~a#~a" name position))
         (ann (find-if
               (lambda (c) (and (string= "annotates" (st:claim-relation c))
                                (string= key (st:claim-subject-key c))))
               (st:claims-touching graph 'mem:belief :memory-note name
                                   :role :object :current t))))
    (and ann (mem:claim-cite ann))))

(defun annotate-banners (stores dir &key provider producer
                                         (max-tool-turns 4)
                                         (model-name "unknown"))
  "One ASK per prose-target BANNER in DIR, over STORES (the first is
the write store) as PRODUCER, with three tools; the model's reading
lands as a decision citing that one banner (SS5).  One banner per ASK,
not per note, so a note with two prose banners cites each
unambiguously (finding 1, #14 unit 3 final review).  Returns ((name .
position) . decision-id-or-NIL) per candidate banner, name then
position order; NIL is a declined annotation, not an error."
  (let ((write (first stores))
        (tools (annotation-tools stores :producer producer)))
    (loop for (name . banner) in (%candidate-banners dir)
          for position = (mem:banner-position banner)
          collect
          (let* ((since (local-time:now))
                 (system (format nil "~a~%~%note: ~a~%banner: ~a~%model: ~a"
                                 *annotation-instructions* name position
                                 model-name))
                 (cite (%banner-annotates-cite write name position)))
            (llm:ask (%annotate-prompt name banner)
                     :provider provider :system system :tools tools
                     :max-tool-turns max-tool-turns)
            (cons (cons name position)
                  (and cite
                       (%newest-decision-by write cite producer
                                            stores since)))))))
