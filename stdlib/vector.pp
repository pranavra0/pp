# stdlib/vector.pp — vector conversions and folds

def vector->list(v) {
  let (go = fn(i) {
    if i >= vector-length(v) { nil }
    else { cons(vector-get(v, i), go(i + 1)) }
  }) { go(0) }
}

def list->vector(lst) { vector(...lst) }
def vector-map(f, v) { list->vector(map(f, vector->list(v))) }
def vector-filter(pred, v) { list->vector(filter(pred, vector->list(v))) }
def vector-foldl(f, acc, v) { foldl(f, acc, vector->list(v)) }
