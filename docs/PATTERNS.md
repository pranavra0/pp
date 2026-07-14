# pp Pattern Analysis — what the codebase already knows

Pass through the AST, reader, evaluator, compiler, VM, primitives, and runtime.
Not suggestions — patterns the code already embodies that could be surfaced
as syntax or made systematic.

See also: [PRAGMATIC-SYNTAX.md](PRAGMATIC-SYNTAX.md) for the target surface,
[CONVENTIONS.md](CONVENTIONS.md) for naming/style,
[MASTER-PLAN.md](MASTER-PLAN.md) for the phased implementation roadmap.

---

## 1. The Runtime Triad: three ambient stacks, one pattern

```ocaml
Runtime.handler_stack        : (string * (value list -> value) * string) list ref
Runtime.current_capabilities : capability list ref
Runtime.config_stack         : value list ref
```

All three use `Runtime.with_ref` — save, set, run body, restore on every exit
(normal return, exception, tail call).

**Files to touch for a unified surface:**
- `src/reader_braces.ml` — add `with { caps: ..., config: ..., handler: ... }`
- `src/desugar.ml` — normalize the nested `EWithCaps`/`EWithConfig`/`EWithHandler` order

This unification is reader-only; the runtime already supports it.

---

## 2. `ELocated` — locations threaded through the AST

Every expression can be wrapped in `ELocated ((file, line), inner_expr)`.
Source locations are semantically transparent but operationally load-bearing:
error messages, formatter layout, and LAW-20 hashes all depend on them.

**Consequence:** the brace printer must preserve location identity byte-for-byte.
Any new surface syntax must emit locations at the same sites the existing
readers do, or error-message parity between backends breaks.

**Files to touch:**
- `src/reader_braces.ml` — emit `ELocated` for every new form
- `src/main.ml` (fmt/why/graph printers) — handle new forms without dropping locations

---

## 3. The Observation Effect — one `record_read`, many names

Every world-read follows the same shape:

```ocaml
slurp(path)        → record_read (file:<canon-path>)
env-get(name)      → record_read (env:<name>)
tree-observe(root) → record_read (tree:<root>)
probe(name)        → record_read (probe:<name>)
config(key)        → record_read (config:<key>)
```

The surface currently has five different names for the same pattern. The fix
is the `$KIND(...)` sigil family:

```pp
$file("src/main.c")
$env("CC")
$glob("src/*.c")
$probe("clock")
```

**Files to touch:**
- `src/reader_braces.ml` — parse `$KIND(...)` and lower to the right primitive
- `stdlib/*.pp` — migrate existing `slurp`/`env-get`/`list-dir` calls
- Manual examples — rewrite observations with sigils

---

## 4. Tiered Caching — two thunks, one type

```ocaml
VThunk { thunk_persist: true }    → node      → persisted to ~/.pp/store
VThunk { thunk_persist: false }   → let/delay → ephemeral, in-memory only
```

Both are `VThunk`. Both are content-addressed. The only difference is lifetime.

**Surface opportunity:** `@cache` on a `def` wraps the body in `ENode`:

```pp
@cache
def helper(x) { ... }
```

This is reader-only and reuses the existing `node` machinery.

---

## 5. Failure Caching — error as value, cached like success

When a node body raises:

1. Pops the trace frame (keeps reads made before the error).
2. Creates a value for the error.
3. Stores it under its content hash.
4. Stores a `Failed` trace.
5. Resets thunk status to `Unevaluated`.

**Surface opportunity:** expose the `[:ok, v]` / `[:err, e]` convention with
`try { ... }` and `<-` / `?` propagation:

```pp
try {
  a <- divide(x, y)
  b <- divide(a, 2)
  [:ok, a + b]
}
```

No new runtime semantics are needed; this is reader sugar over `match`/`if`.

---

## 6. Identity ≠ Validity — the BSalC model, as code

```ocaml
key    = H(code-hash ‖ free-var-value-hashes)
trace  = set of (cell-id, observed-hash) pairs
hit    = key matches AND some trace still verifies
```

`Store.hit` checks both. `Store.traces` is key → SET of traces.

**Surface opportunity:** `pp why` already explains hit/miss in these terms.
A `reads` clause can make the declared vs actual dependency set visible:

```pp
node compile(src) reads $file(src), $env("CC") { ... }
```

`reads` must never skip trace verification; it is documentation and a target
for `pp check` warnings.

---

## 7. Definition Kind — two ways to bind, one scope

```ocaml
EDef (name, params, body)       # function binding: late-bound, mutually recursive
EDefValue (name, rhs)           # value binding: evaluated at definition time
```

Both follow LAW 4's letrec* rule: every name is visible to the whole block,
but a value def's RHS referencing a later value def raises
"referenced before its definition."

**Surface is already correct:** `def f(x) { ... }` for functions, `let x = e`
for values. The only gap is documentation.

---

## 8. Block as Expression — the `EDo` unification

```ocaml
block_body [single]  →  single
block_body [a; b]    →  EDo [a; b]
block_body []        →  EDo []
```

`Desugar.block_body` already normalizes blocks. Neither backend has to care
about block boundaries.

