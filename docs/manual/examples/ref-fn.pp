# `fn` makes an anonymous function; recursion is the only loop.
print((fn(x) { x + 1 })(41))

def factorial(n) {
  if n = 0 { 1 } else { n * factorial(n - 1) }
}

print(factorial(5))
