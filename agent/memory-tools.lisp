;;;; agent/memory-tools.lisp -- recall, trace, decisions-citing,
;;;; conclude, conclude-absence, retract.  Spec SS6.

(in-package #:cl-llm.agent)

(defun %recall-tool (scope)
  (llm:make-tool
   "recall"
   "Recall what is believed about a subject: every belief on
(subject-namespace, subject-key) across the memory in scope, newest
validity first, each with its cite, standing, validity window, whether
it is current, and what superseded it.  Optional relation narrows to
one predicate; optional at (RFC 3339) keeps only beliefs valid then."
   '((subject-namespace :type string) (subject-key :type string)
     (relation :type string :optional t) (at :type string :optional t))
   (lambda (subject-namespace subject-key relation at)
     (let* ((subject (cons (%keyword subject-namespace) subject-key))
            (instant (and at (%parse-iso at)))
            (rows '()))
       (dolist (g (scope-stores scope))
         (dolist (r (mem:recall g subject :relation relation :at instant))
           (note-cite scope (mem:claim-cite (mem:belief-record-claim r)) g)
           (push (cons g r) rows)))
       (setf rows (stable-sort (nreverse rows)
                               (lambda (a b)
                                 (mem:claim-before-p
                                  (mem:belief-record-claim (cdr a))
                                  (mem:belief-record-claim (cdr b))))))
       (let* ((cap (scope-max-rows scope))
              (shown (subseq rows 0 (min cap (length rows)))))
         (json:to-json
          (json:jobject
           "records" (map 'vector
                          (lambda (x) (%record-json (car x) (cdr x)))
                          shown)
           "truncated" (%bool (> (length rows) cap)))))))))

(defun %find-decision (scope id)
  "The store holding decision ID, or NIL."
  (find-if (lambda (g) (st:claims-touching g 'mem:trace :decision id
                                          :role :subject :limit 1))
           (scope-stores scope)))

(defun %trace-tool (scope)
  (llm:make-tool
   "trace"
   "Reconstruct a decision as of the instant it was made: its rule,
outcome, the conclusion, every evidence cite resolved to the version
believed then with what has changed since, and any refusals."
   '((decision-id :type string))
   (lambda (decision-id)
     (let ((g (%find-decision scope decision-id)))
       (unless g (error "no decision ~a in scope" decision-id))
       (let ((rec (mem:trace g decision-id :scope (scope-stores scope))))
         (dolist (r (mem:decision-record-evidence rec))
           (note-cite scope (mem:cite-record-cite r)
                      (or (cite-store scope (mem:cite-record-cite r)) g)))
         (json:to-json
          (json:jobject
           "id" decision-id
           "store" (mem:store-name g)
           "producer" (mem:decision-record-producer rec)
           "at" (%iso (mem:decision-record-at rec))
           "rule" (mem:decision-record-rule rec)
           "rule-version" (mem:decision-record-rule-version rec)
           "confidence" (mem:decision-record-confidence rec)
           "outcome" (%standing (mem:decision-record-outcome rec))
           "conclusion" (let ((c (mem:decision-record-conclusion rec)))
                          (and c (%cite-record-json (mem:store-name g) c)))
           "evidence" (map 'vector
                           (lambda (r)
                             (%cite-record-json
                              (let ((s (cite-store
                                        scope (mem:cite-record-cite r))))
                                (and s (mem:store-name s)))
                              r))
                           (mem:decision-record-evidence rec))
           "refusals" (map 'vector
                           (lambda (f) (json:jobject "family" (car f)
                                                     "text" (cdr f)))
                           (mem:decision-record-refusals rec)))))))))

(defun %decisions-citing-tool (scope)
  (llm:make-tool
   "decisions-citing"
   "The decisions whose evidence cites a claim, newest first: which
conclusions rest on this belief."
   '((cite :type string))
   (lambda (cite)
     ;; Newest first ACROSS stores (spec SS6): sort by each decision's
     ;; own RECORDED-AT, not by scope order.
     (let ((rows '()))
       (dolist (g (scope-stores scope))
         (dolist (id (mem:decisions-citing g cite :scope (list g)))
           (let ((rec (mem:trace g id)))
             (push (cons (mem:decision-record-at rec)
                        (json:jobject "id" id "store" (mem:store-name g)))
                  rows))))
       (setf rows (sort rows #'local-time:timestamp> :key #'car))
       (json:to-json
        (json:jobject "decisions" (map 'vector #'cdr rows)))))))

;;; Stubs for Tasks 5-6.

(defun %conclude-tool (scope)
  (declare (ignore scope))
  (llm:make-tool
   "conclude"
   "Not yet implemented."
   '()
   (lambda () (error "not implemented"))))

(defun %conclude-absence-tool (scope)
  (declare (ignore scope))
  (llm:make-tool
   "conclude-absence"
   "Not yet implemented."
   '()
   (lambda () (error "not implemented"))))

(defun %retract-tool (scope)
  (declare (ignore scope))
  (llm:make-tool
   "retract"
   "Not yet implemented."
   '()
   (lambda () (error "not implemented"))))
