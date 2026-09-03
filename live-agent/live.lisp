;;;; live-agent/live.lisp -- annotate-banners against a real provider.
;;;; Gated exactly as cl-llm/live: skipped without CL_LLM_LIVE.

(in-package #:cl-llm.agent.live)

(def-suite :cl-llm-agent-live)
(in-suite :cl-llm-agent-live)

(defun live-enabled-p ()
  (let ((v (uiop:getenv "CL_LLM_LIVE")))
    (and v (string/= v "") (string/= v "0"))))

(test live-annotate-banners-records-decisions-with-the-banner-as-evidence
  (if (not (live-enabled-p))
      (skip "CL_LLM_LIVE is not set.")
      (with-stores (w p)
        (mem:capture-memory-dir w (%banner-dir) :producer "capture/live")
        (let ((results (agent:annotate-banners
                        (list w p) (%banner-dir)
                        :provider llm:*provider*
                        :producer "claude-code/live"
                        :model-name (or (llm:provider-default-model
                                         llm:*provider*)
                                        "unknown"))))
          (is (some #'cdr results) "at least one decision")
          (loop for (nil . id) in results when id
                do (let ((rec (mem:trace w id :scope (list w p))))
                     (is (string= "read-banner"
                                  (mem:decision-record-rule rec)))
                     (is (plusp (length
                                 (mem:decision-record-rule-version rec))))
                     (is (eq :resolved
                             (mem:cite-record-state
                              (first
                               (mem:decision-record-evidence rec)))))))))))
