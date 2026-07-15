# `+` and `*` are variadic; `-` and `/` take exactly two arguments; `mod`
# is the remainder. Comparisons chain left to right: `<(1, 2, 3)` is
# `1 < 2 AND 2 < 3`.
print(+(1, 2, 3))
print(10 - 3)
print(*(2, 3, 4))
print(20 / 4)
print(17 mod 5)
