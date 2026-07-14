# pp Ergonomics — Master Implementation Plan

A comprehensive plan covering every surface improvement identified across the
pattern analysis, syntax design, and style conventions. Ordered by dependency,
with exit criteria for each phase.

This plan builds on top of the completed M7 brace-surface migration. It does
not reopen M7; it adds new syntax on top of the existing two-reader,
one-AST architecture.

This plan draws from:
- [PATTERNS.md](PATTERNS.md) — what the codebase already encodes
- [PRAGMATIC-SYNTAX.md](PRAGMATIC-SYNTAX.md) — the target surface design
- [CONVENTIONS.md](CONVENTIONS.md) — naming and style rules

> **Note:** This plan intentionally omits time estimates. Work proceeds
> opportunistically; phases are gated by exit criteria, not calendars.

---

## Phase dependency graph

```
Phase 0 (conventions) ──────────────────────────────────────────────┐
                                                                     │
Phase 1 (basic sugars) ──┬── Phase 1b (error sugars) ───────────────┤
                         │                                           │
Phase 2 (pattern surface)┤                                           │
                         │                                           │
Phase 3 (AST additions) ─┴── Phase 3b (comprehensions) ─────────────┤
                                                                     │
Phase 4 (VM deep support)                                            │
                                                                     │
Phase 5 (tooling) ───────────────────────────────────────────────────┘
```

Phases 0–2 touch only the reader (and `desugar.ml`). Phases 3–4 add AST nodes
and backend support. Phase 5 is tooling and migration.

---

## Phase 0 — Conventions & Documentation

**What:** Canonicalize the naming/style rules. No code changes.

**Deliverables:**

| # | Item | File |
|---|------|------|
| 0.1 | Suffix convention (`?` `!` `->` pure-default) | `docs/CONVENTIONS.md` |
| 0.2 | Truthiness rules (`if x` not `if not(nil?(x))`) | `docs/CONVENTIONS.md` |
| 0.3 | Flat `let` over nested `let` ladders | `docs/CONVENTIONS.md` |
| 0.4 | `cond`-style `else if` chains (no nesting) | `docs/CONVENTIONS.md` |
| 0.5 | Naming: result-named functions, no abbreviations | `docs/CONVENTIONS.md` |
| 0.6 | `car`/`cdr` → alias recommendation | `docs/CONVENTIONS.md` |
| 0.7 | `hash-map-get` → local alias recommendation | `docs/CONVENTIONS.md` |
| 0.8 | Library header block convention | `docs/CONVENTIONS.md` |
| 0.9 | Tier awareness (node vs scripting suffix rules) | `docs/CONVENTIONS.md` |

**Additional work needed:**

| # | Item |
|---|------|
| 0.10 | Rewrite `workspace/std/*.pp` and `workspace/lib/*.pp` in pp-leetcode to follow all conventions |
| 0.11 | Rewrite LeetCode solutions to use flat `let`, proper naming, suffix conventions |
| 0.12 | Add a `docs/CONVENTIONS.md` quick-ref card to the manual appendix |
| 0.13 | Add "style" section to AGENTS.md so AI coders learn the conventions |

> Note: the `workspace/` directory is outside this repo (pp-leetcode). Examples
> in `CONVENTIONS.md` reference it for illustration; update them when integrating
> that code, or replace with real files from `stdlib/` and `tests/`.

**Exit criteria:**
- LeetCode solutions follow Phase 0 conventions
- Every `let` ladder in workspace/{std,lib,problems} collapsed to flat form
- No `is-?` double-suffixing, no `loop`-named helpers, no abbreviation-only names

---

## Phase 1 — Basic Reader Sugars

**What:** Reader-level desugars in `reader_braces.ml` that lower to existing
AST forms. Zero evaluator/compiler/VM changes. LAW-20 keys unchanged.

### 1.1 — `[a, b, c]` list literal

