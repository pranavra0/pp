# The pp Surface — a complete syntax design

This is a syntax for pp designed from the domain model outward. Every concept
pp's runtime knows about gets a surface form that makes it feel inevitable.
Reader-level sugars lower to the existing `Types.expr` AST unless explicitly
noted.

See also: [CONVENTIONS.md](CONVENTIONS.md) for naming/style,
[PATTERNS.md](PATTERNS.md) for the codebase analysis that grounds these choices,
and [MASTER-PLAN.md](MASTER-PLAN.md) for the phased implementation roadmap.

## 1. First, the domain model in one sentence

pp computes a **desired state** (a map of paths to content, or service specs
to config) from **observations of the world** (files, globs, env vars, probes),
using **pure nodes** that may **perform effects** under explicitly-declared
**capabilities**, with **caching by content hash** at every node boundary.

That sentence names the surface forms we need:

| Concept | Surface form |
|---------|-------------|
| Node | `node` |
| Observation | `$file(...)`, `$glob(...)`, `$env(...)`, `$probe(...)`, `$secret(...)` |
| Effect | `run!`, `write!`, `log!` |
| Capability | `needs` clause |
| Desired state | `reconcile { ... }` |
| Domain | `register-domain { ... }` |
| Fenced action | `fenced { ... }` |

Everything else — functions, data, conditionals, modules — is the general-purpose
language carrying these concepts.

## 2. Nodes: the central abstraction

A node is where caching happens. Its syntax makes three things visible:
what it depends on, what authority it needs, and what it produces.

```pp
node compile(src) needs fs.read("src/"), process {
  let obj = scratch(src.replace-ext(".o"))
  run!("cc", "-c", src, "-o", obj)
  obj
}
```

### `needs` clause

Declares capabilities the node requires. Checked at node creation against the
ambient capability set and captured in the node's closure. The node body runs
with exactly the declared capabilities — nothing more.

```pp
needs fs.read("src/")          # read-only filesystem grant
needs fs.write("out/")         # write access (scratch only inside nodes)
needs process                  # run external tools
needs net("api.example.com")   # network access
needs net("*")                 # any network
needs secret("/run/secrets/key")  # confidential read
```

Multiple grants compose with commas:

```pp
needs fs.read("src/"), fs.read("include/"), process
```

Lowers to `with-caps(cap-compose(...), current-capabilities()) { ... }`.

### `reads` clause (documentation and static check only)

`reads` declares the world-cells a node *intends* to observe. It is **not** used
to skip trace verification — a node's cache validity is determined by its
recorded trace, not by declarations. Instead, `reads` is:

- documentation for the programmer;
- a target for `pp check` / `pp why` to warn when the declared set diverges from
the actual runtime trace.

```pp
node version() reads $env("CC"), $file("src/version.txt") {
  let v = $file("src/version.txt") |> slurp |> trim
  let cc = $env("CC", "cc")
  "{cc} {v}"
}
```

Cell forms in `reads`:

```pp
$file("path")           # a single file's content
$glob("src/*.c")        # a directory listing
$env("CC")              # an environment variable
$env("CC", "gcc")       # with default
$probe("clock")         # a volatile observation
$stat("path")           # file existence/type
```

### Node arguments are always forced

`node link(objs)` — `objs` is fully forced before `link`'s body runs. This is
LAW 6 (call-by-value). The node's key includes the hashes of its argument
values.

### Node result

A node body is a single expression. Its value is the node's result. No
`return` keyword — the last expression IS the result.

## 3. World observations: the `$` sigil

pp interacts with the outside world through **cells**. Every observation uses
the `$` sigil so world-reads are visually distinct from ordinary function
calls.

```pp
$file("src/main.c")                  # file content as a string
$env("CC")                          # value of $CC, or nil if unset
$env("CC", "clang")                 # with default
$glob("src/*.c")                    # list of matching paths
$probe("current-time")              # volatile observation
$secret("/run/secrets/key")         # sealed value
$secret("/run/secrets/key") |> unseal  # explicit, greppable open
```

