;; `if` is an expression and evaluates exactly one branch — the untaken one
;; never runs, so the error here is never raised.
(print (if (> 5 0) "pos" "neg"))
(print (if false (error "never") "safe"))
