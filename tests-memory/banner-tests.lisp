;;;; tests-memory/banner-tests.lisp -- spec 2026-09-03 (banners) SS3:
;;;; the scanner on the real shapes; SS4: capture, listing, golden.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %banner-fixture-dir ()
  (asdf:system-relative-pathname
   :cl-llm "tests-memory/fixtures/banners/"))

(defun %fixture-body (name)
  (nth-value 1 (mem:read-frontmatter
                (merge-pathnames (format nil "~a.md" name)
                                 (%banner-fixture-dir)))))

(test scan-finds-the-superseded-blockquote
  (let ((bs (mem:scan-banners (%fixture-body "superseded"))))
    (is (= 1 (length bs)))
    (let ((b (first bs)))
      (is (eq :superseded (mem:banner-kind b)))
      (is (= 1 (mem:banner-position b)))
      (is (local-time:timestamp= (%ts "2026-07-22T00:00:00Z")
                                 (mem:banner-date b)))
      (is (string= "android-sqlite-peer" (mem:banner-link b)))
      (is (= 3 (count #\Newline (mem:banner-text b) :test #'char=))
          "four blockquote lines joined by three newlines")
      (is (search "does not describe how the field app works today"
                  (mem:banner-text b)))
      (is (= 1 (mem:banner-line b))))))

(test scan-finds-a-dated-update-and-stops-at-the-blank-line
  (let ((bs (mem:scan-banners (%fixture-body "update"))))
    (is (= 1 (length bs)))
    (let ((b (first bs)))
      (is (eq :update (mem:banner-kind b)))
      (is (local-time:timestamp= (%ts "2026-07-09T00:00:00Z")
                                 (mem:banner-date b)))
      (is (null (mem:banner-link b)))
      (is (search "extract flags transient failures" (mem:banner-text b)))
      (is (not (search "later paragraph" (mem:banner-text b)))))))

(test scan-finds-a-correction-whose-date-is-inside-the-sentence
  (let ((b (first (mem:scan-banners (%fixture-body "correction")))))
    (is (eq :correction (mem:banner-kind b)))
    (is (local-time:timestamp= (%ts "2026-07-01T00:00:00Z")
                               (mem:banner-date b)))))

(test scan-finds-stale-on-hosts-with-its-link
  (let ((b (first (mem:scan-banners (%fixture-body "stale")))))
    (is (eq :stale (mem:banner-kind b)))
    (is (string= "hosts-now" (mem:banner-link b)))
    (is (local-time:timestamp= (%ts "2026-07-05T00:00:00Z")
                               (mem:banner-date b)))))

(test scan-numbers-two-banners-and-an-undated-one-has-no-date
  (let ((bs (mem:scan-banners (%fixture-body "two"))))
    (is (equal '(1 2) (mapcar #'mem:banner-position bs)))
    (is (equal '(:update :correction) (mapcar #'mem:banner-kind bs)))
    (is (null (mem:banner-date (second bs))))
    (is (string= "test-suite-roadmap" (mem:banner-link (second bs))))))

(test scan-ignores-a-bold-heading-that-is-not-a-banner
  (is (null (mem:scan-banners (%fixture-body "plain"))))
  (is (null (mem:scan-banners ""))
      "control: an empty body is no banners, not an error")
  (is (null (mem:scan-banners "**UPDATED yesterday**"))
      "UPDATE must not match by prefix of UPDATED"))

(defun %capture-banners-fixture (g)
  (mem:capture-memory-dir g (%banner-fixture-dir) :producer +p+))