Each observation records the corresponding trace cell (`file:`, `env:`,
`tree:`, `probe:`, `sealed:`) and returns the observed value.

> **Property access is deferred.** Forms like `$file("x").exists?` or
> `$file("x").hash` are not in this plan. Use the existing predicates
> `file-exists?("x")` and trace cells until a method-access design is worked
> out separately.

## 4. Effects: `!`-suffixed perform wrappers

Effects change the world. They're always explicit, always `!`-suffixed, always
`perform` under the hood.

```pp
run!("cc", "-c", src, "-o", obj)     # execute external tool
write!("path", content)               # write to scratch (node) or real path (script)
log!("building {src}")                # emit log message
http-get!("https://api.example.com")  # HTTP request
http-post!("https://api.example.com", body)
```

Inside a node, `write!`/`slurp!` target the node's sandbox scratch directory.
Absolute paths error. `run!` records `tool:` + `tree:` trace cells; `run-dep!`
refines these to precise `file:` cells by parsing the tool's depfile output.

## 5. Desired state and reconciliation

The program's root returns a **desired-state value**. The reconciler diffs it
against observed reality and applies the minimal change.

```pp
reconcile {
  "build/app"    -> link(objs)
  "build/lib.a"  -> archive(objs)
  "build/version" -> blob(version-string)
}
```

`->` is the desired-state arrow: "this path should contain this content."
Content can be an inline string or a `blob:<sha256>` CAS reference from the
`blob(...)` primitive.

For multi-domain programs:

```pp
reconcile {
  fs: {
    "out/app" -> link(objs)
  }
  proc: {
    "web" -> { cmd: "./out/app", port: 8080 }
  }
}
```

## 6. Handlers: intercepting effects

Handlers establish dynamic extent:

```pp
with handler log: fn(msg) { print("LOG: {msg}") } {
  run!("make", "build")
}
```

Multiple handlers in one block:

```pp
with handler
  log: fn(msg) { ... },
  read-file: fn(path) { if path = "mock.txt" { "fake" } else { read-file!(path) } }
{
  ...
}
```

The `with handler` block restores the previous handler stack on every exit —
normal return, exception, and tail call (LAW 27).

A unified `with {}` form is also supported:

```pp
with {
  caps: narrow-cap,
  config: { cc: "clang", cflags: ["-O2"] },
  handler log: fn(msg) { print("LOG: {msg}") }
} {
  body
}
```

## 7. Configuration: scoped ambient data

Configuration is dynamically-scoped key-value data, distinct from
capabilities:

```pp
with config {
  cc: "clang",
  cflags: ["-O2", "-Wall"]
} {
  build()
}
```

Read inside a node:

```pp
let cc = config("cc", "gcc")      # "clang" if set, "gcc" if not
let cflags = config("cflags")     # nil if not set
```

Config reads record `config:<key>` trace cells.

## 8. General-purpose language

### Functions

```pp
def compile(src, flags = []) {
  let obj = src.replace-ext(".o")
  run!("cc", ...flags, "-c", src, "-o", obj)
  obj
}
```

- Default arguments: `flags = []`
- Rest arguments: `def link(main, ...objs) { ... }` (objs is a list)
- Type annotations: `def greet(name: string) -> string { ... }`
- `fn(x, y) { x + y }` for anonymous functions

### Bindings

```pp
let x = 1                       # single binding
let (a = 1, b = a + 1)         # mutual letrec
let* (x = 1, x = x + 2)        # sequential — for shadowing
```

### Conditionals

```pp
if x > 0 { "positive" }
else if x < 0 { "negative" }
else { "zero" }

cond {
  x > 0  => "positive"
  x < 0  => "negative"
  true   => "zero"             # else is spelled `true =>`
}
```

`cond` arms use `=>` to avoid overloading the `->` used for maps and desired
state.

### Data structures

