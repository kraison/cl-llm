;;;; tests-agent-prolog/query-tests.lisp -- spec SS8: the guard, the
;;;; budgets, the row cap, the scope.

(in-package #:cl-llm.agent.prolog/tests)

(def-suite :cl-llm-agent-prolog)
(in-suite :cl-llm-agent-prolog)

(test a-guarded-query-over-beliefs-returns-rows
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (%belief w "last-push" '(:sha . "abc"))
    (let* ((tool (prolog:make-query-tool (list w p)))
           (r (json:parse
               (llm:call-tool
                tool
                (%args "text"
                       (concatenate
                        'string "(is-a ?c belief-binary) "
                        "(node-slot-value ?c relation ?r)"))))))
      (is (string= "cl-llm-memory" (json:jget r "store")))
      (is (equalp #("c" "r") (json:jget r "columns")))
      (is (= 2 (length (json:jget r "rows"))))
      (is (eq nil (json:jget r "truncated"))))))

(test query-names-a-store-in-scope
  (with-stores (w p)
    (%belief p "owner" '(:person . "kevin"))
    (let ((tool (prolog:make-query-tool (list w p))))
      (is (= 1 (length
                (json:jget
                 (json:parse
                  (llm:call-tool
                   tool (%args "text" "(is-a ?c belief-binary)"
                               "store" "memory-private")))
                 "rows"))))
      (signals llm:llm-tool-error
        (llm:call-tool tool (%args "text" "(is-a ?c belief-binary)"
                                   "store" "elsewhere"))))))

(test the-guard-refuses-reader-syntax-with-its-own-reason
  (with-stores (w p)
    (let ((tool (prolog:make-query-tool (list w p))))
      (handler-case
          (progn (llm:call-tool tool (%args "text" "(is-a ?c #.(quit))"))
                 (fail "a #. query must be refused"))
        (llm:llm-tool-error (e)
          (is (search "#" (princ-to-string (llm:llm-error-underlying e)))))))))

(test an-excluded-or-effectful-predicate-is-refused
  (with-stores (w p)
    (let ((tool (prolog:make-query-tool (list w p))))
      (signals llm:llm-tool-error
        (llm:call-tool tool (%args "text" "(lisp ?x (+ 1 2))"))))))

(test the-inference-budget-is-the-operators
  (with-stores (w p)
    (dotimes (i 5) (%belief w (format nil "r~a" i) '(:v . "1")))
    (let ((tool (prolog:make-query-tool (list w p) :max-inferences 1)))
      (handler-case
          (progn
            (llm:call-tool
             tool
             (%args "text"
                    (concatenate
                     'string "(is-a ?a belief-binary) "
                     "(is-a ?b belief-binary)")))
            (fail "the budget must trip"))
        (llm:llm-tool-error (e)
          (is (search "inference"
                      (string-downcase
                       (princ-to-string
                        (llm:llm-error-underlying e))))))))))

(test the-row-cap-is-the-operators
  (with-stores (w p)
    (dotimes (i 5) (%belief w (format nil "r~a" i) '(:v . "1")))
    (let* ((tool (prolog:make-query-tool (list w p) :max-rows 2))
           (r (json:parse
               (llm:call-tool
                tool (%args "text" "(is-a ?c belief-binary)"
                            "limit" 100)))))
      (is (= 2 (length (json:jget r "rows"))))
      (is (eq t (json:jget r "truncated"))))))