(defun %annotations (g name)
  "The ANNOTATES beliefs touching NAME as object."
  (remove "annotates"
          (st:claims-touching g 'mem:belief :memory-note name :role :object)
          :key #'st:claim-relation :test-not #'string=))

(test capture-records-a-superseded-note-as-superseded-by-its-link
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((rs (mem:recall g '(:memory-note . "superseded")
                          :relation "superseded-by")))
      (is (= 1 (length rs)))
      (let ((r (first rs)))
        (is-true (mem:belief-record-current-p r))
        (is (eq :asserted (mem:belief-record-standing r)))
        (is (string= "android-sqlite-peer"
                     (st:claim-object-key (mem:belief-record-claim r))))
        (is (local-time:timestamp=
             (%ts "2026-07-22T00:00:00Z")
             (te:bound-earliest
              (te:extent-start (mem:belief-record-extent r)))))))
    (let ((as (%annotations g "superseded")))
      (is (= 1 (length as)))
      (is (string= "superseded#1" (st:claim-subject-key (first as))))
      (is (string= "superseded" (st:claim-method (first as)))))))

(test an-update-annotates-but-never-supersedes
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (is (= 1 (length (%annotations g "update"))))
    (is (null (mem:recall g '(:memory-note . "update")
                          :relation "superseded-by")))
    ;; a linking correction is still an addendum
    (is (= 2 (length (%annotations g "two"))))
    (is (null (mem:recall g '(:memory-note . "two")
                          :relation "superseded-by")))))

