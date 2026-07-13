;; `defmacro` receives its arguments as unevaluated forms and returns a new
;; form. Quasiquote is the usual way to assemble the expansion.
(defmacro (unless test body) `(if ,test nil ,body))
(print (unless false "ran"))
(print (unless true "ran"))