**Current state:** `[a, b]` lowers to `vector(a, b)`. Should lower to
`list(a, b)` — lists are the default collection in pp.

**Change:** In `reader_braces.ml`, `TLBracket` parsing: emit
`EApply(ESymbol "list", exprs)` instead of `EApply(ESymbol "vector", exprs)`.

**Spread:** `[a, ...rest]` → `cons(a, rest)`. Multi-element spread:
`[a, b, ...rest]` → `cons(a, cons(b, rest))`.

```pp
[a, b, c]       → list(a, b, c)
[a, ...rest]    → cons(a, rest)
[a, b, ...rest] → cons(a, cons(b, rest))
```

### 1.2 — `m[k]` map access

**New syntax:** `expr [ index ]` in postfix position.

```pp
m[:key]          → hash-map-get(m, :key)
m["string-key"]  → hash-map-get(m, "string-key")
v[0]             → vector-get(v, 0)
```

**Parser change:** Add `TLBracket` to `parse_postfix` (next to `TLParen` call
handling). Parse one expression inside brackets, close with `TRBracket`.

**Ambiguity:** `f[x]` could be map access or function call with a list
argument. Resolution: in postfix position (after an expression), `[` always
means index. To call a function with a list literal, use parens: `f([a, b])`.

### 1.3 — `{ m | k -> v }` map update

**New syntax:** `{ base | k1 -> v1, k2 -> v2 }` — a map literal with a
base expression and update arrows.

```pp
{ m | :key -> value }               → map-insert(m, :key, value)
{ m | :a -> 1, :b -> 2 }            → map-insert(map-insert(m, :a, 1), :b, 2)
```

### 1.4 — string interpolation: `f"Hello, {name}!"`

**New syntax:** `f"..."` — an f-prefixed string with `{expr}` interpolation
holes. The `f` must be glued to the opening quote.

```pp
f"Hello, {name}! Value: {x + 1}."
→ string-append("Hello, ", name, "! Value: ", number->string(x + 1), ".")
```

The lexer reads the whole f-string; the parser splits on `{` / `}` boundaries,
parsing each `{...}` content as an expression. Non-string holes are wrapped in
`number->string` (or an equivalent `to-string` primitive).

### 1.5 — `cond { test => result; ... }` multi-way conditional

**New syntax:** `cond { arm; arm; ... }` where each arm is `test => result`
and arms are separated by newlines or `;`.

```pp
cond {
  close = ")" => "("
  close = "}" => "{"
  close = "]" => "["
  true        => nil
}
```

Lowers to nested `EIf`. The `else` arm is syntactic sugar for `true => expr`.
`=>` is used instead of `->` to avoid overloading the map/desired-state arrow.

### 1.6 — `...args` spread in list/vector construction

**New syntax:** `[a, ...rest, b]` and `vec[a, ...rest, b]`.

Lowers to cons/append chains.

### 1.7 — `$KIND` observation sigils

**New syntax:** `$` prefix followed by an observation head.

```pp
$file("src/main.c")    → slurp("src/main.c")
$env("CC")             → env-get("CC")
$env("CC", "gcc")      → env-get("CC", "gcc")
$glob("src/*.c")       → list-dir("src", "*.c")
$probe("clock")        → probe("clock")
$secret("/run/key")    → sealed read
```

This unifies the five world-read primitives under one visual family. Each
lowers to the existing primitive and records the appropriate trace cell.

### 1.8 — `...args` spread in call position

**New syntax:** `f(a, b, ...rest)` — splices a list into arguments.

```pp
run!("cc", ...flags, "-o", out)
```

This requires a new `apply` primitive that calls a function with a dynamic
argument list. It is not purely reader-level; it needs evaluator and VM support.

### Phase 1 exit criteria

- All Phase 1 sugars parse and round-trip through `pp fmt` with hash equality
- `dune runtest` green (no existing behavior changed)
- Manual examples updated to use new syntax where appropriate
- Fuzzer extended to generate the new forms (round-trip test)

