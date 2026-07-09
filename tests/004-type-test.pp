;; Type annotation tests
(print "=== Type Annotations ===")
(def (square x : int) : int (* x x))
(print "square 5:" (square 5))
(let [x : int 42]
  (print "x:" x))
(print "=== ALL TESTS PASSED ===")
