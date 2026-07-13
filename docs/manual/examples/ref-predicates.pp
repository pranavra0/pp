;; Type predicates force their argument and test its shape.
(print (int? 3))
(print (string? "x"))
(print (keyword? :k))
(print (pair? (list 1)))
(print (map? (hash-map :a 1)))
(print (fn? car))
(print (vector? (vector 1)))
