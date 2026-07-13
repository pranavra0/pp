# Braces are the surface; s-expressions are the AST. quote { ... } turns
# the form inside into that AST, as data. Quasiquote is a template:
# unquote(e) fills one hole, splice(e) splices a list into a list position.
print(quote { if a { b } else { c } })
print(quasiquote { f(1, unquote(1 + 1), splice(list(3, 4))) })
