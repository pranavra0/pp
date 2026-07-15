# Map update via spread — { ...base, key -> value } produces a new map
# with the given keys inserted or replaced.
let base = {:name -> "app", :port -> 8080}
let updated = { ...base, :port -> 9090, :debug -> true }
print(updated[:port])
print(updated[:debug])
