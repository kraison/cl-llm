;;;; tests-agent-mcp/identity-tests.lisp -- principals, the hello, the
;;;; bind rule.  Spec SS5.

(in-package #:cl-llm.agent.mcp/tests)
(in-suite :cl-llm-agent-mcp)

(defun %write-principals (root entries)
  (let ((path (concatenate 'string root "principals.sexp")))
    (ensure-directories-exist path)
    (with-open-file (s path :direction :output :if-exists :supersede)
      (prin1 entries s))
    path))

(defun %hello (principal secret)
  (format nil "{\"cl-llm-memory\": {\"principal\": ~s, \"secret\": ~s}}"
          principal secret))

(test principals-are-canonical-producers-with-secrets
  "SS5: the file is ((producer . secret) ...); a non-canonical producer
or a non-string secret is refused; a missing file is NIL."
  (with-scratch-root (root)
    (is (equal '(("claude-code/laptop" . "s1"))
               (mcp:read-principals
                (%write-principals root '(("claude-code/laptop" . "s1"))))))
    (signals error
      (mcp:read-principals (%write-principals root '(("Bad Name" . "s")))))
    (signals error
      (mcp:read-principals (%write-principals root '(("a/b" . 42)))))
    (is (null (mcp:read-principals (%sub root "absent.sexp"))))))

(test a-hello-line-parses-and-other-lines-do-not
  (multiple-value-bind (principal secret)
      (mcp:parse-hello (%hello "claude-code/laptop" "s1"))
    (is (string= "claude-code/laptop" principal))
    (is (string= "s1" secret)))
  (is (mcp:hello-line-p (%hello "a/b" "c")))
  (is (not (mcp:hello-line-p
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"))
      "control: a JSON-RPC line is not a hello")
  (is (not (mcp:hello-line-p "not json"))))

(test resolve-identity-under-the-secret-provider
  "SS5: a matching hello names its principal; a wrong secret, a hello
for an unknown principal, and no hello off loopback are refused; no
hello on loopback is the default."
  (let ((principals '(("claude-code/laptop" . "s1")))
        (lo #(127 0 0 1))
        (far #(10 0 0 7)))
    (is (string= "claude-code/laptop"
                 (mcp:resolve-identity
                  :secret (%hello "claude-code/laptop" "s1")
                  far "default/host" principals)))
    (is (eq :refused (mcp:resolve-identity
                      :secret (%hello "claude-code/laptop" "wrong")
                      lo "default/host" principals)))
    (is (eq :refused (mcp:resolve-identity
                      :secret (%hello "nobody/here" "s1")
                      lo "default/host" principals)))
    (is (string= "default/host"
                 (mcp:resolve-identity :secret nil lo "default/host"
                                       principals))
        "no hello on loopback: the default")
    (is (eq :refused (mcp:resolve-identity :secret nil far "default/host"
                                           principals))
        "no hello off loopback: refused")))

(test a-non-loopback-bind-needs-principals
  "SS5: the configuration validator refuses an open listener with the
default identity; loopback needs nothing, and principals unlock any
address."
  (signals error (mcp:check-bind "0.0.0.0" nil))
  (is (string= "0.0.0.0" (mcp:check-bind "0.0.0.0" '(("a/b" . "s")))))
  (is (string= "127.0.0.1" (mcp:check-bind "127.0.0.1" nil)) "control"))
