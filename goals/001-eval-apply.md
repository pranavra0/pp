# Goal 001: `eval-pp` and `apply-pp` builtins

**Status:** pending

## Why

pp can read and evaluate code from the OCaml side, but pp code itself cannot
eval pp strings or apply functions dynamically. Adding these two builtins makes
the language self-aware — the meta-circular evaluator becomes trivial.

Fexprs already give us operatives (functions that receive unevaluated args).
`eval-pp` + `apply-pp` complete the picture: the ability to evaluate arbitrary
expressions and apply functions dynamically from within pp.

## What

Two new builtins:

1. **`(eval-pp string)`** — reads and evaluates a pp expression from a string.
   Returns the result value. The expression is evaluated in the **calling
   environment** (the env where `eval-pp` is called), not a fresh env.

   ```lisp
   (let [x 10]
     (eval-pp "(+ x 5)"))  ;; => 15
   ```

2. **`(apply-pp fn args)`** — applies a function to a *list* of arguments
   (already evaluated). Unlike normal application which wraps args in thunks,
   `apply-pp` takes a list of already-forced values and calls the function.

   ```lisp
   (apply-pp + (list 1 2 3))  ;; => 6
   (apply-pp cons (list 1 (list 2)))  ;; => (1 2)
   ```

## Implementation notes

- `eval-pp` needs the current environment. Currently builtins don't receive the
  env — only args. This means either:
  - (a) Give builtins access to the current eval environment (pass env through
    the builtin call path), or
  - (b) Thread the env through a hidden parameter.

  The simplest approach: modify the `VBuiltin` type or the builtin calling
  convention to pass the env. Alternatively, store a "current env" ref in the
  evaluator (similar to `handler_stack` / `current_capabilities`) that
  `eval-pp` can read.

  Recommend: add `current_env : env ref` to evaluator.ml, updated on every
  eval entry. `eval-pp` reads this ref, calls `Reader.read_string`, and
  `eval`.

- `apply-pp` is simpler: it takes an already-evaluated function value and a
  list of already-evaluated argument values, and calls `apply` (not
  `apply_tail` — we don't need TCO for apply-pp since it's used sparingly).

- Both builtins should force their arguments first (like all other builtins).

## Files to modify

- `src/primitives.ml` — register the two new builtins
- `src/evaluator.ml` — add `current_env` ref, update it in eval entry points
- Possibly `src/types.ml` — if the VBuiltin signature changes (unlikely)

## Test file

Run `tests/001-eval-apply-test.pp` — it must produce correct output without errors.
