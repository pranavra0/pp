# Equal node code and inputs share a cache entry, so the body prints once.
let first = node { print("compute once"); 6 * 7 }
let second = node { print("compute once"); 6 * 7 }
print(force(first))
print(force(second))
