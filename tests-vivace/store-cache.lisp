;;;; tests-vivace/store-cache.lisp

(in-package #:cl-llm.rag.vivace/tests)
(in-suite :cl-llm-rag-vivace)

(defparameter *corpus*
  '(("tm62"  . "the TM-62 is a Soviet anti-tank blast mine with a pressure fuze")
    ("pfm1"  . "the PFM-1 is a small scatterable butterfly anti-personnel mine")
    ("ozm72" . "the OZM-72 is a bounding fragmentation mine")))

(defun load-corpus (store embedder)
  (rag:store-add store
                 (loop for (doc . text) in *corpus*
                       collect (rag:make-chunk text :document-id doc
                                               :embedding (rag:embed embedder text)))))

(test cached-store-add-search-count
  (with-temp-graph (g)
    (let ((emb (rag:make-mock-embedder))
          (store (v:make-graph-store g :strategy :cache)))
      (load-corpus store emb)
      (is (= 3 (rag:store-count store)))
      (let ((hits (rag:store-search store (rag:embed emb "anti-tank mine") 1)))
        (is (string= "tm62" (rag:chunk-document-id (rag:hit-chunk (first hits)))))))))

(test scan-and-cache-return-identical-rankings
  "The load-bearing invariant: strategy is invisible through the contract."
  (let ((emb (rag:make-mock-embedder))
        (queries '("anti-tank mine" "butterfly" "fragmentation bounding")))
    (flet ((rankings (strategy)
             (with-temp-graph (g)
               (let ((store (v:make-graph-store g :strategy strategy)))
                 (load-corpus store emb)
                 (loop for q in queries
                       collect (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
                                       (rag:store-search store (rag:embed emb q) 3)))))))
      (is (equal (rankings :scan) (rankings :cache))))))
