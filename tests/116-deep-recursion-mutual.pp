# Mutual recursion — stack-safe
def even?(n) { if n <= 0 { true } else { odd?(n - 1) } }
def odd?(n)  { if n <= 0 { false } else { even?(n - 1) } }
print(even?(100000))
