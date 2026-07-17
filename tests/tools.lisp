;;;; tests/tools.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(defmacro with-clean-registry (&body body)
  `(let ((cl-llm::*tools-registry* (make-hash-table :test 'equal)))
     ,@body))

(test deftool-defines-a-callable-lisp-function
  "deftool must expand to a plain defun -- nothing hidden."
  (with-clean-registry
    (eval '(llm:deftool tool-add ((a :type integer) (b :type integer))
            "Add two numbers."
            (+ a b)))
    (is (= 3 (funcall 'tool-add 1 2)))))

(test deftool-registers-the-tool
  (with-clean-registry
    (eval '(llm:deftool tool-noop () "Does nothing." nil))
    (let ((tool (llm:find-tool 'tool-noop)))
      (is (typep tool 'llm:tool))
      (is (string= "tool-noop" (llm:tool-name tool)))
      (is (string= "Does nothing." (llm:tool-description tool))))))

(test find-tool-accepts-symbol-string-and-object
  (with-clean-registry
    (eval '(llm:deftool tool-noop () "Does nothing." nil))
    (let ((tool (llm:find-tool 'tool-noop)))
      (is (eq tool (llm:find-tool "tool-noop")))
      (is (eq tool (llm:find-tool tool))))))

(test find-tool-signals-on-unknown-tool
  (with-clean-registry
    (signals c:llm-tool-error (llm:find-tool 'no-such-tool))))

(test schema-bare-symbol-is-required-string
  (let ((schema (cl-llm::derive-schema '(city))))
    (is (string= "object" (json:jget schema "type")))
    (is (string= "string" (json:jget schema "properties" "city" "type")))
    (is (equalp #("city") (json:jget schema "required")))))

(test schema-enum-parameter
  (let ((schema (cl-llm::derive-schema '((units :celsius :fahrenheit)))))
    (is (equalp #("celsius" "fahrenheit")
                (json:jget schema "properties" "units" "enum")))
    (is (string= "string" (json:jget schema "properties" "units" "type")))
    (is (equalp #("units") (json:jget schema "required")))))

(test schema-typed-parameter
  (let ((schema (cl-llm::derive-schema '((depth :type integer)))))
    (is (string= "integer" (json:jget schema "properties" "depth" "type")))
    (is (equalp #("depth") (json:jget schema "required")))))

(test schema-default-implies-optional
  (let ((schema (cl-llm::derive-schema '((limit :type integer :default 10)))))
    (is (string= "integer" (json:jget schema "properties" "limit" "type")))
    (is (= 10 (json:jget schema "properties" "limit" "default")))
    (is (equalp #() (json:jget schema "required"))
        ":default must imply optional")))

(test schema-explicit-optional
  (let ((schema (cl-llm::derive-schema '((note :type string :optional t)))))
    (is (equalp #() (json:jget schema "required")))))

(test schema-list-type
  (let ((schema (cl-llm::derive-schema '((ids :type (list string))))))
    (is (string= "array" (json:jget schema "properties" "ids" "type")))
    (is (string= "string" (json:jget schema "properties" "ids" "items" "type")))))

(test schema-boolean-and-number-types
  (let ((schema (cl-llm::derive-schema '((flag :type boolean) (score :type number)))))
    (is (string= "boolean" (json:jget schema "properties" "flag" "type")))
    (is (string= "number" (json:jget schema "properties" "score" "type")))))

(test schema-optional-marker-makes-rest-non-required
  (let ((schema (cl-llm::derive-schema '(city &optional (depth :type integer)))))
    (is (equalp #("city") (json:jget schema "required")))
    (is (string= "integer" (json:jget schema "properties" "depth" "type")))))

(test schema-rejects-unknown-type
  (signals error (cl-llm::derive-schema '((x :type frobnicate)))))

(test schema-mixed-parameters
  (let ((schema (cl-llm::derive-schema '(city (units :celsius :fahrenheit)
                                         (limit :type integer :default 10)))))
    (is (equalp #("city" "units") (json:jget schema "required")))
    (is (= 3 (hash-table-count (json:jget schema "properties"))))))

(test anthropic-encode-tool
  (with-clean-registry
    (eval '(llm:deftool tool-weather (city) "Look up weather." city))
    (let* ((p (test-anthropic-provider))
           (encoded (json:parse (json:to-json
                                 (llm:encode-tool p (llm:find-tool 'tool-weather))))))
      (is (string= "tool-weather" (json:jget encoded "name")))
      (is (string= "Look up weather." (json:jget encoded "description")))
      (is (string= "string" (json:jget encoded "input_schema" "properties" "city" "type"))))))

(test anthropic-encode-request-includes-tools
  (with-clean-registry
    (eval '(llm:deftool tool-weather (city) "Look up weather." city))
    (let* ((p (test-anthropic-provider))
           (c (llm:make-conversation :messages (list (llm:make-message :user "hi"))))
           (body (json:parse (llm:encode-request p c
                                                 :tools (list (llm:find-tool 'tool-weather))))))
      (is (string= "tool-weather" (json:jget body "tools" 0 "name"))))))

;;; Additional coverage beyond the brief.
;;;
;;; The brief flags a specific, unverified suspicion about POSITIONAL-ARGUMENTS
;;; as written: it reconstructs call order from the schema's "required" list
;;; (declaration order, preserved) plus the *remaining* properties sorted
;;; ALPHABETICALLY -- not in declaration order. Two optional parameters whose
;;; names are not already alphabetical get silently bound to the wrong Lisp
;;; parameter. This test is designed to fail against that implementation and
;;; pass only once ordering is recovered from the tool's own declaration
;;; order (e.g. a slot populated by DEFTOOL at macroexpansion time).
(test call-tool-binds-optional-arguments-by-declaration-order-not-alphabetical
  "Two optional parameters declared in non-alphabetical order (zebra before
apple) must still bind to the correct Lisp parameter when called by keyword;
resorting them alphabetically to reconstruct call order is a distinct bug from
resorting hash-table iteration order, and both must be avoided."
  (with-clean-registry
    (eval '(llm:deftool tool-zebra-apple
            ((zebra :type string :default "z") (apple :type string :default "a"))
            "Report zebra then apple, in that order."
            (list zebra apple)))
    (let ((tool (llm:find-tool 'tool-zebra-apple))
          (args (make-hash-table :test 'equal)))
      (setf (gethash "zebra" args) "Z")
      (setf (gethash "apple" args) "A")
      (is (equal '("Z" "A") (cl-llm::call-tool tool args))
          "ZEBRA must receive \"Z\" and APPLE must receive \"A\" regardless of ~
           alphabetical order or hash-table iteration order"))))

(test call-tool-handles-hyphenated-parameter-names
  "A schema property such as \"node-id\" must round-trip through keyword
interning -- (intern (string-upcase key) :keyword) on both the encode and
decode side -- to bind the NODE-ID lambda variable correctly."
  (with-clean-registry
    (eval '(llm:deftool tool-node-id ((node-id :type string))
            "Echo the given node-id."
            node-id))
    (let ((tool (llm:find-tool 'tool-node-id))
          (args (make-hash-table :test 'equal)))
      (setf (gethash "node-id" args) "abc123")
      (is (string= "abc123" (cl-llm::call-tool tool args))))))

(test call-tool-with-zero-parameters
  "deftool with an empty parameter list must define a callable nullary
function, and call-tool must invoke it with either an empty arguments
hash-table or NIL."
  (with-clean-registry
    (eval '(llm:deftool tool-noop () "Does nothing." :ok))
    (let ((tool (llm:find-tool 'tool-noop)))
      (is (eq :ok (cl-llm::call-tool tool (make-hash-table :test 'equal))))
      (is (eq :ok (cl-llm::call-tool tool nil))))))

(test call-tool-wraps-a-signalling-tool-body-in-llm-tool-error
  (with-clean-registry
    (eval '(llm:deftool tool-boom () "Always fails." (error "boom")))
    (let ((tool (llm:find-tool 'tool-boom)))
      (signals c:llm-tool-error (cl-llm::call-tool tool nil)))))
