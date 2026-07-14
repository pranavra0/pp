# pp Style Guide

How to write pp that feels good to read and natural to reach for. Most
"Bad"/"Good" examples reference the external `pp-leetcode` workspace; the
ones in this tree (`stdlib/`, `tests/`, `examples/`) should be migrated to
match as part of Phase 0.

For the **complete language surface** — syntax for nodes, capabilities,
observations, effects, reconciliation, handlers, domains, probes, secrets, and
the general-purpose language — see [PRAGMATIC-SYNTAX.md](PRAGMATIC-SYNTAX.md).

For a **pattern analysis** of the codebase — what the AST, evaluator, compiler,
and runtime already know and how PL theory describes them — see
[PATTERNS.md](PATTERNS.md).

---

## 1. Suffixes: four signals at the call site

pp lets you put `?`, `!`, and `->` in names. Use them. Call sites become
honest at a glance.

| Suffix | Means | Example |
|--------|-------|---------|
| `?` | Returns a bool | `nil?(x)`, `open?(c)`, `starts-with?(s, prefix)` |
| `!` | Does I/O or mutates | `run!("cc", f)`, `log!("done")` |
| `->` | Converts between types | `string->number(s)`, `number->string(n)` |
| *(none)* | Pure function — the default | `sort(lst)`, `merge(a, b)`, `map(f, lst)` |

Rules of thumb:
- If it answers yes/no, it gets `?`. Not `is-` and not `is-?`.
- If you wouldn't cache it, it gets `!`. (pp uses `not(…)` for negation — `!` is never an operator.)
- If its whole job is turning an A into a B, it gets `->`.
- Otherwise it's pure and suffix-free. Most functions here.

---

## 2. Truthiness: `nil` and `false` are the only falsy values

`0`, `""`, empty list, empty map — all truthy. Use this.

```pp
;; Testing for presence — truthiness wins
if found            { ... }   ;; "if found is something"     (3 words → 1)
if nil?(stack)      { ... }   ;; "if stack is empty"         (reads as a question — fine)
if not(ok)          { ... }   ;; "if ok is false"            (for actual booleans)
```

Don't write `if not(nil?(x))` when `if x` does the same thing. Don't write
`if x = nil` when `if nil?(x)` is shorter and reads as a question.

---

## 3. `else if` chains: they work, no extra nesting

pp reads `else if` as a single chain. There is no `elif` keyword — just
don't nest the second `if` inside braces.

```pp
;; Good — flat chain
if open?(c) {
  loop(i + 1, cons(c, stack))
} else if nil?(stack) {
  false
} else if car(stack) = match-close(c) {
  loop(i + 1, cdr(stack))
} else {
  false
}

;; Bad — gratuitous nesting (the second "if" is inside braces)
if open?(c) {
  loop(i + 1, cons(c, stack))
} else {
  if nil?(stack) {
    false
  } else if car(stack) = match-close(c) {
    loop(i + 1, cdr(stack))
  } else {
    false
  }
}
```

---

## 4. `let`: one flat form, not a ladder

pp's `let` is letrec — every binding sees every other binding. Put all your
locals in one `let`.

```pp
;; Good — one let, four bindings
let (n = length(nums), mid = n / 2,
     left = take(mid, nums), right = drop(mid, nums)) {
  merge(sort(left), sort(right))
}

;; Bad — four lets, four indent levels (real code from 0053)
let (val = car(lst)) {
  let (new-cur = if cur + val > val { cur + val } else { val }) {
    if new-cur > best { kadane(cdr(lst), new-cur, new-cur) }
    else               { kadane(cdr(lst), new-cur, best) }
  }
}
```

When bindings genuinely depend on order (shadowing, staged reads), use `let*`:

```pp
let* (x = 1, x = x + 1, x = x * 2) { x }    ;; => 4
```

---

## 5. Naming

### Functions: verb-led, name the result

```pp
;; Good — what it produces
def longest-palindrome(s)  { ... }
def remove-duplicates(nums) { ... }

;; Bad — how it works
def expand-around-centre(s) { ... }
def two-pointer-scan(nums)  { ... }
```

### Values: full words, one concept each

```pp
let (max-len = 0, best-start = 0, seen = hash-map()) { ... }   ;; good
let (ml = 0, bs = 0, m = hash-map())                { ... }   ;; bad
```

### Inner helpers: name the step

Every LeetCode solution defines a helper called `loop`. Name it for what
it computes instead.

```pp
;; Good
def max-profit(prices) {
  def scan(lst, low, best) { ... }
  scan(cdr(prices), car(prices), 0)
}

;; Good
def two-sum(nums, target) {
  def find(i, seen) { ... }
  find(0, hash-map())
}

;; Bad
def max-profit(prices) {
  def loop(lst, min-price, best) { ... }
  loop(cdr(prices), car(prices), 0)
}
```

---

