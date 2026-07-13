;; `do` runs each form in order for its effects and returns the last value.
(print (do (print "step 1") (print "step 2") 99))
