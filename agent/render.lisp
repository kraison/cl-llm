;;;; agent/render.lisp -- values as the model reads them.  Spec SS5.

(in-package #:cl-llm.agent)

(defun %iso (ts)
  (and (typep ts 'local-time:timestamp)
       (local-time:format-rfc3339-timestring
        nil ts :timezone local-time:+utc-zone+)))

(defun %parse-iso (string)
  "A TIMESTAMP from an RFC 3339 STRING; a malformed one signals, and
the tool loop shows the model the message."
  (local-time:parse-timestring string))

(defun %from (extent)
  (and extent (%iso (te:bound-earliest (te:extent-start extent)))))

(defun %to (extent)
  (and extent
       (let ((end (te:extent-end extent)))
         (and (not (te:bound-unknown-p end))
              (not (eq :unbounded (te:bound-latest end)))
              (%iso (te:bound-latest end))))))

(defun %standing (keyword)
  (and keyword (string-downcase (symbol-name keyword))))

(defun %keyword (string)
  (intern (string-upcase string) :keyword))

(defun %bool (x) (if x :true :false))

(defun %endpoint-json (ns key)
  (json:jobject "namespace" (%standing ns) "key" key))

(defun %record-json (store record)
  "One BELIEF-RECORD as the model reads it (SS6)."
  (let* ((c (mem:belief-record-claim record))
         (s (mem:belief-record-superseded-by record))
         (e (mem:belief-record-extent record)))
    (json:jobject
     "store" (mem:store-name store)
     "cite" (mem:claim-cite c)
     "relation" (st:claim-relation c)
     "object" (and (typep c 'mem:belief-binary)
                   (%endpoint-json (st:claim-object-namespace c)
                                   (st:claim-object-key c)))
     "standing" (%standing (mem:belief-record-standing record))
     "valid-from" (%from e)
     "valid-to" (%to e)
     "current" (%bool (mem:belief-record-current-p record))
     "superseded-by" (and s (mem:claim-cite s)))))

(defun %cite-record-json (store-name record)
  (json:jobject
   "store" store-name
   "cite" (mem:cite-record-cite record)
   "state" (%standing (mem:cite-record-state record))
   "changed-since" (%standing (mem:cite-record-changed-since record))
   "standing" (%standing (mem:cite-record-standing record))
   "valid-from" (%from (mem:cite-record-extent record))
   "valid-to" (%to (mem:cite-record-extent record))))
