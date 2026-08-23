# pp syntax: the settled surface

pp's brace surface, definitive: one form per concept, every sigil exactly
one meaning. Supersedes `PRAGMATIC-SYNTAX.md`, `PATTERNS.md`, and
`CONVENTIONS.md`; [DESIGN.md](DESIGN.md) records the rejected alternatives.
Implemented; the stable source contract.

---

## Sigils

The table below is closed. New syntax must reuse these meanings; it must
never overload them.

| Sigil | Meaning | Where |
|-------|---------|-------|
| `$`   | observes the world | `$file(...)`, `$env(...)`, `$glob(...)`, `$probe(...)`, `$secret(...)`, `$config(...)` |
| `!`   | performs an effect (suffix) | `run!`, `write!`, `log!`; uniformly, no exceptions |
| `?`   | returns a bool (name suffix only) | `nil?`, `open?`; never a postfix operator |
| `->`  | "key has value" in data; type conversion in names | map literals `{k -> v}`, `reconcile {}` bodies; `string->number` |
| `=>`  | "pattern yields" | `match` arms |
| `<-`  | "unwrap `[:ok, v]` or propagate `[:err, e]`" | inside `try {}` only |
| `\|>` | data flows left to right | pipelines: this is pp's method syntax |
| `...` | spread | list literals, call arguments, map update/merge |
| `:`   | grammar, never data (see below) | keywords `:foo`, type annotations `x: ty`, closed clause headers |

### Grammar, not data: the colon rule

A `:` key is special-form clause grammar only — the reader consumes it
against a closed keyword set and lowers to something that is not a map:
`with { caps:, config:, handlers: }`, annotations `x: ty`, `fenced`'s
`:kind` slot. Braces that survive to runtime as a map value use `->`.

The test is mechanical: if the lowering emits `hash-map`/`map-insert`, the
surface is `->`. So `register-domain` takes an ordinary `->` map, as
`stdlib/domain-fs.pp` already writes it, and a `fenced` body is an ordinary
`->` map; only `fenced`'s `:kind` slot is grammar.

### Arrow Pattern

`->` glued to a preceding name character extends the name:
`string->number` is one identifier. `->` with whitespace on both sides is
the map arrow. Normative; also in SPEC.md's brace-surface token table.

---

## Data

```pp
[1, 2, 3]                 # list: the default collection (cons-cells)
[head, ...tail]           # spread: cons(head, tail)
vec[1, 2, 3]              # vector: random access
{ :a -> 1, "k" -> 2 }     # map; keys are arbitrary expressions
{ ...m, :key -> value }   # update: insert/overwrite into a copy of m
{ ...defaults, ...overrides }   # merge (rightmost wins)
m[:key]                   # map access;  v[0] for vector access
:foo                      # keyword: self-evaluating symbol
```

- `[...]` builds a list, pp's default collection (cons-cells) — a revision
  from the original vector default; it changed value hashes, recorded in
  SPEC.md.
- Spread is one concept used in three places: list construction, call
  arguments (`run!("cc", ...flags, "-o", out)`), and map update or merge.
  There is no separate `{m | k -> v}` form.
- In postfix position, immediately after an expression, `[` always means
  index. To call a function with a list literal, use parens: `f([a, b])`.

### Tagged values: the checked convention

A fallible result is a two-element list whose head is a keyword:

```pp
[:ok, value]
[:err, message]
```

Checked convention: `match` special-cases tagged patterns, `try {}` is
defined over this shape, `collect` consumes it, and `pp lint` flags
functions returning `[:err, _]` on one branch and a bare value on another.
No ADT declaration syntax: pp is dynamically typed; the tag convention plus
`match` is the whole mechanism. Destructure with `match` or `<-`, never
`car`/`cdr`.

---

## Observations: the `$` family

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

Facts, not decoration:
- Arguments are arbitrary expressions:
  `$file(string-append(root, "/greeting.txt"))` is legal. A family that
  cannot spell computed paths cannot be the exclusive observation surface.
- `$` is the only way to read the world in user code. The underlying
  primitives (`slurp`, `env-get`, `list-dir`, `probe`, `config`) still
  exist (`$` lowers to them), but `pp lint` warns on bare primitive reads
  outside the stdlib, so `grep '\$[a-z]'` over a program gives a complete
  audit of its world-surface.
