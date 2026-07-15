# Type annotations are checked when the body runs. Passing a string where
# an int is expected is caught — the manual shows the real error.
def increment(n: int): int { n + 1 }
increment("oops")
