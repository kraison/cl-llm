;;;; json.lisp -- the only file that knows about jzon.
;;;;
;;;; jzon has three behaviours that will silently corrupt requests if used
;;;; directly, so they are contained here:
;;;;   1. JSON null parses to the symbol CL:NULL, not NIL.
;;;;   2. (stringify nil) emits "false", not "null" -- so a nil-valued optional
;;;;      parameter would be sent as an explicit false.
;;;;   3. Keywords stringify uppercased (:foo => "FOO").

(in-package #:cl-llm.json)

(defun normalize (value)
  "Recursively replace JSON null (the symbol CL:NULL) with NIL.
JSON false also reads as NIL, so the two are indistinguishable after parsing.
That is acceptable for provider responses and is the documented behaviour."
  (cond
    ((eq value 'null) nil)
    ((hash-table-p value)
     (let ((new (make-hash-table :test 'equal :size (hash-table-count value))))
       (maphash (lambda (k v) (setf (gethash k new) (normalize v))) value)
       new))
    ((and (vectorp value) (not (stringp value)))
     (map 'vector #'normalize value))
    (t value)))

(defun parse (input)
  "Parse INPUT (a string or character stream) into hash-tables and vectors.
JSON null is normalized to NIL."
  (normalize (jzon:parse input)))

(defun to-json (value &key pretty)
  "Serialize VALUE to a JSON string."
  (jzon:stringify value :stream nil :pretty pretty))

(defun jkey (key)
  "Convert KEY to a JSON object key.
Strings pass through verbatim. Symbols and keywords are downcased and have
hyphens converted to underscores, so :MAX-TOKENS becomes \"max_tokens\"."
  (if (stringp key)
      key
      (substitute #\_ #\- (string-downcase (string key)))))

(defun jvalue (value)
  "Convert VALUE to something jzon will serialize correctly.
:TRUE and :FALSE become real JSON booleans; every other keyword is an error,
because jzon would silently uppercase it."
  (case value
    (:true t)
    (:false nil)
    (t (if (keywordp value)
           (error "Cannot serialize keyword ~s as a JSON value; jzon would ~
                   uppercase it. Pass a string, or :TRUE/:FALSE for booleans."
                  value)
           value))))

(defun jobject (&rest plist)
  "Build a JSON object from PLIST, OMITTING any key whose value is NIL.
Omission (rather than emitting null) is what optional API parameters require.
Use :TRUE or :FALSE for an explicit boolean."
  (let ((object (make-hash-table :test 'equal)))
    (loop for (key value) on plist by #'cddr
          unless (null value)
            do (setf (gethash (jkey key) object) (jvalue value)))
    object))

(defun jarray (&rest elements)
  "Build a JSON array from ELEMENTS."
  (map 'vector #'jvalue elements))

(defun jget (object &rest keys)
  "Look up a chained path through OBJECT.
String keys index hash-tables; integers index vectors. Returns NIL if any step
misses, so (jget response \"content\" 0 \"text\") is safe on any shape."
  (let ((current object))
    (dolist (key keys current)
      (setf current
            (cond
              ((null current) (return nil))
              ((hash-table-p current) (gethash (jkey key) current))
              ((and (vectorp current) (not (stringp current)) (integerp key))
               (when (< -1 key (length current))
                 (aref current key)))
              (t (return nil)))))))
