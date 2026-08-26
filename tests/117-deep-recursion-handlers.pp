# Deep recursion under handlers — effect boundaries must compose
with { handlers: { :inc -> fn(n) { n + 1 } } } {
  def rec(n) { if n <= 0 { 0 } else { perform inc(1) + rec(n - 1) } }
  print(rec(100000))
}
