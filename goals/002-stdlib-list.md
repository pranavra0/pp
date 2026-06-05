# Goal 002: Basic stdlib — list operations

**Status:** pending

## Why

pp has a REPL, modules, lazy evaluation, and now `eval-pp`. But without basic
collection operations, every user must reimplement `map` from scratch. A small,
high-quality stdlib makes the language usable for real programs.

## What

Create `stdlib/list.pp` with these functions (all lazy where possible):

| Function | Signature | Description |
|----------|-----------|-------------|
| `map` | `(fn, list)` | Lazily apply fn to each element; returns new lazy list |
| `filter` | `(pred, list)` | Lazily filter list by predicate |
| `foldl` | `(fn, acc, list)` | Left fold (strict: forces list elements as it goes) |
| `foldr` | `(fn, acc, list)` | Right fold (lazy where possible) |
| `range` | `(start, end)` | Build a lazy list of integers [start, end) |
| `take` | `(n, list)` | Take first n elements (forces them) |
| `length` | `(list)` | Count elements (forces the spine, not elements) |

All functions must work with lazy lists (thunks in the cdr).

## Implementation notes

- Write in pure pp — no OCaml changes needed.
- Use `def` for each function.
- `cons` stores values as thunks (lazy). `car`/`cdr` force the pair but return
  elements as-is (which may be thunks). Force elements explicitly when a
  function needs their value.
- `map` must be lazy: `(map f xs)` returns a list whose elements are computed
  on demand. Use `delay` to wrap each `(f x)` call.
- `filter` must be lazy: only compute elements as the list is traversed.
- `foldl` is strict (iterative); `foldr` is lazy where possible.
- Test with both finite and lazy/infinite lists to verify laziness.

## Files to create

- `stdlib/list.pp` — the list library
- `tests/002-list-test.pp` — test file (already provided below)

## Test file

Run `tests/002-list-test.pp` — it must produce correct output without errors.
