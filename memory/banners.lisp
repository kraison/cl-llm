;;;; memory/banners.lisp -- the hand-written supersession banners, by
;;;; line shape.  Spec 2026-09-03 (banners) SS3; the listing SS4.

(in-package #:cl-llm.memory)

(defstruct banner
  "One banner found in a note body (SS3).  DATE is a TIMESTAMP at
00:00:00Z from the first YYYY-MM-DD on the heading line, or NIL; LINK
the first [[name]] in TEXT, or NIL; TEXT the banner's lines verbatim."
  kind position date link text line)

(defparameter +banner-words+
  '(("SUPERSEDED" . :superseded) ("UPDATE" . :update)
    ("CORRECTION" . :correction) ("STALE" . :stale)))

(defun %strip-prefix (line prefix)
  (if (and (>= (length line) (length prefix))
           (string= prefix line :end2 (length prefix)))
      (subseq line (length prefix))
      nil))

(defun %word-boundary-p (s word)
  "S starts with WORD followed by end-of-string or a non-letter -- so
\"UPDATE\" does not match \"UPDATED\" (Task 1 review)."
  (and (%strip-prefix s word)
       (or (= (length s) (length word))
           (not (alpha-char-p (char s (length word)))))))

(defun %heading-kind (line)
  "The banner kind LINE opens, or NIL.  After an optional \"> \" and an
optional warning sign, the line must start with ** and a banner word."
  (let* ((s (or (%strip-prefix line "> ") line))
         (s (or (%strip-prefix s (format nil "~a " (code-char #x26a0))) s))
         (s (%strip-prefix s "**")))
    (and s
         (cdr (assoc-if (lambda (word) (%word-boundary-p s word))
                         +banner-words+)))))

(defun %blockquote-p (line)
  (and (plusp (length line)) (char= #\> (char line 0))))

(defun %blank-p (line)
  (zerop (length (string-trim '(#\Space #\Tab #\Return) line))))

(defun %digit-run-p (s start n)
  (and (<= (+ start n) (length s))
       (every #'digit-char-p (subseq s start (+ start n)))))

(defun %first-date (line)
  "The first YYYY-MM-DD in LINE as a TIMESTAMP at midnight UTC, or NIL."
  (loop for i from 0 to (- (length line) 10)
        when (and (%digit-run-p line i 4)
                  (char= #\- (char line (+ i 4)))
                  (%digit-run-p line (+ i 5) 2)
                  (char= #\- (char line (+ i 7)))
                  (%digit-run-p line (+ i 8) 2))
          return (local-time:parse-timestring
                  (format nil "~aT00:00:00Z" (subseq line i (+ i 10))))))

(defun %first-link (text)
  "The name inside the first [[...]] in TEXT, or NIL."
  (let ((open (search "[[" text)))
    (when open
      (let ((close (search "]]" text :start2 (+ open 2))))
        (when close (subseq text (+ open 2) close))))))

(defun scan-banners (body)
  "The banners in BODY, in order, positions from 1 (SS3).  Parses line
shapes only: a heading line opens a banner; a blockquote banner runs
over the following > lines, any other over the following lines to the
next blank line."
  (let ((lines (uiop:split-string body :separator '(#\Newline)))
        (banners '()) (position 0) (i 0))
    (loop while (< i (length lines))
          do (let* ((line (nth i lines))
                    (kind (%heading-kind line)))
               (if (null kind)
                   (incf i)
                   (let ((quoted (%blockquote-p line))
                         (start i)
                         (collected (list line)))
                     (incf i)
                     (loop while (and (< i (length lines))
                                      (let ((l (nth i lines)))
                                        (if quoted
                                            (%blockquote-p l)
                                            (not (%blank-p l)))))
                           do (push (nth i lines) collected)
                              (incf i))
                     (let ((text (format nil "~{~a~^~%~}"
                                          (nreverse collected))))
                       (push (make-banner :kind kind
                                           :position (incf position)
                                           :date (%first-date line)
                                           :link (%first-link text)
                                           :text text
                                           :line (1+ start))
                             banners))))))
    (nreverse banners)))

(defun banner-listing (graph dir)
  "The deterministic shape capture-and-diff compares (SS4): per note in
name order, per banner in position order, (NOTE POSITION KIND DATE
LINK TEXT-DIGEST DATED-P); DATE is NIL when the banner took the note's
stamp, as CAPTURE-LISTING does for an unstamped note."
  (loop for path in (%note-files dir)
        for fm = (read-frontmatter path)
        for name = (or (getf fm :name) (pathname-name path))
        append (loop for b in (scan-banners
                               (nth-value 1 (read-frontmatter path)))
                     for key = (format nil "~a#~a" name
                                       (banner-position b))
                     for node = (first (gdb:index-lookup
                                        graph 'memory-banner
                                        'bn-key key))
                     collect (list name (banner-position b)
                                   (and node (bn-kind node))
                                   (and node (bn-dated-p node)
                                        (bn-date node))
                                   (and node
                                        (plusp (length (bn-link node)))
                                        (bn-link node))
                                   (and node (body-digest (bn-text node)))
                                   (and node (bn-dated-p node))))))
