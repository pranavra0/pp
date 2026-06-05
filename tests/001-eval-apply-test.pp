;; 001-eval-apply-test.pp
;; Test file for eval-pp and apply-pp builtins.
;; Must run without errors and produce expected output.

(print "=== 1. eval-pp: basic expression ===")
(print "eval-pp (+ 1 2 3) =>" (eval-pp "(+ 1 2 3)"))

(print "")
(print "=== 2. eval-pp: uses calling environment ===")
(let [x 10
      y 20]
  (print "eval-pp (+ x y) =>" (eval-pp "(+ x y)")))

(print "")
(print "=== 3. eval-pp: define in do scope ===")
(do
  (eval-pp "(def (square x) (* x x))")
  (print "square 5 =>" (square 5)))

(print "")
(print "=== 4. apply-pp: apply + to list ===")
(print "apply-pp + [1 2 3 4 5] =>" (apply-pp + (list 1 2 3 4 5)))

(print "")
(print "=== 5. apply-pp: apply cons ===")
(print "apply-pp cons [1 (list 2)] =>" (apply-pp cons (list 1 (list 2))))

(print "")
(print "=== 6. apply-pp: with fn ===")
(let [add (fn (a b) (+ a b))]
  (print "apply-pp add [7 8] =>" (apply-pp add (list 7 8))))

(print "")
(print "=== ALL TESTS PASSED ===")
