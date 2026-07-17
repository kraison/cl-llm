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
