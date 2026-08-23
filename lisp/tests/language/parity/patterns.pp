# M3 pure parity: quote, list patterns, variables, and guards.
print(quote { 1 + 2 })
def classify(xs) {
  match xs {
    [a, b] if a < b => "ascending"
    _ => "other"
  }
}
print(classify([1, 2]))
print(classify([2, 1]))
