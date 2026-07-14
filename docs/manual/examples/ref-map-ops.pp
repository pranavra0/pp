# Map builtins: construct, look up, insert, and read keys/values. Maps are
# immutable — map-insert and map-remove return new maps.
let m = {:a -> 1, :b -> 2}
print(m[:a])
print({ m | :c -> 3 })
print(map-keys(m))
print(map-vals(m))
print(map-remove(m, :a))
