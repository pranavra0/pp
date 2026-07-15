# The `...` prefix splices a collection into a function call:
# `f(a, ...rest, b)` lowers to `apply(f, list(a), rest, list(b))`.
# A compound spread target uses the spaced `... expr` form.
# Plain arguments before and after the spread are grouped into `list(...)`
# segments; each spread is its own segment. Here `...parts` splices the list
# into the call so `print` receives five values instead of three.
let parts = ["c", "d"]
print("a", "b", ...parts, "e")
