;; A module is a block whose definitions become a value; `import` merges that
;; value's exports into the current scope.
(let [m (module (def (double x) (* x 2))
                (def tau 6))]
  (import m)
  (print (double tau)))
