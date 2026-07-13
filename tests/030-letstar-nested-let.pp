# tests/030 — regression pin for the D21-family VM divergence caught by the
# fuzzer (fuzz-failures/outdiff_* of 2026-07-10): a nested `let` inside a
# `let*` binding RHS made the VM read the WRONG slot for a sibling binding
# (e.g. x8 evaluated to x12's 48 instead of 97). Fixed in the working tree;
# these four shrunk repros must print the tree-walker's answers under both
# backends forever.
let* (x7 = 0, x8 = let (x12 = 48) { 97 }) {
  print(if x8 { x8 } else {
    vector-get([if true { 24 } else { 72 }, if false { 11 } else { x7 }, +(84, 71, 96)], 1) }) }
let* (x1 = 0, x2 = hash-map-get({:k6 -> let (x8 = 91) { x1 }}, :k6)) {
  print(x2 + *(1, x2, 7 - let (x5 = 55) { 88 }))
}
let* (x1 = 31, x2 = hash-map-get({:k4 -> let (x5 = 0) { x5 }}, :k4) - 1) { print((
fn(x3) { x2 })(x2))
}
let* (x7 = 0, x8 = if let (x11 = 5) { "hello" } { 1 } else { x7 }) { print((
fn(x9) { x8 })(38) * (x8 / 1 - vector-get([72, 73, 84 / 8], 0) / 2))
}