---

## Phase 1b — Error Handling Sugars

**What:** Reader-level sugars for the five-tier error model. All lower to
`match`-like chains over `[:ok, v]` / `[:err, e]` tagged lists.

### 1b.1 — `[:ok(v)]` / `[:err(e)]` tagged values

Use the existing convention: a two-element list whose first element is `:ok`
or `:err`.

```pp
[:ok, value]
[:err, message]
[:none]
```

No new tag syntax is introduced; `#` remains the comment character exclusively.

### 1b.2 — `try { }` block with `<-` propagation

**New syntax:**

```pp
try {
  a <- fallible()        # if :err, exit try with that error
  b <- another(a)        # a is unwrapped
  [:ok, a + b]
}
```

The `<-` arrow means: match the RHS against `[:ok, v]` → bind v;
`[:err, e]` → exit the try block with `[:err, e]`.

Lowers to nested `match`/`if` chains. A regular `let x = e` inside `try` does
not unwrap.

### 1b.3 — `?` postfix operator

`expr?` is a postfix alias for unwrap-or-propagate.

```pp
try {
  let a = divide(x, y)?
  let b = divide(a, 2)?
  [:ok, a + b]
}
```

Ship both `<-` and `?`; they lower to the same machinery.

### 1b.4 — `collect { }` error accumulation

**New syntax:**

```pp
let results = collect {
  srcs |> map(fn(f) { compile(f) })
}
```

Runs every expression, gathers all `:err`s, and returns `[:ok, values]` if all
succeeded, or `[:err, errors]` if any failed.

**Lowering:** A pass over the block partitions results into oks and errs.
May use a stdlib helper that the reader calls.

### Phase 1b exit criteria

- `try { a <- f(); b <- g(a); [:ok, b] }` produces correct error-propagation behavior
- `collect { ... }` accumulates all errors in a build-like scenario
- `dune runtest` green
- Fuzzer extended

---

## Phase 2 — Pattern Surface

**What:** Reader-level sugars that make pp's runtime patterns visible in
source. Still reader-only, still zero AST changes (except where noted).

### 2.1 — Function clauses (multiple `def`s, same name)

**New syntax:** Multiple `def` forms with the same name, differing only in
patterns on arguments.

```pp
def divide(a, 0) { [:err, "division by zero"] }
def divide(a, b) { [:ok, a / b] }

def fib(0) { 0 }
def fib(1) { 1 }
def fib(n) { fib(n - 1) + fib(n - 2) }
```

**Lowering:** Collect all `def`s with the same name. Emit a single `def`
whose body is a `cond`-like chain of pattern matches. Clauses are tried in
source order.

This needs a multi-pass approach in the block parser: collect defs, group by
name, emit merged forms. Function clauses are NOT duplicates; `check_block_defs`
must be updated to allow them.

### 2.2 — `@` attributes on nodes and defs

**New syntax:** `@tag(args)` annotations above definitions.

```pp
@needs(fs.read("src/"), process)
@reads($glob("src/*.c"))
node compile(src) { ... }

@cache
def helper(x) { ... }    # @cache on a def makes it a node

@deprecated("use new-fn instead")
def old-fn(x) { ... }
```

**Lowering:** `@needs(...)` on a `node` lowers to the existing `needs` →
`EWithCaps` machinery. `@cache` on a `def` wraps the body in `ENode`.
`@deprecated` emits a `perform log(...)` call at the start of the body (or is
stored as metadata for a linter).

### 2.3 — Unified `with` form

**New syntax:** A single `with` block that combines caps, config, and
handlers.

```pp
with {
  caps: narrow-cap,
  config: { cc: "clang", cflags: ["-O2", "-Wall"] },
  handler log: fn(msg) { print("LOG: {msg}") },
  handler read-file: fn(path) { mock-read(path) }
} {
  body
}
```

