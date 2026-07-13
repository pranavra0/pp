;; Config is ambient, dynamically-scoped data — distinct from capabilities,
;; which are authority. A binding is visible to everything called within.
(print (with-config {:host "db1"}
         (config :host)))
