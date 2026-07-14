# pp SYNTAX — the settled surface

The definitive design for pp's brace surface: one form per concept, every
sigil with exactly one meaning. This document supersedes the earlier
`PRAGMATIC-SYNTAX.md`, `PATTERNS.md`, and `CONVENTIONS.md` (consolidated
2026-07-14 after a two-round pragmatist-vs-theorist design review; the
rejected alternatives are recorded in [DESIGN.md](DESIGN.md) §6, with the
reason each was rejected, so they stay dead).

Implementation status is tracked in [MASTER-PLAN.md](MASTER-PLAN.md), which
is ref-pinned. This document describes the *target* surface; where a form is
not yet implemented (or is implemented differently on the current branch),
the plan says so — this document does not.

---

## 1. The one rule

**Every form reads like what it does, and every sigil means exactly one
thing.** pp's domain model — observations of the world, pure cacheable
nodes, capability-gated effects, a desired-state value — must be visible at
every call site. Syntax that duplicates an existing mechanism, or that looks
load-bearing without being load-bearing, is rejected regardless of how nice
it reads in isolation.

The sigil table. This is closed: new syntax must reuse these meanings, never
overload them.

| Sigil | Meaning | Where |
|-------|---------|-------|
| `$`   | observes the world | `$file(...)`, `$env(...)`, `$glob(...)`, `$probe(...)`, `$secret(...)`, `$config(...)` |
| `!`   | performs an effect (suffix) | `run!`, `write!`, `log!` — uniformly, no exceptions |
| `?`   | returns a bool (name suffix only) | `nil?`, `open?` — never a postfix operator |
| `->`  | "key has value" in data; type conversion in names | map literals `{k -> v}`, `reconcile {}` bodies; `string->number` |
| `=>`  | "pattern yields" | `match` arms |
| `<-`  | "unwrap `[:ok, v]` or propagate `[:err, e]`" | inside `try {}` only |
| `\|>` | data flows left to right | pipelines — this is pp's method syntax |
| `...` | spread | list literals, call arguments, map update/merge |
| `:`   | grammar, never data (see §2) | keywords `:foo`, type annotations `x: ty`, closed clause headers |

### The `:` rule — grammar vs. data

`:` keys are **special-form clause grammar only**: positions where the
reader itself consumes the key against a closed, fixed keyword set and
lowers to something that is not a map (`with { caps:, config:, handlers: }`;
type annotations `x: ty`; the kind slot in `fenced :email`). Any braces that
survive to runtime as a first-class map value spell `->`.

The test is mechanical: **if the lowering emits `hash-map`/`map-insert`, the
surface is `->`.** Consequently `register-domain` takes an ordinary `->` map
(as `stdlib/domain-fs.pp` already writes it), and a `fenced` body is an
ordinary `->` map; only `fenced`'s `:kind` slot is grammar.

### The `->` glue rule

`->` glued to a preceding name character extends the name
(`string->number` is one identifier); `->` with whitespace on both sides is
the map arrow. This rule is normative in SPEC Appendix B.1.

---

## 2. Data

```pp
[1, 2, 3]                 # list — the default collection (cons-cells)
[head, ...tail]           # spread: cons(head, tail)
vec[1, 2, 3]              # vector — random access
{ :a -> 1, "k" -> 2 }     # map; keys are arbitrary expressions
{ ...m, :key -> value }   # update: insert/overwrite into a copy of m
{ ...defaults, ...overrides }   # merge (rightmost wins)
m[:key]                   # map access;  v[0] — vector access
:foo                      # keyword — self-evaluating symbol
```

- `[...]` builds a **list**. (SPEC L9 revised from the original vector
  lowering — an acknowledged, hash-affecting change; see MASTER-PLAN.)
- Spread is one concept in three places: list construction, call arguments
  (`run!("cc", ...flags, "-o", out)`), and map update/merge. There is no
  separate `{m | k -> v}` form.
- In postfix position (immediately after an expression), `[` always means
  index. To call a function with a list literal, use parens: `f([a, b])`.

### Tagged values — the checked convention

A fallible result is a two-element list whose head is a keyword:

```pp
[:ok, value]
[:err, message]
```

This is a *checked* convention, not just a habit: `match` special-cases
tagged patterns, `try {}` is defined over exactly this shape, `collect`
consumes it, and `pp lint` flags functions that return `[:err, _]` on one
branch and a bare value on another. There is deliberately **no ADT
declaration syntax** — pp is dynamically typed; the tag convention plus
`match` is the whole mechanism. Destructure results with `match` or `<-`,
never with `car`/`cdr`.

---

