# `perform` dispatches to the nearest handler installed by `with-handler`.
# The `handlers:` clause takes a map of keyword -> function pairs.
with { handlers: { :double -> fn(x) { x * 2 } } } {
  print(perform double(21))
}
