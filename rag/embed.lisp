;;;; rag/embed.lisp -- turning text into vectors.

(in-package #:cl-llm.rag)

(deftype embedding () '(simple-array single-float (*)))

(defun embedding-norm (v)
  "L2 norm of V."
  (declare (type (simple-array single-float (*)) v))
  (let ((sum 0f0))
    (declare (type single-float sum))
    (dotimes (i (length v) (sqrt sum))
      (incf sum (* (aref v i) (aref v i))))))

(defun non-finite-embedding-error ()
  (error 'llm-rag-error
         :message "embedding contains a non-finite or out-of-range value; refusing to index it"))

(defun finite-single-float-p (x)
  "T if the single-float X is neither NaN nor +/-infinity.
Order matters: (= X X) is NIL for a NaN and is evaluated with an unordered
comparison that does not itself trap on a quiet NaN, so it is safe to check
first and short-circuit before the magnitude bound below -- which uses an
ORDERED comparison (<=) that WOULD trap on a NaN operand if one reached it."
  (and (= x x)
       (<= (- most-positive-single-float) x most-positive-single-float)))

(defun as-embedding (sequence)
  "Coerce SEQUENCE to a (simple-array single-float (*)) and L2-normalise it.
Normalising at ingest is what lets cosine similarity reduce to a plain dot
product at query time.  A zero vector has no direction and is returned as-is.

A NaN or infinite component is rejected with LLM-RAG-ERROR rather than
allowed to poison the stored vector.  Two independent guards are needed:
implementations with IEEE float traps enabled (SBCL, by default) signal an
ARITHMETIC-ERROR partway through the arithmetic below -- e.g. squaring a NaN
while accumulating NORM -- before any explicit check would run, so that is
caught and re-signalled as LLM-RAG-ERROR.  The finiteness check on NORM runs
BEFORE the normalising divide loop, so that loop itself never executes with
a non-finite NORM.  Implementations without traps enabled (e.g. ECL) instead
compute silently to a NaN or infinite NORM, which self-equality alone does
NOT catch (infinity is self-equal under IEEE 754); FINITE-SINGLE-FLOAT-P's
magnitude bound is what rejects that case."
  (handler-case
      (let* ((n (length sequence))
             (v (make-array n :element-type 'single-float)))
        (let ((i 0))
          (map nil (lambda (x)
                     (setf (aref v i) (coerce x 'single-float))
                     (incf i))
               sequence))
        (let ((norm (embedding-norm v)))
          (unless (finite-single-float-p norm)
            (non-finite-embedding-error))
          (unless (zerop norm)
            (dotimes (i n)
              (setf (aref v i) (/ (aref v i) norm))))
          v))
    (arithmetic-error () (non-finite-embedding-error))))

(defclass embedder ()
  ((model :initarg :model :initform nil :reader embedder-model))
  (:documentation "Abstract: maps text to an embedding vector."))

(defgeneric embed (embedder input)
  (:documentation "Embed INPUT. A string returns one EMBEDDING; a list of strings
returns a list of EMBEDDINGs in input order."))

;;; Local / OpenAI-compatible

(defclass openai-compatible-embedder (embedder)
  ((base-url :initarg :base-url
             :initform (error "openai-compatible-embedder requires :base-url, ~
                               e.g. \"http://localhost:11434/v1\".")
             :reader embedder-base-url)
   (api-key :initarg :api-key :initform nil :reader embedder-api-key-slot))
  (:documentation "Posts to <base-url>/embeddings, OpenAI-compatible."))

(defun make-openai-compatible-embedder (&key base-url model api-key)
  (make-instance 'openai-compatible-embedder
                 :base-url base-url :model model :api-key api-key))

(defun strip-trailing-slash (string)
  (if (and (plusp (length string)) (char= #\/ (char string (1- (length string)))))
      (subseq string 0 (1- (length string)))
      string))

(defun embedder-endpoint (embedder)
  (concatenate 'string (strip-trailing-slash (embedder-base-url embedder)) "/embeddings"))

(defun embedder-api-key (embedder)
  (or (embedder-api-key-slot embedder)
      (funcall cl-llm::*getenv-function* "OPENAI_API_KEY")))

(defun embedder-headers (embedder)
  (let ((key (embedder-api-key embedder)))
    (append (list (cons "content-type" "application/json"))
            (when key
              (list (cons "authorization" (concatenate 'string "Bearer " key)))))))

(defun encode-embedding-request (model texts)
  (json:to-json (json:jobject :model model :input (coerce texts 'vector))))

(defun decode-embedding-response (parsed)
  "Extract embeddings from a parsed OpenAI-compatible response, ordered by index."
  (let* ((data (json:jget parsed "data"))
         (items (sort (coerce (or data #()) 'list) #'<
                      :key (lambda (item) (or (json:jget item "index") 0)))))
    (mapcar (lambda (item) (as-embedding (json:jget item "embedding"))) items)))

(defmethod embed ((embedder openai-compatible-embedder) input)
  (let* ((texts (if (listp input) input (list input)))
         (body (cl-llm::request-with-retry
                (embedder-endpoint embedder)
                :method :post
                :headers (embedder-headers embedder)
                :content (encode-embedding-request (embedder-model embedder) texts)))
         (vectors (decode-embedding-response
                   (handler-case (json:parse body)
                     (error ()
                       (error 'llm-rag-error
                              :message "could not parse the embeddings response as JSON"))))))
    (if (listp input) vectors (first vectors))))

;;; Deterministic mock (a bag-of-words hashing embedder)

(defclass mock-embedder (embedder)
  ((dimension :initarg :dimension :initform 32 :reader embedder-dimension))
  (:documentation "A deterministic, offline embedder: bag-of-words hashed into a
fixed-dimension L2-normalized vector. Shared words raise cosine, so retrieval
tests exercise real ranking."))

(defun make-mock-embedder (&key (dimension 32))
  (make-instance 'mock-embedder :dimension dimension))

(defun string-hash (string)
  "A small deterministic hash (djb2), portable across implementations."
  (let ((h 5381))
    (loop for ch across string
          do (setf h (logand (+ (* h 33) (char-code ch)) #xffffffff)))
    h))

(defun words (text)
  (remove "" (uiop:split-string (string-downcase text)
                                :separator '(#\Space #\Newline #\Tab #\, #\. #\; #\:))
          :test #'string=))

(defmethod embed ((embedder mock-embedder) input)
  (flet ((one (text)
           (let ((v (make-array (embedder-dimension embedder)
                                :element-type 'double-float :initial-element 0d0)))
             (dolist (w (words text))
               (incf (aref v (mod (string-hash w) (embedder-dimension embedder))) 1d0))
             (as-embedding v))))
    (if (listp input) (mapcar #'one input) (one input))))
