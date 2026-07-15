# `match` is the one pattern-dispatch form. Guards (`p if cond => body`)
# let an arm fire only when the pattern matches AND the guard is truthy.
def classify(n) {
  match n {
    x if x < 0   => "negative"
    0            => "zero"
    x if x > 100 => "large"
    _            => "small"
  }
}

print(classify(-5))
print(classify(0))
print(classify(50))
print(classify(200))