```pp
[1, 2, 3]                       # list
[head, ...tail]                 # list with spread (cons)
vec[1, 2, 3]                    # vector (random access)
{ :a -> 1, :b -> 2 }            # map
set{ :a, :b, :c }               # set
```

Map/vector access:

```pp
m[:key]                         # hash-map-get(m, :key)
v[0]                            # vector index
```

Map insert/update:

```pp
{ m | :key -> value }           # map-insert(m, :key, value)
{ m | :a -> 1, :b -> 2 }        # multiple inserts
```

### Loops and iteration

No loop keyword — recursion is the loop. Tail calls are constant-stack (LAW 10).

```pp
[1, 2, 3] |> map(fn(x) { x * 2 })
[1, 2, 3] |> filter(fn(x) { x > 1 })
[1, 2, 3] |> foldl(+, 0)
[1, 2, 3] |> each(fn(x) { log!("{x}") })
```

### String interpolation

```pp
"Hello, {name}! The answer is {40 + 2}."
f"src/{name}.c"                 # f-prefix for interpolation
```

Lowers to `string-append` with `number->string` inserted for non-string holes.

### Pattern matching

```pp
match x {
  [a, b, ...rest] => process(a, b, rest)
  [single]        => single
  []              => nil
}

match result {
  [:ok, value] => value
  [:err, msg]  => error!(msg)
}
```

This needs new AST forms and backend support.

### Spread/rest in calls

```pp
run!("cc", ...flags, "-o", out)
```

Requires an `apply` primitive that dispatches a function with a dynamic
argument list.

## 9. Modules and islands

```pp
module math {
  def add(x, y) { x + y }
  def mul(x, y) { x * y }

  export add, mul
}
```

`import(math)` merges the exported bindings into the current scope.

```pp
island("github:owner/repo#v1.2.3",
       "a1b2c3d4e5f6...")       # inline content-hash pin
```

The pin is part of the code hash (LAW 20). No pin = hard error. Fetching is
opt-in runtime authority (`pp --fetch-islands`).

## 10. Macros

Macros receive unevaluated s-expression forms and return new forms:

```pp
defmacro unless(test, body) {
  quasiquote {
    if not(unquote(test)) { unquote(body) }
  }
}

unless(x > 0) { log!("x is not positive") }
```

`quasiquote { ... }` templates with `unquote(e)` holes are the usual way to
build expansions. `gensym()` produces fresh names for hygiene.

## 11. Domains and probes

```pp
register-domain {
  name: "my-fs",
  namespace: ["file:/srv/www", "tree:/srv/www"],
  observe: fn() { tree-observe!("/srv/www") },
  diff: fn(observed, desired) { fs-diff(observed, desired) },
  apply: fn(plan) { fs-apply!(plan) },
  write-cap: fs.read("/srv/www")
}
```

A probe is a domain with no write authority:

```pp
register-probe("current-time",
  fn() { now!() },
  cap: none)
```

Then read it anywhere:

```pp
let t = $probe("current-time")
```

## 12. Fenced effects

Non-convergent actions (send email, charge card) that can't be replayed:

```pp
fenced(:email, {
  to: "user@example.com",
  subject: "Build complete",
  body: "All {count} targets built."
})
```

Fenced effects are barred from node bodies. They're sequenced by the
reconciler, with an intent/done journal, at-most-once per pass.

## 13. Error handling — five tiers that match the runtime

pp already has the right machinery: **effects**, **handlers**, and **node
failure caching** (LAW 28). Error handling exposes that machinery honestly.

### Tier 1: Errors as values — `[:ok, v]` / `[:err, e]`

A function that can fail returns a tagged list:

```pp
def divide(a, b) {
  if b = 0 { [:err, "division by zero"] }
  else     { [:ok, a / b] }
}
```

A node that returns `[:err, ...]` stores a failed trace with the error value's
hash.

### Tier 2: `try { }` with `<-` unwrap

Inside a `try` block, `<-` unwraps `[:ok, v]` or propagates `[:err, e]`.

