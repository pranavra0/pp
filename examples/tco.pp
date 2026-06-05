;; TCO: tail-call optimization verification
;; All patterns pass at 10k in bytecode, 100k+ in native.
;; Deep thunk chains (arithmetic accumulator patterns) may overflow
;; due to lazy thunk accumulation — a separate concern from TCO.

(print "=== TCO: simple tail recursion ===")
(def (f n) (if (<= n 0) 0 (f (- n 1))))
(print "f 10000 =" (f 10000))

(print "")
(print "=== TCO: two-arg tail recursion ===")
(def (f2 n acc) (if (<= n 0) acc (f2 (- n 1) acc)))
(print "f2 10000 =" (f2 10000 42))

(print "")
(print "=== TCO: mutual tail recursion ===")
(def (is-even n) (if (<= n 0) true (is-odd (- n 1))))
(def (is-odd n) (if (<= n 0) false (is-even (- n 1))))
(print "is-even 10000 =" (is-even 10000))
(print "is-odd 10000 =" (is-odd 10000))

(print "")
(print "=== TCO verified ===")
