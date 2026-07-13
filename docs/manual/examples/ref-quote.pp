# Quotation is total: any form becomes data. Quasiquote (`) with unquote (,)
# and unquote-splicing (,@) build structure with holes.
print(quote { if a { b } else { c } })
print(quasiquote(cons(quote { 1 }, cons(list(quote { (unquote) }, 1 + 1), cons(list(quote { unquote-splicing }, list(3, 4)), quote { nil })))))
