;; At the top level, (def name value) evaluates the value once and binds it;
;; (def (name args) body) defines a function.
(def answer (* 6 7))
(print answer)
(def (square x) (* x x))
(print (square 7))
