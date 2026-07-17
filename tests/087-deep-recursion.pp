# pins: LAW-11

# Tail recursion (LAW 10 already holds; this is a baseline)
def sum(n, acc) { if n <= 0 { acc } else { sum(n - 1, acc + n) } }
print(sum(100000, 0))

# Non-tail recursion — the LAW 11 target
def count(n) { if n <= 0 { 0 } else { 1 + count(n - 1) } }
print(count(100000))

# Mutual recursion — stack-safe
def even?(n) { if n <= 0 { true } else { odd?(n - 1) } }
def odd?(n)  { if n <= 0 { false } else { even?(n - 1) } }
print(even?(100000))

# Deep recursion under handlers — effect boundaries must compose
with { handlers: { :inc -> fn(n) { n + 1 } } } {
  def rec(n) { if n <= 0 { 0 } else { perform inc(1) + rec(n - 1) } }
  print(rec(100000))
}

# Stdlib map — exercises machine mode with list traversal
load("stdlib/list.pp")
def inc(x) { x + 1 }
def len(xs) { if nil?(xs) { 0 } else { 1 + len(cdr(xs)) } }
print(len(map(inc, range(0, 5000))))
