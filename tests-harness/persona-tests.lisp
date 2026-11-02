;;;; tests-harness/persona-tests.lisp -- personas as data (spec SS6.2).

(in-package #:cl-llm.harness/tests)
(in-suite :cl-llm-harness)

(defparameter +echo-persona-text+
  "(:name \"echo\" :system \"Be terse.\" :tools (\"tool-echo\")
 :provider (:kind :openai-compatible :base-url \"http://x/v1\"
            :model \"m\" :api-key-file \"/nonexistent\")
 :parameters (:temperature 0.2)
 :budgets (:max-turns 3 :max-seconds 30))")

(defun report-of (condition)
  (format nil "~a" condition))

(test persona-name-must-be-canonical
  (signals harness:persona-error
    (harness:make-persona :name "Bad Name" :provider (llm:make-mock-provider)))
  (is (string= "summariser-2"
               (harness:persona-name
                (harness:make-persona :name "summariser-2"
                                      :provider (llm:make-mock-provider))))))

(test persona-file-round-trip
  (with-scratch-dir (dir)
    (let ((p (harness:load-persona-file
              (write-text (merge-pathnames "echo.persona" dir)
                          +echo-persona-text+))))
      (is (string= "echo" (harness:persona-name p)))
      (is (string= "Be terse." (harness:persona-system p)))
      (is (equal '("tool-echo") (harness:persona-tools p)))
      (is (equal '(:temperature 0.2) (harness:persona-parameters p)))
      (is (= 3 (harness:persona-max-turns p)))
      (is (= 30 (harness:persona-max-seconds p))))))

(test persona-file-unknown-key-refused
  (with-scratch-dir (dir)
    (let ((path (write-text (merge-pathnames "bad.persona" dir)
                            "(:name \"bad\" :sytem \"oops\")")))
      (handler-case (progn (harness:load-persona-file path)
                           (fail "an unknown key was accepted"))
        (harness:persona-error (e)
          (is (search "SYTEM" (string-upcase (report-of e)))))))))

(defvar *evaluated* nil "Set by a #. form only if a persona file ran.")

(test persona-file-never-evaluated
  ;; Qualified symbols: the file is read into KEYWORD, so a bare ERROR
  ;; would fail as :ERROR even if evaluated, and pass vacuously.
  (setf *evaluated* nil)
  (with-scratch-dir (dir)
    (let ((path (write-text
                 (merge-pathnames "evil.persona" dir)
                 (concatenate
                  'string "(:name \"evil\" :provider (:kind :anthropic)"
                  " :system #.(cl:progn (cl:setf"
                  " cl-llm.harness/tests::*evaluated* cl:t) \"x\"))"))))
      (signals harness:persona-error (harness:load-persona-file path))
      (is (null *evaluated*) "the persona file's #. form ran"))))

(test persona-directory-finds-by-name
  (with-scratch-dir (dir)
    (write-text (merge-pathnames "echo.persona" dir) +echo-persona-text+)
    (let ((source (harness:make-persona-directory dir)))
      (is (string= "echo"
                   (harness:persona-name (harness:find-persona source "echo"))))
      (is (null (harness:find-persona source "absent"))))))

(test persona-key-file-unreadable
  (let ((p (harness:make-persona
            :name "keyless"
            :provider '(:kind :openai-compatible :base-url "http://x/v1"
                        :model "m" :api-key-file "/nonexistent/key"))))
    (handler-case (progn (harness:persona-make-provider p)
                         (fail "a missing key file was accepted"))
      (harness:persona-error (e)
        (is (search "/nonexistent/key" (report-of e)))))))

(test persona-key-file-read-at-call-time
  (with-scratch-dir (dir)
    (let* ((key (write-text (merge-pathnames "key" dir) "k1"))
           (p (harness:make-persona
               :name "rotating"
               :provider (list :kind :openai-compatible
                               :base-url "http://x/v1" :model "m"
                               :api-key-file (namestring key)))))
      (write-text key (format nil "k2~%"))
      (is (string= "k2" (llm:provider-api-key
                         (harness:persona-make-provider p)))))))

(test persona-file-improper-list-refused
  ;; Final review: a dotted or circular plist is a PERSONA-ERROR, never
  ;; a TYPE-ERROR or a hang.  #1= is not stopped by *READ-EVAL* NIL.
  (with-scratch-dir (dir)
    (dolist (text '("(:name . \"x\")"
                    "#1=(:name \"x\" . #1#)"))
      (let ((path (write-text (merge-pathnames "odd.persona" dir) text)))
        (handler-case
            (bt:with-timeout (5)
              (harness:load-persona-file path)
              (fail "~a was accepted" text))
          (harness:persona-error () (pass))
          (bt:timeout () (fail "~a hung the loader" text))
          (error (e) (fail "~a escaped as ~a" text (type-of e))))))))
