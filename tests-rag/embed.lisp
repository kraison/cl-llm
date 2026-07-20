;;;; tests-rag/embed.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(test embed-mock-is-deterministic
  (let ((e (rag:make-mock-embedder)))
    (is (equalp (rag:embed e "TM-62 landmine") (rag:embed e "TM-62 landmine")))
    (is (not (equalp (rag:embed e "TM-62 landmine") (rag:embed e "butterfly mine"))))))

(test embed-mock-word-overlap-is-more-similar
  "Shared words -> higher cosine, so retrieval tests are meaningful."
  (flet ((cosine (a b)
           (let ((dot (loop for x across a for y across b sum (* x y))))
             dot)))                      ; both are unit vectors, so dot = cosine
    (let* ((e (rag:make-mock-embedder))
           (q (rag:embed e "TM-62 fuze"))
           (near (rag:embed e "the TM-62 fuze is dangerous"))
           (far (rag:embed e "weather forecast tomorrow")))
      (is (> (cosine q near) (cosine q far))))))

(test embed-mock-vector-is-unit-length
  (let* ((e (rag:make-mock-embedder))
         (v (rag:embed e "anything")))
    (is (typep v '(simple-array double-float (*))))
    (is (< (abs (- 1.0d0 (sqrt (loop for x across v sum (* x x))))) 1d-9))))

(test embed-mock-batch-preserves-order
  (let* ((e (rag:make-mock-embedder))
         (vs (rag:embed e (list "a" "b" "c"))))
    (is (= 3 (length vs)))
    (is (equalp (first vs) (rag:embed e "a")))
    (is (equalp (third vs) (rag:embed e "c")))))

(test encode-embedding-request-shape
  (let ((body (json:parse (rag::encode-embedding-request "nomic" (list "x" "y")))))
    (is (string= "nomic" (json:jget body "model")))
    (is (string= "x" (json:jget body "input" 0)))
    (is (string= "y" (json:jget body "input" 1)))))

(test decode-embedding-response-orders-by-index
  "The API may return items out of order; decode must sort by index."
  (let* ((parsed (json:parse
                  "{\"data\":[{\"embedding\":[0.0,1.0],\"index\":1},
                              {\"embedding\":[1.0,0.0],\"index\":0}],\"model\":\"m\"}"))
         (vectors (rag::decode-embedding-response parsed)))
    (is (= 2 (length vectors)))
    (is (equalp (coerce #(1.0d0 0.0d0) '(simple-array double-float (*)))
                (first vectors)))
    (is (equalp (coerce #(0.0d0 1.0d0) '(simple-array double-float (*)))
                (second vectors)))))

(test openai-embedder-builds-embeddings-endpoint
  (let ((e (rag:make-openai-compatible-embedder
            :base-url "http://localhost:11434/v1" :model "nomic-embed-text")))
    (is (string= "http://localhost:11434/v1/embeddings" (rag::embedder-endpoint e)))
    (is (string= "http://localhost:11434/v1/embeddings"
                 (rag::embedder-endpoint
                  (rag:make-openai-compatible-embedder
                   :base-url "http://localhost:11434/v1/" :model "m")))
        "a trailing slash is stripped")))

;;; A minimal, self-contained fake HTTP driver for offline testing of the
;;; integrated EMBED method's request/response wiring. Deliberately not
;;; shared with cl-llm/tests, to avoid a cross-test-system dependency.
;;;
;;; cl-llm.http is not locally-nicknamed in this package (see packages.lisp),
;;; so it is referenced by its full package name throughout.

(defclass fake-embed-driver (cl-llm.http:driver)
  ((body :initarg :body :reader fake-body)
   (last-url :initform nil :accessor fake-last-url)
   (last-content :initform nil :accessor fake-last-content)
   (last-headers :initform nil :accessor fake-last-headers)))

(defmethod cl-llm.http:perform-request ((driver fake-embed-driver) url
                                        &key method headers content timeout)
  (declare (ignore method timeout))
  (setf (fake-last-url driver) url
        (fake-last-content driver) content
        (fake-last-headers driver) headers)
  ;; The driver contract: (values body status headers), and it must never
  ;; signal on a 2xx status.
  (values (fake-body driver) 200 nil))

(defparameter +canned-embeddings-response+
  "{\"data\":[{\"embedding\":[1.0,0.0],\"index\":0},
              {\"embedding\":[0.0,1.0],\"index\":1}],\"model\":\"m\"}"
  "A canned OpenAI-compatible embeddings response for two input texts.")

(test embed-openai-compatible-round-trip
  "The integrated EMBED method on OPENAI-COMPATIBLE-EMBEDDER, exercised
offline via a fake HTTP driver -- endpoint building, header building,
request encoding, RETRY-REQUEST-WITH dispatch, and response decoding all
wired together correctly."
  (let ((driver (make-instance 'fake-embed-driver :body +canned-embeddings-response+))
        (e (rag:make-openai-compatible-embedder :base-url "http://x/v1" :model "m")))
    (let ((vectors (let ((cl-llm.http:*driver* driver))
                     (rag:embed e (list "a" "b")))))
      (is (= 2 (length vectors)))
      (is (equalp (coerce #(1.0d0 0.0d0) '(simple-array double-float (*)))
                  (first vectors)))
      (is (equalp (coerce #(0.0d0 1.0d0) '(simple-array double-float (*)))
                  (second vectors))))))

(test embed-openai-compatible-sends-correct-request
  "The request EMBED sends hits the right URL and carries the right body."
  (let ((driver (make-instance 'fake-embed-driver :body +canned-embeddings-response+))
        (e (rag:make-openai-compatible-embedder :base-url "http://x/v1" :model "m")))
    (let ((cl-llm.http:*driver* driver))
      (rag:embed e (list "a" "b")))
    (is (string= "http://x/v1/embeddings" (fake-last-url driver)))
    (let ((sent (json:parse (fake-last-content driver))))
      (is (string= "m" (json:jget sent "model")))
      (is (string= "a" (json:jget sent "input" 0)))
      (is (string= "b" (json:jget sent "input" 1))))))

(test embed-openai-compatible-sends-auth-header-when-key-present
  "When an API key is configured, EMBED sends a Bearer authorization header."
  (let ((driver (make-instance 'fake-embed-driver :body +canned-embeddings-response+))
        (e (rag:make-openai-compatible-embedder
            :base-url "http://x/v1" :model "m" :api-key "sk-test")))
    (let ((cl-llm.http:*driver* driver))
      (rag:embed e (list "a")))
    (is (string= "Bearer sk-test"
                 (cdr (assoc "authorization" (fake-last-headers driver)
                             :test #'string-equal))))))

(test embed-openai-compatible-single-string-returns-one-vector
  "A single string input (not a list) returns one EMBEDDING, not a list."
  (let ((driver (make-instance 'fake-embed-driver :body +canned-embeddings-response+))
        (e (rag:make-openai-compatible-embedder :base-url "http://x/v1" :model "m")))
    (let ((result (let ((cl-llm.http:*driver* driver))
                    (rag:embed e "a"))))
      (is (typep result '(simple-array single-float (*))))
      (is (equalp (coerce #(1.0d0 0.0d0) '(simple-array double-float (*))) result)))))

(test embed-openai-compatible-malformed-response-signals-llm-rag-error
  "A non-JSON response body surfaces as RAG:LLM-RAG-ERROR, not a raw parse
error escaping from the JSON layer."
  (let ((driver (make-instance 'fake-embed-driver :body "not json{{{"))
        (e (rag:make-openai-compatible-embedder :base-url "http://x/v1" :model "m")))
    (signals rag:llm-rag-error
      (let ((cl-llm.http:*driver* driver))
        (rag:embed e (list "a"))))))

(test as-embedding-is-normalised-single-float
  "as-embedding returns a single-float array of unit length."
  (let ((v (rag:as-embedding '(3.0d0 4.0d0))))
    (is (typep v '(simple-array single-float (*))))
    (is (< (abs (- 1.0 (rag:embedding-norm v))) 1e-5))
    ;; 3-4-5 triangle: normalised components are 0.6 and 0.8
    (is (< (abs (- 0.6 (aref v 0))) 1e-5))
    (is (< (abs (- 0.8 (aref v 1))) 1e-5))))

(test as-embedding-zero-vector-is-left-alone
  "A zero vector has no direction; normalising must not divide by zero."
  (let ((v (rag:as-embedding '(0.0 0.0 0.0))))
    (is (typep v '(simple-array single-float (*))))
    (is (every #'zerop v))))
