;;;; tests-memory/scope-tests.lisp -- a scope of stores in trust order:
;;;; validation, snapshots, and the cross-store behaviour of every
;;;; reader.  Spec 2026-09-05 (S6b), cl-llm#24.

(in-package #:cl-llm.memory/tests)
(in-suite :cl-llm-memory)

(defun %clockless-pair (fn)
  "Two stores with NO clock, for the refusals a clocked fixture cannot
show.  *SYSTEM-CLOCK* is bound NIL explicitly so the premise does not
depend on run order."
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (gdb:*system-clock* nil)
         (gdb:*system-directory*
           (format nil "/tmp/cl-llm-scope-sys-~a/" stamp))
         (dirs (list (format nil "/tmp/cl-llm-scope-a-~a/" stamp)
                     (format nil "/tmp/cl-llm-scope-b-~a/" stamp)))
         (a (gdb:make-graph :cl-llm-memory (first dirs)
                            :buffer-pool-size 1000))
         (b (gdb:make-graph :memory-private (second dirs)
                            :buffer-pool-size 1000)))
    (unwind-protect (funcall fn a b)
      (ignore-errors (gdb:close-graph a))
      (ignore-errors (gdb:close-graph b))
      (dolist (d (cons gdb:*system-directory* dirs))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))

(defmacro with-clockless-pair ((a b) &body body)
  `(%clockless-pair (lambda (,a ,b) ,@body)))

(test check-scope-accepts-two-clocked-stores-and-one-clockless-store
  "SS3: the positive cases.  A multi-store scope on one clock passes;
a single store needs no clock."
  (with-two-stores (a b)
    (let ((s (list a b)) (r (list b a)))
      (is (eq s (mem:check-scope s)) "returns the very list")
      (is (eq r (mem:check-scope r :write-store a)))))
  (with-clockless-pair (a b)
    (declare (ignore b))
    (is (null (gdb:graph-system-clock a)) "control: no clock")
    (is (equal (list a) (mem:check-scope (list a))))))

(test check-scope-refuses-a-malformed-scope
  "SS3: empty, a repeated graph, a write store outside the list --
each SCOPE-ARGUMENT-ERROR, a BELIEF-ARGUMENT-ERROR whose message names
the store."
  (with-two-stores (a b)
    (signals mem:scope-argument-error (mem:check-scope '()))
    (signals mem:scope-argument-error (mem:check-scope (list a a)))
    (signals mem:scope-argument-error
      (mem:check-scope (list a) :write-store b))
    (handler-case (mem:check-scope (list a a))
      (mem:scope-argument-error (c)
        (is (typep c 'mem:belief-argument-error))
        (is (search "cl-llm-memory" (princ-to-string c)))))
    (is (equal (list a b) (mem:check-scope (list a b))) "control")))

(test check-scope-refuses-a-closed-store
  "SS3: GRAPH-OPEN-P is the engine's own open flag (recon E8)."
  (with-clockless-pair (a b)
    (declare (ignore b))
    (is (equal (list a) (mem:check-scope (list a))) "control: open")
    (gdb:close-graph a)
    (signals mem:scope-argument-error (mem:check-scope (list a)))))

(test check-scope-refuses-two-stores-not-on-one-clock
  "SS3 one regime: two clockless stores are refused; the message names
the clockless store."
  (with-clockless-pair (a b)
    (signals mem:scope-argument-error (mem:check-scope (list a b)))
    (handler-case (mem:check-scope (list a b))
      (mem:scope-argument-error (c)
        (is (search "no system clock" (princ-to-string c)))))
    (is (equal (list a) (mem:check-scope (list a))) "control")))

(test check-scope-refuses-two-stores-on-two-clocks
  "SS3: attached, but to different clocks -- two counters, no shared
axis.  Built outside the fixture: the two store names are the only
schemas this suite declares, and a third open graph under either name
is a STORE-ID-COLLISION-ERROR (one system directory per image)."
  (let* ((stamp (format nil "~a-~a" (get-internal-real-time)
                        (random 1000000)))
         (gdb:*system-clock* nil)
         (gdb:*system-directory*
           (format nil "/tmp/cl-llm-scope2-sys-~a/" stamp))
         (cdirs (list (format nil "/tmp/cl-llm-scope2-c1-~a/" stamp)
                      (format nil "/tmp/cl-llm-scope2-c2-~a/" stamp)))
         (dirs (list (format nil "/tmp/cl-llm-scope2-a-~a/" stamp)
                     (format nil "/tmp/cl-llm-scope2-b-~a/" stamp)))
         (clocks (mapcar #'gdb:open-system-clock cdirs))
         (a nil) (b nil))
    (unwind-protect
         (progn
           (setf a (gdb:make-graph :cl-llm-memory (first dirs)
                                   :buffer-pool-size 1000
                                   :system-clock (first clocks))
                 b (gdb:make-graph :memory-private (second dirs)
                                   :buffer-pool-size 1000
                                   :system-clock (second clocks)))
           (is (not (eq (gdb:graph-system-clock a)
                        (gdb:graph-system-clock b)))
               "control: two clocks")
           (signals mem:scope-argument-error
             (mem:check-scope (list a b)))
           (handler-case (mem:check-scope (list a b))
             (mem:scope-argument-error (e)
               (is (search "different clock" (princ-to-string e)))))
           (is (equal (list a) (mem:check-scope (list a))) "control"))
      (when a (ignore-errors (gdb:close-graph a)))
      (when b (ignore-errors (gdb:close-graph b)))
      (dolist (c clocks) (ignore-errors (gdb:close-system-clock c)))
      (dolist (d (append cdirs dirs (list gdb:*system-directory*)))
        (ignore-errors (uiop:delete-directory-tree
                        (pathname d) :validate t
                        :if-does-not-exist :ignore))))))

(test scope-snapshots-compose-and-refuse-inside-a-transaction
  "SS3 (recon C9): under WITH-SCOPE-SNAPSHOTS both stores answer and
*TRANSACTION* is NIL; inside an open transaction the read is refused
before any engine call -- for a two-store scope, where the engine would
have signalled CROSS-GRAPH-TRANSACTION-ERROR on the foreign half, and
for a one-store scope, where the engine would have ALLOWED the read and
shown uncommitted state.  The control is the engine's own refusal."
  (with-two-stores (a b)
    (%belief-in a "ci-status" '(:verdict . "green"))
    (%belief-in b "ci-status" '(:verdict . "red"))
    (mem:with-scope-snapshots ((list a b))
      (is (null gdb:*transaction*))
      (is (= 1 (length (mem:recall a +ss+))))
      (is (= 1 (length (mem:recall b +ss+)))))
    (gdb:with-transaction (:graph a)
      (signals mem:scope-argument-error
        (mem:with-scope-snapshots ((list a b)) (mem:recall b +ss+)))
      (signals mem:scope-argument-error
        (mem:with-scope-snapshots ((list a)) (mem:recall a +ss+)))
      ;; The controls go to the engine directly: RECALL itself is now
      ;; refused up front by the helper.
      (signals gdb:cross-graph-transaction-error
        (st:claims-touching b 'mem:belief :repo "cl-llm" :role :subject)
        "control: the engine refuses the foreign half only")
      (is (= 1 (length (st:claims-touching a 'mem:belief :repo "cl-llm"
                                           :role :subject)))
          "control: the engine allows the own-store half"))))

(defun %row (records object-key)
  (find object-key records
        :key (lambda (r) (st:claim-object-key (mem:belief-record-claim r)))
        :test #'string=))

(test recall-supersedes-across-stores-from-equal-or-higher-trust-only
  "SS4 (#46): one series split across two stores.  Scope (P W), P more
trusted.  A newer belief in P supersedes W's older one: the W row is
not current and names P's claim and store.  A newer belief in W does
NOT supersede P's older one: both rows current, nothing superseded.
The reversed scope is the control that proves the rule reads the
order."
  (with-two-stores (w p)
    ;; W: green from 09-01; P: red from 09-02 -- P newer.
    (%belief-in w "ci-status" '(:verdict . "green"))
    (gdb:with-transaction (:graph p)
      (mem:record-belief p +ss+ "ci-status" '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (%open-from (%ts "2026-09-02T08:00:00Z"))))
    (let* ((rows (mem:recall p +ss+ :scope (list p w)))
           (green (%row rows "green"))
           (red (%row rows "red")))
      (is (= 2 (length rows)))
      (is (eq w (mem:belief-record-store green)))
      (is (eq p (mem:belief-record-store red)))
      (is (mem:belief-record-current-p red))
      (is (not (mem:belief-record-current-p green))
          "P is more trusted and newer: W's belief is superseded")
      (is (eq (mem:belief-record-claim red)
              (mem:belief-record-superseded-by green)))
      (is (eq p (mem:belief-record-superseded-by-store green))))
    ;; The reversed scope: W more trusted than P; P's newer belief may
    ;; not supersede W's.
    (let* ((rows (mem:recall w +ss+ :scope (list w p)))
           (green (%row rows "green"))
           (red (%row rows "red")))
      (is (mem:belief-record-current-p green) "control: reversed order")
      (is (mem:belief-record-current-p red))
      (is (null (mem:belief-record-superseded-by green)))
      (is (null (mem:belief-record-superseded-by red))))
    ;; Single-store reads are unchanged: each store sees only itself.
    (is (= 1 (length (mem:recall w +ss+))))
    (is (mem:belief-record-current-p (first (mem:recall w +ss+))))))

(test recall-keeps-filters-per-store-and-the-order-contract
  "SS4: :AT and :RELATION apply per store before the union; the union
keeps validity-start-descending order across stores."
  (with-two-stores (w p)
    (%belief-in w "ci-status" '(:verdict . "green"))
    (%belief-in w "owner" '(:person . "kevin"))
    (gdb:with-transaction (:graph p)
      (mem:record-belief p +ss+ "ci-status" '(:verdict . "red")
                         :producer +p+ :standing :observed
                         :extent (%open-from (%ts "2026-09-02T08:00:00Z"))))
    (let ((rows (mem:recall w +ss+ :relation "ci-status"
                                   :scope (list w p))))
      (is (= 2 (length rows)))
      (is (string= "red" (st:claim-object-key
                          (mem:belief-record-claim (first rows))))
          "newest validity first, across stores"))
    (is (= 2 (length (mem:recall w +ss+ :at (%ts "2026-09-01T12:00:00Z")
                                        :scope (list w p))))
        "at 09-01 noon: green and owner, not red")
    (is (= 3 (length (mem:recall w +ss+ :scope (list w p)))))))

(test resolve-cite-answers-from-the-first-store-in-scope
  "SS6 (#48): one cite, two stores holding the same identity; the
record names the first store in scope order, whichever order is
given.  A cite whose claim postdates AT is :ABSENT with no store."
  (with-two-stores (w p)
    (let* ((cw (%belief-in w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite cw))
           (cp (%belief-in p "ci-status" '(:verdict . "green")))
           ;; AS-OF NOW must postdate both versions' stamps.
           (now (progn (sleep 0.01) (local-time:now))))
      (is (string= cite (mem:claim-cite cp))
          "control: both stores mint one cite for one fact")
      (let ((r (mem:resolve-cite w cite now :scope (list w p))))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (string= "cl-llm-memory" (mem:cite-record-store r))))
      (let ((r (mem:resolve-cite w cite now :scope (list p w))))
        (is (eq :resolved (mem:cite-record-state r)))
        (is (string= "memory-private" (mem:cite-record-store r))))
      (let ((r (mem:resolve-cite w (mem:claim-cite
                                    (%belief-in w "owner"
                                                '(:person . "x")))
                                 (%ts "2020-01-01T00:00:00Z")
                                 :scope (list w p))))
        (is (eq :absent (mem:cite-record-state r)))
        (is (null (mem:cite-record-store r)))))))

(test decisions-citing-names-the-store-and-trace-finds-it-in-scope
  "SS7 (#47): a decision recorded in P is found through a scope whose
first store is W: DECISIONS-CITING returns (id . store-name) and TRACE
resolves it, naming its store; TRACE-LISTING gives a :MISSING row for an
id no store holds instead of signalling."
  (with-two-stores (w p)
    (let* ((e (%belief-in p "ci-status" '(:verdict . "green")))
           (d (mem:conclude p (list :belief +ss+ "releasable" '(:v . "yes")
                                    :standing :inferred)
                            :producer +p+ :evidence (list e) :rule "r"
                            :scope (list p))))
      (is (equal (list (cons (mem:decision-id d) "memory-private"))
                 (mem:decisions-citing w e :scope (list w p))))
      (let ((rec (mem:trace w (mem:decision-id d) :scope (list w p))))
        (is (not (null rec)))
        (is (string= "memory-private" (mem:decision-record-store rec)))
        (is (eq :concluded (mem:decision-record-outcome rec))))
      (is (null (mem:trace w (mem:decision-id d)))
          "control: W alone does not hold it")
      (is (equal '((:missing nil nil nil nil))
                 (mem:trace-listing w (list "no-such-id")
                                    :scope (list w p)))))))

(test write-evidence-keeps-one-row-per-cite-naming-the-first-store
  "SS7 (#51, documented bound): the trace family's identity excludes
METHOD, so one cite cited from two stores is ONE evidence row, naming
the first store in the pairs list; distinct cites are distinct rows
(the control).  Two rows for one cite would collide on the unique
constraint."
  (with-two-stores (w p)
    (let* ((cw (%belief-in w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite cw))
           (other (mem:claim-cite (%belief-in w "owner" '(:person . "k")))))
      (%belief-in p "ci-status" '(:verdict . "green"))
      (let* ((d (mem:conclude w (list :belief +ss+ "releasable"
                                      '(:v . "yes") :standing :inferred)
                              :producer +p+
                              :evidence (list (cons cite "memory-private")
                                              (cons cite "cl-llm-memory")
                                              other)
                              :rule "r" :scope (list w p)))
             (rec (mem:trace w (mem:decision-id d) :scope (list w p)))
             (ev (mem:decision-record-evidence rec)))
        (is (= 2 (length ev)) "one row per cite: two cites, two rows")
        (is (string= "memory-private"
                     (mem:cite-record-store
                      (find cite ev :key #'mem:cite-record-cite
                                    :test #'string=)))
            "the first pair's store names the row")))))

(test decisions-record-their-commit-epoch
  "SS7: two conclusions on two stores under one clock record integer
epochs in increasing order, and TRACE reads the same number back; a
refusal records one too."
  (with-two-stores (w p)
    (let* ((d1 (mem:conclude w (list :belief +ss+ "a" '(:v . "1")
                                     :standing :inferred
                                     :extent (%open-from
                                              (%ts "2026-09-01T08:00:00Z")))
                             :producer +p+ :rule "r"))
           (d2 (mem:conclude p (list :belief +ss+ "b" '(:v . "1")
                                     :standing :inferred)
                             :producer +p+ :rule "r"))
           ;; The validator path: retract, then re-assert the identical
           ;; fact at the same valid-from -- the unique family refuses
           ;; (as trace-tests' a-refused-proposal-is-recorded-and-writes-
           ;; no-belief does).
           (start (%open-from (%ts "2026-09-01T08:00:00Z")))
           (d3 (progn (gdb:with-transaction (:graph w)
                        (mem:retract-belief (mem:decision-claim d1)))
                      (mem:conclude w (list :belief +ss+ "a" '(:v . "1")
                                            :standing :inferred
                                            :extent start)
                                    :producer +p+ :rule "r"))))
      (is (integerp (mem:decision-epoch d1)))
      (is (< (mem:decision-epoch d1) (mem:decision-epoch d2)))
      (is (= (mem:decision-epoch d1)
             (mem:decision-record-epoch (mem:trace w (mem:decision-id d1)))))
      (is (= (mem:decision-epoch d2)
             (mem:decision-record-epoch
              (mem:trace w (mem:decision-id d2) :scope (list w p)))))
      (is (eq :refused (mem:decision-outcome d3)) "control: refused path")
      (is (integerp (mem:decision-epoch d3))))))

(defun %families (g id)
  (mapcar #'car (mem:decision-record-refusals (mem:trace g id))))

(test conclude-refuses-a-belief-governed-by-a-higher-trust-store
  "SS5 (#50): scope (P W), write store W.  P holds the governing prior
of the proposal's series; the proposal is refused with the
SCOPE-CONFLICT family naming P's cite and store, nothing is written to
either store, and the decision's report is the (:SCOPE-CONFLICT ...)
list.  The control: the same proposal with P absent from the scope
concludes."
  (with-two-stores (w p)
    (let* ((prior (%belief-in p "ci-status" '(:verdict . "green")))
           (before-w (length (st:claims-by-producer w 'mem:belief +p+)))
           (before-p (length (st:claims-by-producer p 'mem:belief +p+)))
           (before-p-trace (length (st:claims-by-producer p 'mem:trace
                                                          +p+)))
           (d (mem:conclude w (list :belief +ss+ "ci-status"
                                    '(:verdict . "red") :standing :inferred
                                    :extent (%open-from
                                             (%ts "2026-09-02T08:00:00Z")))
                            :producer +p+ :rule "r" :scope (list p w))))
      (is (eq :refused (mem:decision-outcome d)))
      (is (null (mem:decision-claim d)))
      (is (equal (list :scope-conflict (mem:claim-cite prior)
                       "memory-private")
                 (mem:decision-report d)))
      (is (equal '("scope-conflict") (%families w (mem:decision-id d))))
      (let ((text (cdr (first (mem:decision-record-refusals
                               (mem:trace w (mem:decision-id d)))))))
        (is (search (mem:claim-cite prior) text))
        (is (search "memory-private" text))
        (is (not (search "(:" text)) "prose, not a Lisp form"))
      (is (= before-w (length (st:claims-by-producer w 'mem:belief +p+))))
      (is (= before-p (length (st:claims-by-producer p 'mem:belief +p+))))
      (is (= before-p-trace
             (length (st:claims-by-producer p 'mem:trace +p+)))
          "nothing traced into P either")
      (is (eq :concluded
              (mem:decision-outcome
               (mem:conclude w (list :belief +ss+ "ci-status"
                                     '(:verdict . "red")
                                     :standing :inferred
                                     :extent (%open-from
                                              (%ts "2026-09-02T08:00:00Z")))
                             :producer +p+ :rule "r" :scope (list w))))
          "control: without P in scope the write proceeds"))))

(test conclude-overrides-a-lower-trust-prior-and-records-it-as-evidence
  "SS5 (#50): scope (W P), write store W.  P holds the prior; W's newer
belief is concluded, supersedes P's at read time, and the trace carries
the overridden cite with P's name as its store.  A prior in the write
store itself still goes to the validator (the control)."
  (with-two-stores (w p)
    (let* ((prior (%belief-in p "ci-status" '(:verdict . "green")))
           (d (mem:conclude w (list :belief +ss+ "ci-status"
                                    '(:verdict . "red") :standing :inferred
                                    :extent (%open-from
                                             (%ts "2026-09-02T08:00:00Z")))
                            :producer +p+ :rule "r" :scope (list w p)))
           (rec (mem:trace w (mem:decision-id d) :scope (list w p)))
           (ev (mem:decision-record-evidence rec)))
      (is (eq :concluded (mem:decision-outcome d)))
      (is (= 1 (length ev)))
      (is (string= (mem:claim-cite prior) (mem:cite-record-cite (first ev))))
      (is (string= "memory-private" (mem:cite-record-store (first ev))))
      (let ((rows (mem:recall w +ss+ :scope (list w p))))
        (is (not (mem:belief-record-current-p (%row rows "green"))))
        (is (mem:belief-record-current-p (%row rows "red"))))
      ;; Control: the validator path is untouched -- retract W's red,
      ;; re-assert the identical fact at the same valid-from, and the
      ;; unique family refuses, not scope-conflict.  RETRACT-BELIEF
      ;; needs an ambient transaction or :GRAPH to resolve (as the
      ;; analogous fix in decisions-record-their-commit-epoch does).
      (gdb:with-transaction (:graph w)
        (mem:retract-belief (mem:decision-claim d)))
      (let ((d2 (mem:conclude w (list :belief +ss+ "ci-status"
                                      '(:verdict . "red")
                                      :standing :inferred
                                      :extent (%open-from
                                               (%ts "2026-09-02T08:00:00Z")))
                              :producer +p+ :rule "r" :scope (list w p))))
        (is (eq :refused (mem:decision-outcome d2)))
        (is (equal '("unique") (%families w (mem:decision-id d2))))))))

(test conclude-absence-takes-no-scope-pre-read
  "SS5 (recon C3): an absence has no series; the pre-read does not
apply and the write proceeds under any scope."
  (with-two-stores (w p)
    (%belief-in p "ci-status" '(:verdict . "green"))
    (let ((d (mem:conclude w (list :absence +ss+ "ci-status"
                                   :standing :searched-empty)
                           :producer +p+ :rule "r" :scope (list p w))))
      (is (eq :concluded (mem:decision-outcome d))))))

;;; #53 (SS7): the epoch axis.  Under a clocked scope a decision's
;;; cites resolve at its commit epoch, and the scope's trust rule
;;; reaches CHANGED-SINCE.

(test trace-resolves-evidence-at-the-decisions-epoch
  "SS7 (#53): under a clocked scope TRACE resolves every cite on the
epoch axis and says which axis it used.  P's cited claim is updated in
place after the decision -- CONFIDENCE, which the identity key does not
cover, so the cite still resolves -- and the trace still reports the
version live at the decision's epoch, flagged :UPDATED.  Controls: the
same trace before the update reports no change, and an :EPOCH read past
the update sees the new version, so the epoch is load-bearing."
  (with-two-stores (w p)
    (let* ((e (gdb:with-transaction (:graph p)
                (mem:record-belief
                 p +ss+ "ci-status" '(:verdict . "green")
                 :producer +p+ :standing :observed :confidence 0.9
                 :extent (%open-from (%ts "2026-01-01T00:00:00Z")))))
           (cite (mem:claim-cite e))
           (d (mem:conclude w (list :belief +ss+ "releasable"
                                    '(:v . "yes") :standing :inferred)
                            :producer +p+ :evidence (list e) :rule "r"
                            :scope (list w p)))
           (before (mem:trace w (mem:decision-id d) :scope (list w p))))
      (is (eq :epoch (mem:decision-record-axis before)))
      (is (null (mem:cite-record-changed-since
                 (first (mem:decision-record-evidence before))))
          "control: nothing has changed yet")
      ;; A new version of the cited claim, and so a later epoch.
      (gdb:with-transaction (:graph p)
        (let ((c (gdb:copy e)))
          (setf (st:claim-confidence c) 0.5)
          (gdb:save c)))
      (let* ((rec (mem:trace w (mem:decision-id d) :scope (list w p)))
             (ev (first (mem:decision-record-evidence rec))))
        (is (eq :epoch (mem:decision-record-axis rec)))
        (is (string= cite (mem:cite-record-cite ev)))
        (is (eq :updated (mem:cite-record-changed-since ev)))
        (is (= 0.9 (st:claim-confidence (mem:cite-record-claim ev)))
            "the version live at the decision's epoch, not today's"))
      (is (= 0.5 (st:claim-confidence
                  (mem:cite-record-claim
                   (mem:resolve-cite p cite nil
                                     :epoch (+ 1000000
                                               (mem:decision-epoch d))))))
          "control: a later epoch sees the update"))))

(test trace-reports-a-cross-store-supersession-of-evidence
  "SS7 (#53): W's cited belief is still open in W, so the single-store
%CHANGED-SINCE sees nothing; a newer belief in the MORE trusted P
supersedes it over the scope, and the evidence record says :SUPERSEDED
and names the successor's cite and store.  The evidence still resolves
in the store the decision named.  Control: the reversed scope, where P
is less trusted and may not supersede."
  (with-two-stores (w p)
    (let* ((green (%belief-in w "ci-status" '(:verdict . "green")))
           (d (mem:conclude w (list :belief +ss+ "releasable"
                                    '(:v . "yes") :standing :inferred)
                            :producer +p+ :evidence (list green)
                            :rule "r"))
           (red (gdb:with-transaction (:graph p)
                  (mem:record-belief
                   p +ss+ "ci-status" '(:verdict . "red")
                   :producer +p+ :standing :observed
                   :extent (%open-from
                            (%ts "2026-09-02T08:00:00Z"))))))
      (let* ((rec (mem:trace w (mem:decision-id d) :scope (list p w)))
             (ev (first (mem:decision-record-evidence rec))))
        (is (string= (mem:claim-cite green) (mem:cite-record-cite ev)))
        (is (eq :superseded (mem:cite-record-changed-since ev)))
        (is (equal (cons (mem:claim-cite red) "memory-private")
                   (mem:cite-record-superseded-by ev)))
        (is (string= "cl-llm-memory" (mem:cite-record-store ev))
            "resolved in the store the evidence named, not P"))
      (let* ((rec (mem:trace w (mem:decision-id d) :scope (list w p)))
             (ev (first (mem:decision-record-evidence rec))))
        (is (null (mem:cite-record-changed-since ev))
            "control: P is less trusted; it may not supersede")
        (is (null (mem:cite-record-superseded-by ev)))))))

(test trace-on-a-clockless-store-uses-the-instant-axis
  "SS7 (#53): a store with no system clock still numbers its
transactions, but those epochs are a private counter -- the engine
refuses to read on that axis -- so TRACE resolves at the outcome's
recorded instant and reports :INSTANT."
  (with-memory-graph (g)
    (is (null (gdb:graph-system-clock g)) "control: no clock")
    (let* ((e (%belief-in g "ci-status" '(:verdict . "green")))
           (d (mem:conclude g (list :belief +ss+ "releasable"
                                    '(:v . "yes") :standing :inferred)
                            :producer +p+ :evidence (list e) :rule "r"))
           (rec (mem:trace g (mem:decision-id d))))
      (is (eq :instant (mem:decision-record-axis rec)))
      (is (integerp (mem:decision-record-epoch rec))
          "an epoch exists; the clock, not the epoch, is the test")
      (is (eq :resolved (mem:cite-record-state
                         (first (mem:decision-record-evidence rec)))))
      (is (eq :resolved (mem:cite-record-state
                         (mem:decision-record-conclusion rec))))
      (signals st:epoch-axis-unavailable
        (mem:resolve-cite g (mem:claim-cite e) nil :epoch 1)))))

(test resolve-cite-refuses-both-or-neither-axis
  "SS7 (#53): exactly one axis.  Neither and both are
BELIEF-ARGUMENT-ERRORs; either alone resolves (the control)."
  (with-two-stores (w p)
    (declare (ignore p))
    (let* ((c (%belief-in w "ci-status" '(:verdict . "green")))
           (cite (mem:claim-cite c))
           (now (progn (sleep 0.01) (local-time:now)))
           (epoch (st:claim-commit-epoch
                   (mem:cite-record-claim
                    (mem:resolve-cite w cite now)))))
      (is (integerp epoch) "control: the store stamps an epoch")
      (signals mem:belief-argument-error (mem:resolve-cite w cite nil))
      (signals mem:belief-argument-error
        (mem:resolve-cite w cite now :epoch epoch))
      (is (eq :resolved (mem:cite-record-state
                         (mem:resolve-cite w cite now))))
      (is (eq :resolved (mem:cite-record-state
                         (mem:resolve-cite w cite nil :epoch epoch)))))))

(test a-lower-trust-store-never-outdates-a-higher-one
  "#82 under SS4's trust rule: Y's later belief in the second store
does not outdate X's in the first.  The reversed scope, where Y's
store leads, is the control that proves the rule reads scope order."
  (with-two-stores (w p)
    (%belief-as w +px+ '(:verdict . "green") "2026-09-01T08:00:00Z"
                :subject +ss+)
    (%belief-as p +py+ '(:verdict . "red") "2026-09-02T08:00:00Z"
                :subject +ss+)
    (let* ((rows (mem:recall w +ss+ :relation "ci-status"
                             :scope (list w p)))
           (green (%row rows "green")))
      (is (= 2 (length rows)))
      (is (mem:belief-record-current-p green))
      (is (null (mem:belief-record-outdated-by green))
          "P is lower trust: its later belief does not outdate W's"))
    (let* ((rows (mem:recall p +ss+ :relation "ci-status"
                             :scope (list p w)))
           (green (%row rows "green"))
           (red (%row rows "red")))
      (is (not (null (mem:belief-record-outdated-by green)))
          "reversed: P is trusted first, so W's belief is outdated")
      (is (string= (st:claim-identity-key (mem:belief-record-claim red))
                   (st:claim-identity-key
                    (mem:belief-record-outdated-by green))))
      (is (eq p (mem:belief-record-outdated-by-store green)))
      (is (null (mem:belief-record-outdated-by red))))))

(test the-leader-is-sought-per-candidate-among-the-stores-it-trusts
  "#82: the trust rule belongs to the CHOICE of leader, per candidate.
One global leader vetoed afterwards would let P's later belief mask
W-NEW, the legitimate outdater in W's own store.  Scope (W P): W holds
X-OLD from 09-01 and W-NEW from 09-02, P holds P-NEWEST from 09-03 --
three producers on one (subject, relation)."
  (with-two-stores (w p)
    (%belief-as w +px+ '(:verdict . "x-old") "2026-09-01T08:00:00Z"
                :subject +ss+)
    (%belief-as w +pz+ '(:verdict . "w-new") "2026-09-02T08:00:00Z"
                :subject +ss+)
    (%belief-as p +py+ '(:verdict . "p-newest") "2026-09-03T08:00:00Z"
                :subject +ss+)
    (flet ((leader-key (row)
             (let ((c (mem:belief-record-outdated-by row)))
               (and c (st:claim-object-key c)))))
      (let* ((rows (mem:recall w +ss+ :relation "ci-status"
                               :scope (list w p)))
             (x (%row rows "x-old"))
             (b (%row rows "w-new"))
             (a (%row rows "p-newest")))
        (is (= 3 (length rows)))
        (is (string= "w-new" (leader-key x))
            "X is outdated by W's own later belief, not masked by P's")
        (is (eq w (mem:belief-record-outdated-by-store x)))
        (is (null (leader-key b))
            "W-NEW leads among the stores that may outdate it")
        (is (null (leader-key a)) "P-NEWEST is the latest anywhere"))
      ;; The mirror: P first in scope, so its later belief outdates both
      ;; of W's -- the trust rule reads scope order, not store identity.
      (let* ((rows (mem:recall p +ss+ :relation "ci-status"
                               :scope (list p w)))
             (x (%row rows "x-old"))
             (b (%row rows "w-new"))
             (a (%row rows "p-newest")))
        (is (string= "p-newest" (leader-key x)))
        (is (string= "p-newest" (leader-key b)))
        (is (eq p (mem:belief-record-outdated-by-store x)))
        (is (null (leader-key a)))))))
