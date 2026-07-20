# At the top level, names are predeclared across the scope. Function definitions
# can refer forward; value definitions still evaluate at their statement.
let answer = 6 * 7
print(answer)

def square(x) { x * x }
print(square(7))
