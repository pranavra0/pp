# stdlib/map.pp — map utilities over the map primitives (hash-map,
# hash-map-get, map-insert, map-remove, map-keys, map-vals).
# Depends on stdlib/list.pp (member?, foldl) — load that first.

# map-has?(m, k) — whether k is a key of m
def map-has?(m, k) { member?(k, map-keys(m)) }


# map-merge(a, b) — a with every binding of b inserted (b wins on collision)
def map-merge(a, b) { foldl(
fn(acc, k) { { ...acc, k -> b[k] } }, a, map-keys(b))
}

def map-filter(pred, m) { foldl(fn(acc, k) {
  if pred(k, m[k]) { { ...acc, k -> m[k] } } else { acc }
}, {}, map-keys(m)) }

def map-map-values(f, m) { foldl(fn(acc, k) { { ...acc, k -> f(m[k]) } }, {}, map-keys(m)) }
def map-map-keys(f, m) { foldl(fn(acc, k) {
  let (new-k = f(k)) {
    if map-has?(acc, new-k) { error("map-map-keys: duplicate key") }
    else { map-insert(acc, new-k, m[k]) }
  }
}, {}, map-keys(m)) }
def map-from-pairs(pairs) { foldl(fn(acc, pair) {
  if nil?(pair) { error("map-from-pairs: each pair needs two items") }
  else if nil?(cdr(pair)) { error("map-from-pairs: each pair needs two items") }
  else if not(nil?(cdr(cdr(pair)))) { error("map-from-pairs: each pair needs two items") }
  else if map-has?(acc, car(pair)) { error("map-from-pairs: duplicate key") }
  else { map-insert(acc, car(pair), car(cdr(pair))) }
}, {}, pairs) }
def map-to-pairs(m) { map(fn(k) { list(k, m[k]) }, map-keys(m)) }
