# Map builtins: construct, look up, insert, and read keys/values. Maps are
# immutable — `map-insert` and `map-remove` return new maps.
# The bracket syntax `m[:key]` lowers to `hash-map-get`.
let scores = {:alice -> 95, :bob -> 87}
print(scores[:alice])

# Map update via spread — `{ ...scores, :charlie -> 78 }` produces a new map.
print({ ...scores, :charlie -> 78 })
print(map-keys(scores))
print(map-vals(scores))
print(map-remove(scores, :alice))
