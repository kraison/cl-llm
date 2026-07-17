;;;; tools.lisp -- define tools in Lisp; the model calls them, in-process.
;;;;
;;;; DEFTOOL defines the entire tool surface in Lisp: it expands to a plain
;;;; DEFUN plus a registration form, and the tool loop calls that function
;;;; IN-PROCESS, in your own image. So a tool body closes over whatever an
;;;; ordinary function closes over -- live database handles, open transactions,
;;;; special bindings. Nothing leaves the image except the model's chosen
;;;; arguments.
;;;;
;;;; The JSON schema the model sees is derived from the typed lambda list.
;;;;
;;;; Load this file, then: (examples/tools:run)

(ql:quickload :cl-llm)

(defpackage #:examples/tools
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm))
  (:export #:run))

(in-package #:examples/tools)

(defun provider ()
  ;; Use a tool-capable model. qwen2.5 supports tool calling; so do the
  ;; gpt-oss:*-cloud models (see ollama-cloud.lisp).
  (make-instance 'llm:openai-compatible-provider
                 :base-url "http://localhost:11434/v1"
                 :model    "qwen2.5:7b"))

;;; Parameter forms (all derived into JSON schema):
;;;   city                          -- required string
;;;   (units :celsius :fahrenheit)  -- required enum
;;;   (depth :type integer)         -- required integer
;;;   (limit :type integer :default 10) -- optional, defaulted
;;;   (ids :type (list string))     -- required array of strings
;;;   (note :type string :optional t)   -- optional
;;; Types: string, integer, number, boolean, (list <type>).

(defvar *audit* nil "Proof the tool bodies actually ran, in-process.")

(llm:deftool get-weather (city (units :celsius :fahrenheit))
  "Get the current weather for a city."
  (push (list :weather city units) *audit*)
  ;; A real body might hit an API or a database; here we just fabricate.
  (format nil "~a: 18 degrees ~a, overcast" city (string-downcase (string units))))

(llm:deftool multiply ((a :type integer) (b :type integer))
  "Multiply two integers."
  (push (list :multiply a b) *audit*)
  (* a b))

;;; The in-process pattern that motivates the whole design: a tool body that
;;; closes over live application state. Swap this stub for a real store
;;; (e.g. a graph query against an in-memory database).
(defparameter *graph*
  '((n1 . (n2 n3)) (n2 . (n4)) (n3 . (n4 n5))))

(llm:deftool find-related (node-id (depth :type integer :default 1))
  "Find nodes directly related to a node in the knowledge graph."
  (declare (ignore depth))
  (push (list :graph node-id) *audit*)
  (let ((neighbors (cdr (assoc (intern (string-upcase node-id)) *graph*))))
    (if neighbors
        (format nil "~a is connected to: ~{~a~^, ~}" node-id neighbors)
        (format nil "~a has no known connections" node-id))))

(defun run ()
  (setf llm:*provider* (provider))
  (setf *audit* nil)

  ;; The tool loop runs automatically: model requests a tool, cl-llm executes it,
  ;; feeds the result back, and repeats -- bounded by *max-tool-turns* (default 8)
  ;; so a runaway model cannot loop forever.

  (format t "~&--- weather (enum arg) ---~%~a~%"
          (llm:ask "What's the weather in Oakland in celsius? Use the tool."
                   :tools '(get-weather)))

  (format t "~&--- arithmetic (typed integer args) ---~%~a~%"
          (llm:ask "Use the multiply tool for 23 times 19." :tools '(multiply)))

  (format t "~&--- graph query (tool closes over *graph*) ---~%~a~%"
          (llm:ask "What is node n1 connected to? Use find-related."
                   :tools '(find-related)))

  ;; Everything the model invoked, proving it ran in your image:
  (format t "~&--- tools actually invoked in-process ---~%~{  ~s~%~}"
          (reverse *audit*))
  ;; => (:WEATHER "Oakland" "celsius") (:MULTIPLY 23 19) (:GRAPH "n1")

  (values))

;;; Security note: the MODEL chooses the arguments. A narrow tool like
;;; find-related is bounded by its schema. A general escape hatch such as
;;; (deftool run-query (sql) ...) would hand the model arbitrary execution
;;; against your store -- a legitimate choice, but a deliberate one. Prefer
;;; narrow, purpose-specific tools, and treat tool arguments as untrusted input.

;; (examples/tools:run)
