;;;; scripts/registry.lisp -- CL_LLM_ASDF_REGISTRY onto ASDF's central
;;;; registry, shared by memory-mcp.lisp and memory-image.lisp (#72).
;;;; Loaded after (require :asdf) and before any quickload.

;; CL_LLM_ASDF_REGISTRY: colon-separated trees, first on the registry,
;; so the child builds what its launcher built (plan ruling 1).
(let ((registry (uiop:getenv "CL_LLM_ASDF_REGISTRY")))
  (when (and registry (plusp (length registry)))
    (dolist (dir (reverse (uiop:split-string registry :separator ":")))
      (when (plusp (length dir))
        (push (uiop:ensure-directory-pathname dir)
              asdf:*central-registry*)))))
