# `let*` is sequential: each binding sees only the ones written above it,
# so a name can shadow itself.
print(let* (x = 1, x = x + 1) { x })
