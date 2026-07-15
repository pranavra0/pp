# `let` bindings are mutual: every binding sees every other, whatever the
# textual order. One flat `let` with all bindings is the idiomatic style.
print(let (y = x + 1, x = 1) { y })
