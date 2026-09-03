;;;; memory/capture.lisp -- the memory corpus as the dogfood tenant.
;;;; Deterministic: frontmatter + digest, no prose parsing (spec SS7).

(in-package #:cl-llm.memory)

(defun %read-file (path)
  (with-open-file (in path :external-format :utf-8)
    (let ((s (make-string (file-length in))))
      (subseq s 0 (read-sequence s in)))))

(defun %trim (s) (string-trim '(#\Space #\Tab #\Return) s))

(defun read-frontmatter (path)
  "Two values: a plist (:NAME :DESCRIPTION :TYPE :MODIFIED), each a
string or NIL, and the body after the closing fence.  Reads only the
line shapes the memory files use -- `key: value` at the top level and
under `metadata:` -- and is not a YAML parser."
  (let* ((text (%read-file path))
         (lines (uiop:split-string text :separator '(#\Newline))))
    (unless (and lines (string= "---" (%trim (first lines))))
      (return-from read-frontmatter (values nil text)))
    (let ((plist '()) (i 1))
      (loop while (and (< i (length lines))
                       (string/= "---" (%trim (nth i lines))))
            do (let* ((line (nth i lines))
                      (colon (position #\: line)))
                 (when colon
                   (let ((key (%trim (subseq line 0 colon)))
                         (val (%trim (subseq line (1+ colon)))))
                     (when (plusp (length val))
                       (cond ((string= key "name")
                              (setf (getf plist :name) val))
                             ((string= key "description")
                              (setf (getf plist :description) val))
                             ((string= key "type")
                              (setf (getf plist :type) val))
                             ((string= key "modified")
                              (setf (getf plist :modified) val)))))))
               (incf i))
      (values plist
              (format nil "~{~a~^~%~}" (nthcdr (1+ i) lines))))))

(defun body-digest (string)
  "Lowercase sha256 hex of STRING's UTF-8 octets."
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    :sha256 (babel:string-to-octets string :encoding :utf-8))))

(defun %note-modified (fm path)
  "The MODIFIED stamp, RFC3339 UTC; the file's write date when the note
carries none -- and then the capture is only as reproducible as the
filesystem."
  (or (getf fm :modified)
      (local-time:format-rfc3339-timestring
       nil (local-time:universal-to-timestamp (file-write-date path))
       :timezone local-time:+utc-zone+)))

(defun %existing-note (graph name)
  (first (gdb:index-lookup graph 'memory-note 'note-name name)))

(defparameter +iso-date-format+
  '((:year 4) #\- (:month 2) #\- (:day 2) #\T (:hour 2) #\: (:min 2)
    #\: (:sec 2) :gmt-offset-or-z)
  "RFC3339 without fractional seconds -- FORMAT-RFC3339-TIMESTRING
always emits microseconds, which a banner's midnight date has none of.")

(defun %iso-date (ts)
  (local-time:format-timestring nil ts :format +iso-date-format+
                                :timezone local-time:+utc-zone+))

(defun %banner-date-and-extent (banner modified)
  "Two values: the banner's own ISO date, or MODIFIED when undated;
and the [date, unknown) validity extent from it (banners spec SS4)."
  (let* ((dated (banner-date banner))
         (date (if dated (%iso-date dated) modified)))
    (values date
            (te:make-interval
             (te:exact-bound (local-time:parse-timestring date))
             (te:unknown-bound)
             :semantics :validity :standing :asserted))))

(defun %capture-banner (graph name banner modified producer)
  "One banner as a node and its ANNOTATES belief (banners spec SS4).
A capture reflects the file as truth: a re-dated or re-kinded banner
under the same key is a CORRECTION, via %ASSERT-FROM-FILE, not a
supersession RECORD-BELIEF's idempotent path would miss."
  (let* ((key (format nil "~a#~a" name (banner-position banner)))
         (kind (string-downcase (symbol-name (banner-kind banner))))
         (old (first (gdb:index-lookup graph 'memory-banner
                                       'bn-key key))))
    (multiple-value-bind (date extent)
        (%banner-date-and-extent banner modified)
      (if old
          (let ((c (gdb:copy old)))
            (setf (bn-note c) name
                  (bn-position c) (banner-position banner)
                  (bn-kind c) kind
                  (bn-date c) date
                  (bn-dated-p c) (and (banner-date banner) t)
                  (bn-link c) (or (banner-link banner) "")
                  (bn-text c) (banner-text banner))
            (gdb:save c))
          (make-memory-banner :graph graph
                              :bn-key key
                              :bn-note name
                              :bn-position (banner-position banner)
                              :bn-kind kind
                              :bn-date date
                              :bn-dated-p (and (banner-date banner) t)
                              :bn-link (or (banner-link banner) "")
                              :bn-text (banner-text banner)))
      (%assert-from-file graph (cons :banner key) "annotates"
                         (cons :memory-note name)
                         :producer producer :method kind :extent extent))))

(defun %last-replacing-banner (banners)
  "The SUPERSEDED/STALE banner with a link, highest position, or NIL:
two such banners on one note keep the note as SUPERSEDED-BY's subject
(a belief series is single-valued per subject and relation), so only
the last by position writes it (banners spec SS4)."
  (car (last (remove-if-not
              (lambda (b) (and (banner-link b)
                               (member (banner-kind b) '(:superseded
                                                          :stale))))
              banners))))

(defun %capture-superseded-by (graph name banner modified producer)
  "NAME's SUPERSEDED-BY belief, from its last replacing BANNER only.
Two such banners with equal or non-increasing dates would abort the
whole capture under plain RECORD-BELIEF; going through
%ASSERT-FROM-FILE makes a non-later date a correction instead."
  (multiple-value-bind (date extent)
      (%banner-date-and-extent banner modified)
    (declare (ignore date))
    (%assert-from-file graph (cons :memory-note name) "superseded-by"
                       (cons :memory-note (banner-link banner))
                       :producer producer :extent extent)))

(defun %removed-banner-p (name n-now key)
  "True when KEY (a subject key touching NAME as ANNOTATES object) is a
banner past position N-NOW -- one the current scan no longer carries
(finding 2, #14 unit 3 final review)."
  (let ((prefix (format nil "~a#" name)))
    (and (>= (length key) (length prefix))
         (string= prefix key :end2 (length prefix))
         (let ((pos (parse-integer key :start (length prefix)
                                   :junk-allowed t)))
           (and pos (> pos n-now))))))

(defun %retract-removed-banners (graph name producer n-now)
  "Retract PRODUCER's current ANNOTATES belief on every banner past
position N-NOW: the file no longer carries it, so its belief must not
be left looking current (banners spec SS4, finding 2, #14 unit 3 final
review).  Same producer filter as %CURRENT-PREDECESSOR, so another
producer's belief is never touched."
  (dolist (c (st:claims-touching graph 'belief :memory-note name
                                 :role :object))
    (when (and (typep c 'belief-binary)
               (string= "annotates" (st:claim-relation c))
               (string= producer (st:claim-producer c))
               (st:claim-current-p c)
               (%open-p c)
               (%removed-banner-p name n-now (st:claim-subject-key c)))
      (retract-belief c))))

(defun %retract-stale-superseded-by (graph name producer)
  "No replacing banner remains on NAME: retract PRODUCER's current
SUPERSEDED-BY belief on it, if any (finding 2, #14 unit 3 final
review) -- %CURRENT-PREDECESSOR's own producer filter."
  (let ((pred (%current-predecessor graph producer (cons :memory-note name)
                                    "superseded-by")))
    (when pred (retract-belief pred))))

(defun %capture-note (graph path producer banners)
  (multiple-value-bind (fm body) (read-frontmatter path)
    (let* ((name (or (getf fm :name) (pathname-name path)))
           (modified (%note-modified fm path))
           (start (local-time:parse-timestring modified))
           (old (%existing-note graph name)))
      (if old
          (let ((c (gdb:copy old)))
            (setf (note-description c) (or (getf fm :description) "")
                  (note-type c) (or (getf fm :type) "")
                  (note-modified c) modified
                  (note-body c) body)
            (gdb:save c))
          (make-memory-note :graph graph
                            :note-name name
                            :note-description
                            (or (getf fm :description) "")
                            :note-type (or (getf fm :type) "")
                            :note-modified modified
                            :note-body body))
      (record-belief graph (cons :memory-note name) "content"
                     (cons :digest (body-digest body))
                     :producer producer :standing :asserted
                     :extent (te:make-interval
                              (te:exact-bound start) (te:unknown-bound)
                              :semantics :validity :standing :asserted))
      (when banners
        (let ((bs (scan-banners body)))
          (dolist (b bs)
            (%capture-banner graph name b modified producer))
          (%retract-removed-banners graph name producer (length bs))
          (let ((last (%last-replacing-banner bs)))
            (if last
                (%capture-superseded-by graph name last modified producer)
                (%retract-stale-superseded-by graph name producer))))))))

(defun %note-files (dir)
  (sort (remove "MEMORY" (uiop:directory-files dir "*.md")
                :key #'pathname-name :test #'string=)
        #'string< :key #'pathname-name))

(defun capture-memory-dir (graph dir &key producer (banners t))
  "One MEMORY-NOTE per *.md in DIR (MEMORY.md, the index, excluded) and
one content belief per note under PRODUCER.  A note whose body changed
since the last capture gets a new content claim that SUPERSEDES the old
one; an unchanged note is idempotent.  When BANNERS (default T), also
captures each note's banners as MEMORY-BANNER nodes and their
ANNOTATES/SUPERSEDED-BY beliefs (banners spec SS4).  One transaction
per note.  Returns the number of notes captured."
  (%check-producer producer)
  (let ((n 0))
    (dolist (path (%note-files dir) n)
      (gdb:with-transaction (:graph graph)
        (%capture-note graph path producer banners))
      (incf n))))

(defun capture-listing (graph dir)
  "The deterministic shape capture-and-diff compares: per note, its
recall of the content series, newest first -- (NAME DIGEST START
CURRENT-P SUPERSEDED-BY-DIGEST) rows.  A note with no MODIFIED stamp
starts at the file's write date, which no two checkouts share, so its
START is NIL here rather than making the golden host-bound."
  (loop for path in (%note-files dir)
        for fm = (read-frontmatter path)
        for name = (or (getf fm :name) (pathname-name path))
        for stamped = (and (getf fm :modified) t)
        append (loop for r in (recall graph (cons :memory-note name)
                                      :relation "content")
                     for c = (belief-record-claim r)
                     for s = (belief-record-superseded-by r)
                     collect (list name
                                   (st:claim-object-key c)
                                   (and stamped
                                        (local-time:format-rfc3339-timestring
                                         nil (%start-instant c)
                                         :timezone local-time:+utc-zone+))
                                   (belief-record-current-p r)
                                   (and s (st:claim-object-key s))))))
