;;;; tools.lisp -- deftool and JSON schema derivation.
;;;;
;;;; A tool is an ordinary Lisp function: deftool expands to a plain DEFUN plus
;;;; a registration form, and the tool loop calls it in-process. Tool bodies
;;;; therefore close over whatever a normal function closes over -- live
;;;; database handles, open transactions, special bindings.
;;;;
;;;; SECURITY: the MODEL chooses the arguments. A narrow tool is bounded by its
;;;; schema; a general escape hatch such as (deftool run-query (sql) ...) is
;;;; not, and grants the model arbitrary execution. Prefer narrow tools, and
;;;; treat every argument as untrusted input.

(in-package #:cl-llm)

(defclass tool ()
  ((name :initarg :name :reader tool-name :type string)
   (description :initarg :description :reader tool-description :type string)
   (schema :initarg :schema :reader tool-schema
           :documentation "A JSON Schema object describing the parameters.")
   (function :initarg :function :reader tool-function)
   (parameter-names :initarg :parameter-names :reader tool-parameter-names
                     :initform nil
                     :documentation "Parameter names, as downcased strings, in
the declaration order recorded by DEFTOOL at macroexpansion time. CALL-TOOL
uses this -- rather than re-deriving order from the schema's \"required\" list
plus an alphabetical sort of whatever remains -- because a hash-table's
iteration order is unspecified and an alphabetical sort does not match the
Lisp function's actual (declaration-order) lambda list. Both would silently
swap two optional parameters declared out of alphabetical order."))
  (:documentation "A Lisp function the model may call, plus its schema."))

(defvar *tools-registry* (make-hash-table :test 'equal)
  "Maps tool name (string) to TOOL.")

(defun register-tool (tool)
  (setf (gethash (tool-name tool) *tools-registry*) tool))

(defun unregister-tool (name)
  (remhash (string-downcase (string name)) *tools-registry*))

(defun find-tool (designator)
  "Resolve DESIGNATOR -- a TOOL, a symbol, or a string -- to a TOOL."
  (etypecase designator
    (tool designator)
    ((or symbol string)
     (let ((name (string-downcase (string designator))))
       (or (gethash name *tools-registry*)
           (error 'c:llm-tool-error
                  :tool-name name
                  :underlying "No such tool is registered. Define it with deftool."))))))

;;; Schema derivation

(defun json-type-name (type)
  "Map a cl-llm parameter type to a JSON Schema type name."
  (case type
    (string "string")
    (integer "integer")
    (number "number")
    (boolean "boolean")
    (t (error "Unsupported tool parameter type ~s. Use string, integer, ~
               number, boolean, or (list <type>)." type))))

(defun type-schema (type)
  "The JSON Schema fragment for TYPE."
  (if (and (consp type) (eq (first type) 'list))
      (json:jobject :type "array"
                    :items (json:jobject :type (json-type-name (second type))))
      (json:jobject :type (json-type-name type))))

(defun enum-spec-p (spec)
  "True when SPEC is an enum, e.g. (units :celsius :fahrenheit).
A spec list is distinguished by its second element being :type, :default, or
:optional; anything else keyword-ish is an enum member."
  (and (consp spec)
       (cdr spec)
       (not (member (second spec) '(:type :default :optional)))))

(defun parameter-schema (spec)
  "Return (values NAME SCHEMA REQUIRED-P) for one parameter SPEC."
  (cond
    ;; Bare symbol: required string.
    ((symbolp spec)
     (values (string-downcase (string spec)) (json:jobject :type "string") t))
    ;; Enum: (units :celsius :fahrenheit)
    ((enum-spec-p spec)
     (values (string-downcase (string (first spec)))
             (json:jobject :type "string"
                           :enum (map 'vector
                                      (lambda (v) (string-downcase (string v)))
                                      (rest spec)))
             t))
    ;; Spec list: (depth :type integer :default 1 :optional t)
    ((consp spec)
     (destructuring-bind (name &key (type 'string) (default nil default-p)
                                    (optional nil))
         spec
       (let ((schema (type-schema type)))
         (when default-p
           (setf (gethash "default" schema) default))
         (values (string-downcase (string name))
                 schema
                 (not (or optional default-p))))))
    (t (error "Malformed tool parameter specification: ~s" spec))))

(defun derive-schema (parameters)
  "Derive a JSON Schema object from a deftool lambda list."
  (let ((properties (make-hash-table :test 'equal))
        (required '())
        (all-optional nil))
    (dolist (spec parameters)
      (cond
        ((eq spec '&optional) (setf all-optional t))
        ((member spec '(&key &rest))
         (error "~s is not supported in a deftool lambda list. Tools are called ~
                 positionally from a decoded JSON object; use :optional or ~
                 :default to make a parameter optional." spec))
        (t
         (multiple-value-bind (name schema requiredp) (parameter-schema spec)
           (setf (gethash name properties) schema)
           (when (and requiredp (not all-optional))
             (push name required))))))
    (json:jobject :type "object"
                  :properties properties
                  :required (coerce (nreverse required) 'vector))))

;;; deftool

(defun parameter-lambda-variable (spec)
  "The Lisp variable name for one parameter SPEC."
  (if (symbolp spec) spec (first spec)))

(defun optional-spec-p (spec)
  "True when SPEC declares :default or :optional, and so cannot be a required
positional parameter."
  (and (consp spec)
       (not (enum-spec-p spec))
       (destructuring-bind (name &key type (default nil default-p) optional)
           spec
         (declare (ignore name type))
         (or default-p optional (and default t)))))

(defun parameter-lambda-list (parameters)
  "Convert a deftool lambda list into an ordinary Lisp lambda list.
An &OPTIONAL marker is inserted automatically before the first optional
parameter, because (defun f (a (b 10))) is a syntax error -- a default is only
legal after &optional."
  (let ((result '())
        (in-optional nil))
    (dolist (spec parameters (nreverse result))
      (cond
        ((eq spec '&optional)
         (unless in-optional (setf in-optional t) (push '&optional result)))
        ((member spec '(&key &rest))
         (error "~s is not supported in a deftool lambda list; use :optional or ~
                 :default instead." spec))
        (t
         (let ((variable (parameter-lambda-variable spec)))
           (cond
             ((optional-spec-p spec)
              (unless in-optional (setf in-optional t) (push '&optional result))
              (let ((default (getf (rest spec) :default)))
                (push (if default (list variable default) variable) result)))
             (in-optional (push variable result))
             (t (push variable result)))))))))

(defun parameter-names (parameters)
  "The Lisp variable names PARAMETERS declares, as downcased strings, in
declaration order. This is the order CALL-TOOL uses to turn the model's
decoded JSON object back into a positional argument list; it must match
PARAMETER-LAMBDA-LIST's variable order exactly, so it is derived the same way
-- by walking PARAMETERS once, skipping only the &OPTIONAL marker (DEFTOOL
rejects &KEY and &REST elsewhere)."
  (loop for spec in parameters
        unless (eq spec '&optional)
          collect (string-downcase (string (parameter-lambda-variable spec)))))

(defmacro deftool (name parameters docstring &body body)
  "Define NAME as an ordinary function AND register it as a tool the model may
call. The JSON schema is derived from PARAMETERS and DOCSTRING.

PARAMETERS entries are one of:
  city                          -- required string
  (units :celsius :fahrenheit)  -- required enum
  (depth :type integer)         -- required integer
  (limit :type integer :default 10) -- optional, defaulted
  (ids :type (list string))     -- required array of strings
  (note :type string :optional t)   -- optional

Types: string, integer, number, boolean, (list <type>).

The expansion is a plain DEFUN plus a REGISTER-TOOL call -- nothing is hidden,
and the function remains callable directly from Lisp."
  (check-type docstring string "a docstring: the model relies on it to decide
when to call this tool")
  (let ((lambda-list (parameter-lambda-list parameters)))
    `(progn
       (defun ,name ,lambda-list
         ,docstring
         ,@body)
       (register-tool
        (make-instance 'tool
                       :name ,(string-downcase (string name))
                       :description ,docstring
                       :schema (derive-schema ',parameters)
                       :function #',name
                       :parameter-names ',(parameter-names parameters)))
       ',name)))

;;; Calling

(defun positional-arguments (tool plist)
  "Order PLIST's values to match TOOL's declared parameter order.
The model returns a JSON object; the Lisp function takes positional
arguments, so DEFTOOL's declaration order -- recorded on TOOL at
macroexpansion time via PARAMETER-NAMES, not reconstructed from the schema's
hash-table property order -- is the contract."
  (loop for name in (tool-parameter-names tool)
        collect (getf plist (intern (string-upcase name) :keyword))))

(defun call-tool (tool arguments)
  "Invoke TOOL with ARGUMENTS, a hash-table of decoded JSON arguments.
Signals LLM-TOOL-ERROR if the tool body signals, so a misbehaving tool cannot
crash the loop opaquely."
  (let ((values '()))
    (maphash (lambda (key value)
               (push (intern (string-upcase key) :keyword) values)
               (push value values))
             (or arguments (make-hash-table :test 'equal)))
    (handler-case
        (apply (tool-function tool) (positional-arguments tool (nreverse values)))
      (c:llm-error (e) (error e))
      (error (e)
        (error 'c:llm-tool-error :tool-name (tool-name tool)
                                 :underlying (princ-to-string e))))))
