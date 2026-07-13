print(force(node {
  [1 + 2, 2.5, "s", :kw, quote { sym }, cons(1, 2), [1, [2]], {"a" -> 1, "b" -> 2}, hash-set(1, 2), nil, 1 = 1, 1 = 2]
}))
