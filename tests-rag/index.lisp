;;;; tests-rag/index.lisp

(in-package #:cl-llm.rag.test)

(in-suite cl-llm-rag-suite)

(test make-index-requires-an-embedder
  (signals error (rag:make-index)))

(test add-documents-chunks-embeds-and-stores
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder))))
    (rag:add-documents index
                       (list (rag:make-document
                              "the TM-62 mine has a pressure fuze that is dangerous"
                              :id "d1" :metadata '(:title "TM-62"))))
    (is (plusp (rag:store-count (rag:index-store index))))
    ;; provenance survives chunking
    (let ((hit (first (rag:retrieve index "TM-62 fuze" :k 1))))
      (is (string= "d1" (rag:chunk-document-id (rag:hit-chunk hit))))
      (is (string= "TM-62" (getf (rag:chunk-metadata (rag:hit-chunk hit)) :title)))
      (is (integerp (getf (rag:chunk-metadata (rag:hit-chunk hit)) :position))))))

(test index-retrieves-the-relevant-document
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder))))
    (rag:add-documents index
                       (list (rag:make-document "anti-tank mines and their fuzes" :id "mines")
                             (rag:make-document "field medical evacuation procedures" :id "medevac")))
    (is (string= "mines"
                 (rag:chunk-document-id
                  (rag:hit-chunk (first (rag:retrieve index "tank mine fuze" :k 1))))))))

(test save-and-load-index-round-trips
  (let ((index (rag:make-index :embedder (rag:make-mock-embedder)))
        (path (merge-pathnames "rag-index-test.dat" (uiop:temporary-directory))))
    (rag:add-documents index (list (rag:make-document "PFM-1 butterfly mine" :id "d")))
    (rag:save-index index path)
    (let ((loaded (rag:load-index path (rag:make-mock-embedder))))
      (is (= (rag:store-count (rag:index-store index))
             (rag:store-count (rag:index-store loaded))))
      (is (string= "d" (rag:chunk-document-id
                        (rag:hit-chunk (first (rag:retrieve loaded "butterfly" :k 1)))))))
    (ignore-errors (delete-file path))))
