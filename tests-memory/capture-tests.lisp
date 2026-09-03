;;;; tests-memory/capture-tests.lisp -- spec SS7, capture-and-diff.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %fixture-dir ()
  (asdf:system-relative-pathname
   :cl-llm "tests-memory/fixtures/memory/"))

(defun %golden-path ()
  (asdf:system-relative-pathname
   :cl-llm "tests-memory/golden/capture.sexp"))

(defun %copy-fixture-to-temp ()
  (let ((dir (format nil "/tmp/cl-llm-memory-corpus-~a-~a/"
                     (get-internal-real-time) (random 1000000))))
    (ensure-directories-exist dir)
    (dolist (f (uiop:directory-files (%fixture-dir) "*.md"))
      (uiop:copy-file f (merge-pathnames (file-namestring f) dir)))
    dir))

(defun %rewrite-beta (dir)
  (with-open-file (out (merge-pathnames "beta.md" dir)
                       :direction :output :if-exists :supersede
                       :external-format :utf-8)
    (format out "---~%name: beta~%description: edited~%metadata:~%~
  type: feedback~%  modified: 2026-08-20T10:00:00Z~%---~%~%~
Suite is 500 pass / 0 fail.~%")))

(test frontmatter-reads-name-type-and-modified
  (multiple-value-bind (fm body)
      (mem:read-frontmatter (merge-pathnames "beta.md" (%fixture-dir)))
    (is (string= "beta" (getf fm :name)))
    (is (string= "feedback" (getf fm :type)))
    (is (string= "2026-08-02T10:00:00Z" (getf fm :modified)))
    (is (search "486 pass" body))
    (is (not (search "---" body)) "the fence is not part of the body")))

(test a-note-without-a-modified-stamp-reads-nil-not-a-guess
  (is (null (getf (mem:read-frontmatter
                   (merge-pathnames "gamma.md" (%fixture-dir)))
                  :modified))))

(test the-digest-is-stable-and-utf-8
  (is (string= (mem:body-digest "héllo") (mem:body-digest "héllo")))
  (is (string/= (mem:body-digest "a") (mem:body-digest "b")))
  (is (= 64 (length (mem:body-digest "")))))

(test capture-makes-one-note-and-one-content-belief-per-file
  (with-memory-graph (g)
    (is (= 3 (mem:capture-memory-dir g (%fixture-dir) :producer +p+)))
    (let ((rs (mem:recall g '(:memory-note . "beta")
                          :relation "content")))
      (is (= 1 (length rs)))
      (is (eq :digest (st:claim-object-namespace
                       (mem:belief-record-claim (first rs)))))
      (is-true (mem:belief-record-current-p (first rs))))))

(test a-second-capture-after-an-edit-supersedes-rather-than-overwrites
  "The #16 case: the old content claim survives, closed and naming the
new one.  Control: an unedited note gains no second claim."
  (let ((dir (%copy-fixture-to-temp)))
    (unwind-protect
         (with-memory-graph (g)
           (mem:capture-memory-dir g dir :producer +p+)
           (%rewrite-beta dir)
           (mem:capture-memory-dir g dir :producer +p+)
           (let ((beta (mem:recall g '(:memory-note . "beta")
                                   :relation "content"))
                 (alpha (mem:recall g '(:memory-note . "alpha")
                                    :relation "content")))
             (is (= 2 (length beta)))
             (is-true (mem:belief-record-current-p (first beta)))
             (is-false (mem:belief-record-current-p (second beta)))
             (is (eq (mem:belief-record-claim (first beta))
                     (mem:belief-record-superseded-by (second beta))))
             (is (= 1 (length alpha)) "control")))
      (uiop:delete-directory-tree (pathname dir) :validate t))))

(test capture-and-diff-matches-the-committed-golden
  "Ordering as the contract: the listing is compared whole, so a
reordering or a changed digest is a diff, not a pass."
  (let ((dir (%copy-fixture-to-temp)))
    (unwind-protect
         (with-memory-graph (g)
           (mem:capture-memory-dir g dir :producer +p+)
           (%rewrite-beta dir)
           (mem:capture-memory-dir g dir :producer +p+)
           (let ((got (mem:capture-listing g dir))
                 (want (with-open-file (in (%golden-path))
                         (let ((*read-eval* nil)) (read in)))))
             (is (equal want got)
                 "regenerate the golden ONLY for an intended change: ~
                  (mem:capture-listing g dir) -> ~a" (%golden-path))))
      (uiop:delete-directory-tree (pathname dir) :validate t))))

(test the-listing-renders-every-start-at-second-precision
  "#36: one rendering for the tenant -- no six-digit fraction in the
capture listing, the same shape BANNER-LISTING and the banner pass use."
  (let ((dir (%copy-fixture-to-temp)))
    (unwind-protect
         (with-memory-graph (g)
           (mem:capture-memory-dir g dir :producer +p+)
           (dolist (row (mem:capture-listing g dir))
             (let ((start (third row)))
               (when start
                 (is (= 20 (length start)) "~a" start)
                 (is (char= #\Z (char start 19)))))))
      (uiop:delete-directory-tree (pathname dir) :validate t))))
