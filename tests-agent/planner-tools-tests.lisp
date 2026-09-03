;;;; tests-agent/planner-tools-tests.lisp -- spec SS7.

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %seed-two-stores (w p)
  (%belief w "ci-status" '(:verdict . "green"))
  (%belief w "ci-status" '(:verdict . "red") :start "2026-09-02T08:00:00Z")
  (%belief p "owner" '(:person . "kevin")))

(test retrieve-fuses-the-scopes-claim-sources-and-cites-each-claim
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "anything"
                     "endpoints" (vector "repo:cl-llm")))
           (ev (coerce (json:jget r "evidence") 'list)))
      (is (equal '("claim") (coerce (json:jget r "modes") 'list)))
      (is (= 3 (length ev)))
      (is (every (lambda (e) (mem:cite-p (json:jget e "cite"))) ev))
      (is (equal '("cl-llm-memory" "memory-private")
                 (sort (remove-duplicates
                        (mapcar (lambda (e) (json:jget e "store")) ev)
                        :test #'string=)
                       #'string<)))
      (is (every (lambda (e) (stringp (json:jget e "text"))) ev))
      (is (stringp (json:jget r "bounds" "window" "from")))
      (is (string= "inferred" (json:jget r "bounds" "window" "standing"))))))

(test retrieve-applies-a-supplied-window-and-reports-it-asserted
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm")
                     "from" "2026-09-02T08:00:00Z"
                     "to" "2026-09-03T00:00:00Z"))
           (keys (mapcar (lambda (e) (json:jget e "cite"))
                         (coerce (json:jget r "evidence") 'list))))
      (is (string= "asserted" (json:jget r "bounds" "window" "standing")))
      ;; Supersession closes green 1ns before red's 09-02T08:00 start
      ;; (memory/write.lisp %CLOSE-VALIDITY); the window starts exactly
      ;; there, so ALLEN-RELATION reads green as definitely :BEFORE it
      ;; and BOUNDED-EVIDENCE drops it (rag/bundle.lisp).  Red and the
      ;; open owner belief survive.
      (is (= 2 (length keys)))))
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm")
                     "from" "2026-09-02T00:00:00Z"
                     "to" "2026-09-03T00:00:00Z"))
           (keys (mapcar (lambda (e) (json:jget e "cite"))
                         (coerce (json:jget r "evidence") 'list))))
      ;; A window starting at midnight overlaps green's last eight
      ;; hours: ALLEN-RELATION answers neither :BEFORE nor :AFTER, so
      ;; uncertainty is never exclusion -- all three survive.
      (is (= 3 (length keys))))))

(test retrieve-clamps-k-and-a-recognised-endpoint-with-nothing-is-searched-empty
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+ :k 1))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:cl-llm") "k" 50)))
      (is (= 1 (length (json:jget r "evidence"))))
      (is (eq t (json:jget r "truncated"))))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "retrieve" "query" "q"
                     "endpoints" (vector "repo:nothing-here")))
           (ev (coerce (json:jget r "evidence") 'list)))
      ;; Two stores in scope, two distinct absence items -- a store's
      ;; own name in each one's document id keeps FUSE from collapsing
      ;; them to one (claims/source.lisp %ABSENCE-EVIDENCE).
      (is (= 2 (length ev)))
      (is (every (lambda (e)
                   (string= "searched-empty" (json:jget e "standing")))
                 ev))
      (is (every (lambda (e) (null (json:jget e "cite"))) ev))
      (is (equal '("cl-llm-memory" "memory-private")
                 (sort (mapcar (lambda (e) (json:jget e "store")) ev)
                       #'string<))
          "each absence names the store that looked"))))

(test plan-bounds-derives-a-window-from-the-seed
  (with-stores (w p)
    (%seed-two-stores w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "plan-bounds" "query" "q"
                     "endpoints" (vector "repo:cl-llm"))))
      (is (string= "2026-09-01T08:00:00.000000Z"
                   (json:jget r "window" "from")))
      (is (string= "inferred" (json:jget r "window" "standing")))
      (is (null (json:jget r "box")))
      (is (string= "searched-empty" (json:jget r "box-standing"))))))

(test retrieve-signals-on-a-noncanonical-endpoint-namespace
  "Controller ruling 2: %ENDPOINTS uses the validating %KEYWORD for the
namespace half of each \"namespace:key\" string, so a non-canonical
namespace is a tool error, not a silent intern."
  (with-stores (w p)
    (%seed-two-stores w p)
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (llm:call-tool (%tool tools "retrieve")
                       (%args "query" "q"
                              "endpoints" (vector "Bad NS:cl-llm")))))))
