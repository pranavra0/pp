# stdlib/set.pp — set operations with canonical runtime set identity

def set-has?(s, x) { member?(hash-value(x), map(fn(existing) { hash-value(existing) }, set->list(s))) }
def set-insert(s, x) { if set-has?(s, x) { s } else { hash-set(... set->list(s), x) } }
def set-remove(s, x) { let target = hash-value(x); hash-set(... filter(fn(y) { not(hash-value(y) = target) }, set->list(s))) }
def set-union(a, b) { foldl(set-insert, a, set->list(b)) }
def set-intersection(a, b) { hash-set(... filter(fn(x) { set-has?(b, x) }, set->list(a))) }
def set-difference(a, b) { hash-set(... filter(fn(x) { not(set-has?(b, x)) }, set->list(a))) }
def list->set(xs) { foldl(set-insert, hash-set(), xs) }
