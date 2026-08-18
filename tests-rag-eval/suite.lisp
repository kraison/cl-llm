;;;; tests-rag-eval/suite.lisp

(in-package #:cl-llm.rag.eval.test)

(def-suite cl-llm-rag-eval-suite
  :description "Deterministic bundle scorers.")

(in-suite cl-llm-rag-eval-suite)

(defun %ev (doc-id &key (method :dense) (standing :indeterminate))
  (rag:make-evidence :chunk (rag:make-chunk (format nil "text-~a" doc-id)
                                            :document-id doc-id)
                     :score 1.0d0 :method method :standing standing))

(defun %bundle (doc-ids &key (modes '(:dense)))
  (rag:make-bundle :query "q"
                   :evidence (mapcar #'%ev doc-ids)
                   :modes modes))

(defun %fuse-fixture-sources ()
  "Seven chunks over dense + sparse stores, real sources -- not the %BUNDLE
fixture.  Shared by GOLDEN.LISP (the committed-golden regression test) and
SCORERS.LISP (I2, cl-llm#13: scorers driven over a real FUSE bundle).

Each chunk embeds its OWN full text (not one distinguishing word the way
an earlier version of this fixture did) and varies both how many times
\"mine\" occurs and how many filler words surround it, so dense cosines
and sparse BM25 scores are all pairwise distinct -- verified by direct
probe, not assumed: at :K 7 every one of the 7 dense cosines differs,
every one of the 7 BM25 scores differs, and every one of the 7 fused RRF
scores differs.  A fixture where either mode produces exact ties lets
FUSE's ordering collapse to tiebreak order (document id), which is what
this fixture exists to rule out (cl-llm#13's review of the original,
tie-heavy version).

FUSE's RRF ordering over these chunks at :K 7 is empirically
(g e f a b c d), not the alphabetical (a b c d e f g) a document-id-sort
regression would produce -- and, more discriminating still, changing
*RRF-K* from 60 to 10 changes that order too (f and a swap), which the
original two-mode-tie fixture could not detect at all (see golden.lisp's
docstring on A-REAL-FUSE-BUNDLE-MATCHES-ITS-COMMITTED-GOLDEN)."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store))
         (sparse-store (rag:make-sparse-store))
         (texts '(("a" . "mine")
                  ("b" . "beta beta beta mine mine mine mine")
                  ("c" . "gamma gamma mine mine mine")
                  ("d" . "delta delta delta mine mine mine")
                  ("e" . "iota mine mine mine")
                  ("f" . "omicron omicron mine mine mine mine")
                  ("g" . "epsilon mine mine mine mine")))
         (chunks (mapcar (lambda (p)
                            (rag:make-chunk (cdr p) :document-id (car p)
                                            :embedding (rag:embed
                                                        embedder (cdr p))))
                          texts)))
    (rag:store-add dense-store chunks)
    (rag:store-add sparse-store chunks)
    (list (rag:make-dense-source embedder dense-store)
          (rag:make-sparse-source sparse-store))))
