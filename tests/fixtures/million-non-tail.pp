# One-million-element LAW 11 acceptance fixture; intentionally outside the
# regular suite because it is a resource-scale proof rather than a fast regression.
load("stdlib/list.pp")
def increment(x) { x + 1 }
def length(xs) { if nil?(xs) { 0 } else { 1 + length(cdr(xs)) } }
print(length(map(increment, range(0, 1000000))))
