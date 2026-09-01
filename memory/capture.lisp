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

(defun %capture-note (graph path producer)
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
                              :semantics :validity :standing :asserted)))))

(defun %note-files (dir)
  (sort (remove "MEMORY" (uiop:directory-files dir "*.md")
                :key #'pathname-name :test #'string=)
        #'string< :key #'pathname-name))

(defun capture-memory-dir (graph dir &key producer)
  "One MEMORY-NOTE per *.md in DIR (MEMORY.md, the index, excluded) and
one content belief per note under PRODUCER.  A note whose body changed
since the last capture gets a new content claim that SUPERSEDES the old
one; an unchanged note is idempotent.  One transaction per note.
Returns the number of notes captured."
  (%check-producer producer)
  (let ((n 0))
    (dolist (path (%note-files dir) n)
      (gdb:with-transaction (:graph graph)
        (%capture-note graph path producer))
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
