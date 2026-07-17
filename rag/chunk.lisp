;;;; rag/chunk.lisp -- the default chunker.

(in-package #:cl-llm.rag)

(defun split-text (text &key (size 1000) (overlap 200))
  "Split TEXT into overlapping windows of ~SIZE characters sharing OVERLAP
characters with the previous window. Returns a list of (SUBSTRING . START).
Signals LLM-RAG-ERROR if OVERLAP is not strictly less than SIZE (which would not
advance)."
  (unless (< overlap size)
    (error 'llm-rag-error
           :message (format nil "chunk overlap (~a) must be less than size (~a)"
                            overlap size)))
  (let ((length (length text))
        (advance (- size overlap))
        (pieces '()))
    (when (zerop length)
      (return-from split-text nil))
    (loop for start = 0 then (+ start advance)
          while (< start length)
          do (push (cons (subseq text start (min length (+ start size))) start) pieces)
          until (>= (+ start size) length))
    (nreverse pieces)))
