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
          "an undated banner starts at the note's MODIFIED"))
    (let ((node (first (gdb:index-lookup g 'mem:memory-banner
                                         'mem:bn-key "stale#1"))))
      (is-true (mem:bn-dated-p node))
      (is (string= "2026-07-05T00:00:00Z" (mem:bn-date node))))))

(test a-second-capture-writes-nothing-new
  (with-two-stores (g b)
    (declare (ignore b))
    (%capture-banners-fixture g)
    (let ((before (length (st:claims-by-producer g 'mem:belief +p+))))
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
