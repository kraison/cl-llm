;;;; agent/mcp/adapter.lisp -- each cl-llm tool as a cl-mcp tool.
;;;; Spec SS3; recon C1, C9, C12, E1, E2, E3.

(in-package #:cl-llm.agent.mcp)

(defun %schema-alist (schema)
  "cl-llm's JSON Schema -- nested EQUAL hash tables and vectors -- as the
string-keyed alist cl-mcp encodes and validates.  \"required\" becomes
a LIST: cl-mcp validates it with DOLIST, and a vector would turn every
call into an internal error while tools/list looked right (recon C1)."
  (cond ((and (hash-table-p schema) (zerop (hash-table-count schema)))
         (make-hash-table :test 'equal)) ; {} not [] (Task 2 review)
        ((hash-table-p schema)
         (loop for key being the hash-keys of schema using (hash-value v)
               collect (cons key (if (string= key "required")
                                     (coerce v 'list)
                                     (%schema-alist v)))))
        ((and (vectorp schema) (not (stringp schema)))
         (map 'vector #'%schema-alist schema))
        (t schema)))

(defun %array-parameters (tool)
  "The names of TOOL's array-typed parameters, from its schema."
  (let ((props (gethash "properties" (llm:tool-schema tool))))
    (when props
      (loop for name being the hash-keys of props using (hash-value spec)
            when (equal (gethash "type" spec) "array")
              collect name))))

(defun %arguments-table (arguments array-names)
  "cl-mcp's decoded ARGUMENTS -- a string-keyed alist; arrays are lists,
null and false are NIL, a JSON float is a double so an integer cap sent
as 5.0 falls back to the configured cap (recon E1, C12) -- as the EQUAL
hash table CALL-TOOL takes, with ARRAY-NAMES' values as vectors: the
tools read arrays with ACROSS (recon E2)."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (pair arguments table)
      (let ((name (car pair)) (value (cdr pair)))
        (setf (gethash name table)
              (if (and (member name array-names :test #'string=)
                       (listp value))
                  (coerce value 'vector)
                  value))))))

(defun %handler (tool)
  "The cl-mcp handler for TOOL: the tool's JSON text on success; on an
LLM-TOOL-ERROR -- a refusal or a bad argument, what the in-process loop
shows the model -- its message with the error flag, cl-mcp's isError.
Other conditions propagate to RUN-SERVER's loop (SS7)."
  (let ((arrays (%array-parameters tool)))
    (lambda (arguments)
      (handler-case
          (values (llm:call-tool tool (%arguments-table arguments arrays))
                  nil)
        (c:llm-tool-error (e) (values (princ-to-string e) t))))))

(defun register-llm-tool (server tool)
  "Register the cl-llm TOOL on the cl-mcp SERVER."
  (mcp:register-tool server (llm:tool-name tool)
                     :description (llm:tool-description tool)
                     :schema (%schema-alist (llm:tool-schema tool))
                     :handler (%handler tool)))

(defun %query-tool (stores max-rows)
  ;; Reached by name so this system does not depend on
  ;; cl-llm/agent/prolog; the scripts load it on request (ruling 2).
  (unless (find-package "CL-LLM.AGENT.PROLOG")
    (error "the query tool needs cl-llm/agent/prolog loaded"))
  (uiop:symbol-call :cl-llm.agent.prolog :make-query-tool stores
                    :max-rows max-rows))

(defun make-memory-server (stores &key write-store producer sources
                                       (k 5) (max-rows 50) query-tool
                                       (name "cl-llm-memory")
                                       (version "0.1"))
  "A cl-mcp server with one MCP tool per agent tool over STORES (trust
order) writing to WRITE-STORE as PRODUCER, caps K and MAX-ROWS, SOURCES
added to the planner -- MAKE-AGENT-TOOLS' arguments, so every bound is
fixed here and the model chooses arguments only.  QUERY-TOOL adds the
guarded Prolog tool over the store list (scope-blind, recon C9).  One
server per connection: cl-mcp keeps the output stream in it (recon
C10)."
  (let ((server (mcp:make-server :name name :version version)))
    (dolist (tool (agent:make-agent-tools stores :write-store write-store
                                                 :producer producer
                                                 :sources sources
                                                 :k k :max-rows max-rows))
      (register-llm-tool server tool))
    (when query-tool
      (register-llm-tool server (%query-tool stores max-rows)))
    server))
