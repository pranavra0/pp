# A macro receives forms and returns the form evaluated at its call site.
defmacro unless(test, body) {
  quasiquote { if unquote(test) { nil } else { unquote(body) } }
}

print(unless(false, "ran"))
print(unless(true, "skipped"))
