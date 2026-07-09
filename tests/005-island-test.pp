;; Island syntax test
(print "=== Island Syntax ===")
(print "Parsing island form...")
;; This should parse without error:
(let [i (island github:test/example v1.0)]
  (print "island parsed:" i))
(print "=== ALL TESTS PASSED ===")
