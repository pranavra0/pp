# `delay` defers evaluation and `force` memoizes it.
let answer = delay(do { print("compute once"); 6 * 7 })
print(force(answer))
print(force(answer))
