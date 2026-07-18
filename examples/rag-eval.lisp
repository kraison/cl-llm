;;;; rag-eval.lisp -- measure a RAG system, don't trust it: recall + groundedness.
;;;;
;;;; A RAG system has TWO measurable layers, and they need different harnesses:
;;;;
;;;;   1. RETRIEVAL quality (recall@k, MRR) -- is the right passage even reachable?
;;;;      This is upstream of any generation, so it does NOT use cl-llm/eval's
;;;;      run-suite (there's no ASK to score). It's a small standalone loop.
;;;;   2. ANSWER quality (groundedness, correct abstention) -- given retrieval,
;;;;      what does the model do with it? This DOES fit cl-llm/eval: a variant's
;;;;      :prompt-fn reconstructs the grounded prompt and the scorers grade the
;;;;      response.
;;;;
;;;; Measuring them separately is the point: recall tells you if the passage is
;;;; reachable; answer eval, with retrieval held constant, tells you what the model
;;;; does with it. Conflating them hides which half is failing.
;;;;
;;;; This is the cross-lingual corpus from rag-crosslingual.lisp (RU/UK sources,
;;;; English questions). NOTE: the tiny N here makes every number illustrative, not
;;;; statistical -- a real gold set has dozens of probes PER language.
;;;;
;;;; Prerequisites (same as rag-crosslingual):
;;;;   ollama pull bge-m3
;;;;   ollama pull qwen2.5:7b
;;;;
;;;; Load this file, then: (examples/rag-eval:run)

(ql:quickload '(:cl-llm/rag :cl-llm/eval))

(defpackage #:examples/rag-eval
  (:use #:cl)
  (:local-nicknames (#:llm #:cl-llm)
                    (#:rag #:cl-llm.rag)
                    (#:eval #:cl-llm.eval))
  (:export #:run))

(in-package #:examples/rag-eval)

(defparameter *ollama* "http://localhost:11434/v1")

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

;;; The gold set: an English question, the doc-id(s) that SHOULD be retrieved, the
;;; source language, and a KIND that lets us slice the hard cases out.
(defstruct probe question relevant (lang "en") (kind :topical))

(defparameter *gold*
  (list
   (make-probe :question "which mine is called the butterfly mine?"
               :relevant '("pfm1")  :lang "uk" :kind :topical)
   (make-probe :question "which mine bounds into the air before exploding?"
               :relevant '("ozm72") :lang "ru" :kind :topical)
   (make-probe :question "which anti-tank mine has a metal body?"
               :relevant '("tm62m") :lang "ru" :kind :designation)
   (make-probe :question "which anti-tank mine is hard to find with a metal detector?"
               :relevant '("tm62p") :lang "ru" :kind :designation)))

;;; Out-of-corpus probes have no relevant doc: the RIGHT retrieval is "nothing
;;; useful", and the right ANSWER is to abstain. They're excluded from recall
;;; (undefined) but drive the abstention scorer.
(defparameter *out-of-corpus*
  (list
   (make-probe :question "what is the blast radius of a 152mm artillery shell?"
               :relevant '() :kind :out-of-corpus)
   (make-probe :question "who designed the M18 Claymore mine?"
               :relevant '() :kind :out-of-corpus)))

;;; ---------------------------------------------------------------------------
;;; Layer 1: RETRIEVAL eval (standalone -- no ASK, no cl-llm/eval).
;;; ---------------------------------------------------------------------------

(defun retrieved-ids (index question k)
  "Top-k retrieved DOC-ids, deduped, best-rank first."
  (remove-duplicates
   (mapcar (lambda (h) (rag:chunk-document-id (rag:hit-chunk h)))
           (rag:retrieve index question :k k))
   :from-end t :test #'equal))

(defun probe-metrics (index probe k)
  (let* ((ids   (retrieved-ids index (probe-question probe) k))
         (rel   (probe-relevant probe))
         (found (intersection ids rel :test #'equal))
         (rank  (loop for id in ids for i from 1
                      when (member id rel :test #'equal) return i)))
    (list :hit    (if found 1 0)                            ; any relevant in top-k?
          :recall (/ (float (length found)) (length rel))  ; fraction of relevant found
          :rr     (if rank (/ 1.0 rank) 0.0))))             ; 1/rank of the first hit

(defun mean (key rows)
  (if rows (/ (reduce #'+ rows :key (lambda (r) (getf (cdr r) key))) (float (length rows))) 0.0))

(defun report-slice (name rows)
  (format t "  ~14a  hit=~,2f  recall=~,2f  mrr=~,2f  (n=~a)~%"
          name (mean :hit rows) (mean :recall rows) (mean :rr rows) (length rows)))

(defun evaluate-retrieval (index &key (k 2))
  ;; k=2 on a 4-doc corpus keeps recall discriminating; a real corpus uses a
  ;; larger k (recall@k saturates once k approaches the corpus size).
  (let ((rows (loop for p in *gold* collect (cons p (probe-metrics index p k)))))
    (flet ((where (pred) (remove-if-not (lambda (r) (funcall pred (car r))) rows)))
      (format t "~&=== Layer 1: retrieval eval @k=~a  (~a probes) ===~%" k (length rows))
      (report-slice "overall"     rows)
      (report-slice "EN->ru"      (where (lambda (p) (string= "ru" (probe-lang p)))))
      (report-slice "EN->uk"      (where (lambda (p) (string= "uk" (probe-lang p)))))
      (report-slice "topical"     (where (lambda (p) (eq :topical (probe-kind p)))))
      (report-slice "designation" (where (lambda (p) (eq :designation (probe-kind p))))))))

;;; ---------------------------------------------------------------------------
;;; Layer 2: ANSWER eval (in cl-llm/eval).
;;; Freeze the retrieved context into each case so retrieval is held constant and
;;; the scorers measure the MODEL.
;;; ---------------------------------------------------------------------------

(defparameter *cases* nil "Set in RUN once the index exists (retrieval is frozen here).")

(defun make-rag-cases (index probes &key (k 3))
  (loop for p in probes
        collect (eval:make-case
                 (probe-question p)
                 :expected (first (probe-relevant p))
                 :metadata (list :context (rag:assemble-context
                                           (rag:retrieve index (probe-question p) :k k))
                                 :out-of-corpus (eq :out-of-corpus (probe-kind p))))))

;;; A variant's prompt-fn rebuilds the grounded user prompt from the frozen
;;; context; the grounding+language system prompt rides in the variant args.
(defun grounded-prompt (case)
  (format nil "Sources:~%~a~%Question: ~a"
          (getf (eval:case-metadata case) :context)
          (eval:case-input case)))

(defparameter *grounding+lang*
  (format nil "~a~%~%The sources may be in Russian or Ukrainian; answer in English."
          rag:*grounding-instructions*))   ; reuse the SAME grounding text as production

;;; Groundedness: an LLM judge (which must also read RU/UK) checks whether every
;;; claim in the answer is supported by the frozen sources. DEFJUDGE parses a
;;; 0-1 score from the reply and degrades to 0.0 on an unparseable judge.
(eval:defjudge grounded-in-sources (case response)
  (format nil "Reply with a single number from 0 to 1, nothing else. Score 1 if
EVERY factual claim in the ANSWER is supported by the SOURCES (which may be in
Russian or Ukrainian); score 0 if any claim is not. An answer that declines
because the sources don't cover the question scores 1.~%~%SOURCES:~%~a~%~%ANSWER:~%~a"
          (getf (eval:case-metadata case) :context)
          (and response (llm:response-text response))))

;;; Correct abstention: reward declining if and only if the case is out-of-corpus.
(eval:defscorer correct-abstention (case response)
  "1.0 when the answer abstains exactly on the out-of-corpus cases."
  (let ((abstained (and response
                        (search "not in the provided sources"
                                (string-downcase (llm:response-text response)))))
        (out (getf (eval:case-metadata case) :out-of-corpus)))
    (if (eq (not (null abstained)) (not (null out)))
        (eval:score 1.0)
        (eval:score 0.0 :explanation (if out "should have abstained" "abstained wrongly")))))

(eval:defsuite crosslingual-answers
  :dataset *cases*                          ; the run-time thunk reads the frozen cases
  :variants ((:model "qwen2.5:7b" :prompt-fn #'grounded-prompt
              :system *grounding+lang* :label "qwen"))
  :scorers (grounded-in-sources correct-abstention))

(defun run ()
  (setf llm:*provider* (make-instance 'llm:openai-compatible-provider
                                      :base-url *ollama* :model "qwen2.5:7b"))
  (let ((index (rag:make-index
                :embedder (rag:make-openai-compatible-embedder
                           :base-url *ollama* :model "bge-m3"))))
    (rag:add-documents index *corpus*)

    ;; Layer 1: retrieval recall/MRR, sliced by language and by kind.
    (evaluate-retrieval index :k 2)
    ;; => overall       hit=1.00  recall=1.00  mrr=0.88
    ;;    topical       hit=1.00  recall=1.00  mrr=1.00
    ;;    designation   hit=1.00  recall=1.00  mrr=0.75   ; <- the ТМ-62М/ТМ-62П blur:
    ;;    recall saturates on a 4-doc corpus, but MRR still exposes that the exact
    ;;    designation isn't always ranked #1 -- the job of the future hybrid retriever.

    ;; Layer 2: freeze retrieval into the cases, then score the answers. The
    ;; judge's ASK and the variant's ASK both run against the bound provider.
    (setf *cases* (make-rag-cases index (append *gold* *out-of-corpus*) :k 3))
    (format t "~&~%=== Layer 2: answer eval (groundedness + abstention) ===~%")
    (eval:report (eval:run-suite 'crosslingual-answers) :detail t))
  ;; => variant  grounded-in-sources  correct-abstention
  ;;    qwen     1.00                 1.00
  ;; qwen2.5:7b grounded on every in-corpus question and abstained on BOTH
  ;; out-of-corpus ones -- on THIS tiny set. A real gold set (dozens of probes per
  ;; language) is where a weaker slice, or a model that won't abstain, shows up.
  (values))

;; (examples/rag-eval:run)
