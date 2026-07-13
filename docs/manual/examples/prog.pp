(def (expensive)
  (node (do (print "compiling greeter.o") (* 6 7))))
(print (expensive))
