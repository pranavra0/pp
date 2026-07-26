# `defmacro` receives its arguments as unevaluated forms (sexpr data) and
# returns a new form, expanded before the evaluator sees it. The body of
# `quasiquote { ... }` is a template in ordinary brace syntax.
defmacro unless(test, body) {
  quasiquote { if unquote(test) { nil } else { unquote(body) } }
}

print(unless(false, "ran"))
print(unless(true, "ran"))
