# Regression: local-slot reuse across a lazily-forced thunk.
#
# The evaluator uses explicit heap state for frames and continuations. A
# nested `let` inside a `let*` binding RHS is evaluated through a thunk; when
# that thunk is forced later, its local state must not overwrite the sibling
# binding captured by the closure. The regression protects the evaluator's
# environment-extension and continuation state implementation.

print("=== nested let in let* binding, captured by a closure ===")
# x2's RHS contains a nested let; x2 is then captured by fn(x3) { x2 }.
# Correct answer: -1  (the bug returned 0 = the inner let's x5).
print("a =>", let* (x1 = 31, x2 = let (x5 = 0) { x5 } - 1) {
  (
fn(x3) { x2 })(x2)
})
print("")
print("=== nested let inside a collection literal in a binding ===")
print("b =>", let* (x1 = 31, x2 = {:k4 -> let (x5 = 0) { x5 }}[:k4] - 1) {
  (
fn(x3) { x2 })(x2)
})
print("")
print("=== two nested lets in sequential bindings, both captured ===")
print("c =>", let* (a = let (t = 10) { t } + 1, b = let (u = 20) { u } + 2) {
  (
fn(z) { a })(0) + (fn(z) { b })(0)
})
print("")
print("=== nested let in a mutual-let binding, captured ===")
print("d =>", let (p = let (q = 5) { q } - 1, f =
fn(z) { p }) { f(99) })


print("")
print("=== nested let in vector literal element, later var captured ===")
print("e =>", let* (x1 = 7, x2 = vector-get(vec[let (w = 3) { w }, x1], 1)) {
  (
fn(z) { x2 })(x2)
})
print("")
print("=== deeper nesting: let inside let inside let* binding ===")
print("f =>", let* (x1 = 1, x2 = let (y = let (zz = 40) { zz }) { y + 2 }) {
  (
fn(z) { x2 })(x2)
})
print("")
print("=== ALL TESTS PASSED ===")
