;;;; rag-vivace.lisp -- back the RAG store with a vivace-graph (graph-db) graph.
;;;;
;;;; cl-llm/rag/vivace lets a persistent graph-db graph BE your vector store, so
;;;; the retrieval corpus lives in the same graph as your field data. It satisfies
;;;; the RAG vector-store protocol, so `(make-index :store (make-graph-store g))`
;;;; is a drop-in -- nothing else in the pipeline changes.
;;;;
;;;; It offers three search strategies, identical through the contract (same
;;;; ranking; same scores too for the unit-norm query vectors rag:embed returns):
;;;;   :segment -- DEFAULT. Embeddings live in graph-db's mmap vector segment;
;;;;               search never materialises a node it will not return, and the
;;;;               corpus need not fit in the Lisp heap. The right default for a
;;;;               persistent graph. First open of a pre-segment corpus pays a
;;;;               one-time, resumable migration sweep.
;;;;   :cache   -- composes an in-RAM index (memory-store). FASTER than :segment
;;;;               (~15ms vs ~35ms at 20k chunks, because the corpus is already
;;;;               in the heap) and the right choice when it fits there. NOT
;;;;               deprecated.
;;;;   :scan    -- no index; scores every chunk vertex per query (lowest RAM).
;;;;               Fallback and correctness reference.
;;;; and the graph is durable, so you index once and reopen without re-embedding.
;;;;
;;;; NOTE: the default changed from :cache to :segment. This example passes
;;;; :strategy explicitly throughout, so it is unaffected; a caller that relied
;;;; on the old default should pass :strategy :cache.
;;;;
;;;; This example runs with NO Ollama and NO API key: it uses a deterministic
;;;; MOCK-EMBEDDER + MOCK-PROVIDER, over a REAL on-disk graph-db graph. To use real
;;;; embeddings, swap the embedder for a make-openai-compatible-embedder (one line;
;;;; see rag-local.lisp) -- everything else is the same.
;;;;
;;;; Prerequisites: graph-db (vivace-graph-v3) is NOT in Quicklisp, so put it on
;;;; the ASDF path before loading, e.g.:
;;;;   (push #p"/path/to/vivace-graph-v3/" asdf:*central-registry*)
;;;;   (push #p"/path/to/cl-llm/"          asdf:*central-registry*)
;;;; then load this file and: (examples/rag-vivace:run)

(ql:quickload :cl-llm/rag/vivace)

(defpackage #:examples/rag-vivace
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag)
                    (#:v   #:cl-llm.rag.vivace)
                    (#:gdb #:graph-db))
  (:export #:run))

(in-package #:examples/rag-vivace)

;;; Descriptive ordnance-identification facts (public reference material, not
;;; procedures). In a real deployment these chunks would live in the SAME graph as
;;; the team's field data, so a literature hit can later be joined to it.
(defparameter *corpus*
  (list
   (rag:make-document
    "The TM-62M is a Soviet-designed anti-tank blast mine with a metal body and a
     pressure-activated fuze. It holds a high-explosive main charge."
    :id "tm62m" :metadata '(:title "TM-62M" :language "en"))
   (rag:make-document
    "The PFM-1 is a small scatterable anti-personnel blast mine, nicknamed the
     butterfly mine for its winged shape. It is pressure-sensitive."
    :id "pfm1" :metadata '(:title "PFM-1" :language "en"))
   (rag:make-document
    "The OZM-72 is a bounding anti-personnel fragmentation mine that launches to
     roughly waist height before detonating."
    :id "ozm72" :metadata '(:title "OZM-72" :language "en"))))

;;; A scripted stand-in for the answering model (a real model produces these from
;;; the grounding prompt). RAG-ASK sends "Sources:...\nQuestion: <q>".
(defun grounding-mock ()
  (llm:make-mock-provider
   :responder
   (lambda (conversation)
     (let* ((user (llm:part-text (first (llm:message-content
                                         (car (last (llm:conversation-messages conversation)))))))
            (pos (search "Question: " user))
            (q (if pos (subseq user (+ pos (length "Question: ")) ) user)))
       (cond ((search "TM-62" q) "The TM-62M uses a pressure-activated fuze [1].")
             ((search "butterfly" q) "The butterfly mine is the PFM-1 [1].")
             (t "not in the provided sources"))))))

(defun titles (hits)
  (mapcar (lambda (h) (getf (rag:chunk-metadata (rag:hit-chunk h)) :title)) hits))

(defun run ()
  ;; graph-db logs snapshot/close operations via log4cl; quiet it for a clean demo.
  (ignore-errors (log:config :error))
  (let* ((embedder (rag:make-mock-embedder))
         (dir (merge-pathnames "cl-llm-rag-vivace-demo/" (uiop:temporary-directory)))
         (name :eod-kb))
    (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)
    (unwind-protect
         (progn
           ;; 1. Create a persistent graph and build a graph-backed index over it.
           ;;    The ONLY change from an in-memory index is :store -- the rest of
           ;;    the RAG pipeline (add-documents, rag-ask) is identical.
           (let* ((graph (gdb:make-graph name dir))
                  (index (rag:make-index
                          :embedder embedder
                          :store (v:make-graph-store graph :strategy :cache))))
             (rag:add-documents index *corpus*)
             (format t "~&--- indexed into the graph ---~%~a chunk(s) stored as graph vertices~%"
                     (rag:store-count (rag:index-store index)))
             ;; => 3 chunk(s) stored as graph vertices

             ;; 2. Grounded, cited answer -- retrieved from graph-stored chunks.
             (multiple-value-bind (answer hits)
                 (rag:rag-ask index "What fuze does the TM-62M use?"
                              :k 3 :provider (grounding-mock))
               (format t "~&--- rag-ask (graph-backed) ---~%~a~%  sources: ~{~a~^, ~}~%"
                       answer (titles hits)))
             ;; => The TM-62M uses a pressure-activated fuze [1].
             ;;      sources: TM-62M, OZM-72, PFM-1

             ;; 3. Strategy is invisible through the contract: a :scan store over
             ;;    the SAME graph retrieves the same ranking as the :cache store.
             (let* ((cache (v:make-graph-store graph :strategy :cache))
                    (scan  (v:make-graph-store graph :strategy :scan))
                    (q (rag:embed embedder "anti-tank mine with a metal body")))
               (format t "~&--- scan vs cache (same graph) ---~%  cache: ~{~a~^, ~}~%  scan:  ~{~a~^, ~}~%"
                       (titles (rag:store-search cache q 2))
                       (titles (rag:store-search scan q 2))))
             ;; => cache: TM-62M, PFM-1
             ;;    scan:  TM-62M, PFM-1      ; identical (deterministic tie-break)

             ;; 4. Persist: closing the graph snapshots it to disk.
             (gdb:close-graph graph)
             (format t "~&--- graph closed (persisted to disk) ---~%"))

           ;; 5. Reopen: the corpus is still there and HYDRATES from the graph --
           ;;    no re-chunking, no re-embedding. open-graph-store attaches a store
           ;;    to the reopened graph.
           (let* ((store (v:open-graph-store dir :name name :strategy :cache))
                  (index (rag:make-index :embedder embedder :store store)))
             (format t "~&--- reopened from disk ---~%~a chunk(s) hydrated~%"
                     (rag:store-count store))
             (format t "~&--- rag-ask after reopen (no re-embedding) ---~%~a~%"
                     (rag:rag-ask index "Which mine is the butterfly mine?"
                                  :provider (grounding-mock)))
             ;; => 3 chunk(s) hydrated
             ;;    The butterfly mine is the PFM-1 [1].
             (gdb:close-graph (v:graph-store-graph store))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))
  (values))

;; (examples/rag-vivace:run)