(test the-banner-node-holds-the-text-and-its-date
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((node (first (gdb:index-lookup g 'mem:memory-banner
                                         'mem:bn-key "two#2"))))
      (is (search "Stage 5 is NOT" (mem:bn-text node)))
      (is (string= "correction" (mem:bn-kind node)))
      (is (string= "test-suite-roadmap" (mem:bn-link node)))
      (is (null (mem:bn-dated-p node)))
      (is (string= "2026-07-10T10:00:00Z" (mem:bn-date node))
          "an undated banner starts at the note's MODIFIED")
      (is (string= "two" (mem:bn-note node)))
      (is (= 2 (mem:bn-position node))))
    (let ((node (first (gdb:index-lookup g 'mem:memory-banner
                                         'mem:bn-key "stale#1"))))
      (is-true (mem:bn-dated-p node))
      (is (string= "2026-07-05T00:00:00Z" (mem:bn-date node))))))

(test a-second-capture-writes-nothing-new
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((before (length (st:claims-by-producer g 'mem:belief +p+))))
      (is (plusp before) "control: the first capture wrote beliefs")
      (%capture-banners-fixture g)
      (is (= before (length (st:claims-by-producer g 'mem:belief +p+))))
      (is (= 1 (length (%annotations g "superseded")))))))

(test banners-off-captures-as-unit-one-did
  (with-two-stores (g b)
    (declare (ignore b))
    (mem:capture-memory-dir g (%banner-fixture-dir) :producer +p+
                            :banners nil)
    (is (null (%annotations g "superseded")))
    (is (= 1 (length (mem:recall g '(:memory-note . "superseded")
                                 :relation "content")))
        "control: the content belief is there")))

(defun %copy-banner-fixture-to-temp ()
  (let ((dir (format nil "/tmp/cl-llm-banner-corpus-~a-~a/"
                     (get-internal-real-time) (random 1000000))))
    (ensure-directories-exist dir)
    (dolist (f (uiop:directory-files (%banner-fixture-dir) "*.md"))
      (uiop:copy-file f (merge-pathnames (file-namestring f) dir)))
    dir))

(defun %read-utf8 (path)
  (with-open-file (in path :external-format :utf-8)
    (let ((s (make-string (file-length in))))
      (subseq s 0 (read-sequence s in)))))

(defun %replace-all-in-file (path old new)
  "Every occurrence of OLD in PATH becomes NEW."
  (let* ((text (%read-utf8 path))
         (out (with-output-to-string (s)
                (loop with start = 0
                      for pos = (search old text :start2 start)
                      while pos
                      do (write-string text s :start start :end pos)
                         (write-string new s)
                         (setf start (+ pos (length old)))
                      finally (write-string text s :start start)))))
    (with-open-file (o path :direction :output :if-exists :supersede
                       :external-format :utf-8)
      (write-string out o))))

(test a-re-dated-banner-corrects-not-supersedes
  "The banner's object never changes (SS4), so RECORD-BELIEF's own
idempotent path would keep the old date; a file capture is truth, so
this is a CORRECTION (controller ruling, #14 unit 3 task 2 review)."
  (let ((dir (%copy-banner-fixture-to-temp)))
    (unwind-protect
         (with-two-stores (g b)
           (declare (ignore b))
           (mem:capture-memory-dir g dir :producer +p+)
           ;; bumps both the frontmatter MODIFIED and the banner's own
           ;; heading date, so the note's content belief also supersedes
           ;; cleanly -- unrelated to what this test is about.
           (%replace-all-in-file (merge-pathnames "stale.md" dir)
                                 "2026-07-05" "2026-07-06")
           (mem:capture-memory-dir g dir :producer +p+)
           (let ((rs (mem:recall g '(:banner . "stale#1")
                                 :relation "annotates"
                                 :include-retracted t)))
             (is (= 2 (length rs)))
             (is-true (mem:belief-record-current-p (first rs)))
             (is (local-time:timestamp=
                  (%ts "2026-07-06T00:00:00Z")
                  (te:bound-earliest
                   (te:extent-start
                    (mem:belief-record-extent (first rs))))))
             (is-false (mem:belief-record-current-p (second rs)))
             (is-true (mem:belief-record-retracted-at (second rs))))
           (let ((node (first (gdb:index-lookup g 'mem:memory-banner
                                                'mem:bn-key "stale#1"))))
             (is (string= "2026-07-06T00:00:00Z" (mem:bn-date node)))))
      (uiop:delete-directory-tree (pathname dir) :validate t))))

(defun %write-double-superseded-note (dir)
  (ensure-directories-exist dir)
  (with-open-file (out (merge-pathnames "double.md" dir)
                       :direction :output :if-exists :supersede
                       :external-format :utf-8)
    (format out "---~%name: double~%description: Two undated ~
SUPERSEDED banners on one note~%metadata:~%  type: project~%  ~
modified: 2026-07-01T10:00:00Z~%---~%> **SUPERSEDED ~c premise A no ~
longer true.** See [[first-link]].~%~%> **SUPERSEDED ~c premise B no ~
longer true.** See [[second-link]].~%"
            (code-char #x2014) (code-char #x2014))))

(test two-superseded-banners-the-last-wins-with-no-error
  "Two replacing banners with equal or non-increasing dates would
abort the whole capture under plain RECORD-BELIEF; the last by
position wins and its write is a correction, not an error (controller
ruling, #14 unit 3 task 2 review)."
  (let ((dir (format nil "/tmp/cl-llm-banner-double-~a-~a/"
                     (get-internal-real-time) (random 1000000))))
    (unwind-protect
         (progn
           (%write-double-superseded-note dir)
           (with-two-stores (g b)
             (declare (ignore b))
             (finishes (mem:capture-memory-dir g dir :producer +p+))
             (let ((rs (mem:recall g '(:memory-note . "double")
                                   :relation "superseded-by")))
               (is (= 1 (length rs)))
               (is (string= "second-link"
                            (st:claim-object-key
                             (mem:belief-record-claim (first rs))))))
             (let ((before (length (st:claims-by-producer
                                    g 'mem:belief +p+))))
               (finishes (mem:capture-memory-dir g dir :producer +p+))
               (is (= before (length (st:claims-by-producer
                                      g 'mem:belief +p+)))))))
      (ignore-errors
       (uiop:delete-directory-tree (pathname dir) :validate t)))))

(defun %banner-golden-path ()
  (asdf:system-relative-pathname :cl-llm "tests-memory/golden/banners.sexp"))

(test banner-listing-matches-the-golden
  "Capture-and-diff (programme SS11): ordering is the contract."
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((rows (mem:banner-listing g (%banner-fixture-dir)))
          (golden (with-open-file (in (%banner-golden-path))
                    (let ((*read-eval* nil)) (read in)))))
      (is (equal golden rows)
          "diff: ~s" (set-exclusive-or golden rows :test #'equal)))))
