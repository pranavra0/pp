# Type annotations are optional and checked when the body runs. A well-typed
# call passes through unchanged.
def increment(n: int): int { n + 1 }
print(increment(41))
