;; `let` bindings are mutual: every binding sees every other, whatever the
;; textual order.
(print (let [y (+ x 1)
             x 1]
         y))
