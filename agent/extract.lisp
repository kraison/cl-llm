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
