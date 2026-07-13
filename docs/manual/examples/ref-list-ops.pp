;; List builtins need no library: list, cons, car, cdr, and map are primitive.
(print (list 1 2 3))
(print (cons 0 (list 1 2)))
(print (car (list 1 2 3)))
(print (cdr (list 1 2 3)))
(print (map (fn (x) (* x x)) (list 1 2 3 4)))
