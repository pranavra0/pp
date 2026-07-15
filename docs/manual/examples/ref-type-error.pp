# A type annotation mismatch names the offending value and location.
def increment(n: int): int { n + 1 }
increment("oops")