- `$secret` returns a sealed value. `unseal(v)` is the one sanctioned,
  greppable escape. The node-boundary bans (no capabilities or sealed
  values in free vars or results) apply unchanged.
- The family extends by new heads only; pp never adds a second notation.
  The removed cell-literal tokens (`file:"P"` etc.) are recorded in SPEC.md's
  lowering table; `pp fmt` rewrites old code hash-preservingly. Heads are
  closed, instances open (DESIGN.md): trace verification must know how to
  re-observe each kind, so a user-injected head would put user code inside
  cache soundness. User extension goes one level up: `register-probe`/
  `register-domain` mint new observations read through `$probe(...)`. The
  head set is one typed table over `Cell.t` (`surface_tables`); readers,
  quasiquote grammar, lint, fuzzer, and the SPEC appendix derive from it.

`reads` clauses on nodes use the same forms, as declared intent:

```pp
node version() reads $env("CC"), $file("src/version.txt") { ... }
```

`reads` is documentation plus a `pp check` target: it warns when declared
and actual trace diverge, but never skips trace verification.

---

## Effects: always `!`-suffixed

Effects change the world: always explicit, always `!`-suffixed, and
always `perform` underneath.

```pp
run!("cc", "-c", src, "-o", obj)
run-closed!({
  :tool -> compiler,
  :tool-path -> "bin/cc",
  :args -> ["-c", "/in/main.c", "-o", "main.o"],
  :inputs -> sources,
  :env -> {},
  :platform -> {"os" -> "linux"},
  :policy -> {:redundancy -> 3},
  :outputs -> ["main.o"]
})
write!(path, content)
log!(f"building {src}")
```

`!` means "performs an effect": exactly that, never "uncached" or
"scripting-tier". The convention survives only if it applies without
exception; pure functions carry no suffix.

Ambient `run` is scripting-tier only. `run-closed!` may execute inside a node
only when the installed trusted executor classifies that exact immutable
request as cacheable. The bundled Linux executor classifies its requests as
scripting-only because some semantic inputs remain ambient. Provider-specific
execution policy is optional canonical data in `:policy`, usually constructed
by a library or macro; it adds no syntax.

## Runtime libraries

Runtime policy is ordinary pp data. Load `stdlib/runtime.pp` and configure the
current script before evaluating nodes:

```pp
load("stdlib/runtime.pp")
configure-runtime({
  :schedule -> schedule-parallel(4),
  :build-policy -> build-policy({:toolchain -> "clang"}),
  :execution-policy -> execution-policy({:network -> false}),
  :reporter -> reporter-console
})
```

For a custom result-transparent scheduler, provide a pp function over job
descriptors. It returns a mode and a complete partition of job indexes:

```pp
def schedule-policy(jobs) {
  {:mode -> :parallel, :width -> 4,
   :batches -> vec[vec[0], vec[1], vec[2]]}
}
configure-runtime({:schedule -> schedule-custom(schedule-policy)})
```

The runtime rejects missing, duplicate, or out-of-range indexes. The policy
cannot execute a job, inspect its thunk, or mint authority.

The schedule selects where node misses are dispatched; it cannot change node
results or keys. A reporter receives an immutable vector of runtime events
after the program completes. Build and execution policies are canonical data
interpreted by the selected library or executor provider. Unknown manifest
fields, non-canonical policies, remote schedules without host configuration,
and runtime configuration from inside a persistent node are errors.

---

## Nodes and authority

A node is the cacheable computation, where identity (the LAW 20 key) and
validity (traces) attach. It is a keyword: never inferred, never granted
by an attribute.

```pp
node source-digest(src) needs fs.read("src/") {
  hash-string($file(src))
}
```

- `needs` declares capability grants; it lowers to real
  `cap-restrict`/`cap-compose` calls. Grant descriptors (`fs.read("p")`,
  `fs.write("p")`, `fs.rw("p")`, `process`, `net("host")`) are grant grammar:
  fixed names existing only inside `needs`, not a dotted-name facility.
