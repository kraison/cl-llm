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
      "control: an empty body is no banners, not an error"))
