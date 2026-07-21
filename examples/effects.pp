# `perform` dispatches an effect to the nearest dynamically scoped handler.
with { handlers: { :ask -> fn(question) { string-append(question, " 42") } } } {
  print(perform ask("answer:"))
}
