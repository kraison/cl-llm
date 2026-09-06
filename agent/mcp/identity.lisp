;;;; agent/mcp/identity.lisp -- who a connection writes as.  Spec SS5.

(in-package #:cl-llm.agent.mcp)

(defun read-principals (path)
  "((producer . secret) ...) from PATH, each producer canonical; NIL
when PATH does not exist; signals on a malformed entry."
  (when (probe-file path)
    (let ((entries (with-open-file (s path)
                     (let ((*read-eval* nil)) (read s nil nil)))))
      (dolist (e entries entries)
        (unless (and (consp e) (stringp (car e)) (stringp (cdr e))
                     (st:canonical-producer-p (car e)))
          (error "malformed principals entry ~s" e))))))

(defun %address-string (address)
  (if (stringp address)
      address
      (format nil "~{~a~^.~}" (coerce address 'list))))

(defun loopback-p (address)
  "ADDRESS -- a usocket address vector or a string -- is loopback.  A
16-element vector is IPv6 (usocket's octet form): loopback iff every
element but the last is 0 and the last is 1."
  (if (and (vectorp address) (not (stringp address))
           (= 16 (length address)))
      (and (every #'zerop (subseq address 0 15)) (= 1 (aref address 15)))
      (let ((s (%address-string address)))
        (or (string= s "localhost") (string= s "::1")
            (and (>= (length s) 4) (string= "127." (subseq s 0 4)))))))

(defun check-bind (address principals)
  "ADDRESS when it is loopback or PRINCIPALS is non-NIL (SS5): an open
listener with the default identity cannot exist."
  (unless (or (loopback-p address) principals)
    (error "binding ~a needs a principals file; none is configured"
           address))
  address)

(defun %hello-object (line)
  ;; A top-level JSON array (a batch request) parses fine but makes
  ;; ASSOC signal; the whole form is guarded, not just YASON:PARSE, so
  ;; any non-object LINE is simply not a hello.
  (ignore-errors
   (let ((object (yason:parse line :object-as :alist)))
     (and (consp object)
          (assoc "cl-llm-memory" object :test #'string=)))))

(defun hello-line-p (line)
  "LINE is a hello (SS5), well-formed or not."
  (and (%hello-object line) t))

(defun parse-hello (line)
  "=> (values PRINCIPAL SECRET) from a hello LINE; NIL otherwise."
  (let ((hello (cdr (%hello-object line))))
    (when (consp hello)
      (values (cdr (assoc "principal" hello :test #'string=))
              (cdr (assoc "secret" hello :test #'string=))))))

(defun %tailscale-node (peer)
  ;; claude-code/<node> from `tailscale whois`; NIL when it cannot say.
  (ignore-errors
   (let* ((json (uiop:run-program
                 (list "tailscale" "whois" "--json" (%address-string peer))
                 :output :string :error-output nil))
          (node (cdr (assoc "Node" (yason:parse json :object-as :alist)
                            :test #'string=)))
          (name (cdr (assoc "ComputedName" node :test #'string=))))
     (and (stringp name) (plusp (length name))
          (format nil "claude-code/~(~a~)" name)))))

(defun resolve-identity (provider line peer default principals)
  "The producer for a connection, or :REFUSED (SS5).  :SECRET -- a hello
LINE matching PRINCIPALS names it; no hello on a loopback PEER is
DEFAULT; anything else is refused.  :TAILSCALE -- the peer's node."
  (ecase provider
    (:secret
     (multiple-value-bind (principal secret) (and line (parse-hello line))
       (cond ((and (stringp principal) (stringp secret))
              (let ((entry (assoc principal principals :test #'string=)))
                (if (and entry (string= (cdr entry) secret))
                    principal
                    :refused)))
             (line :refused)
             ((loopback-p peer) default)
             (t :refused))))
    (:tailscale (or (%tailscale-node peer) :refused))))
