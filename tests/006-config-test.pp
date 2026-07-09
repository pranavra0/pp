;; 006-config-test.pp
;; Test ReaderT-style ambient configuration.

(print "=== 1. with-config reads keys ===")
(with-config {:name "pp" :version 2}
  (print "name =>" (config :name))
  (print "version =>" (config :version)))

(print "")
(print "=== 2. config missing with default ===")
(with-config {:a 1}
  (print "missing default =>" (config :missing "fallback")))

(print "")
(print "=== 3. config missing without default ===")
(with-config {:a 1}
  (print "missing nil =>" (config :not-there)))

(print "")
(print "=== 4. nested with-config shadows outer key ===")
(with-config {:x "outer" :y "outer-y"}
  (with-config {:x "inner"}
    (print "nested x =>" (config :x))
    (print "nested y =>" (config :y))))

(print "")
(print "=== ALL TESTS PASSED ===")