## 6. `car`/`cdr`: define aliases if they bother you

`car` and `cdr` are builtins — terse, precise, and historically
load-bearing (changing them would invalidate every cached computation,
LAW-20). But if they hurt readability in your codebase, alias them in a
prelude:

```pp
def first(lst)  { car(lst) }
def rest(lst)   { cdr(lst) }
def second(lst) { car(cdr(lst)) }
```

Pick one style per file. `car`/`cdr` is fine for tight recursion; `first`/`rest`
is better for multi-step algorithms.

---

## 7. Map access: alias the verbosity away

`hash-map-get` and `map-insert` are accurate but long. In map-heavy code:

```pp
def get(m, k)   { hash-map-get(m, k) }
def put(m, k, v) { map-insert(m, k, v) }
def has?(m, k)  { not(nil?(hash-map-get(m, k))) }
```

```pp
;; Before
let (found = hash-map-get(seen, complement)) {
  if found { list(found, i) }
  else     { loop(i + 1, map-insert(seen, num, i)) }
}

;; After
let (found = get(seen, complement)) {
  if found { list(found, i) }
  else     { find(i + 1, put(seen, num, i)) }
}
```

---

## 8. Comments: why, not what — with a header

The code says what. Comments say why: algorithm choice, complexity, edge
case.

Library files get a header listing every export:

```pp
# lib/hash_map.pp — hash map utilities
#
#   hash-map-new()     create empty map
#   get(m, k)          lookup key (nil if missing)
#   put(m, k, v)       insert/update, returns new map
#   has?(m, k)         key membership test
```

Solution files get a one-liner:

```pp
# 0053 Maximum Subarray — Kadane's algorithm, O(n)
```

---

## 9. Tier awareness: know where you are

- **Node tier** (`node { … }`) — pure, cached. The body runs under a fixed
  capability set and its effects are traced. `!`-suffixed functions may
  appear when they perform traced effects (e.g. `run!`, `run-dep!`); their
  results become part of the node's value and are cached like any other.
- **Scripting tier** (top-level `perform …`, `do { … }`) — imperative,
  uncached. `!` functions live here.

`!` means "does I/O or mutates the world." It is not a ban from node bodies;
it is a warning that the function is not a pure computation. Functions that
only read files inside a node do not need `!` because the trace records the
reads, but `run!` and friends keep `!` because they reach outside the process.

---

## 10. Before/after: a LeetCode solution rewired

`best_time_to_buy_and_sell_stock.pp` (0121), with every rule applied.

### Before (real code from the pp-leetcode workspace)

```pp
def max-profit(prices) {
  if nil?(prices) { 0 } else {
    def loop(lst, min-price, best) {
      if nil?(lst) { best } else {
        let (price = car(lst)) {
          let (new-min = if price < min-price { price } else { min-price }) {
            let (profit = price - new-min) {
              let (new-best = if profit > best { profit } else { best }) {
                loop(cdr(lst), new-min, new-best)
              }
            }
          }
        }
      }
    }
    loop(cdr(prices), car(prices), 0)
  }
}
```

### After

```pp
def max-profit(prices) {
  if nil?(prices) { 0 } else {
    def scan(lst, low, best) {
      if nil?(lst) { best } else {
        let (price = car(lst),
             new-low = if price < low { price } else { low },
             profit = price - new-low,
             new-best = if profit > best { profit } else { best }) {
          scan(cdr(lst), new-low, new-best)
        }
      }
    }
    scan(cdr(prices), car(prices), 0)
  }
}
```

Four things changed:
1. **Helper named `scan`** not `loop`
2. **One flat `let`** — four bindings where there were four levels
3. **Values named for meaning** — `low` not `min-price`
4. **`car` left as `car`** — tight recursion, terse is fine

Same algorithm, same output, half the indent depth.

---

## 11. Quick reference

```pp
;; ── Suffixes ──────────────────────────────
def done?(x)      { ... }    ;; predicate: returns bool
def deploy!(spec) { ... }    ;; effectful: does I/O
def str->int(s)   { ... }    ;; conversion: A -> B
def sort(lst)     { ... }    ;; pure: the default

;; ── Bindings ──────────────────────────────
let (a = 1, b = a + 1)   { ... }   ;; mutual letrec — use this
let* (x = 1, x = x + 1)  { ... }   ;; sequential — when shadowing

;; ── Conditions ────────────────────────────
if nil?(x)  { ... }               ;; empty check (reads as question)
if x        { ... }               ;; presence check (truthiness)
if not(ok)  { ... }               ;; boolean negation
if a { ... } else if b { ... }    ;; chain — don't nest else { if ... }

;; ── Alias your friction ───────────────────
def first(lst)  { car(lst) }
def rest(lst)   { cdr(lst) }
def get(m, k)   { hash-map-get(m, k) }
def put(m, k, v) { map-insert(m, k, v) }
```
