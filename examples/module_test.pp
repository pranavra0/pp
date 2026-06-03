;; module test v2

(print "=== 1. Inline module + import ===")
(let [m (module (def (double x) (* x 2)) (def (triple x) (* x 3)))]
  (import m)
  (print "double 5 =" (double 5))
  (print "triple 5 =" (triple 5)))

(print "")
(print "=== 2. Load file into scope ===")
(load "examples/math.pp")
(print "square 5 =" (square 5))
(print "cube 3 =" (cube 3))
(print "+1 9 =" (+1 9))

(print "")
(print "=== 3. Load-module (fresh env) ===")
;; Load into a fresh isolated env, export only what the file defines
(let [m2 (load-module "examples/math.pp")]
  (print "m2 =" m2))

(print "")
(print "=== Done ===")
