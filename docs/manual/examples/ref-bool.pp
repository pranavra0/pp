;; Only nil and false are falsy; everything else (including 0) is truthy.
;; `and`/`or` short-circuit and return the deciding value, not a boolean.
(print (and 1 2 3))
(print (or false nil 5))
(print (and true false))
(print (not nil))
(print (not 0))