## 3. Observations: the `$` family

Every read of the outside world goes through one visual family. Each form
records its trace cell and returns the observed value.

```pp
$file("src/main.c")          # file content        → cell file:<canonical-path>
$env("CC")                   # env var (nil if unset) → cell env:CC
$env("CC", "gcc")            # with default
$glob("src/*.c")             # matching paths      → cell tree:/glob manifest
$probe("clock")              # volatile observation → cell probe:clock
$secret("/run/secrets/key")  # sealed read          → cell sealed:<path>
$config("cc", "gcc")         # scoped config read   → cell config:cc
```

Rules that make the family real rather than decorative:

- **Arguments are arbitrary expressions**, not just string literals:
  `$file(string-append(root, "/greeting.txt"))` is legal. A family that
  cannot spell computed paths cannot be the exclusive observation surface.
- **`$` is the only way to read the world in user code.** The underlying
  primitives (`slurp`, `env-get`, `list-dir`, `probe`, `config`) still exist
  — `$` lowers to them — but `pp lint` warns on bare primitive reads outside
  the stdlib. The payoff: `grep '\$[a-z]'` over a program is a complete
  audit of its world-surface.
- **`$secret` returns a sealed value.** `unseal(v)` is the one sanctioned,
  greppable escape. The node-boundary bans (no capabilities or sealed values
  in free vars or results) apply unchanged.
- The family is **extensible by new heads only** — a future observation kind
  joins as `$kind(...)`; a second notation is never added. The older
  `file:"P"` / `env:"N"` / `tree:"R"` cell-literal tokens are removed from
  the language (SPEC L47–L49 amended); `pp fmt` rewrites them, which is
  hash-preserving because both notations lower to the same AST.
- **Closed heads, open instances** (DESIGN.md §1 principle 7). The heads
  are closed because trace verification must know how to *re-observe* each
  cell kind — a user-injected head would put user code inside the cache
  soundness argument. User-level extension goes one level up:
  `register-probe`/`register-domain` mint new observations with free-form
  names, read through `$probe(...)` like any other cell. The head set is
  defined once, as a typed table over the runtime's `Cell.t` variant
  (`surface_tables`, MASTER-PLAN A′1); the readers, quasiquote grammar,
  lint, fuzzer, and the SPEC appendix all derive from that table.

`reads` clauses on nodes use the same forms, as declared intent:

```pp
node version() reads $env("CC"), $file("src/version.txt") { ... }
```

`reads` is documentation plus a `pp check` target (warn when declared and
actual trace diverge). It never skips trace verification.

---

## 4. Effects: `!`-suffixed, uniformly

Effects change the world; they are always explicit, always `!`-suffixed,
always `perform` underneath.

```pp
run!("cc", "-c", src, "-o", obj)
run-dep!("cc", "-MD", ...)         # depfile-refined tracing
write!(path, content)
log!(f"building {src}")
```

`!` means "performs an effect" — exactly that, never "uncached" or
"scripting-tier." The convention survives only if it is exceptionless, so
every effect wrapper in stdlib and the manual carries it (`run-dep!`, not
`run-dep!`). Pure functions are suffix-free; `?` marks predicates; `->` in a
name marks a conversion (`->string` is the generic one).

---

## 5. Nodes and authority

A node is the cacheable computation — where identity (LAW 20 key) and
validity (traces) attach. It is a keyword, never inferred, never granted by
an attribute, and it is the *only* spelling of node-ness.

```pp
node compile(src) needs fs.read("src/"), process {
  let obj = scratch(src |> replace-ext(".o"))
  run!("cc", "-c", src, "-o", obj)
  obj
}
```

- `needs` declares capability grants; it lowers to real
  `cap-restrict`/`cap-compose` calls. Grant descriptors (`fs.read("p")`,
  `fs.write("p")`, `fs.rw("p")`, `process`, `net("host")`) are grant
  grammar — the dotted heads are fixed descriptor names that exist only
  inside `needs`, not a general dotted-name or method facility.
- **`needs` is value-open.** Descriptors are sugar; any expression
  evaluating to a capability is a legal grant item, so teams name and
  compose their own grants as ordinary bindings:

  ```pp
  let k8s-prod = cap-compose(net("k8s.prod.internal"), process)

  node deploy(manifest) needs k8s-prod, fs.read("manifests/") { ... }
  ```

  Capability *kinds* stay closed (unforgeability — DESIGN.md §1 principles
  3 and 7); the *vocabulary* is open at the value level. Named grants are
  the intended idiom for anything beyond a one-off path grant.
- Node arguments are forced call-by-value (LAW 6); the last expression is
  the result; no `return`.
