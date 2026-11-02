;;;; conversation-vivace/store.lisp -- the store protocol over a
;;;; caller-owned graph (#89).  One vertex per conversation holding its
;;;; JSON; found by index, never by scan.  Every operation binds
;;;; GRAPH-DB:*GRAPH* to the store's graph: a node read under another
;;;; graph is undefined.  docs/conversations.md, "The graph store".

(in-package #:cl-llm.conversation.vivace)

(defmacro define-conversation-store (graph-name)
  "Declare the conversation vertex type and its indexes in GRAPH-NAME.
Call before the graph is opened, as MEM:DEFINE-MEMORY-STORE.  Returns
GRAPH-NAME."
  `(progn
     (gdb:def-vertex stored-conversation-vertex ()
       ((cv-id      :type string)
        (cv-owner   :type string)
        (cv-updated :type integer)
        (cv-current :type boolean)
        (cv-json    :type string))
       ,graph-name)
     (gdb:def-index stored-conversation-vertex cv-id ,graph-name
       :name cv-id-index)
     (gdb:def-index stored-conversation-vertex cv-owner ,graph-name
       :name cv-owner-index)
     ',graph-name))

(defclass graph-conversation-store ()
  ((graph :initarg :graph :reader graph-conversation-store-graph))
  (:documentation "Stored conversations in a borrowed graph-db graph
whose name was declared with DEFINE-CONVERSATION-STORE."))

(defun make-graph-conversation-store (graph)
  (make-instance 'graph-conversation-store :graph graph))

(defun %owner-key (owner)
  "The index key for OWNER: a NIL owner is the empty string."
  (or owner ""))

(defun %vertices (graph slot value)
  (gdb:index-lookup graph 'stored-conversation-vertex slot value))

(defmethod llm:save-conversation ((store graph-conversation-store) sc)
  (let* ((graph (graph-conversation-store-graph store))
         (gdb:*graph* graph)
         (id (llm:stored-conversation-id sc))
         (json (llm:stored-conversation-to-json sc))
         (owner (%owner-key (llm:stored-conversation-owner sc)))
         (updated (llm:stored-conversation-updated sc))
         (current (and (llm:stored-conversation-current-p sc) t)))
    (gdb:with-transaction (:graph graph)
      (let ((old (first (%vertices graph 'cv-id id))))
        (if old
            (let ((copy (gdb:copy old)))
              (setf (cv-owner copy) owner
                    (cv-updated copy) updated
                    (cv-current copy) current
                    (cv-json copy) json)
              (gdb:save copy))
            (make-stored-conversation-vertex
             :cv-id id :cv-owner owner :cv-updated updated
             :cv-current current :cv-json json :graph graph))))
    sc))

(defmethod llm:load-conversation ((store graph-conversation-store) id
                                  &key owner)
  (let* ((graph (graph-conversation-store-graph store))
         (gdb:*graph* graph)
         (vertex (and (stringp id) (first (%vertices graph 'cv-id id)))))
    (when vertex
      (let ((sc (llm:stored-conversation-from-json (cv-json vertex))))
        (when (or (null owner)
                  (equal owner (llm:stored-conversation-owner sc)))
          sc)))))

(defmethod llm:list-conversations ((store graph-conversation-store) owner)
  (let* ((graph (graph-conversation-store-graph store))
         (gdb:*graph* graph))
    (sort (loop for vertex in (%vertices graph 'cv-owner
                                         (%owner-key owner))
                for sc = (handler-case
                             (llm:stored-conversation-from-json
                              (cv-json vertex))
                           (error (e)
                             (warn "skipping unreadable conversation ~a: ~a"
                                   (cv-id vertex) e)
                             nil))
                when sc collect sc)
          #'> :key #'llm:stored-conversation-updated)))
