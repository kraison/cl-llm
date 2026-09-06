;;;; tests-agent-mcp/adapter-tests.lisp -- cl-llm tools as cl-mcp tools.
;;;; Spec SS3; recon C1, E1, E2.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defun %registry (server)
  ;; The server's tool registry; MCP-SERVER-TOOLS is exported.
  (cl-mcp:mcp-server-tools server))

(defun %text (content)
  "The text of the first content block."
  (cdr (assoc "text" (first content) :test #'string=)))

(defun %schema-of (server name)
  (mcp.tools:tool-input-schema (mcp.tools:get-tool (%registry server) name)))

(test every-agent-tool-registers-with-a-string-keyed-schema
  "SS3: one MCP tool per cl-llm tool, in cl-mcp's alist form."
  (with-stores (w p)
    (let* ((server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (names (mapcar #'mcp.tools:tool-name
                          (mcp.tools:list-tools (%registry server)))))
      (is (= 8 (length names)))
      (dolist (n '("recall" "trace" "decisions-citing" "conclude"
                   "conclude-absence" "retract" "retrieve" "plan-bounds"))
        (is (member n names :test #'string=) n))
      (let ((schema (%schema-of server "recall")))
        (is (string= "object" (cdr (assoc "type" schema :test #'string=))))
        (is (listp (cdr (assoc "required" schema :test #'string=))))
        (is (assoc "properties" schema :test #'string=)))
      (is (null (mcp.tools:get-tool (%registry server) "query"))
          "control: no query tool unless asked"))))

(test a-required-list-validates-and-a-vector-does-not
  "recon C1: the registered schema carries REQUIRED as a list, so
cl-mcp's validator accepts a complete call; the same schema with
REQUIRED as a vector makes the validator signal a TYPE-ERROR on every
call -- the control that proves the coercion is load-bearing."
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let* ((server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (registry (%registry server))
           (args '(("subject-namespace" . "repo")
                   ("subject-key" . "cl-llm"))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool registry "recall" args)
        (is (null error-p))
        (is (= 1 (length (json:jget (json:parse (%text content))
                                    "records")))))
      (let* ((schema (%schema-of server "recall"))
             (broken (mapcar (lambda (pair)
                               (if (string= (car pair) "required")
                                   (cons "required"
                                         (coerce (cdr pair) 'vector))
                                   pair))
                             schema)))
        (mcp.tools:register-tool registry "recall-v" "" broken
                                 (lambda (a) (declare (ignore a)) "x"))
        (signals type-error (mcp.tools:call-tool registry "recall-v" args)
          "control: a vector REQUIRED breaks every call")))))

(test a-list-valued-array-argument-reaches-the-tool-as-a-vector
  "recon E2: cl-mcp decodes a JSON array as a list; the tools read
arrays with ACROSS.  CONCLUDE's EVIDENCE arrives as a list and the
conclusion still cites it; the control is the same call with no
evidence, which needs no conversion."
  (with-stores (w p)
    (let* ((cite (mem:claim-cite (%belief w "ci-status" '(:verdict . "green"))))
           (server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (registry (%registry server)))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool
           registry "conclude"
           `(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
             ("relation" . "releasable")
             ("object-namespace" . "verdict") ("object-key" . "yes")
             ("rule" . "r") ("evidence" ,cite)))
        (is (null error-p))
        (let* ((out (json:parse (%text content)))
               (id (json:jget out "id"))
               (rec (mem:trace w id)))
          (is (string= "concluded" (json:jget out "outcome")))
          (is (string= cite (mem:cite-record-cite
                             (first (mem:decision-record-evidence rec)))))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool
           registry "conclude"
           '(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
             ("relation" . "other") ("object-namespace" . "v")
             ("object-key" . "1") ("rule" . "r")))
        (is (null error-p) "control: no evidence, no conversion")
        (is (string= "concluded"
                     (json:jget (json:parse (%text content)) "outcome")))))))

(test a-refusal-is-text-with-the-error-flag
  "SS3: an LLM-TOOL-ERROR -- here a bad standing -- becomes a text
block with isError; the message is the in-process loop's.  The control
is the same call with a valid standing."
  (with-stores (w p)
    (let* ((server (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+))
           (registry (%registry server))
           (base '(("subject-namespace" . "repo") ("subject-key" . "cl-llm")
                   ("relation" . "x") ("object-namespace" . "v")
                   ("object-key" . "1") ("rule" . "r"))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool registry "conclude"
                               (cons '("standing" . "bogus") base))
        (is (eq t error-p))
        (is (search "standing must be one of" (%text content))))
      (multiple-value-bind (content error-p)
          (mcp.tools:call-tool registry "conclude"
                               (cons '("standing" . "observed") base))
        (declare (ignore content))
        (is (null error-p) "control")))))

(test the-query-tool-joins-only-when-asked
  "SS3 (recon C9): :QUERY-TOOL T appends the guarded query tool over the
store list; it is absent otherwise."
  (with-stores (w p)
    (let ((with (mcp:make-memory-server (list w p) :write-store w
                                                    :producer +p+
                                                    :query-tool t))
          (without (mcp:make-memory-server (list w p) :write-store w
                                                       :producer +p+)))
      (is (mcp.tools:get-tool (%registry with) "query"))
      (is (null (mcp.tools:get-tool (%registry without) "query"))
          "control"))))
