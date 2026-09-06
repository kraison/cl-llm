;;;; tests-agent/taxonomy-tool-tests.lisp -- list-taxonomy (#64 SS3).

(in-package #:cl-llm.agent/tests)
(in-suite :cl-llm-agent)

(defun %seed-taxonomy (w p)
  (%belief w "ci-status" '(:verdict . "green"))
  (%belief w "ci-status" '(:verdict . "red") :start "2026-09-02T08:00:00Z")
  (%belief w "outage-root-cause" '(:cause . "quill")
           :subject '(:incident . "ledger-freeze-2026-05-22"))
  (%belief w "outage-root-cause" '(:cause . "sigil")
           :subject '(:incident . "drift-b8dc70-2026"))
  (%belief p "owner" '(:person . "kevin")))

(defun %named (entries name)
  (find name (coerce entries 'list)
        :key (lambda (e) (json:jget e "name")) :test #'string=))

(defun %names (entries)
  (mapcar (lambda (e) (json:jget e "name")) (coerce entries 'list)))

(test list-taxonomy-describes-every-store-in-scope
  (with-stores (w p)
    (%seed-taxonomy w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "list-taxonomy"))
           (stores (coerce (json:jget r "stores") 'list))
           (first-store (first stores))
           (ns (json:jget first-store "namespaces"))
           (incident (%named ns "incident"))
           (repo (%named ns "repo"))
           (rel (json:jget first-store "relations")))
      (is (= 2 (length stores)))
      (is (string= "cl-llm-memory" (json:jget first-store "store")))
      (is (string= "memory-private" (json:jget (second stores) "store")))
      ;; every namespace totals 2 claims: ties break by name
      (is (equal '("cause" "incident" "repo" "verdict") (%names ns)))
      (is (= 2 (json:jget incident "subjects")))
      (is (= 0 (json:jget incident "objects")))
      (is (= 2 (json:jget incident "keys")))
      (is (equal '("drift-b8dc70-2026" "ledger-freeze-2026-05-22")
                 (coerce (json:jget incident "sample") 'list)))
      (is (= 2 (json:jget repo "subjects")))
      (is (= 1 (json:jget repo "keys")))
      (is (equal '("ci-status" "outage-root-cause") (%names rel)))
      (is (= 2 (json:jget (elt rel 0) "claims")))
      (is (equal '("person" "repo")
                 (%names (json:jget (second stores) "namespaces")))))))

(test list-taxonomy-caps-samples-and-keys-by-max-rows
  (with-stores (w p)
    (%seed-taxonomy w p)
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+
                                                     :max-rows 1))
           (r (%call tools "list-taxonomy" "store" "cl-llm-memory"))
           (stores (coerce (json:jget r "stores") 'list))
           (incident (%named (json:jget (first stores) "namespaces")
                             "incident")))
      (is (= 1 (length stores)))
      (is (= 1 (length (json:jget incident "sample"))))
      (is (= 2 (json:jget incident "keys")) "the count is the full count")
      (let ((k (%call tools "list-taxonomy" "namespace" "incident"
                      "limit" 50)))
        (is (= 1 (length (json:jget k "keys"))))
        (is (json:jget k "truncated"))))
    (let* ((tools2 (agent:make-agent-tools (list w p) :producer +p+
                                                       :max-rows 50))
           (r2 (%call tools2 "list-taxonomy" "store" "cl-llm-memory"
                      "limit" 1))
           (stores2 (coerce (json:jget r2 "stores") 'list))
           (incident2 (%named (json:jget (first stores2) "namespaces")
                              "incident")))
      (is (= 1 (length (json:jget incident2 "sample"))))
      (is (= 2 (json:jget incident2 "keys"))))))

(test list-taxonomy-lists-keys-under-a-namespace-across-the-scope
  (with-stores (w p)
    (%seed-taxonomy w p)
    (%belief p "owner" '(:person . "kevin")
             :subject '(:repo . "vivace-graph"))
    (let* ((tools (agent:make-agent-tools (list w p) :producer +p+))
           (r (%call tools "list-taxonomy" "namespace" "repo"))
           (keys (coerce (json:jget r "keys") 'list)))
      (is (string= "repo" (json:jget r "namespace")))
      ;; claims descending, then key, then scope order
      (is (equal '(("cl-llm" "cl-llm-memory" 2)
                   ("cl-llm" "memory-private" 1)
                   ("vivace-graph" "memory-private" 1))
                 (mapcar (lambda (k) (list (json:jget k "key")
                                           (json:jget k "store")
                                           (json:jget k "claims")))
                         keys)))
      (is (eq nil (json:jget r "truncated"))))))

(test list-taxonomy-refuses-an-uncanonical-namespace-and-an-unknown-store
  (with-stores (w p)
    (%belief w "ci-status" '(:verdict . "green"))
    (let ((tools (agent:make-agent-tools (list w p) :producer +p+)))
      (signals llm:llm-tool-error
        (%call tools "list-taxonomy" "namespace" "INCIDENT"))
      (signals llm:llm-tool-error
        (%call tools "list-taxonomy" "store" "elsewhere"))
      (is (= 0 (length (json:jget (%call tools "list-taxonomy"
                                         "namespace" "incident")
                                  "keys")))
          "a canonical namespace nothing holds is the store's answer"))))
