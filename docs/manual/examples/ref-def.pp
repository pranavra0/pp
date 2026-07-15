# At the top level, `let name = value` evaluates once and binds it;
# `def name(args) { body }` defines a function. Top-level bindings are
# sequential — each `def` sees only the ones before it.
let answer = 6 * 7
print(answer)

def square(x) { x * x }
print(square(7))
