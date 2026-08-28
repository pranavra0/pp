# tests/030 — regression pins for slot reuse in nested `let` within `let*`
# A nested `let` inside a `let*` binding RHS must not read the wrong slot
# for a sibling binding (for example, x8 must not evaluate to x12's 48
# instead of 97). These shrunk programs preserve that regression coverage
# under the runtime evaluator.
let* (x7 = 0, x8 = let (x12 = 48) { 97 }) {
  print(if x8 { x8 } else {
    vector-get(vec[if true { 24 } else { 72 }, if false { 11 } else { x7 }, +(84, 71, 96)], 1) }) }
let* (x1 = 0, x2 = {:k6 -> let (x8 = 91) { x1 }}[:k6]) {
  print(x2 + *(1, x2, 7 - let (x5 = 55) { 88 }))
}
let* (x1 = 31, x2 = {:k4 -> let (x5 = 0) { x5 }}[:k4] - 1) { print((
fn(x3) { x2 })(x2))
}
let* (x7 = 0, x8 = if let (x11 = 5) { "hello" } { 1 } else { x7 }) { print((
fn(x9) { x8 })(38) * (x8 / 1 - vector-get(vec[72, 73, 84 / 8], 0) / 2))
}