```pp
def compute(x, y) {
  try {
    a <- divide(x, y)
    b <- divide(a, 2)
    [:ok, a + b]
  }
}
```

Optionally, `expr?` is a postfix alias for unwrap-or-propagate:

```pp
try {
  let a = divide(x, y)?
  let b = divide(a, 2)?
  [:ok, a + b]
}
```

Ship both; they lower to the same `match` chain.

### Tier 3: `perform error(msg)` — the effect

When you want to BAIL OUT, use the error effect:

```pp
def must-divide(a, b) {
  if b = 0 { perform error("division by zero") }
  a / b
}
```

Unhandled errors crash the process. Handle them with `with handler`.

### Tier 4: `collect { ... }` — error accumulation

Builds don't short-circuit. `collect` runs every expression, gathers all
`:err`s, and returns them together.

```pp
let results = collect {
  srcs |> map(fn(f) { compile(f) })
}
;; results = [:ok, [obj1, obj2, ...]]
;;        or [:err, [err1, err2, ...]]
```

### Tier 5: Node failure caching (automatic)

No syntax needed. When a node body raises, pp stores a `Failed` trace. A null
rebuild with unchanged inputs re-serves the failure without re-running.

### Summary

| Situation | Mechanism | Cached? |
|-----------|-----------|---------|
| Pure function that can fail | `[:ok, v]` / `[:err, e]` + `<-` | Yes |
| Script should bail out | `perform error(msg)` + handler | No |
| Build — see all errors | `collect { ... }` | Yes |
| Node crashed | Failure trace | Yes |
| Authority denied | `Capability_error` | No |

## 14. Before/after: a complete build file

### Today

```pp
load("stdlib/list.pp")
load("stdlib/string.pp")
load("stdlib/map.pp")

def compile(src) { ... }
def link(objs)   { ... }

node app() {
  let (srcs = perform list-dir("src", "*.c")) {
    link(map(compile, srcs))
  }
}

{"build/app" -> app()}
```

### With this surface

```pp
node compile(src) needs fs.read("src/"), process {
  let obj = scratch(src.replace-ext(".o"))
  run!("cc", "-c", src, "-o", obj)
  obj
}

node link(objs) needs process {
  let app = scratch("app")
  run!("cc", "-o", app, ...objs)
  app
}

node app() reads $glob("src/*.c") {
  $glob("src/*.c") |> map(compile) |> link
}

reconcile {
  "build/app" -> app()
}
```

## 15. Implementation phasing

| Phase | What | Dependencies |
|-------|------|--------------|
| **A** | `[a,b]` lists, `m[k]` maps, `let x = e`, `cond`, pipeline, `needs`, `$KIND` observations, string interpolation, `reconcile { }`, `!` convention, `...` in list/vector construction | Reader + printer |
| **B** | `with {}` unification, `{ m \| k -> v }` map update, default/rest args, call spread (`...`), `try`/`collect`, `[:ok,]/[:err,]` sugars | Needs `apply` primitive; mostly reader |
| **C** | `match` expression, function clauses, `@needs`/`@cache` attributes, `register-domain`/`register-probe` surface, `fenced { }`, `secret:` via `$secret` | New AST + both backends |
| **D** | `for` comprehensions, destructuring `let`, resumable effects (`resume`) | New AST/VM; stretch |

## 16. The elegance test

Every form obeys a single rule: **it reads like what it does.**

- `node f(x) needs fs.read("src/")` — a cacheable computation needing authority
- `$file("src/main.c")` — an observation of the world
- `run!("cc", "-c", src)` — a side effect, visible at the call site
- `reconcile { "out/app" -> link(objs) }` — a declaration of desired state
- `$probe("clock")` — a volatile observation
- `fenced(:email, { ... })` — a non-convergent action, behind a barrier
- `$secret("/run/key") |> unseal` — a confidential read, explicitly opened
- `[1, 2, 3] |> map(fn(x) { x * 2 })` — data flowing left to right