- `needs` is value-open. Descriptors are sugar; any expression evaluating
  to a capability is a legal grant item, so teams can name and compose
  their own grants as ordinary bindings:

  ```pp
  let k8s-prod = cap-compose(net("k8s.prod.internal"), process)

  node deploy(manifest) needs k8s-prod, fs.read("manifests/") { ... }
  ```

  Capability kinds stay closed (capabilities are unforgeable authority, not
  ordering — DESIGN.md); the vocabulary of grants stays open at the value
  level. Named grants are the idiom for anything beyond a one-off path grant.
- Node arguments are forced call-by-value (LAW 6); the last expression is
  the result, with no `return`.
- Call sites are unmarked: node and function application have identical
  semantics, and marking them would tax every `def`-to-`node` refactor. The
  audit surface is the definition-site keyword plus `pp why`.

---

## Desired state

The program's root value is a desired-state map, an ordinary pp map.
`reconcile {}` is identity sugar over the map literal (SPEC.md): no AST, no
semantics; the desired-state arrow is the map arrow:

```pp
reconcile {
  "build/app" -> app()
  "build/lib.a" -> archive(objs)
}
```

Multi-domain roots are maps of maps, ordinary data:

```pp
reconcile {
  :fs   -> { "out/app" -> link(objs) }
  :proc -> { "web" -> { :cmd -> "./out/app", :port -> 8080 } }
}
```

`register-domain` takes an ordinary `->` map (see "grammar, not data",
above):

```pp
register-domain({
  :name -> "my-fs",
  :observe -> fn() { tree-observe!("/srv/www") },
  :diff -> fn(observed, desired) { fs-diff(observed, desired) },
  :apply -> fn(plan) { fs-apply!(plan) }
})
```

---

## Dynamic extent: the unified `with`

Capabilities, config, and handlers are three instances of one mechanism:
save, set, run, restore. One binder serves all three. Each key takes a
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

`caps:` / `config:` / `handlers:` are clause grammar, a closed set (see
"grammar, not data", above). Lowering nests in canonical order: caps
outermost, then config, then handlers. A single-purpose block is the same
form with one clause. The handler stack restores on every exit: normal
return, error, or tail call (LAW 27).

Config reads inside the extent use `$config(key, default)` and record
`config:` trace cells like every other observation.

---

## Errors: the five tiers

| Situation | Mechanism | Cached? |
|-----------|-----------|---------|
| Pure function that can fail | `[:ok, v]` / `[:err, e]` + `try`/`<-` | yes |
| Script should bail out | `perform error(msg)` + handler | no |
| Build: see all errors | `collect` | yes |
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

`<-` is do-notation for the Result shape, deliberately not generalised:
`<-` always means exactly the tagged-list protocol above, and other
effect shapes don't use `try`.
Bindings are sequential; rebinding a name shadows it, like `let*`. This is
a documented exception to the rule against duplicate definitions in one
block (LAW 4), and it is pinned by a behavior test.

### `collect`: accumulation, not short-circuit

`collect` is a function, used in pipelines:

```pp
let results = map(compile, srcs) |> collect
# [:ok, [obj1, obj2, ...]]  if every element was [:ok, _]
# [:err, [e1, e2, ...]]     if any element was [:err, _]
```

`try` short-circuits at the first error (monadic); `collect` runs
everything and accumulates (applicative, or validation-style). Builds want
`collect`; scripts usually want `try`, hence no `collect {}` block form.

---

## Pattern matching with `match`

`match` is the one pattern-dispatch mechanism, with no function clauses
and no `cond`:

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

Patterns can be literals (`42`, `"s"`, `true`, `nil`), variables that bind,
the wildcard `_`, lists with spread, tagged values, and guards (`pat if
cond => expr`). The first match wins; no match is a runtime error. For a
multi-way conditional with no destructuring, use a flat `if`/`else if`
chain, or `match` on the scrutinised value with guards. Map patterns may
be added later as a new pattern kind; they will not add a new form.

The engine must agree on every pattern kind, and this is exercised by the
fuzzer. The lowering uses unshadowable internal primitives, so user code
shadowing `car` or `=` cannot change match semantics.

---

## Strings

