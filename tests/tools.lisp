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

;;; Code review Findings 1-3 on the argument-binding path.
;;;
;;; All three are silent-corruption bugs, not loud errors: an omitted
;;; argument becomes NIL via GETF instead of the DEFUN's declared default; a
;;; NIL :default serializes as JSON "false"; and every model-supplied key is
;;; interned into :KEYWORD before being filtered, which is unbounded growth
;;; driven by untrusted input.

;;; Finding 1: omitted arguments must get their declared default (or signal
;;; on a missing required argument), never a silently-substituted NIL.

(test call-tool-fills-omitted-optional-with-its-declared-default
  "An omitted optional with a declared :default must receive that default,
the same value the DEFUN's lambda list would supply -- not NIL."
  (with-clean-registry
    (eval '(llm:deftool tool-limit ((limit :type integer :default 10))
            "Report the limit."
            limit))
    (let ((tool (llm:find-tool 'tool-limit))
          (args (make-hash-table :test 'equal)))
      (is (= 10 (cl-llm::call-tool tool args))
          "omitting LIMIT must yield its declared default 10, not NIL"))))

(test call-tool-signals-on-missing-required-argument
  "A required parameter the model did not supply must signal LLM-TOOL-ERROR
naming the tool and the missing parameter -- the tool body must never run
with a silently-NIL required argument."
  (with-clean-registry
    (eval '(llm:deftool tool-lookup ((node-id :type string) (depth :type integer :default 1))
            "Look up a node."
            (format nil "lookup ~a at depth ~a" node-id depth)))
    (let ((tool (llm:find-tool 'tool-lookup))
          (args (make-hash-table :test 'equal))
          (ran nil))
      (setf (gethash "depth" args) 3)
      (handler-case
          (progn (cl-llm::call-tool tool args) (setf ran t))
        (c:llm-tool-error (e)
          (is (string= "tool-lookup" (c:llm-error-tool-name e)))
          (is (search "node-id" (c:llm-error-underlying e))
              "the error must name the missing parameter")))
      (is (not ran) "the tool body must never run without its required argument"))))

(test call-tool-optional-not-truncated-when-earlier-optional-omitted
  "If an EARLIER optional is omitted but a LATER one is supplied, the earlier
one must still get its declared default and the later its supplied value --
the argument list must not simply be truncated to the supplied keys."
  (with-clean-registry
    (eval '(llm:deftool tool-two-optionals
            ((first-val :type integer :default 1) (second-val :type integer :default 2))
            "Report both."
            (list first-val second-val)))
    (let ((tool (llm:find-tool 'tool-two-optionals))
          (args (make-hash-table :test 'equal)))
      (setf (gethash "second-val" args) 99)
      (is (equal '(1 99) (cl-llm::call-tool tool args))
          "FIRST-VAL must still default to 1 while SECOND-VAL binds to the ~
           supplied 99"))))

(test call-tool-distinguishes-json-false-from-absent
  "A supplied value of JSON false (which reads as NIL) must be distinguishable
from an omitted argument: the former must bind to NIL, the latter to the
declared default."
  (with-clean-registry
    (eval '(llm:deftool tool-flag ((flag :type boolean :default t))
            "Report the flag."
            flag))
    (let ((tool (llm:find-tool 'tool-flag))
          (supplied-false (make-hash-table :test 'equal))
          (omitted (make-hash-table :test 'equal)))
      (setf (gethash "flag" supplied-false) nil)
      (is (eq nil (cl-llm::call-tool tool supplied-false))
          "an explicitly-supplied JSON false must bind to NIL, not the default")
      (is (eq t (cl-llm::call-tool tool omitted))
          "an omitted FLAG must bind to its declared default T"))))

(test call-tool-omitted-optional-without-default-yields-nil
  "An optional declared without :default (via :optional t) must yield NIL
when omitted, matching its DEFUN default."
  (with-clean-registry
    (eval '(llm:deftool tool-note ((note :type string :optional t))
            "Report the note."
            note))
    (let ((tool (llm:find-tool 'tool-note))
          (args (make-hash-table :test 'equal)))
      (is (eq nil (cl-llm::call-tool tool args))))))

;;; Finding 2: a NIL :default must not serialize as JSON "false".

(test schema-nil-default-omits-the-default-key
  "A NIL :default (e.g. an array-typed parameter with no natural default)
must not appear in the schema at all -- writing straight into the schema
hash-table bypasses JOBJECT/JVALUE's nil-omission convention and previously
serialized as the nonsense \"default\": false."
  (let* ((schema (cl-llm::derive-schema '((tags :type (list string) :default nil))))
         (prop (json:jget schema "properties" "tags")))
    (multiple-value-bind (value presentp) (gethash "default" prop)
      (declare (ignore value))
      (is (not presentp)
          "a NIL :default must omit the \"default\" key entirely"))))

(test schema-falsy-non-nil-defaults-still-serialize
  "0 and \"\" are not NIL and must survive as real schema defaults."
  (let ((schema (cl-llm::derive-schema '((count :type integer :default 0)
                                         (label :type string :default "")))))
    (is (= 0 (json:jget schema "properties" "count" "default")))
    (is (string= "" (json:jget schema "properties" "label" "default")))))

(test schema-keyword-false-default-round-trips-as-json-false
  "A :default :false must serialize as a real JSON boolean false (surviving a
round trip through the same JOBJECT/JVALUE convention the rest of the
codebase uses), not error and not silently uppercase to \"FALSE\"."
  (let* ((schema (cl-llm::derive-schema '((flag :type boolean :default :false))))
         (round-tripped (json:parse (json:to-json schema)))
         (flag-schema (json:jget round-tripped "properties" "flag")))
    (multiple-value-bind (value presentp) (gethash "default" flag-schema)
      (is (eq t presentp) "the default key must survive serialization")
      (is (eq nil value) "JSON false decodes back to NIL"))))

;;; Finding 3: unrecognized model-supplied keys must never be interned.

(test call-tool-does-not-intern-unknown-model-supplied-keys
  "An unrecognized key from the model must be ignored without ever being
interned into the :KEYWORD package -- keywords are not garbage-collected, and
tool arguments are untrusted input."
  (with-clean-registry
    (eval '(llm:deftool tool-echo (city) "Echo city." city))
    (let* ((tool (llm:find-tool 'tool-echo))
           (args (make-hash-table :test 'equal))
           (junk-name (symbol-name (gensym "JUNK-TOOL-ARG-"))))
      (setf (gethash "city" args) "Boston")
      (setf (gethash junk-name args) "ignored")
      (is (string= "Boston" (cl-llm::call-tool tool args)))
      (is (not (find-symbol junk-name :keyword))
          "an unrecognized argument key must never be interned into :KEYWORD"))))
