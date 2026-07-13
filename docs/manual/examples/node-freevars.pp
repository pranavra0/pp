;; The node key folds in the VALUES of the free variables the body references,
;; not the code that produced them (LAW 20). `x` and `y` are computed
;; differently but are the same value, so `(squared x)` and `(squared y)` are
;; the same node — the body runs once. A different value is a different node.
(def (squared n) (node (do (print "squaring") (* n n))))
(def x 5)
(def y (+ 2 3))
(print (squared x))
(print (squared y))
(print (squared 9))