Interpolation requires the `f` prefix, glued to the quote:

```pp
f"Hello, {name}! Value: {x + 1}."
```

Holes take arbitrary expressions and lower through the generic
`->string`. Ordinary strings never interpolate: `"{x}"` is three literal
characters, so JSON fragments, shell snippets, and generated code are
safe.

---

## Functions, bindings and conditionals

```pp
def compile(src, flags = []) { ... }     # default args
def link(main, ...objs) { ... }          # rest args
fn(x, y) { x + y }                       # anonymous

let x = 1                                # value binding
let (a = 1, b = f(a)) { ... }            # one flat let (letrec; LAW 4)
let* (x = 1, x = x + 1) { ... }          # sequential, for shadowing

if x > 0 { "pos" } else if x < 0 { "neg" } else { "zero" }
```

- `else` may follow the closing brace on the same line or on the next
  line; both parse. `pp fmt` normalises to `} else {`.
- Only `nil` and `false` are falsy. Write `if found`, not
  `if not(nil?(found))`.
- pp has no loops. Recursion with tail calls (LAW 10) and the list
  functions `map`, `filter` and `foldl` are the iteration story, with no
  comprehensions. Those take the function first (`map(f, list)`), so they
  are called directly, not piped into.
- There is no dot-method call. `x |> f(args)` is the method syntax:
  `x` becomes f's FIRST argument, so `|>` chains a value through functions
  written receiver-first (`|> collect`, `src |> replace-ext(".o")`). An
  identifier may not contain `.` outside grant descriptors; this is
  linted.

---

## Fenced actions

Non-convergent effects, such as email or payment, sit behind a fence,
sequenced by the reconciler's intent journal; nodes are barred from using
them:

```pp
fenced :email {
  :to -> "user@example.com",
  :subject -> "Build complete",
  :body -> f"All {count} targets built."
}
```

`:email` is the kind slot (grammar); the body is an ordinary `->` map.

---

## Macros and quasiquote

```pp
defmacro unless(test, body) {
  quasiquote {
    if not(unquote(test)) { unquote(body) }
  }
}
```

Hygiene is manual, using `gensym()`; templates are surface syntax. The
normative rule: every surface form parses identically inside
`quasiquote {}` (same lowering, same collection defaults) or is
explicitly listed as an exclusion in SPEC.md's quasiquote section. CI
enforces this: any new reader form must ship
with its quasiquote counterpart, or an entry in that exclusion list, and
the fuzzer round-trips generated forms through `quasiquote { unquote(...) }`.

---

## Modules and islands

`load("path.pp")` and content-pinned islands
(`island("github:owner/repo#ref", "<hash>")`) are unchanged by this
settlement. The inline pin is part of the code hash (LAW 20); no pin is a
hard error. A `module`/`export` grouping form remains future work, not part of the
settled surface.

---

## Writing style

- Suffixes: `?` for a predicate, `!` for an effect, `->` for a conversion,
  and bare for pure: if you wouldn't cache it, it gets `!`. Don't use
  `is-` prefixes, and don't double up with `is-?`.
- Naming: lead functions with a verb that names the result
  (`longest-palindrome`, not `expand-around-centre`); use full-word values
  (`max-len`, not `ml`); name inner helpers after the step they do
  (`scan`, not `loop`).
- Use one flat `let`. pp's `let` is letrec, so bindings see each other;
  don't build ladders. Use `let*` only for genuine shadowing.
- Use flat `else if` chains; never nest the second `if` inside braces.
- Pick one style per file for `car`/`cdr` versus `first`/`rest`.
- Comments should say why, not what. A library file opens with a header
  listing every export.
- Produce and consume `[:ok, v]`/`[:err, e]` through `try`, `match`, or
  `collect`, never `car` a result.

---

## A full example

```pp
node source-digest(src) needs fs.read("src/") {
  hash-string($file(src))
}

reconcile {
  "main.digest" -> source-digest("src/main.c")
}
```

Read any line and you know what it does: `$` observes, `!` acts, `needs`
grants, `<-` propagates, `collect` accumulates, `->` declares data, `|>`
flows. That property, the whole program auditable by sigil, is the
design.