**Lowering:** Nested `EWithCaps`, `EWithConfig`, `EWithHandler` in canonical
order.

### 2.4 — `fenced { }` shorthand

**Current:** `perform fenced(:email, hash-map(...))`

**New:**

```pp
fenced :email {
  to: "user@example.com"
  subject: "Build complete"
  body: "All {count} targets built."
}
```

Lowers to a map literal passed to `fenced`.

### 2.5 — `$secret` and `unseal`

Already covered by Phase 1.7. Keep `unseal` as the primitive name.

### Phase 2 exit criteria

- Function clauses: `def fib(0) { 0 }; def fib(1) { 1 }; def fib(n) { ... }` works identically in both backends
- `@needs` / `@reads` on nodes produce correct capability narrowing
- Unified `with { caps:, config:, handler: }` nests correctly
- All Phase 2 sugars round-trip through `pp fmt`
- `dune runtest` green

---

## Phase 3 — AST Additions

**What:** New AST nodes that need evaluator, compiler, and VM support.
These change the language semantics (or at least the execution model) and must
be identically supported in both backends.

### 3.1 — `match` expression

**New AST node:** `EMatch of expr * (pattern * expr) list`

```pp
match value {
  [:ok, v]  => process(v)
  [:err, e] => log!("error: {e}"); nil
  [x, ...rest] => recurse(x, rest)
  []        => default
  _         => fallback
}
```

