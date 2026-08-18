;;;; rag-eval/packages.lisp

(defpackage #:cl-llm.rag.eval
  (:use #:cl)
  (:local-nicknames (#:rag #:cl-llm.rag)
                    (#:eval #:cl-llm.eval))
  (:export
   #:bundle-recall-at-k #:bundle-containment
   #:bundle-standing-well-formed #:bundle-method-attributed
   #:bundle-projection #:write-golden #:check-golden))
