# stdlib/map.pp — map utilities over the map primitives (hash-map,
# hash-map-get, map-insert, map-remove, map-keys, map-vals).
# Depends on stdlib/list.pp (member?, foldl) — load that first.

# (map-has? m k) — whether k is a key of m
def map-has?(m, k) { member?(k, map-keys(m)) }


# (map-merge a b) — a with every binding of b inserted (b wins on collision)
def map-merge(a, b) { foldl(
fn(acc, k) { map-insert(acc, k, hash-map-get(b, k)) }, a, map-keys(b))
}
