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
  "You are annotating one note of an agent's memory. The banner's own
text is below, in this prompt, under the note line -- read it there,
not through a tool. Call retrieve with query the note's name and
endpoints [\"memory-note:<name>\"] only to get its evidence cite: the
item whose cite contains |annotates| is the banner's belief, and its
cite is what you cite. Then call conclude once: subject-namespace
memory-note, subject-key <name>, relation overturns, object-namespace
proposition, object-key one sentence stating what the banner
overturns, standing inferred, rule read-banner, rule-version <model>,
evidence [that cite]. Then reply done. If the banner overturns
nothing you can state, reply no."
  "The system prompt; <name> and <model> are filled per note, and the
banner text itself rides the user turn, not this prompt -- retrieve's
claim renderer emits a one-line summary, not banner prose (SS5).")

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

(defun %banner-block (banner)
  "One BANNER verbatim, for the user prompt: its position, kind, date,
then its text (controller fix, Task 3 review)."
  (format nil "banner ~a (~a, ~a):~%~a"
          (mem:banner-position banner)
          (string-downcase (symbol-name (mem:banner-kind banner)))
          (%banner-date-string banner)
          (mem:banner-text banner)))

(defun %annotate-prompt (name banners)
  "The user turn: NAME, then each of NAME's prose BANNERS verbatim, so
the model reads the banner's own words here rather than through
retrieve, whose claim renderer cannot supply them (controller fix,
Task 3 review)."
  (format nil "note: ~a~%~%~{~a~^~%~%~}~%~%Annotate this note."
          name (mapcar #'%banner-block banners)))

(defun %note-annotates-cite (write name)
  "The cite of NAME's first ANNOTATES belief (as CLAIMS-TOUCHING
returns it, retracted or not -- matching the test's own
%ANNOTATES-CITE), or NIL when the note was captured with no banners
(banners spec SS4)."
  (let ((ann (find "annotates"
                   (st:claims-touching write 'mem:belief :memory-note name
                                       :role :object)
                   :key #'st:claim-relation :test #'string=)))
    (and ann (mem:claim-cite ann))))

(defun annotate-banners (stores dir &key provider producer
                                         (max-tool-turns 4)
                                         (model-name "unknown"))
  "One ASK per note in DIR with a prose-target banner, over STORES (the
first is the write store) as PRODUCER, with three tools; the model's
reading lands as a decision citing the banner (SS5).  Returns (name .
decision-id-or-NIL) per candidate, name order; NIL is a declined
annotation, not an error."
  (let ((write (first stores))
        (tools (annotation-tools stores :producer producer)))
    (loop for (name . banners) in (sort (%candidate-notes dir)
                                        #'string< :key #'car)
          collect
          (let* ((since (local-time:now))
                 (system (format nil "~a~%~%note: ~a~%model: ~a"
                                 *annotation-instructions* name model-name))
                 (cite (%note-annotates-cite write name)))
            (llm:ask (%annotate-prompt name banners)
                     :provider provider :system system :tools tools
                     :max-tool-turns max-tool-turns)
            (cons name (and cite
                            (%newest-decision-by write cite producer
                                                 stores since)))))))
