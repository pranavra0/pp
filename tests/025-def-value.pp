;; tests/025-def-value.pp — (def x v) with a non-list head is a VALUE binding
;; (the roadmap §1 footgun fix), not a nullary closure. Differential: both
;; backends must produce identical output. The expected-output oracle lives in
;; tests/025-def-value.sh; this file pins backend parity.

;; simple value bindings, sequential visibility
(def x 5)
(print x)
(def y (+ x 1))
(print y)
(def s (string-append "a" "b"))
(print s)
(def lst (list 1 2 3))
(print (car lst))

;; function defs are unchanged (and still see later rebinds at call time)
(def (f a) (+ a x))
(print (f 10))

;; top-level rebinding is sequential
(def x 7)
(print x)

;; the RHS is evaluated at definition time (strict, like a statement)
(def eff (print "effect-at-def-time"))
(print (nil? eff))

;; ... but evaluation does not force: delay stays a thunk until referenced
(def d (delay 42))
(print (force d))

;; do-block value defs: letrec*-style block scope, backpatched on execution
(print (do (def z (* y 2)) (+ z 1)))

;; inside a function body (non-top-level frame in the VM): value defs and
;; function defs mix; the function sees the block-scoped value
(def (g n)
  (do (def m (* n 2))
      (def (h k) (+ k m))
      (h m)))
(print (g 5))

;; a function defined BEFORE the value it references (letrec* forward ref,
;; resolved by the time it is called)
(def (fwd n)
  (do (def (use k) (+ k base))
      (def base (* n 10))
      (use 1)))
(print (fwd 3))

;; value defs shadow inside let bodies
(let [q 3] (print (do (def w (+ q 1)) (* w w))))

;; a value binding holding a function value is callable
(def add1 (fn (n) (+ n 1)))
(print (add1 41))
