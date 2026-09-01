;;;; memory/recall.lisp -- read back by subject, bounded by validity,
;;;; with supersession and retraction visible.  Spec SS6.

(in-package #:cl-llm.memory)

(defstruct belief-record
  "One recalled claim plus what a caller would otherwise recompute
wrongly.  SUPERSEDED-BY is COMPUTED -- the next claim in the same
(producer subject relation) series by validity start -- never stored,
so it cannot go stale (spec SS4)."
  claim
  (current-p nil)
  (superseded-by nil)
  (retracted-at nil)
  standing
  extent)

(defun %retracted-at (claim)
  (let ((e (st:claim-transaction-extent claim)))
    (and e
         (not (st:claim-current-p claim))
         (let ((end (te:bound-latest (te:extent-end e))))
           (and (typep end 'local-time:timestamp) end)))))

(defun %recorded-at (claim)
  "A timestamp for ordering; a pre-axis claim sorts last."
  (let ((at (st:claim-recorded-at claim)))
    (if (typep at 'local-time:timestamp)
        at
        (local-time:unix-to-timestamp 0))))

(defun %series-key (claim)
  (list (st:claim-producer claim)
        (st:claim-subject-namespace claim)
        (st:claim-subject-key claim)
        (st:claim-relation claim)))

(defun %successor (claim series)
  "The earliest-starting current claim in SERIES that starts after
CLAIM, or NIL."
  (let ((start (%start-instant claim))
        (best nil))
    (dolist (c series best)
      (when (and (not (eq c claim))
                 (st:claim-current-p c)
                 (local-time:timestamp< start (%start-instant c))
                 (or (null best)
                     (local-time:timestamp< (%start-instant c)
                                            (%start-instant best))))
        (setf best c)))))

(defun %object-key-for-order (claim)
  (if (typep claim 'belief-binary) (st:claim-object-key claim) ""))

(defun %before-p (a b)
  "The order contract: validity start descending, RECORDED-AT descending,
object key ascending."
  (let ((sa (%start-instant a)) (sb (%start-instant b)))
    (cond ((local-time:timestamp> sa sb) t)
          ((local-time:timestamp< sa sb) nil)
          (t (let ((ra (%recorded-at a)) (rb (%recorded-at b)))
               (cond ((local-time:timestamp> ra rb) t)
                     ((local-time:timestamp< ra rb) nil)
                     (t (string< (%object-key-for-order a)
                                 (%object-key-for-order b)))))))))

(defun %holds-at-p (claim at)
  "True when CLAIM's validity possibly contains AT: start no later than
AT, end unknown or no earlier than AT.  Not CLAIMS-TOUCHING's :AT --
the algebra admits an unknown end that precedes its own start, so an
open-ended belief starting AFTER the instant reads as :FINISHED-BY it
(kraison/cl-temporal-extent#2)."
  (let* ((e (st:claim-extent claim))
         (start (te:bound-earliest (te:extent-start e)))
         (end (te:extent-end e)))
    (and (not (local-time:timestamp< at start))
         (or (te:bound-unknown-p end)
             (eq :unbounded (te:bound-latest end))
             (not (local-time:timestamp< (te:bound-latest end) at))))))

(defun recall (graph subject &key relation producer at include-retracted)
  "BELIEF-RECORDs about SUBJECT, ordered newest validity first (SS6).
RELATION and PRODUCER narrow the series; AT keeps only beliefs valid at
that instant; retracted claims are excluded unless INCLUDE-RETRACTED.
Nothing recorded returns NIL -- which is not an absence standing."
  (%check-endpoint :subject subject)
  (let* ((all (st:claims-touching graph 'belief (car subject)
                                  (cdr subject) :role :subject))
         (wanted (remove-if-not
                  (lambda (c)
                    (and (or (null relation)
                             (string= relation (st:claim-relation c)))
                         (or (null producer)
                             (string= producer (st:claim-producer c)))
                         (or include-retracted (st:claim-current-p c))
                         (or (null at) (%holds-at-p c at))))
                  all))
         (series (make-hash-table :test 'equal)))
    ;; Successors are found within the full series, so a claim outside
    ;; the AT window can still be named as what superseded one inside.
    (dolist (c all) (push c (gethash (%series-key c) series)))
    (loop for c in (sort (copy-list wanted) #'%before-p)
          for current = (st:claim-current-p c)
          collect (make-belief-record
                   :claim c
                   :current-p (and current (%open-p c))
                   :superseded-by
                   (%successor c (gethash (%series-key c) series))
                   :retracted-at (%retracted-at c)
                   :standing (st:claim-standing c)
                   :extent (st:claim-extent c)))))
