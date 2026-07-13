;; Type annotations are optional, and checked when the body runs. Passing a
;; string where an int is annotated is caught — the manual shows the real error.
(def (inc n : int) : int (+ n 1))
(inc "oops")
