;; Type annotations are optional and checked when the body runs. A well-typed
;; call passes through unchanged.
(def (inc n : int) : int (+ n 1))
(print (inc 41))
