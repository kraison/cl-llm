;;;; agent/extract.lisp -- the belief claim source's key extractor:
;;;; the endpoints a query names, by key token, from a store's
;;;; vocabulary (#64 SS4.1).

(in-package #:cl-llm.agent)

(defun %tokens (string)
  "The lowercase runs of [a-z0-9] in STRING of length >= 3, distinct,
in first-occurrence order."
  (let ((tokens '()) (run '()))
    (flet ((flush ()
             (when run
               (let ((tok (coerce (reverse run) 'string)))
                 (when (and (>= (length tok) 3)
                            (not (member tok tokens :test #'string=)))
                   (push tok tokens))))
             (setf run '())))
      (loop for ch across (string-downcase string)
            do (if (or (char<= #\a ch #\z) (char<= #\0 ch #\9))
                   (push ch run)
                   (flush)))
      (flush))
    (nreverse tokens)))

(defun %key-tokens (key)
  "KEY lowercased, split on #\\-, plus the whole key."
  (let ((key (string-downcase key)) (parts '()) (start 0))
    (loop for i = (position #\- key :start start)
          do (push (subseq key start i) parts)
          while i do (setf start (1+ i)))
    (cons key (remove "" parts :test #'string=))))

(defun %endpoint-match (tokens endpoint)
  "(values SCORE NAMESPACE-HIT-P) for ENDPOINT against query TOKENS:
SCORE counts distinct tokens equal to a key token or the whole key."
  (let ((key-tokens (%key-tokens (cdr endpoint))))
    (values (count-if (lambda (tok) (member tok key-tokens :test #'string=))
                      tokens)
            (and (member (%standing (car endpoint)) tokens :test #'string=)
                 t))))

(defun %endpoint-name (endpoint)
  "ENDPOINT as the \"namespace:key\" string the tools speak."
  (format nil "~a:~a" (%standing (car endpoint)) (cdr endpoint)))

(defun %better-match-p (a b)
  "Over (SCORE HIT ENDPOINT) triples: score descending, a namespace
hit first, shorter key, then namespace:key alphabetically."
  (destructuring-bind (sa ha ea) a
    (destructuring-bind (sb hb eb) b
      (cond ((/= sa sb) (> sa sb))
            ((not (eq ha hb)) ha)
            ((/= (length (cdr ea)) (length (cdr eb)))
             (< (length (cdr ea)) (length (cdr eb))))
            (t (string< (%endpoint-name ea) (%endpoint-name eb)))))))

(defun make-key-extractor (vocabulary &key (cap 10))
  "A function of a query string returning up to CAP endpoints of
VOCABULARY as (namespace-keyword . key), best match first.  A token
equal to a namespace name selects nothing by itself; it breaks ties."
  (lambda (query)
    (let ((tokens (%tokens query)) (scored '()))
      (dolist (ep (mem:vocabulary-endpoints vocabulary))
        (multiple-value-bind (score hit) (%endpoint-match tokens ep)
          (when (plusp score)
            (push (list score hit ep) scored))))
      (let ((sorted (sort scored #'%better-match-p)))
        (mapcar #'third (subseq sorted 0 (min cap (length sorted))))))))

;;;; The semantic route (#78 R2, R3): the same extractor, with the
;;;; endpoints whose profile embeds nearest the query filling the cap.

(defstruct (endpoint-embedder (:constructor %make-endpoint-embedder))
  "A RAG:EMBEDDER with the MODEL it names and the cosine FLOOR a dense
candidate must clear (#78 R3, R7).  EMBED is the (text -> vector)
function the memory layer takes -- it depends on no LLM."
  embedder model floor embed)

(defun make-endpoint-embedder (embedder &key floor)
  "Wrap EMBEDDER for the semantic index; => an ENDPOINT-EMBEDDER.
EMBEDDER must name a model (RAG:EMBEDDER-MODEL, recorded on every
vector so a model change re-embeds); FLOOR is required, a real in
[0, 1].  Trap: nothing here checks that FLOOR suits the embedder -- a
floor too low turns retrieve's refusal into noise."
  (let ((model (rag:embedder-model embedder)))
    (unless (and (stringp model) (plusp (length model)))
      (error "the embedder names no model; the index records one per ~
              vector"))
    (unless (and (realp floor) (<= 0 floor 1))
      (error "FLOOR must be a real in [0, 1], not ~s" floor))
    (%make-endpoint-embedder
     :embedder embedder :model model :floor floor
     :embed (lambda (text) (rag:embed embedder text)))))

(defun make-hybrid-key-extractor (graph vocabulary endpoint-embedder
                                  &key (cap 10) query-vector)
  "A function of a query string returning up to CAP endpoints of GRAPH
as (namespace-keyword . key): VOCABULARY's lexical matches first, in
MAKE-KEY-EXTRACTOR's order, then the endpoints whose profile embeds
nearest the query at cosine >= the embedder's floor, best first.
QUERY-VECTOR is a function of the query returning its embedding, so a
caller can memoise it across the stores in scope; the default embeds
on every call.  ENDPOINT-EMBEDDER NIL is MAKE-KEY-EXTRACTOR itself.
Traps: an endpoint a write touched and the indexer has not re-embedded
is reachable lexically only (#78 SS4.1); and the vector search runs
when the returned function is called, not under whatever snapshot
VOCABULARY was read in."
  (let ((lexical (make-key-extractor vocabulary :cap cap)))
    (if (null endpoint-embedder)
        lexical
        (let ((qv (or query-vector
                      (endpoint-embedder-embed endpoint-embedder)))
              (floor (endpoint-embedder-floor endpoint-embedder))
              (model (endpoint-embedder-model endpoint-embedder)))
          (lambda (query)
            (let* ((l (funcall lexical query))
                   (room (- cap (length l))))
              (if (plusp room)
                  (let ((dense
                          (loop for (ep . score)
                                  in (mem:nearest-endpoints
                                      graph (funcall qv query)
                                      ;; K bounds the SEGMENT hits, and a
                                      ;; duplicate or another model's
                                      ;; vector costs an endpoint (#78
                                      ;; SS3.3) -- ask for more than CAP.
                                      :k (* 2 cap) :model model)
                                when (and (>= score floor)
                                          (not (member ep l :test #'equal)))
                                  collect ep)))
                    (append l (subseq dense 0 (min room (length dense)))))
                  l)))))))
