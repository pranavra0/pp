# pins: LAW-11

# Non-tail recursion — the LAW 11 target
def count(n) { if n <= 0 { 0 } else { 1 + count(n - 1) } }
print(count(100000))
