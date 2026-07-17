;;;; tests/json.lisp

(in-package #:cl-llm.test)

(in-suite cl-llm-suite)

(test json-parse-normalizes-null
  "JSON null must read as NIL, not the CL:NULL symbol jzon returns."
  (let ((h (json:parse "{\"a\":null,\"b\":1}")))
    (is (null (gethash "a" h)))
    (is (= 1 (gethash "b" h)))))

(test json-parse-normalizes-nested-null
  "Normalization must reach into nested objects and arrays."
  (let ((h (json:parse "{\"a\":{\"b\":null},\"c\":[null,2]}")))
    (is (null (json:jget h "a" "b")))
    (is (null (json:jget h "c" 0)))
    (is (= 2 (json:jget h "c" 1)))))

(test json-parse-booleans
  (let ((h (json:parse "{\"t\":true,\"f\":false}")))
    (is (eq t (gethash "t" h)))
    (is (null (gethash "f" h)))))

(test jobject-omits-nil-values
  "A nil value must be omitted entirely, NOT emitted as false."
  (let ((s (json:to-json (json:jobject :model "m" :temperature nil))))
    (is (string= "{\"model\":\"m\"}" s))))

(test jobject-converts-keyword-keys
  (let ((s (json:to-json (json:jobject :max-tokens 5))))
    (is (string= "{\"max_tokens\":5}" s))))

(test jobject-passes-string-keys-verbatim
  (let ((s (json:to-json (json:jobject "node-id" "n1"))))
    (is (string= "{\"node-id\":\"n1\"}" s))))

(test jobject-explicit-booleans
  (let ((s (json:to-json (json:jobject :stream :false :echo :true))))
    (is (string= "{\"stream\":false,\"echo\":true}" s))))

(test jget-chains-and-misses
  (let ((h (json:parse "{\"content\":[{\"text\":\"hi\"}]}")))
    (is (string= "hi" (json:jget h "content" 0 "text")))
    (is (null (json:jget h "content" 9 "text")))
    (is (null (json:jget h "nope" "deeper")))))

(test jarray-builds-vector
  (is (string= "[1,2]" (json:to-json (json:jarray 1 2)))))
