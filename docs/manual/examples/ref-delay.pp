# `delay` suspends a computation; `force` runs it and memoizes the result,
# so the body runs at most once however many times it is forced.
let (t = delay(do {
  print("run once")
  42
})) {
  print(force(t))
  print(force(t))
}
