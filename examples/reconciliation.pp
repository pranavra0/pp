# `reconcile` produces the ordinary map consumed by the CLI reconciler.
print(reconcile {
  "hello.txt" -> "hello",
  "answer.txt" -> "42"
})
