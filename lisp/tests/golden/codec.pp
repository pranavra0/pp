print(force(node {
  vec[1 + 2, 2.5, "m0", :kw, quote { sym }, cons(1, 2),
      vec[1, vec[2]], {"a" -> 1, "b" -> 2}, hash-set(1, 2),
      nil, 1 = 1, 1 = 2]
}))