- Call sites are deliberately unmarked: node application and function
  application have identical semantics at the call site, and marking them
  would tax every `def`→`node` refactor. The audit surface for "what is
  cached and why" is the definition-site keyword plus `pp why`.

---

## 6. Desired state

The program's root value is a desired-state map — an *ordinary* pp map
(SPEC L61: `reconcile {}` is identity sugar over the map literal; it adds no
AST and no semantics). That is why the desired-state arrow **is** the map
arrow:

```pp
reconcile {
  "build/app" -> app()
  "build/lib.a" -> archive(objs)
}
```

Multi-domain roots are maps of maps, still ordinary data:

```pp
reconcile {
  :fs   -> { "out/app" -> link(objs) }
  :proc -> { "web" -> { :cmd -> "./out/app", :port -> 8080 } }
}
```

`register-domain` takes an ordinary `->` map (see §1's `:` rule):

```pp
register-domain({
  :name -> "my-fs",
  :observe -> fn() { tree-observe!("/srv/www") },
  :diff -> fn(observed, desired) { fs-diff(observed, desired) },
  :apply -> fn(plan) { fs-apply!(plan) }
})
```

---

## 7. Dynamic extent: the unified `with`

Capabilities, config, and handlers are three instances of one mechanism
(save/set/run/restore). One binder serves all three; each key takes a
first-class value, so caps, config maps, and handler maps can be built,
composed, and passed around like any other value.

```pp
with {
  caps: narrow-cap,
  config: { :cc -> "clang", :cflags -> ["-O2", "-Wall"] },
  handlers: { :log -> fn(msg) { print(msg) },
              :read-file -> mock-read }
} {
  body
}
```

`caps:` / `config:` / `handlers:` are clause grammar (closed set, `:` rule).
Lowering nests in canonical order: caps outermost, then config, then
handlers. Single-purpose blocks are the same form with one clause. The
handler stack restores on every exit — normal return, error, tail call
(LAW 27).

Config reads inside the extent use `$config(key, default)` and record
`config:` trace cells like every other observation.

---

## 8. Errors — the five tiers

| Situation | Mechanism | Cached? |
|-----------|-----------|---------|
| Pure function that can fail | `[:ok, v]` / `[:err, e]` + `try`/`<-` | yes |
| Script should bail out | `perform error(msg)` + handler | no |
| Build — see *all* errors | `collect` | yes |
| Node crashed | failure trace (LAW 28), automatic | yes |
| Authority denied | capability error | no |

### `try {}` and `<-`

```pp
def compute(x, y) {
  try {
    a <- divide(x, y)      # [:ok, v] binds v; [:err, e] exits the try with it
    b <- divide(a, 2)
    [:ok, a + b]
  }
}
```

`<-` is do-notation for the Result shape — that isomorphism is worth knowing
and is deliberately **not** generalized: `<-` always means exactly the
tagged-list protocol above, and other effect shapes don't use `try`.
Bindings are sequential; rebinding a name shadows (like `let*`), a
documented exception to LAW 4's duplicate-definition check, pinned by a
differential test. There is no postfix `?` operator — `?` belongs to
predicate names.

### `collect` — accumulation, not short-circuit

`collect` is a *function*, used in pipelines:

```pp
let results = srcs |> map(compile) |> collect
# [:ok, [obj1, obj2, ...]]  if every element was [:ok, _]
# [:err, [e1, e2, ...]]     if any element was [:err, _]
```

`try` short-circuits at the first error (monadic); `collect` runs everything
and accumulates (applicative/validation). Builds want `collect`; scripts
usually want `try`. The distinction is the point — there is no `collect {}`
block form.

---

## 9. `match`

The one pattern-dispatch mechanism (there are no function clauses and no
`cond`):

```pp
match result {
  [:ok, v]          => process(v)
  [:err, e] if hard?(e) => perform error(e)
  [:err, e]         => log!(f"soft failure: {e}")
  [x, ...rest]      => recurse(x, rest)
  []                => default
  _                 => fallback
}
```

Patterns: literals (`42`, `"s"`, `true`, `nil`), variables (bind),
wildcard `_`, lists with spread, tagged values, and **guards**
(`pat if cond => expr`). First match wins; no match is a runtime error.
Multi-way conditionals with no destructuring are either flat
`if/else if` chains or `match` on the scrutinized value with guards.
Map patterns may be added later as a new pattern kind; they do not add a
new form.

Both backends must agree on every pattern kind (differential-tested), and
the compiler's lowering must use unshadowable internal primitives — user
code shadowing `car` or `=` cannot change match semantics.

---

## 10. Strings

Interpolation requires the `f` prefix, glued to the quote:

```pp
f"Hello, {name}! Value: {x + 1}."
```

Holes take arbitrary expressions and lower through the generic `->string`.
Ordinary strings never interpolate — `"{x}"` is three literal characters,
so JSON fragments, shell snippets, and generated code are safe by default.

---

## 11. Functions, bindings, conditionals

```pp
def compile(src, flags = []) { ... }     # default args
def link(main, ...objs) { ... }          # rest args
fn(x, y) { x + y }                       # anonymous

let x = 1                                # value binding
let (a = 1, b = f(a)) { ... }            # one flat let (letrec; LAW 4)
let* (x = 1, x = x + 1) { ... }          # sequential, for shadowing

if x > 0 { "pos" } else if x < 0 { "neg" } else { "zero" }
```

- `else` may follow the closing brace on the same line **or on the next
  line** — both parse; `pp fmt` normalizes to `} else {`.
- Truthiness: only `nil` and `false` are falsy. Write `if found`, not
  `if not(nil?(found))`.
- No loops: recursion + tail calls (LAW 10) and pipelines
  (`|> map/filter/foldl`) are the iteration story. There are no
  comprehensions.
- There is **no dot-method call**. `x |> f(args)` is the method syntax.
  (An identifier may not contain `.` outside grant descriptors — linted,
  since the lexer would otherwise accept `src.replace-ext` as one name.)

---

## 12. Fenced actions

Non-convergent effects (email, payment) sit behind a fence, sequenced by the
reconciler's intent journal, barred from nodes:

```pp
fenced :email {
  :to -> "user@example.com",
  :subject -> "Build complete",
  :body -> f"All {count} targets built."
}
```

`:email` is the kind slot (grammar); the body is an ordinary `->` map.

---

## 13. Macros and quasiquote

```pp
defmacro unless(test, body) {
  quasiquote {
    if not(unquote(test)) { unquote(body) }
  }
}
```

Hygiene is manual (`gensym()`); templates are surface syntax. **Normative
rule:** every surface form parses identically inside `quasiquote {}` —
same lowering, same collection defaults — or is explicitly listed as a
quasiquote exclusion in SPEC Appendix B.7. A macro template must never
build a different value than the same text outside a template. CI enforces
this: any new reader form must ship with its quasiquote counterpart or a
B.7 entry, and the fuzzer round-trips generated forms through
`quasiquote { unquote(...) }`.

---

## 14. Modules and islands (unchanged)

`load("path.pp")` and content-pinned islands
(`island("github:owner/repo#ref", "<hash>")`) are unchanged by this
settlement. The inline pin is part of the code hash (LAW 20); no pin is a
hard error. A `module`/`export` grouping form remains future work and is
deliberately **not** part of the settled surface.

---

## 15. Style

- **Suffixes:** `?` predicate, `!` effect, `->` conversion, bare = pure.
  One-liner: *if you wouldn't cache it, it gets `!`*. No `is-` prefixes,
  no `is-?` doubling.
- **Naming:** verb-led functions that name the result
  (`longest-palindrome`, not `expand-around-centre`); full-word values
  (`max-len`, not `ml`); inner helpers name the step (`scan`, not `loop`).
- **One flat `let`** — pp's `let` is letrec, so bindings see each other;
  don't build ladders. `let*` only for genuine shadowing.
- **Flat `else if` chains**; never nest the second `if` in braces.
- **`car`/`cdr` vs `first`/`rest`:** pick one style per file.
- **Comments:** why, not what. Library files open with a header listing
  every export.
- **Results:** produce and consume `[:ok, v]`/`[:err, e]` through
  `try`/`match`/`collect` — never `car` a result.

---

## 16. The showcase

```pp
node compile(src) needs fs.read("src/"), process {
  let obj = scratch(src |> replace-ext(".o"))
  run!("cc", ...($config("cflags", [])), "-c", src, "-o", obj)
  obj
}

node link(objs) needs process {
  let app = scratch("app")
  run!("cc", "-o", app, ...objs)
  app
}

node build() reads $glob("src/*.c") {
  try {
    objs <- $glob("src/*.c") |> map(compile) |> collect
    [:ok, link(objs)]
  }
}

with { config: { :cc -> "clang", :cflags -> ["-O2", "-Wall"] } } {
  reconcile {
    "build/app" -> build()
  }
}
```

Read any line and you know what it does: `$` observes, `!` acts, `needs`
grants, `<-` propagates, `collect` accumulates, `->` declares data,
`|>` flows. That property — the whole program auditable by sigil — is the
design.
