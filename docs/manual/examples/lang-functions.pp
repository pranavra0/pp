;; `def` names a function; the last expression is its result.
(def (square x) (* x x))
(print (square 7))

;; Functions are values. `fn` makes one without naming it.
(print ((fn (x) (* x x)) 7))

;; Recursion is the loop.
(def (fact n)
  (if (= n 0) 1 (* n (fact (- n 1)))))
(print (fact 5))
