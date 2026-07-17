;;;; tests/protocol.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test provider-hierarchy
  (is (subtypep 'llm:anthropic-provider 'llm:provider))
  (is (subtypep 'llm:openai-compatible-provider 'llm:provider)))

(test anthropic-default-model-and-endpoint
  (let ((p (make-instance 'llm:anthropic-provider)))
    (is (string= "claude-opus-4-8" (llm:provider-default-model p)))
    (is (string= "https://api.anthropic.com/v1/messages" (llm:provider-endpoint p)))))

(test anthropic-base-url-is-overridable
  (let ((p (make-instance 'llm:anthropic-provider :base-url "http://localhost:8080")))
    (is (string= "http://localhost:8080/v1/messages" (llm:provider-endpoint p)))))

(test provider-model-slot-overrides-default
  (let ((p (make-instance 'llm:anthropic-provider :model "claude-haiku-4-5-20251001")))
    (is (string= "claude-haiku-4-5-20251001" (llm:provider-model p)))))

(test openai-compatible-endpoint
  (let ((p (make-instance 'llm:openai-compatible-provider
                          :base-url "http://localhost:11434/v1" :model "llama3.1")))
    (is (string= "http://localhost:11434/v1/chat/completions" (llm:provider-endpoint p)))
    (is (string= "llama3.1" (llm:provider-default-model p)))))

(test openai-compatible-requires-base-url
  (signals error (make-instance 'llm:openai-compatible-provider)))

(test anthropic-api-key-from-explicit-initarg
  (let ((p (make-instance 'llm:anthropic-provider :api-key "sk-test")))
    (is (string= "sk-test" (llm:provider-api-key p)))))

(test anthropic-missing-api-key-signals-auth-error
  "With no initarg and no environment variable, asking for the key must fail
loudly rather than send an unauthenticated request."
  (let ((p (make-instance 'llm:anthropic-provider))
        (cl-llm::*getenv-function* (constantly nil)))
    (signals c:llm-auth-error (llm:provider-api-key p))))

(test anthropic-api-key-from-environment
  (let ((p (make-instance 'llm:anthropic-provider))
        (cl-llm::*getenv-function*
          (lambda (name) (when (string= name "ANTHROPIC_API_KEY") "sk-env"))))
    (is (string= "sk-env" (llm:provider-api-key p)))))

(test openai-compatible-api-key-is-optional
  "A local server needs no key; requiring one would break the primary use case."
  (let ((p (make-instance 'llm:openai-compatible-provider :base-url "http://x/v1"))
        (cl-llm::*getenv-function* (constantly nil)))
    (is (null (llm:provider-api-key p)))))

(test anthropic-headers-carry-key-and-version
  (let* ((p (make-instance 'llm:anthropic-provider :api-key "sk-test"))
         (headers (llm:provider-headers p)))
    (is (string= "sk-test" (cdr (assoc "x-api-key" headers :test #'string-equal))))
    (is (string= "2023-06-01" (cdr (assoc "anthropic-version" headers :test #'string-equal))))
    (is (string= "application/json"
                 (cdr (assoc "content-type" headers :test #'string-equal))))))

(test openai-compatible-headers-omit-auth-without-key
  (let* ((p (make-instance 'llm:openai-compatible-provider :base-url "http://x/v1"))
         (cl-llm::*getenv-function* (constantly nil)))
    (is (null (assoc "authorization" (llm:provider-headers p) :test #'string-equal)))))
