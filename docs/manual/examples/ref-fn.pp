;; `fn` makes an anonymous function; recursion is the only loop.
(print ((fn (x) (+ x 1)) 41))
(def (fact n)
  (if (= n 0) 1 (* n (fact (- n 1)))))
(print (fact 5))
