# f-strings interpolate with the `f` prefix: `f"Hello, {name}!"`.
# Ordinary `"..."` strings never interpolate — `"{x}"` is three literal chars.
# `->string` coerces any value; a string renders as itself (no quotes).
let name = "world"
let count = 3
print(f"Hello, {name}! Built {count} targets.")
print(f"formula: {2 + 2}")
print(f"just-text")
