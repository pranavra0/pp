# `def` names a function; the last expression is its result.
# Functions are values — `fn` makes one without naming it.
def square(x) { x * x }
print(square(7))

# Inline function as a value.
print((fn(x) { x * x })(7))

# Recursion is the only loop. Flat `else if` chains keep branching clean.
def factorial(n) {
  if n = 0 {
    1
  } else {
    n * factorial(n - 1)
  }
}

print(factorial(5))
