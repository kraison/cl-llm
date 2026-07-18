;;;; rag-crosslingual.lisp -- index Russian & Ukrainian sources, ask in English.
;;;;
;;;; Cross-lingual retrieval: a multilingual embedder maps text in different
;;;; languages into ONE shared vector space, so an English query finds the
;;;; relevant Russian or Ukrainian passages without translating anything first.
;;;; The answering model then reads those RU/UK passages and answers in English,
;;;; grounded in and citing the ORIGINAL sources.
;;;;
;;;; The only change from rag-local.lisp is the embedding model: bge-m3 aligns
;;;; RU/UK/EN in a shared space, where the English-first nomic-embed-text does not.
;;;;
;;;; Prerequisites: `ollama` running, with a MULTILINGUAL embedder and a chat
;;;; model that reads RU/UK pulled:
;;;;   ollama pull bge-m3        ; multilingual embedder (1024-dim, 100+ languages)
;;;;   ollama pull qwen2.5:7b    ; a chat model with decent RU/UK comprehension
;;;;
;;;; Load this file, then: (examples/rag-crosslingual:run)

(ql:quickload :cl-llm/rag)

(defpackage #:examples/rag-crosslingual
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag))
  (:export #:run))

(in-package #:examples/rag-crosslingual)

(defparameter *ollama* "http://localhost:11434/v1")

;;; A small RU/UK corpus of descriptive ordnance facts (public reference material,
;;; not procedures). Note the near-twin designations TM-62M and TM-62P: dense
;;; retrieval is TOPICAL, so a query about one will also surface the other -- the
;;; exact-designation blur the hybrid dense+sparse layer (not in v1) exists to fix.
(defparameter *corpus*
  (list
   (rag:make-document
    "ТМ-62М — советская противотанковая мина нажимного действия с металлическим
     корпусом. Она содержит основной заряд взрывчатого вещества и взрыватель
     нажимного действия."
    :id "tm62m" :metadata '(:title "ТМ-62М" :language "ru"))
   (rag:make-document
    "ТМ-62П — вариант противотанковой мины ТМ-62 с пластмассовым корпусом, что
     затрудняет её обнаружение металлодетектором."
    :id "tm62p" :metadata '(:title "ТМ-62П" :language "ru"))
   (rag:make-document
    "ПФМ-1 — це малогабаритна фугасна протипіхотна міна, яку розкидають
     дистанційно. Через характерну форму крил її називають «метеликом». Вона
     спрацьовує від тиску."
    :id "pfm1" :metadata '(:title "ПФМ-1" :language "uk"))
   (rag:make-document
    "ОЗМ-72 — выпрыгивающая осколочная противопехотная мина кругового поражения.
     При срабатывании вышибной заряд подбрасывает её примерно на метр, после чего
     происходит подрыв."
    :id "ozm72" :metadata '(:title "ОЗМ-72" :language "ru"))))

;;; A cross-lingual system prompt, composed WITH the grounding rules (never
;;; replacing them): answer in English, but keep ordnance designations in their
;;; original form so nothing is lost in translation.
(defparameter *crosslingual-system*
  "The sources may be in Russian or Ukrainian. Answer in English, concisely.
Preserve ordnance designations exactly as written in the source (e.g. ТМ-62М),
and give the Latin-script form alongside (e.g. TM-62M) when you use one.")

(defun show-hits (label hits)
  (format t "~&--- ~a ---~%" label)
  (loop for hit in hits
        for chunk = (rag:hit-chunk hit)
        do (format t "  ~,3f  [~a] (~a)~%"
                   (rag:hit-score hit)
                   (getf (rag:chunk-metadata chunk) :title)      ; original script
                   (getf (rag:chunk-metadata chunk) :language))))

(defun run ()
  (setf llm:*provider* (make-instance 'llm:openai-compatible-provider
                                      :base-url *ollama* :model "qwen2.5:7b"))
  (let ((index (rag:make-index
                :embedder (rag:make-openai-compatible-embedder
                           :base-url *ollama* :model "bge-m3"))))
    (rag:add-documents index *corpus*)
    (format t "~&--- indexed ~a RU/UK chunk(s) with a multilingual embedder ---~%"
            (rag:store-count (rag:index-store index)))

    ;; 1. English query -> Russian/Ukrainian passages, purely via the shared
    ;;    embedding space. No translation step anywhere.
    (show-hits "retrieve: \"which mine is called the butterfly mine?\""
               (rag:retrieve index "which mine is called the butterfly mine?" :k 2))
    ;; => 0.346  [ПФМ-1] (uk)      ; a Ukrainian source, found from an English query
    ;;    0.284  [ОЗМ-72] (ru)     ; (bge-m3 cosine sits in a lower range than nomic;
    ;;                               relative ranking is what matters, not the magnitude)

    ;; 2. A grounded English answer synthesized from a Ukrainian source.
    (multiple-value-bind (answer hits)
        (rag:rag-ask index "Which mine is nicknamed the butterfly mine, and how is it triggered?"
                     :k 3 :system *crosslingual-system*)
      (format t "~&--- rag-ask (EN answer from UK source) ---~%~a~%  sources: ~{~a~^, ~}~%"
              answer
              (mapcar (lambda (h) (getf (rag:chunk-metadata (rag:hit-chunk h)) :title)) hits)))
    ;; => The mine nicknamed the butterfly mine is ПФМ-1 (PFM-1). It is triggered
    ;;    through pressure [1].          sources: ПФМ-1, ОЗМ-72

    ;; 3. The exact-designation blur, made visible. Asking about TM-62M pulls the
    ;;    near-twin TM-62P too, because dense retrieval matches on topic, not on
    ;;    the exact model suffix. A good answer distinguishes them FROM the sources;
    ;;    precise retrieval of one designation is the job of the (future) hybrid
    ;;    sparse+dense retriever.
    (show-hits "retrieve: \"TM-62M body material\"  (note the near-twin)"
               (rag:retrieve index "What is the body of the TM-62M made of?" :k 2))
    ;; => 0.643  [ТМ-62М] (ru)     ; the query's exact target
    ;;    0.550  [ТМ-62П] (ru)     ; ...but the plastic-cased near-twin rides along
    (format t "~&--- rag-ask (designation precision) ---~%~a~%"
            (rag:rag-ask index "Is the TM-62M's body metal or plastic?"
                         :k 3 :system *crosslingual-system*))
    ;; => The TM-62M's body is metal [1].   ; the model distinguished it from the
    ;;    plastic ТМ-62П in the retrieved set -- but the retriever handed it BOTH,
    ;;    so it's the model, not retrieval, doing the disambiguation here

    ;; 4. Abstention still holds across languages: an out-of-corpus question gets
    ;;    declined, not answered from unrelated RU/UK passages.
    (format t "~&--- rag-ask (out of corpus) ---~%~a~%"
            (rag:rag-ask index "What is the blast radius of a 152mm artillery shell?"
                         :k 3 :system *crosslingual-system*)))
  ;; => Not in the provided sources
  (values))

;; (examples/rag-crosslingual:run)
