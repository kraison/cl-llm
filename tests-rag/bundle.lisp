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

(test evidence-standing-defaults-to-indeterminate
  "A caller who never sets :STANDING gets :INDETERMINATE, not NIL -- the
default that keeps the struct's docstring honest."
  (is (eq :indeterminate (rag:evidence-standing (rag:make-evidence)))))

(defun %bundle-doc-ids (bundle)
  (mapcar (lambda (e) (rag:chunk-document-id (rag:evidence-chunk e)))
          (rag:bundle-evidence bundle)))

(test a-dense-source-produces-evidence-marked-dense
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store)))
    (rag:store-add
     store
     (list (rag:make-chunk "anti-tank mine fuze"
                           :document-id "d1"
                           :embedding (rag:embed embedder "anti-tank"))))
    (let ((ev (rag:collect-evidence (rag:make-dense-source embedder store)
                                    "anti-tank" :k 1)))
      (is (= 1 (length ev)))
      (is (eq :dense (rag:evidence-method (first ev))))
      (is (eq :indeterminate (rag:evidence-standing (first ev))))
      (is (string= "d1" (rag:chunk-document-id
                         (rag:evidence-chunk (first ev))))))))

(test a-sparse-source-produces-evidence-marked-sparse
  (let ((store (rag:make-sparse-store)))
    (rag:store-add store
                   (list (rag:make-chunk "TM-62 fuze" :document-id "d2")))
    (let ((ev (rag:collect-evidence (rag:make-sparse-source store)
                                    "TM-62" :k 1)))
      (is (= 1 (length ev)))
      (is (eq :sparse (rag:evidence-method (first ev))))
      (is (eq :indeterminate (rag:evidence-standing (first ev)))))))

(test fuse-names-every-mode-that-contributed
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store))
         (sparse-store (rag:make-sparse-store))
         (chunk (rag:make-chunk "TM-62 anti-tank mine" :document-id "d1"
                                :embedding (rag:embed embedder "TM-62"))))
    (rag:store-add dense-store (list chunk))
    (rag:store-add sparse-store (list chunk))
    (let ((b (rag:fuse (list (rag:make-dense-source embedder dense-store)
                             (rag:make-sparse-source sparse-store))
                       "TM-62" :k 5)))
      (is (string= "TM-62" (rag:bundle-query b)))
      (is (member :dense (rag:bundle-modes b)))
      (is (member :sparse (rag:bundle-modes b)))
      (is (every (lambda (e) (rag:evidence-standing e))
                 (rag:bundle-evidence b))))))

(test fuse-keeps-distinct-chunks-of-the-same-document
  "⚠ DOCUMENT-CHUNKS (index.lisp) gives every chunk of a document the SAME
document-id -- that is what chunking does.  RECIPROCAL-RANK-FUSION keys by
%CHUNK-KEY, (document-id . text), because dense and sparse stores hold
DIFFERENT chunk objects for the same slice (hybrid.lisp).  FUSE must key
its evidence lookup the same way, or two chunks of one document collapse
into N copies of whichever evidence was seen first."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store))
         (sparse-store (rag:make-sparse-store))
         (c1 (rag:make-chunk "alpha fragment one" :document-id "d1"
                             :embedding (rag:embed embedder "alpha fragment")))
         (c2 (rag:make-chunk "beta fragment two" :document-id "d1"
                             :embedding (rag:embed embedder "beta fragment"))))
    (rag:store-add dense-store (list c1 c2))
    (rag:store-add sparse-store (list c1 c2))
    (let* ((sources (list (rag:make-dense-source embedder dense-store)
                          (rag:make-sparse-source sparse-store)))
           (b (rag:fuse sources "fragment" :k 2))
           (texts (mapcar (lambda (e) (rag:chunk-text (rag:evidence-chunk e)))
                          (rag:bundle-evidence b))))
      (is (= 2 (length texts)))
      (is (member "alpha fragment one" texts :test #'string=))
      (is (member "beta fragment two" texts :test #'string=)))))

(test fusion-order-is-deterministic
  "⚠ Ordering is the regression contract, so it must not depend on hash
order or on which source answered first."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store))
         (sparse-store (rag:make-sparse-store))
         (chunks
           (list (rag:make-chunk "alpha mine" :document-id "a"
                                 :embedding (rag:embed embedder "alpha"))
                 (rag:make-chunk "beta mine" :document-id "b"
                                :embedding (rag:embed embedder "beta"))
                 (rag:make-chunk "gamma mine" :document-id "c"
                                :embedding (rag:embed embedder "gamma")))))
    (rag:store-add dense-store chunks)
    (rag:store-add sparse-store chunks)
    (let* ((sources (list (rag:make-dense-source embedder dense-store)
                          (rag:make-sparse-source sparse-store)))
           (first-run (%bundle-doc-ids (rag:fuse sources "mine" :k 3)))
           (second-run (%bundle-doc-ids (rag:fuse sources "mine" :k 3))))
      (is (equal first-run second-run)))))

(test fuse-truncates-to-k-when-both-sources-return-more
  "⚠ I3, cl-llm#13: RETRIEVE (hybrid.lisp) truncates to :K; FUSE did not,
so a caller could get back up to 2K.  Seven chunks, :K 3: dense's top 3 by
cosine are (a g e), sparse's top 3 by BM25 are (g e f) -- disjoint enough
that the deduped, fused union is 4 items, more than :K, so this is a real
truncation, not a no-op."
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
    (let* ((sources (list (rag:make-dense-source embedder dense-store)
                          (rag:make-sparse-source sparse-store)))
           (b (rag:fuse sources "mine" :k 3)))
      (is (<= (length (rag:bundle-evidence b)) 3)))))

(test a-bounds-record-defaults-both-halves-to-indeterminate
  "⚠ Each half carries its OWN reason: a document corpus has no space at
all while having perfectly good validity time, so one shared standing
would force a lie about one of them."
  (let ((b (rag:make-bounds)))
    (is (null (rag:bounds-box b)))
    (is (null (rag:bounds-window b)))
    (is (eq :indeterminate (rag:bounds-box-standing b)))
    (is (eq :indeterminate (rag:bounds-window-standing b)))))

(test the-two-halves-of-a-bound-carry-independent-reasons
  (let ((b (rag:make-bounds :box '(0 0 1 1) :box-standing :asserted
                            :window nil :window-standing :searched-empty)))
    (is (equal '(0 0 1 1) (rag:bounds-box b)))
    (is (eq :asserted (rag:bounds-box-standing b)))
    (is (eq :searched-empty (rag:bounds-window-standing b)))))

(test evidence-carries-a-box-beside-its-extent
  "Unit 3's claim source and unit 2's metadata plumbing both write here, so
a filter reads one place regardless of where the facet came from."
  (let ((e (rag:make-evidence :chunk (rag:make-chunk "t" :document-id "d")
                              :method :dense :box '(1 2 3 4))))
    (is (equal '(1 2 3 4) (rag:evidence-box e)))
    (is (null (rag:evidence-extent e)))))
