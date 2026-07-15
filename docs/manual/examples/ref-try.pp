# try blocks unwrap [:ok, v] / [:err, e] pairs automatically.
# Each `name <- expr` extracts the value on success or propagates
# the error on failure. The block's last expression is the overall value.
let ok-result = [:ok, 42]
let err-result = [:err, "oops"]

let (good = try { a <- ok-result; a + 1 }) { print(good) }
let (bad = try { a <- err-result; a + 1 }) { print(bad) }
