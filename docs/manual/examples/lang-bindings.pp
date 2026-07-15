# Bindings in a `let` are mutual: every binding sees every other regardless
# of the order they are written. One flat `let` with multiple bindings is
# the idiomatic style — no nested single-binding ladders.
print(let (y = x + 1, x = 1) { y })

# `let*` is the sequential form, where each binding sees only the ones above.
print(let* (x = 1, x = x + 1) { x })
