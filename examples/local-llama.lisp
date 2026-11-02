;;;; local-llama.lisp -- drive a model served by a local llama-server.
;;;;
;;;; Load this file, then: (examples/local-llama:run)
;;;;
;;;; Expects llama-server already running and OpenAI-compatible, e.g.
;;;;   llama-server -m MODEL.gguf --jinja --api-key-file KEY \
;;;;                --host 127.0.0.1 --port 8080
;;;; --jinja gives tool calls; the key file is optional.  cl-llm does not
;;;; start servers.  Two things differ from a hosted model:
;;;;  - a cold first reply includes loading the model, so the timeout is
;;;;    raised well past cl-llm's 60 s default;
;;;;  - a reasoning model spends tokens thinking before it answers, and
;;;;    max-tokens covers both, so it needs headroom or the answer comes
;;;;    back empty with stop reason :MAX-TOKENS.

(ql:quickload :cl-llm)

(defpackage #:examples/local-llama
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run #:provider))

(in-package #:examples/local-llama)

(defun provider (&key (base-url "http://127.0.0.1:8080/v1")
                      (model "local")
                      key-file)
  "An openai-compatible-provider for llama-server at BASE-URL.  MODEL is
the server's alias; KEY-FILE, when given, holds its API key."
  (make-instance 'llm:openai-compatible-provider
                 :base-url base-url
                 :model model
                 :api-key (and key-file
                               (string-trim '(#\Space #\Newline #\Return)
                                            (uiop:read-file-line key-file)))))

(llm:deftool add-integers ((a :type integer) (b :type integer))
  "Add two integers together."
  (+ a b))

(defun run (&key (base-url "http://127.0.0.1:8080/v1") (model "local")
                 key-file)
  (let ((llm:*provider* (provider :base-url base-url :model model
                                  :key-file key-file))
        (llm:*timeout* 300)                ; a cold load takes minutes
        (llm:*max-tokens* 12000))          ; reasoning shares the budget
    ;; 1. One question.  The reasoning stays out of the text.
    (format t "~&--- ask ---~%~a~%"
            (llm:ask "In one sentence, what is Common Lisp?"))

    ;; 2. A conversation: the second turn sees the first.
    (let ((c (llm:make-conversation :provider llm:*provider*
                                    :system "You are terse.")))
      (llm:send c "My name is Ada.")
      (format t "~&--- conversation ---~%~a~%"
              (llm:response-text (llm:send c "What is my name?"))))

    ;; 3. A tool, run in this image by the tool loop.
    (format t "~&--- tool ---~%~a~%"
            (llm:ask "Use add-integers to add 17 and 25. Just the number."
                     :tools '(add-integers)))

    ;; 4. Streaming, pulled one delta at a time.
    (format t "~&--- streaming ---~%")
    (llm:with-streamed-response (r "Count from one to five in words.")
      (llm:do-deltas (d r)
        (write-string d)
        (force-output)))
    (terpri)))
