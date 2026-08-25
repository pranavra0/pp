# pins: LAW-11

# Tail recursion (LAW 10 already holds; this is a baseline)
def sum(n, acc) { if n <= 0 { acc } else { sum(n - 1, acc + n) } }
print(sum(100000, 0))

# Non-tail recursion — the LAW 11 target
def count(n) { if n <= 0 { 0 } else { 1 + count(n - 1) } }
print(count(100000))
