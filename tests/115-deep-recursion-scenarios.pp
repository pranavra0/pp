# Deep-recursion scenarios beyond the LAW 11 pair (kept together in
# tests/087-deep-recursion.pp): mutual recursion, handlers, and stdlib map.

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
