#import "/lib.typ": example

= Style Guide — Quick Reference

This appendix distills the naming and style conventions every pp file should
follow. The full guide is [docs/SYNTAX.md] in the repository.

== Suffix Conventions

Four signals at the call site — no guesswork about what a function does:

#table(
  columns: (auto, 1fr, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Suffix*], [*Means*], [*Example*]),
  [`?`], [Returns a bool], [`nil?(x)`, `file-exists?(p)`, `starts-with?(s, pre)`],
  [`!`], [Does I/O or mutates], [`run!("cc", f)`, `log!("done")`, `write!(p, c)`],
  [`->`], [Converts between types], [`string->number(s)`, `number->string(n)`],
  [_(none)_], [Pure function — the default], [`sort(lst)`, `map(f, lst)`],
)

Rules of thumb:
- If it answers yes/no, it gets `?`. Not `is-` and not `is-?`.
- If you would not cache it, it gets `!`.
- If its whole job is turning an A into a B, it gets `->`.
- Otherwise it is pure and suffix-free. Most functions live here.

== Truthiness

Only `nil` and `false` are falsy. `0`, `""`, empty list, empty map — all truthy.

```pp
if found            ;; "if found is something" — truthiness wins
if nil?(stack)      ;; "if stack is empty" — reads as a question
if not(ok)          ;; "if ok is false" — for actual booleans
```

Never write `if not(nil?(x))` when `if x` does the same thing.

== `else if` Chains

`else if` is a flat chain — do not nest the second `if` inside braces:

```pp
;; Good — flat chain
if open?(c) {
  loop(i + 1, cons(c, stack))
} else if nil?(stack) {
  false
} else {
  true
}
```

== `let`: One Flat Form

pp's `let` is letrec — every binding sees every other. Put all locals in one:

```pp
;; Good — one let, four bindings
let (n = length(nums), mid = n / 2,
     left = take(mid, nums), right = drop(mid, nums)) {
  merge(sort(left), sort(right))
}
```

For sequential shadowing, use `let*`:

```pp
let* (x = 1, x = x + 1, x = x * 2) { x }    ;; => 4
```

== Naming

Functions: verb-led, name the result — `longest-palindrome(s)`, not
`expand-around-centre(s)`. Values: full words, one concept each — `max-len`,
not `ml`. Inner helpers: name the step — `scan(lst, low, best)`, not `loop`.

== `car` / `cdr`

Built-in. Alias to `first` / `rest` in a prelude if needed:

```pp
def first(lst)  { car(lst) }
def rest(lst)   { cdr(lst) }
```

Pick one style per file.

== Map Access

In map-heavy code, alias the verbosity:

```pp
def get(m, k)   { hash-map-get(m, k) }
def put(m, k, v) { map-insert(m, k, v) }
def has?(m, k)  { not(nil?(hash-map-get(m, k))) }
```

== Comments

Why, not what. Algorithm choice, complexity, edge cases. Library files get a
header listing every export:

```pp
// lib/hash_map.pp — hash map utilities
//
//   hash-map-new()     create empty map
//   get(m, k)          lookup key (nil if missing)
//   put(m, k, v)       insert/update, returns new map
//   has?(m, k)         key membership test
```

== Tier Awareness

- *Node tier* (`node { … }`) — pure, cached. `!`-suffixed functions may appear
  when they perform traced effects (`run!`, `run-dep!`); their results become
  part of the node's cached value.
- *Scripting tier* (top-level `do { … }`) — imperative, uncached. `!` functions
  live here.

`!` means "does I/O or mutates the world." It is not a ban from node bodies;
it is a warning that the function is not a pure computation.
