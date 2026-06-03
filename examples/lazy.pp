;; pp example: lazy evaluation demo
;; Demonstrates: let, delay, force, thunks

;; Create an expensive computation (this won't run yet)
(let [x (delay 
          (do (print "this expensive computation runs NOW")
              (* 100 200)))
      
      ;; This one is defined but never used — so it never runs
      y (delay 
          (print "THIS SHOULD NEVER PRINT")
          (error "unused thunk forced"))]

  (print "Before forcing x")
  (print (force x))
  (print "After forcing x")
  
  ;; y is never forced, so the error never fires
  (print "Done — y was never forced"))