**Patterns:**
- Literal: `42`, `"hello"`, `true`, `nil`
- Variable: `x` (matches anything, binds)
- Wildcard: `_` (matches anything, doesn't bind)
- List: `[pat, ...rest]`, `[a, b]`, `[]`
- Tagged: `[:ok, v]`, `[:err, e]`
- Map: `{:key -> v, ...}` (stretch)
- Guard: `pat if cond => expr`

**Evaluator:** Walk patterns left-to-right, first match wins. No match →
runtime error `"match failure"`.

**Compiler:** Emit `JUMP_IF_FALSE` chains, `LOAD_LOCAL`/`STORE_LOCAL`,
`CAR`/`CDR` for list destructure.

### 3.2 — `for` / `while` loops (stretch)

Comprehensions and iteration forms.

```pp
[compile(f) for f in srcs if f.ends-with?(".c")]
→ srcs |> filter(fn(f) { f.ends-with?(".c") }) |> map(compile)
```

Reader-only if desugared to `map`/`filter`.

### 3.3 — `:=` mutation (stretch — scripting tier only)

Mutable local variables for the scripting tier. `x := new-value` updates
a mutable slot. Barred from node bodies.

This needs a new value type (`VRef`) or frame slot mutation operations.
Significant VM change.

### Phase 3 exit criteria

- `match` works identically in both backends for all pattern kinds
- Fuzzer generates match expressions and patterns (both backends agree)
- All existing `if`/`else if` chains that could be `match` still work
- `dune runtest` green
- Fuzzer extended: both grammars generate match

---

## Phase 4 — VM Deep Support

**What:** Features that need new opcodes or significant VM changes.

### 4.1 — Resumable effects (`perform` + `resume`)

**Current:** `perform effect(args)` dispatches to the handler, but the handler
cannot resume the computation.

**New:** `perform effect(args)` captures the continuation. The handler can
call `resume(value)` to continue the original computation with the given
value.

```pp
with handler fetch: fn(url) {
  let cached = cache-get(url)
  if cached { resume(cached) }
  else {
    let result = http-get!(url)
    cache-put(url, result)
    resume(result)
  }
} {
  let data = perform fetch("https://api.example.com/data")
  process(data)
}
```

This is full algebraic effects with delimited continuations. It needs VM
support for capturing and restoring the operand stack, frame stack, and
program counter. The tree-walker can use `call/cc`-style CPS.

### 4.2 — Tail-call modulo cons (stretch)

Optimize `cons(car(lst), recurse(cdr(lst)))` into a single frame that
mutates a tail pointer.

### Phase 4 exit criteria

- If resumable effects ship: `perform` + `resume` works identically in both backends
- Fuzzer generates resumable effect programs
- `dune runtest` green

---

## Phase 5 — Tooling & Migration

**What:** `pp lint`, `pp fmt` integration, documentation, and mechanical
migration of the existing codebase to use new syntax.

### 5.1 — `pp lint`

A linter that checks conventions from Phase 0:

| Rule | Description |
|------|-------------|
| `suffix-predicate` | `?`-suffixed function returns non-bool |
| `suffix-effect` | `!`-suffixed function is pure |
| `suffix-double` | `is-?` double-suffixing |
| `let-ladder` | Chained single-binding `let`s |
| `truthiness` | `if not(nil?(x))` → `if x` |
| `naming-loop` | Helper named `loop` |
| `naming-abbrev` | Single-char or two-char names outside tight loops |
| `car-cdr-mixed` | Mixed `car`/`cdr` and `first`/`rest` in one file |

Implementation: a pass over the AST after parsing. Emits warnings to stderr
with source locations. `pp lint file.pp` exits 0 if clean, 1 if warnings.

### 5.2 — `pp fmt` integration

Ensure all new Phase 1–3 syntax round-trips through the brace printer with
identical LAW-20 hashes. This is the M7 S2 gate: `to-braces | to-sexpr` gives
identical expanded-form hash.

### 5.3 — Migration of existing code

Mechanical rewrite of:
- `stdlib/*.pp`
- `build.pp`
- All `tests/*.pp`
- `examples/*.pp`
- Manual chapter examples

Using `pp fmt` where possible; hand-edit where formatter doesn't support new
syntax yet. Run `dune runtest` after each batch.

### 5.4 — Documentation

- Integrate `CONVENTIONS.md` into the manual (appendix)
- Add `PATTERNS.md` as a design document
- Rewrite manual language reference to use new syntax
- Add "Migration from sexpr" section
- Update `AGENTS.md` with style checklist

### Phase 5 exit criteria

- `pp lint` catches all convention violations in the existing codebase
- Every `.pp` file in the tree uses the new surface syntax
- `dune runtest` green
- `build-self.sh` null-rebuild with 0 recomputes (store populated pre-migration)
- `build-lua.sh` null-rebuild with 0 recomputes
- Manual rebuilds with every example executing

---

## Dev loop & quality gates

Every phase, no matter how small, must pass these gates before it is
considered done:

1. **Differential test:** both backends produce the same result and the same
   error text for every new form.
2. **Round-trip test:** `pp fmt --to-braces | pp fmt --to-sexpr` yields the
   same LAW-20 hash as the original for generated and hand-written examples.
3. **Fuzzer extension:** the fuzzer can generate the new surface forms, and
   round-trip/hash invariants hold.
4. **`dune runtest` green** with no regressions in existing tests.
5. **Manual examples:** at least one executed example in the manual uses the
   new form.

No phase merges until all five gates pass.

---

## Summary

| Phase | Name | Backends touched |
|-------|------|-----------------|
| 0 | Conventions | None |
| 1 | Basic sugars | Reader only (except call-spread `apply`) |
| 1b | Error sugars | Reader only |
| 2 | Pattern surface | Reader only |
| 3 | AST additions | Both |
| 4 | VM deep support | Both (stretch) |
| 5 | Tooling & migration | Reader + tests |

Phases 0–2 can ship independently — they're reader-only, zero LAW-20 impact,
zero VM changes. Phase 3 requires both backend work but is self-contained
(`match`). Phase 4 is stretch. Phase 5 is mechanical.

### Minimal viable ship

Phases 0–2: conventions + all reader sugars + error handling. Everything the
user types is different, but the AST, evaluator, compiler, and VM are untouched.
The store cannot tell anything changed. This is the M7-compatible path.
