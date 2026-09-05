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
