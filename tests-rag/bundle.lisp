;;;; tests-rag/bundle.lisp

(in-package #:cl-llm.rag.test)
(in-suite cl-llm-rag-suite)

(test evidence-carries-its-provenance
  "Every field the epic requires per hit, and STANDING is never NIL."
  (let ((e (rag:make-evidence
            :chunk (rag:make-chunk "text" :document-id "d1")
            :score 1.0d0
            :method :dense
            :standing :indeterminate)))
    (is (string= "d1" (rag:chunk-document-id (rag:evidence-chunk e))))
    (is (eq :dense (rag:evidence-method e)))
    (is (eq :indeterminate (rag:evidence-standing e)))
    (is (null (rag:evidence-extent e)))
    (is (null (rag:evidence-source e)))))

(test evidence-holds-a-real-temporal-extent
  "⚠ Not a re-encoding.  The extent is the library's own struct, which is
what the graph-free dependency bought (vivace-graph#159)."
  (let* ((extent (temporal-extent:make-interval
                  (temporal-extent:exact-bound (local-time:now))
                  (temporal-extent:unknown-bound)
                  :semantics :validity
                  :standing :asserted))
         (e (rag:make-evidence :chunk (rag:make-chunk "t" :document-id "d1")
                               :score 1.0d0 :method :dense
                               :standing :asserted
                               :extent extent)))
    (is (temporal-extent:temporal-extent-p (rag:evidence-extent e)))
    (is (eq :validity
            (temporal-extent:extent-semantics (rag:evidence-extent e))))))

(test a-bundle-is-ordered-and-names-its-modes
  "ORDER IS THE CONTRACT: the bundle preserves the order it was built with."
  (let* ((a (rag:make-evidence :chunk (rag:make-chunk "a" :document-id "a")
                               :score 2.0d0 :method :dense
                               :standing :indeterminate))
         (b (rag:make-evidence :chunk (rag:make-chunk "b" :document-id "b")
                               :score 1.0d0 :method :sparse
                               :standing :indeterminate))
         (bundle (rag:make-bundle :query "q" :evidence (list a b)
                                  :modes '(:dense :sparse))))
    (is (string= "q" (rag:bundle-query bundle)))
    (is (equal '("a" "b")
               (mapcar (lambda (e)
                         (rag:chunk-document-id (rag:evidence-chunk e)))
                       (rag:bundle-evidence bundle))))
    (is (equal '(:dense :sparse) (rag:bundle-modes bundle)))))
