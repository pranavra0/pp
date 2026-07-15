# The node key folds in the VALUES of the free variables the body references,
# not the code that produced them (LAW 20). `x` and `y` are computed
# differently but are the same value, so `squared(x)` and `squared(y)` are
# the same node — the body runs once. A different value produces a different
# key, so `squared(9)` runs separately.
def squared(n) { node { print("squaring"); n * n } }
let x = 5
let y = 2 + 3
print(squared(x))
print(squared(y))
print(squared(9))
