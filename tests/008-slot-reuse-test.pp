;; Regression: VM local-slot reuse across a lazily-forced thunk.
;;
;; The VM frame is a single mutable array shared with every thunk/closure that
;; captures it. The compiler used to truncate the compile-time frame when a
;; scope exited, letting a later binding REUSE a slot index. A nested `let`
;; inside a `let*` binding RHS is compiled into a thunk; when that thunk was
;; forced later, its STORE_LOCAL wrote into the slot the sibling binding had
;; reused, clobbering it — so the VM returned the inner let's value instead of
;; the sibling's. The tree-walker (immutable env chains) was always correct.
;;
;; `dune runtest` runs every file under BOTH backends and diffs the output, so any
;; reintroduction of the divergence fails this test. Fixed by reserving slots
;; for a frame's whole lifetime (compiler.ml extend_cenv: mark-dead, not
;; truncate).

(print "=== nested let in let* binding, captured by a closure ===")
;; x2's RHS contains a nested let; x2 is then captured by (fn (x3) x2).
;; Correct answer: -1  (VM used to print 0 = the inner let's x5).
(print "a =>" (let* [x1 31
                     x2 (- (let [x5 0] x5) 1)]
                ((fn (x3) x2) x2)))

(print "")
(print "=== nested let inside a collection literal in a binding ===")
(print "b =>" (let* [x1 31
                     x2 (- (hash-map-get {:k4 (let [x5 0] x5)} :k4) 1)]
                ((fn (x3) x2) x2)))

(print "")
(print "=== two nested lets in sequential bindings, both captured ===")
(print "c =>" (let* [a (+ (let [t 10] t) 1)
                     b (+ (let [u 20] u) 2)]
                (+ ((fn (z) a) 0) ((fn (z) b) 0))))

(print "")
(print "=== nested let in a mutual-let binding, captured ===")
(print "d =>" (let [p (- (let [q 5] q) 1)
                    f (fn (z) p)]
               (f 99)))

(print "")
(print "=== nested let in vector literal element, later var captured ===")
(print "e =>" (let* [x1 7
                     x2 (vector-get [(let [w 3] w) x1] 1)]
                ((fn (z) x2) x2)))

(print "")
(print "=== deeper nesting: let inside let inside let* binding ===")
(print "f =>" (let* [x1 1
                     x2 (let [y (let [zz 40] zz)] (+ y 2))]
                ((fn (z) x2) x2)))

(print "")
(print "=== ALL TESTS PASSED ===")
