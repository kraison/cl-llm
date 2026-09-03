;;;; memory/cite.lisp -- a claim as a string that survives regeneration,
;;;; and its resolution as of an instant.  Spec 2026-09-02 SS3, SS5.

(in-package #:cl-llm.memory)

(defun %family-parent-of (claim)
  "The registered parent class of CLAIM's family.  CLAIM-FAMILY is keyed
by the parent symbol only, so walk the precedence list until one
answers (an engine-side CLAIM-FAMILY-OF is asked for on
kraison/vivace-graph#321)."
  (dolist (class (sb-mop:class-precedence-list (class-of claim))
                 (%arg-error :claim claim "not a member of a claim family"))
    (let ((name (class-name class)))
      (when (and name (ignore-errors (st:claim-family name)))
        (return name)))))

(defun %render-family (symbol)
  (format nil "~(~a::~a~)"
          (package-name (symbol-package symbol)) (symbol-name symbol)))

(defun claim-cite (claim)
  "CLAIM as a cite: \"<pkg>::<parent>|<identity-key>\" (SS3)."
  (format nil "~a|~a" (%render-family (%family-parent-of claim))
          (st:claim-identity-key claim)))

(defun cite-p (x)
  (and (stringp x) (search "::" x) (position #\| x) t))

(defun %parse-family (string)
  (let ((sep (search "::" string)))
    (unless sep (%arg-error :cite string "no package-qualified family"))
    (let* ((pkg (find-package (string-upcase (subseq string 0 sep))))
           (sym (and pkg (find-symbol (string-upcase
                                       (subseq string (+ sep 2)))
                                      pkg))))
      (unless (and sym (ignore-errors (st:claim-family sym)))
        (%arg-error :cite string "names no registered claim family"))
      sym)))

(defun split-cite (cite)
  "Four values: the family's parent symbol, the subject namespace
keyword, the subject key, and the identity key.  A cite the engine did
not render is a BELIEF-ARGUMENT-ERROR.  The identity key's split, its
escape rule and the namespace rule -- canonical, THEN interned, so no
caller string can mint an unrecoverable keyword (#14 unit 2 final
review) -- are the engine's SPLIT-CLAIM-IDENTITY-KEY
(kraison/vivace-graph#321)."
  (unless (cite-p cite) (%arg-error :cite cite "not a cite"))
  (let* ((bar (position #\| cite))
         (family (%parse-family (subseq cite 0 bar)))
         (ikey (subseq cite (1+ bar))))
    (multiple-value-bind (producer namespace key)
        (handler-case (st:split-claim-identity-key ikey)
          (st:malformed-claim-identity-key ()
            (%arg-error :cite cite
                        "identity key is not one the engine rendered")))
      (declare (ignore producer))
      (values family namespace key ikey))))

(defstruct cite-record
  "One cite resolved AS OF an instant (SS5).  STATE is :RESOLVED, :REAPED
or :ABSENT; CLAIM is the version believed then when :RESOLVED.
CHANGED-SINCE is :RETRACTED, :SUPERSEDED, :UPDATED or NIL.  STORE names
the store the cite was actually resolved against -- NIL when none was
(SS4.3); RESOLVE-CITE leaves it to its caller, which knows the graph."
  cite family (state :absent) claim standing extent changed-since store)

(defun %stamp= (a b)
  "Version stamps by value: LOCAL-TIME:TIMESTAMP is a CLOS instance, so
EQUAL is EQ on it and the node cache can hand back one EQ instance for
two lookups of the same claim, passing vacuously.  A claim predating
the axis has a NIL stamp; two NILs match, one NIL is a change."
  (cond ((and (null a) (null b)) t)
        ((or (null a) (null b)) nil)
        (t (local-time:timestamp= a b))))

(defun %changed-since (as-of-version current)
  (cond ((and (st:claim-current-p as-of-version)
              (not (st:claim-current-p current)))
         :retracted)
        ((and (%open-p as-of-version) (not (%open-p current)))
         :superseded)
        ((not (%stamp= (st:claim-version-stamp as-of-version)
                       (st:claim-version-stamp current)))
         :updated)
        (t nil)))

(defun %current-among (ikey claims)
  "The claim in CLAIMS whose identity key is IKEY, preferring one still
current.  The key survives retraction and re-assertion
(kraison/vivace-graph#303), so retract-and-re-record of the identical
fact leaves two nodes on one key; anchoring on whichever the index
hands back first reported a held belief as :RETRACTED (#30)."
  (let ((matches (remove ikey claims :key #'st:claim-identity-key
                                     :test-not #'string=)))
    (or (find-if #'st:claim-current-p matches) (first matches))))

(defun resolve-cite (graph cite at)
  "CITE as of AT (SS5): find the claim by identity among the subject's
claims, then ask the engine for the version believed at AT.  Never
substitutes the current version -- it is consulted only for
CHANGED-SINCE.  A claim from a family with no validity extent can only
report CHANGED-SINCE :RETRACTED, :UPDATED or NIL -- :SUPERSEDED needs
%OPEN-P, which such a claim never satisfies."
  (multiple-value-bind (family ns key ikey) (split-cite cite)
    (let* ((current (%current-among ikey
                                    (st:claims-touching graph family ns key
                                                        :role :subject)))
           (id (and current (gdb:id current)))
           (then (and id
                      (find-if (lambda (c)
                                 (equalp id (if (st:reaped-claim-p c)
                                                (st:reaped-claim-id c)
                                                (gdb:id c))))
                               (st:claims-touching graph family ns key
                                                   :role :subject
                                                   :as-of at)))))
      (cond ((null then)
             (make-cite-record :cite cite :family family :state :absent))
            ((st:reaped-claim-p then)
             (make-cite-record :cite cite :family family :state :reaped))
            (t
             (make-cite-record :cite cite :family family :state :resolved
                               :claim then
                               :standing (st:claim-standing then)
                               :extent (st:claim-extent then)
                               :changed-since
                               (%changed-since then current)))))))
