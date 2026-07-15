# Only nil and false are falsy; everything else (including 0) is truthy.
# `and`/`or` short-circuit and return the deciding value, not a boolean.
# Flat `else if` chains keep multi-way branching clean.
print(if 1 { if 2 { 3 } else { false } } else { false })
print(if false { true } else if nil { true } else { 5 })
print(if true { false } else { false })
print(not(nil))
print(not(0))
