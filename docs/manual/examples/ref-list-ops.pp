# List builtins need no library: list, cons, car, cdr, and map are primitive.
# `map` is deliberately lazy in the elements, serving as the parallel
# fan-out point the scheduler batches on.
print(list(1, 2, 3))
print(cons(0, list(1, 2)))
print(car(list(1, 2, 3)))
print(cdr(list(1, 2, 3)))

# Pipelines thread values through pure functions; `|>` is the method syntax.
list(1, 2, 3, 4) |> map(fn(x) { x * x }) |> print
