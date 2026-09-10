;;;; agent/mcp/config.lisp -- the environment to a scope on one clock,
;;;; and the bounded close.  Spec SS4, SS6; recon C2, C11.

(in-package #:cl-llm.agent.mcp)

(defun env (name &optional default)
  "The environment variable NAME, or DEFAULT when unset or empty."
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun %dir (string)
  (namestring (uiop:ensure-directory-pathname string)))

(defun parse-scope (spec)
  "SPEC \"name=dir,name=dir\" -> ((keyword . dir) ...) in the given
order -- trust order, most trusted first (SS4).  Dirs get a trailing
slash.  Signals on an entry without a name or a dir."
  (loop for entry in (uiop:split-string spec :separator ",")
        for trimmed = (string-trim " " entry)
        unless (zerop (length trimmed))
          collect (let ((at (position #\= trimmed)))
                    (unless (and at (plusp at) (< (1+ at) (length trimmed)))
                      (error "malformed scope entry ~s; want name=dir"
                             trimmed))
                    (cons (intern (string-upcase (subseq trimmed 0 at))
                                  :keyword)
                          (%dir (subseq trimmed (1+ at)))))))

(defun declare-store-schemas (names)
  "DEFINE-MEMORY-STORE for each of NAMES.  The macro takes an
unevaluated name, so this is an EVAL per name; redeclaring a declared
name is the engine's idempotent case (vivace-graph#196; recon C11)."
  (dolist (name names names)
    (eval `(mem:define-memory-store ,name))))

(defun %open-store (name dir clock pool)
  ;; The memory image's own rule: open when the schema file exists.
  (if (probe-file (concatenate 'string dir "schema.dat"))
      (gdb:open-graph name dir :buffer-pool-size pool :system-clock clock)
      (gdb:make-graph name dir :buffer-pool-size pool :system-clock clock)))

(defun open-scope (&key spec write clock-dir system-dir (buffer-pool 2000))
  "Open the clock at CLOCK-DIR, then every store of SPEC (PARSE-SCOPE's
list) attached to it, under SYSTEM-DIR.  => (values STORES WRITE-STORE
CLOCK).  WRITE names the write store (a string, case-insensitive),
default the last entry.  STORE-NOT-CLOSED-CLEANLY-ERROR and
SYSTEM-CLOCK-IN-USE propagate for the caller to report (SS7); the
process exits on them, which releases the clock's lock.  Any failure
here -- including an unmatched WRITE, discovered only after every
store is already open -- closes whatever opened via CLOSE-SCOPE before
re-signalling, so a partial open never leaks a store into the image's
global id registry (GDB:STORE-ID-COLLISION-ERROR)."
  ;; Global and not restored: in CI's single image the memory and agent
  ;; suites run before this one, and nothing after reads the old value.
  (setf gdb:*system-directory* (%dir system-dir))
  (declare-store-schemas (mapcar #'car spec))
  (let (clock stores ok)
    (unwind-protect
         (progn
           (setf clock (gdb:open-system-clock (%dir clock-dir)))
           (dolist (e spec)
             (push (%open-store (car e) (cdr e) clock buffer-pool) stores))
           (setf stores (nreverse stores))
           (let ((write-store
                   (if write
                       (or (find write stores :key #'gdb:graph-name
                                              :test #'string-equal)
                           (error "write store ~a is not in the scope"
                                  write))
                       (car (last stores)))))
             (setf ok t)
             (values stores write-store clock)))
      (unless ok (close-scope stores clock)))))

(defun close-scope (stores clock)
  "Close every store, each with *GRAPH* bound to it and without the
snapshot -- unbounded work before the .dirty marker clears (recon C2)
-- then the clock.  Never signals; a closed store is skipped."
  (dolist (g stores)
    (ignore-errors
     (let ((gdb:*graph* g))
       (gdb:close-graph g :snapshot-p nil))))
  (when clock
    (ignore-errors (gdb:close-system-clock clock)))
  nil)

;;;; The semantic endpoint index's embedder (#78 SS5)

(defun %embed-floor (string)
  "STRING as the cosine floor: read with *READ-EVAL* NIL, so a value
from the environment cannot evaluate, and under WITH-STANDARD-IO-SYNTAX,
which makes \"0.42\" a single-float.  => the real; signals naming the
offending text otherwise."
  (let ((v (handler-case (with-standard-io-syntax
                           (let ((*read-eval* nil))
                             (read-from-string string)))
             (error () nil))))
    (unless (realp v)
      (error "CL_LLM_MEMORY_EMBED_FLOOR must be a real in [0, 1], not ~s"
             string))
    v))

(defun embedder-from-env ()
  "The semantic index's embedder from CL_LLM_MEMORY_EMBED_URL / _MODEL /
_KEY / _FLOOR (#78 SS5), or NIL when the URL is empty -- the feature is
then inert.  A URL without a model or a floor is an error, as is a floor
outside [0, 1] (MAKE-ENDPOINT-EMBEDDER's own check).  Trap: nothing is
embedded here, so a URL nothing answers on is found only at the first
round trip -- the entry points probe once and report."
  (let ((url (env "CL_LLM_MEMORY_EMBED_URL")))
    (when url
      (let ((model (env "CL_LLM_MEMORY_EMBED_MODEL"))
            (floor (env "CL_LLM_MEMORY_EMBED_FLOOR")))
        (unless model
          (error "CL_LLM_MEMORY_EMBED_MODEL is required with a URL"))
        (unless floor
          (error "CL_LLM_MEMORY_EMBED_FLOOR is required with a URL"))
        (agent:make-endpoint-embedder
         (rag:make-openai-compatible-embedder
          :base-url url :model model
          :api-key (env "CL_LLM_MEMORY_EMBED_KEY"))
         :floor (%embed-floor floor))))))
