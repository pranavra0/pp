# Tail recursion (LAW 10 already holds; this is a baseline) plus a stdlib
# map — machine-mode list traversal over a deep call.
def sum(n, acc) { if n <= 0 { acc } else { sum(n - 1, acc + n) } }
print(sum(100000, 0))

load("stdlib/list.pp")
def inc(x) { x + 1 }
def len(xs) { if nil?(xs) { 0 } else { 1 + len(cdr(xs)) } }
print(len(map(inc, range(0, 5000))))
