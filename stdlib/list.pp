# stdlib/list.pp — basic list operation library

# NOTE: `map` is intentionally NOT defined here. It is a BUILTIN
# (src/runtime/primitives.ml) as of Phase 3, and the builtin is the batching
# fan-out point the parallel scheduler collects on: it applies f via the
# apply hook and conses the results WITHOUT forcing them, so a list of
# node { ... } elements stays unforced until force-deep dispatches the whole
# batch. A pp-level `def map(f, lst) { cons(f(car(lst)), ...) }` here would
# SHADOW the builtin and — because application is strict (Q1: EApply forces
# every argument, so cons's `f(car(lst))` argument is forced inline) —
# force each element one at a time, silently defeating parallel/remote
# batching for any program that loads this file (e.g. every --reconcile
# build, which auto-loads it for the domain libraries). Do not re-add it.

# filter(pred, lst) — return a lazy list of elements satisfying pred
def filter(pred, lst) {
  if nil?(lst) { nil } else if pred(car(lst)) {
    cons(car(lst), filter(pred, cdr(lst)))
  } else { filter(pred, cdr(lst)) }
}


# foldl(f, acc, lst) — left fold (strict in the accumulator)
# foldl(+, 0, list(1, 2, 3))  =>  ((0 + 1) + 2) + 3 = 6
def foldl(f, acc, lst) {
  if nil?(lst) { acc } else { foldl(f, f(acc, car(lst)), cdr(lst)) }
}


# foldr(f, acc, lst) — right fold (lazy)
# foldr(cons, nil, list(1, 2, 3))  =>  (1 . (2 . (3 . nil)))  =  (1 2 3)
def foldr(f, acc, lst) {
  if nil?(lst) { acc } else { f(car(lst), foldr(f, acc, cdr(lst))) }
}


# range(start, end) — generate numbers from start (inclusive) to end (exclusive)
def range(start, end) {
  if start >= end { nil } else { cons(start, range(start + 1, end)) }
}

def range-by(start, end, step) {
  if step = 0 { error("range-by: step must not be zero") }
  else if step > 0 {
    if start >= end { nil } else { cons(start, range-by(start + step, end, step)) }
  } else {
    if start <= end { nil } else { cons(start, range-by(start + step, end, step)) }
  }
}


# take(n, lst) — take first n elements of lst
def take(n, lst) {
  if n < 0 { error("take: count must not be negative") }
  else if if nil?(lst) { true } else { n = 0 } { nil } else {
    cons(car(lst), take(n - 1, cdr(lst)))
  }
}
# length(lst) — count elements in lst (strict: forces the whole list)
def length(lst) { if nil?(lst) { 0 } else { 1 + length(cdr(lst)) } }




# each(f, lst) — apply f to each element for its effects, return nil
def each(f, lst) {
  if nil?(lst) { nil } else {
    f(car(lst))
    each(f, cdr(lst))
  } }

def each!(f, lst) { each(f, lst) }
# append(a, b) — concatenate two lists (lazy in b)
def append(a, b) { if nil?(a) { b } else { cons(car(a), append(cdr(a), b)) } }




# reverse(lst) — strict reversal
def reverse(lst) { foldl(
fn(acc, x) { cons(x, acc) }, nil, lst)
}
# nth(n, lst) — zero-based element access; nil past the end
def nth(n, lst) {
  if n < 0 { error("nth: index must not be negative") }
  else if nil?(lst) { nil } else if n = 0 { car(lst) } else { nth(n - 1, cdr(lst)) }
}


# drop(n, lst) — lst without its first n elements
def drop(n, lst) {
  if n < 0 { error("drop: count must not be negative") }
  else if if nil?(lst) { true } else { n = 0 } { lst } else { drop(n - 1, cdr(lst)) }
}


# member?(x, lst) — structural membership
def member?(x, lst) {
  if nil?(lst) { false } else if x = car(lst) { true } else {
    member?(x, cdr(lst))
  }
}

def reject(pred, lst) { filter(fn(x) { not(pred(x)) }, lst) }
def all?(pred, lst) { if nil?(lst) { true } else if pred(car(lst)) { all?(pred, cdr(lst)) } else { false } }
def any?(pred, lst) { if nil?(lst) { false } else if pred(car(lst)) { true } else { any?(pred, cdr(lst)) } }
def find(pred, lst) { if nil?(lst) { nil } else if pred(car(lst)) { car(lst) } else { find(pred, cdr(lst)) } }
def flat-map(f, lst) { flatten(map(f, lst)) }
def flatten(lst) { if nil?(lst) { nil } else { append(car(lst), flatten(cdr(lst))) } }
def zip(a, b) {
  if nil?(a) { if nil?(b) { nil } else { error("zip: lists must have equal length") } }
  else if nil?(b) { error("zip: lists must have equal length") }
  else { cons(list(car(a), car(b)), zip(cdr(a), cdr(b))) }
}
def enumerate(lst) { enumerate-from(0, lst) }
def enumerate-from(i, lst) {
  if nil?(lst) { nil } else { cons(list(i, car(lst)), enumerate-from(i + 1, cdr(lst))) }
}
def partition(pred, lst) {
  let (parts = foldl(fn(acc, x) {
    if pred(x) { {:matched -> cons(x, acc[:matched]), :rest -> acc[:rest]} }
    else { {:matched -> acc[:matched], :rest -> cons(x, acc[:rest])} }
  }, {:matched -> nil, :rest -> nil}, lst)) {
    {:matched -> reverse(parts[:matched]), :rest -> reverse(parts[:rest])}
  }
}
