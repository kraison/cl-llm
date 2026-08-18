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

(defun %ev-at (doc-id &key extent box)
  (rag:make-evidence :chunk (rag:make-chunk (format nil "t-~a" doc-id)
                                            :document-id doc-id)
                     :method :dense :extent extent :box box))

(defun %interval (y1 y2)
  (temporal-extent:make-interval
   (temporal-extent:exact-bound
    (local-time:parse-timestring (format nil "~a-01-01T00:00:00Z" y1)))
   (temporal-extent:exact-bound
    (local-time:parse-timestring (format nil "~a-01-01T00:00:00Z" y2)))
   :semantics :validity))

(test temporal-bound-reports-indeterminate-when-there-is-nothing-to-look-at
  "⚠ :INDETERMINATE and :SEARCHED-EMPTY are the pair most easily conflated,
and conflating them is the failure this vocabulary exists to prevent."
  (multiple-value-bind (w standing) (rag:temporal-bound '())
    (is (null w))
    (is (eq :indeterminate standing))))

(test temporal-bound-reports-searched-empty-when-no-seed-carries-an-extent
  (multiple-value-bind (w standing)
      (rag:temporal-bound (list (%ev-at "a") (%ev-at "b")))
    (is (null w))
    (is (eq :searched-empty standing))))

(test a-derived-window-encloses-every-seed-extent-and-is-inferred
  (multiple-value-bind (w standing)
      (rag:temporal-bound (list (%ev-at "a" :extent (%interval 2001 2002))
                                (%ev-at "b" :extent (%interval 2005 2006))
                                (%ev-at "c")))
    (is (eq :inferred standing)
        "a derived bound is INFERRED -- it was not observed")
    (is (local-time:timestamp=
         (local-time:parse-timestring "2001-01-01T00:00:00Z")
         (temporal-extent:bound-earliest (temporal-extent:extent-start w))))
    (is (local-time:timestamp=
         (local-time:parse-timestring "2006-01-01T00:00:00Z")
         (temporal-extent:bound-latest (temporal-extent:extent-end w))))))

(test a-window-derived-from-one-instant-is-an-instant-not-an-interval
  "⚠ MAKE-INTERVAL signals when its two bounds are exact and equal, so a
union over extents that share one moment MUST build an instant."
  (let* ((ts (local-time:parse-timestring "2003-03-03T00:00:00Z"))
         (inst (temporal-extent:make-instant (temporal-extent:exact-bound ts)
                                             :semantics :validity)))
    (multiple-value-bind (w standing)
        (rag:temporal-bound (list (%ev-at "a" :extent inst)
                                  (%ev-at "b" :extent inst)))
      (is (eq :inferred standing))
      (is (temporal-extent:extent-instant-p w)))))

(test spatial-bound-mirrors-the-temporal-one
  (multiple-value-bind (b standing) (rag:spatial-bound '())
    (is (null b))
    (is (eq :indeterminate standing)))
  (multiple-value-bind (b standing)
      (rag:spatial-bound (list (%ev-at "a") (%ev-at "b")))
    (is (null b))
    (is (eq :searched-empty standing)))
  (multiple-value-bind (b standing)
      (rag:spatial-bound (list (%ev-at "a" :box '(0 0 2 2))
                               (%ev-at "b" :box '(1 -1 3 1))
                               (%ev-at "c")))
    (is (eq :inferred standing))
    (is (equal '(0 -1 3 2) b) "the enclosing box, not the first one")))

(test supplied-bounds-win-and-are-asserted
  (let ((b (rag:plan-bounds (list (%ev-at "a" :extent (%interval 2001 2002)))
                            :box '(9 9 10 10))))
    (is (equal '(9 9 10 10) (rag:bounds-box b)))
    (is (eq :asserted (rag:bounds-box-standing b))
        "the caller asserts the scope; it was not derived")))

(test the-two-halves-resolve-independently
  "⚠ The reason the bounders are separate operations: an agent pins the
window it cares about and lets the region follow from the evidence."
  (let* ((seeds (list (%ev-at "a" :extent (%interval 2001 2002)
                                  :box '(0 0 1 1))))
         (b (rag:plan-bounds seeds :window (%interval 1990 1991))))
    (is (eq :asserted (rag:bounds-window-standing b)))
    (is (eq :inferred (rag:bounds-box-standing b)))
    (is (equal '(0 0 1 1) (rag:bounds-box b)))))

(test planning-over-nothing-is-indeterminate-on-both-halves
  (let ((b (rag:plan-bounds '())))
    (is (eq :indeterminate (rag:bounds-box-standing b)))
    (is (eq :indeterminate (rag:bounds-window-standing b)))))

(test a-source-reads-facets-from-chunk-metadata
  "Metadata carries the extent as its SEXP -- plain data, so it survives
persistence through any store -- and the box as four numbers."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store))
         (extent (%interval 2001 2002)))
    (rag:store-add
     store (list (rag:make-chunk "anti-tank mine" :document-id "d1"
                                 :metadata (list :extent
                                                 (temporal-extent:extent->sexp
                                                  extent)
                                                 :box '(0 0 1 1))
                                 :embedding (rag:embed embedder "anti-tank"))))
    (let ((ev (rag:collect-evidence (rag:make-dense-source embedder store)
                                    "anti-tank" :k 1)))
      (is (temporal-extent:temporal-extent-p (rag:evidence-extent (first ev))))
      (is (equal '(0 0 1 1) (rag:evidence-box (first ev)))))))

(test a-chunk-without-facet-metadata-yields-nil-facets
  "The map-less tenant's normal case: no keys, no facets, no error."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store)))
    (rag:store-add
     store (list (rag:make-chunk "plain" :document-id "d1"
                                 :embedding (rag:embed embedder "plain"))))
    (let ((ev (rag:collect-evidence (rag:make-dense-source embedder store)
                                    "plain" :k 1)))
      (is (null (rag:evidence-extent (first ev))))
      (is (null (rag:evidence-box (first ev)))))))

(test a-malformed-extent-sexp-in-metadata-signals
  "⚠ A corrupt facet is a definition mistake, not an absence.  Silently
reading it as NIL would make a broken corpus look like a map-less one."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (store (rag:make-memory-store)))
    (rag:store-add
     store (list (rag:make-chunk "bad" :document-id "d1"
                                 :metadata '(:extent (:not-an-extent 9))
                                 :embedding (rag:embed embedder "bad"))))
    (signals temporal-extent:invalid-extent
      (rag:collect-evidence (rag:make-dense-source embedder store)
                            "bad" :k 1))))

(test fuse-retains-the-box
  "⚠ FUSE rebuilds EVIDENCE field by field; BOX must survive the rebuild or
Task 5's filter sees nothing (cl-llm#13 unit 2, task 4)."
  (let* ((embedder (rag:make-mock-embedder :dimension 8))
         (dense-store (rag:make-memory-store))
         (sparse-store (rag:make-sparse-store))
         (chunk (rag:make-chunk "TM-62 anti-tank mine" :document-id "d1"
                                :metadata '(:box (0 0 1 1))
                                :embedding (rag:embed embedder "TM-62"))))
    (rag:store-add dense-store (list chunk))
    (rag:store-add sparse-store (list chunk))
    (let ((b (rag:fuse (list (rag:make-dense-source embedder dense-store)
                             (rag:make-sparse-source sparse-store))
                       "TM-62" :k 5)))
      (is (equal '(0 0 1 1)
                 (rag:evidence-box (first (rag:bundle-evidence b))))))))

(test a-malformed-box-in-metadata-yields-nil-not-a-crash
  "⚠ The plan's global constraint outranks the brief's snippet (task-4
review): a bound excludes only what is KNOWN to fall outside it, so a
corrupted box must degrade to absent -- wrong arity, a non-REAL element,
an improper list, a bare atom -- not signal and not pass through
unchecked to a downstream filter.  The rest of the evidence still builds."
  (let ((embedder (rag:make-mock-embedder :dimension 8)))
    (dolist (bad-box (list '(0 0 1)              ; wrong arity
                           '(0 0 1 :not-a-real)   ; non-real element
                           (list* 0 0 1 2)        ; improper list
                           42))                   ; not a list at all
      (let ((store (rag:make-memory-store)))
        (rag:store-add
         store (list (rag:make-chunk "bad box" :document-id "d1"
                                     :metadata (list :box bad-box)
                                     :embedding (rag:embed
                                                 embedder "bad box"))))
        (let ((ev (rag:collect-evidence (rag:make-dense-source
                                         embedder store)
                                        "bad box" :k 1)))
          (is (null (rag:evidence-box (first ev))))
          (is (string= "d1" (rag:chunk-document-id
                             (rag:evidence-chunk (first ev))))))))))
