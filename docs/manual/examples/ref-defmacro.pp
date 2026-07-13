# `defmacro` receives its arguments as unevaluated forms and returns a new
# form. Quasiquote is the usual way to assemble the expansion.
defmacro unless(test, body) { quasiquote(cons(quote { (if) }, cons(list(quote { (unquote) }, test), cons(quote { nil }, cons(list(quote { (unquote) }, body), quote { nil }))))) }
print(unless(false, "ran"))
print(unless(true, "ran"))