**No change needed.** New syntax just needs to produce statement lists the
existing `block_body` can consume.

---

## 9. Reader Symmetry — two surfaces, one AST, one desugar pass

```ocaml
reader.ml          → Types.expr → Desugar.(block_body, assemble_fn_body, ...)
reader_braces.ml   → Types.expr ↗
```

Both readers target the same AST and call the same desugar functions. Any
reader-level sugar is zero-risk for LAW-20 keys.

**Implication:** Phase 1 and Phase 2 sugars can be added without touching the
store, evaluator, compiler, or VM.

---

## 10. The `needs` Lowering — authority as reader sugar

```pp
node compile(src) needs fs.read("src/"), process { ... }
```

already lowers to `with-caps(cap-compose(...), current-capabilities()) { ... }`.

This pattern is proven. The only remaining work is adding `@needs` and
`@reads` attributes on defs/nodes.

---

## 11. Content-Addressed Linking — the `island` pin

```ocaml
EIsland ("github:owner/repo#ref", Some "a1b2c3d4e5f6...")
```

The inline hex pin IS the code hash. The surface already has this pattern.

**No change needed.** Islands stay as-is.

---

## 12. Algebraic Effects — `perform` + `with-handler`

```pp
perform read-file(path)
with-handler read-file: fn(path) { "mock" } { body }
```

The runtime supports named operations and dynamically-scoped handlers, but
**not resumption.** The handler replaces the operation; it cannot `resume`
the original computation.

**Stretch goal:** resumable effects (`perform` + `resume`) need VM support for
capturing/restoring operand stack, frame stack, and program counter. This is
Phase 4, not a reader-only change.

---

## 13. Gradual Typing — checked at force time

```ocaml
ETyped (expr, ty)     → checked when the function runs, not at definition time
```

pp types are optional and dynamic. The surface already has `def f(x: int) { ... }`.

**No change needed**, unless adding a static checker later.

---

## 14. Node-Boundary Symmetry — authority banned in both directions

```ocaml
Free-var ban: a node's free variable may not contain VCapability or VSealed
Result ban:   a node's result may not contain VCapability or VSealed
```

Both sides are checked independently. The surface makes this visible through
`needs` clauses and `$secret(...)` / `unseal`.

**No change needed.** New observation sigils must return `VSealed` for secrets
so the existing ban applies.

---

## 15. What the codebase needs surfaced (the gaps)

| # | Pattern | Code location | Surface gap | Plan phase |
|---|---------|--------------|-------------|------------|
| A | Tagged values | Convention: `[:ok, v]` lists | `try` / `<-` / `?` | 1b |
| B | Observation monad | `record_read` in Runtime | `$file`, `$env`, `$glob` | 1 |
| C | Dynamic extent unification | `with_ref` used by all three stacks | `with { caps:, config:, handler: }` | 2 |
| D | Error accumulation | None yet | `collect { }` | 1b |
| E | Error propagation | None yet | `try { }` + `<-` / `?` | 1b |
| F | Function clauses | None | Multiple `def`s, same name | 2 |
| G | Pattern matching | `JUMP_IF_FALSE` only | `match` expression | 3 |
| H | Comprehension | None | `[f(x) for x in list if p(x)]` | 3b |
| I | Node metadata | `needs` buried in node syntax | `@cache`, `@needs(...)` | 2 |
| J | Resumable effects | `perform`+handler, no `resume` | `perform effect(args); resume(value)` | 4 |
| K | String interpolation | None | `f"Hello, {name}!"` | 1 |
| L | Spread/rest in calls | None | `run!("cc", ...flags, "-o", out)` | 1 |
| M | Map update syntax | `map-insert(m, k, v)` | `{ m \| k -> v }` | 1 |
| N | Fresh name generation | `gensym()` for macros only | Already adequate | — |

---

## 16. The elegance criterion, restated

pp's codebase already knows all of this. The question is: **which patterns
deserve surface syntax?**

Answer: the ones that make pp's domain model VISIBLE at the call site.
- `$file(...)` makes observations visible
- `[:ok, v]` / `try { }` makes error handling visible
- `needs fs.read(...)` makes authority visible
- `reconcile { ... }` makes desired state visible
- `fenced(:email, ...)` makes non-convergence visible
- `collect { ... }` makes error accumulation visible
- `try { a <- f(); b <- g(); ... }` makes error propagation visible

Everything else — pattern matching, comprehensions, string interpolation —
is general-purpose polish. Nice, but secondary to making pp's thesis legible
in every line of source.

---

## 17. Concrete implementation checklist

For each pattern surfaced, the following must be true before merging:

- [ ] New form parses in `reader_braces.ml` and lowers to a valid `Types.expr`
- [ ] Both backends evaluate the lowered form identically (`--diff`)
- [ ] `pp fmt` can round-trip the form with LAW-20 hash equality
- [ ] The fuzzer can generate the form and the round-trip invariant holds
- [ ] Error messages cite the new form's source location in both backends
- [ ] Manual contains at least one executed example of the form

This checklist is the bridge from pattern analysis to the implementation plan.
