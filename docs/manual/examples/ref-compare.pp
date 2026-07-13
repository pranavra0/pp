# Comparisons are variadic and chain left to right: (< 1 2 3) is 1<2 and 2<3.
print(2 = 2)
print(<(1, 2, 3))
print(>(3, 2, 1))
print(<=(1, 1, 2))
print(3 >= 3)
