# pp — Technical Requirements Document

> **pp** (pronounced "peepee") is a dynamic, lazy, pure-by-default, content-addressed Lisp
> where build systems, package managers, and cluster orchestrators are just the
> runtime's evaluation strategy — not separate tools.

---

## 1. Philosophy

### 1.1 The Problem

Build systems (Make, Bazel), package managers (apt, npm, Nix), init systems
(systemd, launchd), container builders (Dockerfiles), infrastructure
provisioners (Terraform), and cluster orchestrators (Kubernetes) all manage the
same thing: **dependency graphs, execution order, caching, and side effects.**
We built separate, incompatible, broken tools for each domain.

### 1.2 The Insight

Excel, React, Bonsai by Jane Street, and Haskell model computation as a **DAG with explicit data
flow.** Same inputs → same outputs. Caching is principled. The actual structure
of a build, a deployment, a service mesh is a DAG — not a linked list
(Dockerfiles), not a sequence of mutations (shell scripts), not a rigid upfront
enumeration (Nix evaluations).

### 1.3 The Fix

A language where:

- **Every expression is a thunk** — the DAG is not authored; it emerges from
  evaluation.
- **Thunks are content-addressed** — caching and deduplication are automatic.
- **Purity is the default** — side effects require explicit capabilities.
- **Capabilities replace ambient authority** — no expression can access
  resources it wasn't explicitly given.
- **Distributed evaluation is a library call** — not a multi-week
  infrastructure project.

Nix had the right instinct (packages as pure functions of their inputs), but
requires build graphs to be fully serialized before evaluation. A lazy language
gets graph expansion on demand for free — represent LLVM's 50,000 compilation
units as a single node that, when forced, expands into 50,000. No
special-casing needed.

---

## 2. Language Design

### 2.1 Syntax

S-expressions as the core syntax. One uniform tree-shaped grammar maps directly
onto the lazy computation DAG.

```lisp
;; Function definition
(def (factorial n)
  (if (<= n 1)
      1
      (* n (factorial (- n 1)))))

;; Anonymous function
(fn (x y) (+ x y))

;; Let bindings (lazy — each binding is a thunk)
(let ((x (expensive-computation a))
      (y (expensive-computation b)))
  (+ x y))

;; Conditional
(if pred then else)

;; Quoting
(quote (1 2 3))
'(1 2 3)

;; Force a thunk explicitly
(force some-thunk)

;; Modules — thunks that evaluate to environments
(module
  (def (square x) (* x x))
  (def (cube x) (* x (* x x))))

;; Import a module's bindings into the current scope
(import some-module)

;; Load a file into the current scope (like the REPL)
(load "lib/math.pp")

;; Load a file as a module (clean env, returns an env-map)
(def math (load-module "lib/math.pp"))
```

#### 2.1.1 Rich Data Literals

Clojure-style rich literals for ergonomics. These are **syntax**, not library
constructs, but map directly onto the underlying list structure.

```lisp
;; Vectors
[1 2 3]
(vec 1 2 3)

;; Maps / hash tables
{:name "pp" :version 1}
{:a 1, :b 2}               ;; commas are whitespace

;; Sets
#{1 2 3}

;; Keywords (self-evaluating, used as map keys)
:keyword
::namespaced-keyword

;; Tagged literals (extensible reader)
#instant "2026-06-02T00:00:00Z"
#uuid "550e8400-e29b-41d4-a716-446655440000"
```

Higher abstractions (spreadsheet cells, React components, service definitions)
are **libraries** built on the expression model, not syntax extensions. The
core remains one uniform Lisp.

#### 2.1.2 Modules as Environment Thunks

Modules are not a separate namespace or compilation-unit system. A module is
a **thunk that evaluates to an environment**. Importing is forcing that thunk
and merging its bindings into the current scope. Module identity is
`hash(module-body)` — independent of where the module is defined.

```lisp
;; A module is just a thunk that produces an environment-map (VEnvMap)
(module
  (def (double x) (* x 2))
  (def (triple x) (* x 3)))

;; Import merges bindings into the current scope
(let [m (load-module "math.pp")]
  (import m)
  (double 5))  ;; => 10

;; load brings a file's defs into scope directly
(load "stdlib/list.pp")
```

Modules evaluate in a **clean environment** (builtins only, no ambient scope),
so their identity and behavior are stable regardless of import site. Imports
compose through `do`, making them ordinary DAG edges rather than a separate
resolution phase.

### 2.2 Data Model

All values are immutable and have a content hash.

| Type | Examples | Description |
|------|----------|-------------|
| **Nil** | `nil` | The empty value |
| **Bool** | `true`, `false` | Boolean |
| **Int** | `42`, `-1`, `0x2A` | Arbitrary-precision integer |
| **Float** | `3.14`, `1.5e10` | IEEE 754 double |
| **String** | `"hello"` | UTF-8 text |
| **Keyword** | `:foo`, `::ns/bar` | Self-evaluating identifiers for keys |
| **Symbol** | `foo`, `+`, `list` | Identifiers that resolve in an environment |
| **Pair / List** | `(1 2 3)` | Linked list (car/cdr) |
| **Vector** | `[1 2 3]` | Random-access array |
| **Map** | `{:a 1 :b 2}` | Hash map from keys to values |
| **Set** | `#{1 2 3}` | Hash set |
| **Function** | `(fn (x) (+ x 1))` | Closure over an environment |
| **Thunk** | `(delay expr)` | Unevaluated or memoized computation |
| **Capability** | `(filesystem "/tmp" :rw)` | Authority token |
| **Effect** | effect descriptors | Abstract effect operation |

### 2.3 Evaluation Model

#### 2.3.1 Laziness (Haskell-style, call-by-need)

Every expression is a **thunk**: a suspended computation that evaluates at
most once and memoizes its result.

- **Definition time**: creating a thunk does not evaluate it.
- **Force time**: when a thunk's value is required, it evaluates. The result is
  cached (memoized) so subsequent forces return immediately.
- **Space**: a thunk that is never forced is never evaluated. Unreachable
  branches in a conditional are never computed.

This is **not** explicit lazy (Clojure's `delay`/`force` where you opt in).
Laziness is the **default**. The programmer writes normal expressions; the
runtime decides when to evaluate them.

```lisp
;; x is a thunk. It does not evaluate yet.
(let ((x (very-expensive-computation)))
  ;; If we never use x, it never runs.
  (if some-condition
      (do-something x)   ;; x is forced here
      42))                ;; x is never forced
```

#### 2.3.2 Generative Thunks (Graph Expansion)

A thunk, when forced, can produce **new thunks** as part of its evaluation.
This is the mechanism that handles Nix's "dynamic derivation" problem without
special syntax.

```lisp
;; compile-llvm is a single thunk.
;; When forced, it expands into 50,000 sub-thunks (one per compilation unit).
;; The runtime only forces those sub-thunks as their results are needed.
(def (compile-llvm source)
  (let* ((modules (parse-modules source))     ;; returns a list of thunks
         (objects (map compile-module modules))  ;; each compile-module is a thunk
         (linked  (link-objects objects)))       ;; link-objects forces objects lazily
    linked))
```

There is no `thunk` special form for this — it falls out of normal lazy
evaluation. `parse-modules` returns a list of thunks. `compile-module` returns
a thunk for each module. `map` is lazy: it doesn't force the list elements.
`link-objects` forces objects as needed.

The graph is never fully serialized. It expands on demand.

### 2.4 Content Addressing

**Every value has a hash.** This is the foundation of caching, deduplication,
and eventual remote execution.

#### 2.4.1 Hash Scheme

- **Hash function**: SHA-256 (pluggable; BLAKE3 considered for speed).
- **Structural hashing**: the hash of a value depends on the value's structure,
  not its identity or memory location.

| Value | Hash is derived from |
|-------|---------------------|
| Primitive (`42`, `"hello"`, `true`) | The value itself |
| Pair `(a . b)` | `hash("cons", hash(a), hash(b))` |
| Vector | `hash("vector", hash(e0), hash(e1), ...)` |
| Map | `hash("map", sorted(hash(k0), hash(v0)), ...)` |
| Function | `hash("fn", hash(params), hash(body), hash(captured_env))` |
| Thunk (unevaluated) | `hash("thunk", hash(expr), hash(env))` |
| Thunk (evaluated) | `hash(expr)` — the hash of the expression that produced it |
| Capability | `hash("cap", type_tag, scope_hash)` |

#### 2.4.2 Code Store

Definitions are stored in a content-addressed code store. A definition's
identity is its hash. Names are metadata — human-facing aliases for hashes.

```
Code Store:
  hash -> (params, body, source_location, metadata)

Name Index (metadata, not semantic):
  name -> hash
```

This means:

- Two structurally identical functions have the same hash — they ARE the same
  function.
- Renaming a function does not change its identity.
- Dependency conflicts are impossible: two versions have different hashes and
  can coexist.
- Distribution is hash synchronization.

#### 2.4.3 Caching

Every pure thunk, once forced, is cached by its hash. The cache is persistent
(on disk).

```
Cache:
  thunk_hash -> (value_hash, serialized_value, dependencies)

Dependencies:
  [hash_of_resource_accessed, ...]
```

For **pure** thunks (no effects): the hash depends only on expression + inputs.
Cache hit = skip re-evaluation entirely.

For **effectful** thunks (those with capabilities): the hash additionally
depends on the hashes of all resources accessed during evaluation. If a
resource changes, the thunk's hash changes, and the cached result is
invalidated.

### 2.5 Effects and Capabilities

#### 2.5.1 Purity by Default

A function that does not declare effects is **pure**. Pure functions:

- Always return the same result for the same inputs.
- Have no observable side effects.
- Are automatically memoized by the runtime.
- Can be evaluated anywhere (local, remote, speculatively).

#### 2.5.2 Algebraic Effects

Side effects are modeled as **algebraic effects**: abstract operations that are
performed by the program and interpreted by handlers.

```lisp
;; Define an effect (abstract operation)
(defeffect ReadFile (path) content)

;; A function that may perform effects declares them in its signature.
;; The set of effects is part of the function's type (checked at runtime in v1).
(def (read-config fs-cap)
  (effect :capabilities [fs-cap]
    (let* ((content (perform ReadFile fs-cap "config.toml"))
           (parsed  (parse-config content)))
      parsed)))

;; Install a handler that interprets effects
(with-handler
  [(ReadFile (lambda (cap path k)
               ;; k is the continuation: call (k result) to resume
               (let ((content (os-read-file cap path)))
                 ;; Record resource access for caching
                 (record-resource! (hash path) (hash content))
                 (k content))))]
  (read-config my-fs-cap))
```

A handler receives:

1. The effect name and arguments
2. The current capability environment
3. A **continuation** `k` — the rest of the computation after the effect

The handler can:

- Perform the effect and resume with `(k result)`.
- Resumptive handler (most common): does something, then resumes.
- Abort the computation (don't call `k`).
- Resume multiple times (for non-determinism / backtracking).
- Transform the effect (perform a different effect and resume with the result).

#### 2.5.3 Capabilities

**Capabilities are first-class tokens that gate authority.** They replace
Unix's ambient authority model where any process can access anything the user
can access.

```lisp
;; Capability constructors
(filesystem path mode)     ;; mode: :ro, :rw, :wo
(network protocol host)    ;; protocol: :tcp, :udp
(process)                  ;; ability to spawn processes
(time budget-ms)           ;; CPU time budget
(memory budget-bytes)      ;; memory budget

;; Capability combinators
(restrict cap new-scope)   ;; narrow a capability's scope
(compose cap1 cap2 ...)    ;; bundle multiple capabilities
(delegate cap target)      ;; create a capability safe for remote delegation
```

**Principle of least authority**: a function only receives the capabilities it
needs.

```lisp
;; This function only gets read access to /var/lib/config
(def (read-database-config)
  (let ((fs (filesystem "/var/lib/config" :ro)))
    (parse-config (fs/read fs "db.toml"))))

;; It cannot: write files, open network connections, read /etc/passwd,
;; or do anything else with the filesystem.
```

#### 2.5.4 Capability Propagation (for distributed evaluation)

When a thunk is sent to a remote node for evaluation, it receives **only** the
capabilities its parent explicitly delegates. The remote node cannot amplify
its authority simply because code crossed a network boundary.

```lisp
;; Remote evaluation (v2)
;; The remote node gets fs-cap and nothing else.
(let ((remote-task (remote-eval [node1 node2]
                     (effect :capabilities [fs-cap]
                       (build-package source fs-cap)))))
  (force remote-task))
```

#### 2.5.5 Capability Lifecycle

- **Creation**: the top-level expression receives capabilities from the runtime
  (which gets them from the OS/user).
- **Restriction**: capabilities are narrowed before being passed down.
- **Delegation**: a capability can be passed to sub-expressions.
- **Revocation**: a parent can revoke a capability it delegated. The child's
  continued use of the revoked capability raises an error.
- **Expiry**: capabilities can have time bounds.

### 2.6 Build System as Emergent Property

Users do **not** write build graphs or derivations. They write normal
expressions. The DAG emerges from evaluation:

```lisp
;; This is a build. No Makefile, no Dockerfile, no Nix derivation.
;; Just a Lisp expression.
(def (build-my-app source-dir)
  (let* ((src-files  (enumerate-source source-dir))
         (objects    (map compile-file src-files))
         (linked     (link-objects objects))
         (packaged   (create-package linked)))
    packaged))

;; Run the build: force the top-level thunk.
;; The runtime handles caching, parallelism, and incrementality.
(force (build-my-app "./src"))
```

**Incremental builds**: if source files haven't changed, their hashes are the
same, so `compile-file` returns the cached object file. Only changed files are
recompiled.

**Parallelism**: `map` over thunks creates independent sub-computations. The
scheduler can evaluate them in parallel (v1.5).

**Hermeticity**: `compile-file` only has access to the capabilities it's given.
It can't accidentally depend on ambient state (environment variables, installed
packages, system time).

---

## 3. Runtime Architecture (v1)

### 3.1 Components

```
┌─────────────────────────────────────────────────────────┐
│                        pp Runtime                        │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │  Reader  │  │ Evaluator│  │ Scheduler│  │ Primitives│ │
│  │          │  │          │  │          │  │         │ │
│  │ s-expr → │  │ AST →    │  │ force    │  │ built-in│ │
│  │  AST     │  │  Value   │  │ ordering │  │  fns    │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘ │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐   │
│  │  Hasher  │  │  Cache   │  │  Capability Manager  │   │
│  │          │  │          │  │                      │   │
│  │ SHA-256  │  │ thunk →  │  │ track, restrict,     │   │
│  │ Merkle   │  │  value   │  │ delegate, revoke     │   │
│  └──────────┘  └──────────┘  └──────────────────────┘   │
│                                                          │
│  ┌──────────┐  ┌──────────────────────────────────────┐ │
│  │  Code    │  │  Effect System                       │ │
│  │  Store   │  │                                      │ │
│  │          │  │  perform / handle / continue (k)     │ │
│  │ hash→def │  │                                      │ │
│  └──────────┘  └──────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Evaluator

The evaluator is a lazy, call-by-need interpreter:

```
eval(expr, env):
  match expr:
    Literal(value) -> value
    Symbol(name)   -> lookup(name, env)  ;; returns a thunk; force it
    If(cond, t, e) -> if force(eval(cond, env))
                        then eval(t, env)
                        else eval(e, env)
    Let(bindings, body) ->
      new_env = env
      for (name, val_expr) in bindings:
        new_env[name] = Thunk(val_expr, new_env)  ;; create thunk, DON'T force
      eval(body, new_env)
    Fn(params, body) -> Closure(params, body, env)
    Apply(fn_expr, arg_exprs) ->
      fn = force(eval(fn_expr, env))
      args = [Thunk(arg, env) for arg in arg_exprs]  ;; thunks, not forced
      apply_closure(fn, args)
    Perform(effect, args) ->
      ;; Find handler in current handler environment
      handler = lookup_handler(effect, handler_env)
      ;; Record resource access for caching
      record_effect(effect, args)
      ;; Invoke handler with continuation
      handler(effect, args, continuation)
```

### 3.3 Thunk Lifecycle

```
  ┌──────────┐
  │  Created  │  (let binding, function argument, delay)
  └────┬─────┘
       │
       ▼
  ┌──────────┐
  │  Forced   │  (value is needed by another computation)
  └────┬─────┘
       │
       ▼
  ┌────────────┐     cache hit    ┌──────────────┐
  │ Check Cache │ ───────────────→ │ Return Cached │
  └────┬───────┘                   └──────────────┘
       │ cache miss
       ▼
  ┌──────────┐
  │ Evaluate  │  (may force other thunks recursively)
  └────┬─────┘
       │
       ▼
  ┌──────────┐
  │ Memoize   │  (store result in thunk + cache)
  └────┬─────┘
       │
       ▼
  ┌──────────┐
  │  Return   │
  └──────────┘
```

### 3.4 Scheduler

v1: **single-threaded, depth-first**. When a thunk is forced, the evaluator
recursively forces dependencies as needed. This is the simplest correct
implementation.

v1.5: **parallel**. Independent thunks (e.g., elements of a lazy `map`) can be
forced concurrently. The scheduler maintains a work queue of forced-but-
unevaluated thunks. Worker threads pull and evaluate.

The scheduling strategy (depth-first, breadth-first, priority-based) is an
**effect handler** — it can be swapped without changing the language semantics.

### 3.5 Cache

- **In-memory**: thunk hash → `(status, value)` for the current evaluation
  session. Avoids re-evaluating the same thunk within one run.
- **On-disk**: persisted cache in `~/.pp/cache/`. Keyed by thunk hash. Stores
  serialized values and dependency information. Survives process restarts.
- **Invalidation**: a cached thunk is invalid when:
  1. Its expression hash changes (source code changed).
  2. Any of its dependencies (other thunks or external resources) changed hash.
  3. Explicit invalidation request.

### 3.6 Effect System Implementation (v1)

v1 implements a simplified algebraic effect system:

- **Single-shot delimited continuations** (not full multi-prompt). Handlers
  receive the continuation `k` and can call it at most once. This covers 90%+
  of use cases (file I/O, network, logging) and is much simpler to implement.
- **Handler stack**: a dynamic stack of handler environments. `with-handler`
  pushes; scope exit pops.
- **Capability integration**: the handler environment includes the current
  capability set. Handlers reference capabilities to authorize operations.

Full multi-shot continuations (for non-determinism, probabilistic programming,
etc.) are deferred to v2.

---

## 4. Core Primitives and Standard Library

### 4.1 Special Forms

| Form | Description |
|------|-------------|
| `(def name (params...) body)` | Define a named function |
| `(fn (params...) body)` | Anonymous function |
| `(let ((name expr)...) body)` | Lazy bindings (each expr is a thunk) |
| `(if cond then else)` | Conditional |
| `(quote expr)` / `'expr` | Literal data |
| `(force thunk)` | Explicitly force a thunk |
| `(effect :capabilities [...] body)` | Declare an effectful block |
| `(perform effect-name args...)` | Perform an algebraic effect |
| `(with-handler ((effect handler)...) body)` | Install effect handlers |
| `(delay expr)` | Explicitly create a suspended thunk (rarely needed) |
| `(do exprs...)` | Sequence expressions; forces each, returns last |
| `(and exprs...)` | Short-circuiting logical AND |
| `(or exprs...)` | Short-circuiting logical OR |
| `(let* (binding...) body)` | Sequential let (each binding sees previous ones) |
| `(def-fexpr name (params...) body)` | Define an operative (fexpr) — receives unevaluated args |
| `(module defs...)` | Create a module — a thunk producing an environment-map (VEnvMap) |
| `(import mod-expr)` | Force a module thunk and merge its bindings into the current scope |
| `(load "file.pp")` | Evaluate a file in the current scope; defs persist |
| `(load-module "file.pp")` | Evaluate a file in a clean env and return its exports as VEnvMap |

### 4.2 Key Built-ins (v1)

| Built-in | Description |
|----------|-------------|
| `(force thunk)` | Force a thunk to evaluate |
| `(delay expr)` | Explicitly create a suspended thunk |
| `(filesystem path mode)` | Create FS capability (`mode`: `:ro`, `:rw`, `:wo`) |
| `(network protocol)` | Create network capability (`:tcp`, `:udp`, `:any`) |
| `(process)` | Create process capability |
| `(time-budget ms)` | Create CPU time budget capability |
| `(memory-budget bytes)` | Create memory budget capability |
| `(cap-compose caps...)` | Bundle multiple capabilities |
| `(cap-restrict cap scope)` | Narrow a capability's scope |
| `(cap-none)` | Empty capability |
| `(capability? v)` | Predicate: is v a capability? |
| `(effect :capabilities [...] body)` | Mark an effectful block with required capabilities |
| `(perform effect-name args...)` | Perform an algebraic effect |
| `(with-handler ((effect handler)...) body)` | Install effect handlers |

### 4.3 Built-in Effects

| Effect | Args | Returns | Description |
|--------|------|---------|-------------|
| `read-file` | path | string | Read a file (requires fs capability) |
| `write-file` | path, content | nil | Write a file (requires fs capability) |
| `log` | level, message | nil | Log a message |
| `random` | — | int | Random number |
| `(none)` | Empty capability set (pure computation only) |

---

## 5. Examples

### 5.1 Pure Computation (Automatic Caching)

```lisp
(def (expensive-analysis data)
  (let* ((cleaned  (preprocess data))
         (features (extract-features cleaned))
         (model    (train-model features))
         (results  (evaluate-model model)))
    results))

;; First run: evaluates everything
(force (expensive-analysis my-data))

;; Second run with same data: instant (all cache hits)
(force (expensive-analysis my-data))

;; Change my-data: only affected thunks re-evaluate
(force (expensive-analysis modified-data))
```

### 5.2 Build System

```lisp
;; Define compilation as a function with a filesystem capability
(def (compile-c-project src-dir build-dir)
  (effect :capabilities [(filesystem src-dir :ro)
                         (filesystem build-dir :rw)
                         (process)]
    (let* ((c-files   (find-files src-dir ".c"))
           (obj-files (map (fn (f) (compile-cc f build-dir)) c-files))
           (binary    (link-executable obj-files build-dir "myapp")))
      binary)))

;; The build is just forcing the expression.
;; Caching is automatic. Incrementality is free.
(compile-c-project "./src" "./build")
```

### 5.3 Modules

```lisp
;; A math module — just a Lisp expression, not a separate file format
(def math-mod
  (module
    (def (square x) (* x x))
    (def (cube x) (* x (* x x)))))

;; Import merges bindings into scope
(import math-mod)
(square 5)  ;; => 25

;; Load a file directly (defs become visible in current scope)
(load "stdlib/list.pp")

;; Load as an isolated module (clean env, reusable VEnvMap)
(def list-lib (load-module "stdlib/list.pp"))
(import list-lib)
```

### 5.4 Service Definition

```lisp
;; A service is a function that takes capabilities and runs
(def (web-server config)
  (effect :capabilities [(network :tcp)
                         (filesystem config.static-dir :ro)]
    (let* ((socket (perform TcpListen (network :tcp) config.port))
           (handler (create-handler config)))
      (serve-forever socket handler))))

;; Compose services
(def (my-app)
  (let ((db     (delay (postgres-db {:port 5432})))
        (cache  (delay (redis-server {:port 6379})))
        (web    (delay (web-server {:port 8080
                                    :db db
                                    :cache cache}))))
    ;; Each service is a thunk. They start when forced.
    (supervise [db cache web])))
```

### 5.5 Distributed Computation (v2 Syntax Preview)

```lisp
;; Remote evaluation returns a task thunk
(let ((task (remote-eval [node-a node-b node-c]
              ;; This expression runs remotely.
              ;; It only gets the capabilities we delegate.
              (effect :capabilities [(filesystem "/data" :ro)]
                (analyze-dataset "/data/huge-dataset"))))))
;; task is a thunk. Force it to await the result.
;; The runtime handles retries, timeouts, partial failures.
(force task)

;; Redundant execution (v3): run on 3 nodes, return first result
(let ((task (remote-eval {:nodes [node-a node-b node-c]
                          :redundancy 3
                          :strategy :first}
              (critical-computation))))
  (force task))
```

---

## 6. Scope and Roadmap

### 6.1 v1 — "The Local Thunk Engine" (current)

**Goal**: validate the core language semantics — laziness, content-addressing,
capabilities, algebraic effects — on a single machine.

| Feature | Status |
|---------|--------|
| S-expression reader with rich literals | ✅ |
| Haskell-style lazy evaluation | ✅ |
| Content-addressed thunk store (`make_thunk_ca` + global dedup) | ✅ |
| O(1) thunk identity via persistent env IDs and cached hashes | ✅ |
| Recursive `force` (evaluates through thunk chains) | ✅ |
| Lazy data constructors (`cons`/`list` store thunks without forcing) | ✅ |
| Module system (`module`, `import`, `load`, `load-module`) | ✅ |
| Persistent disk cache | ⚠️ v2 |
| Capability tokens (`filesystem`, `network`, `process`, compose, restrict) | ✅ |
| Algebraic effects (`perform`/`with-handler`, single-shot) | ✅ |
| `let*` sequential bindings | ✅ |
| Fexprs (`def-fexpr` — operatives with unevaluated args) | ✅ |
| `and`/`or` short-circuiting special forms | ✅ |
| Closures capture `env ref` (see later `def`s — mutual recursion) | ✅ |
| Tail-call optimization (function calls in tail position don't grow stack) | ✅ |
| REPL + file runner | ✅ |
| Incremental builds (automatic, via content-addressing) | ✅ |

### 6.1.1 Semantic Invariants (frozen)

These three rules are the foundation. They will not change.

| Rule | Description |
|------|-------------|
| **Thunk identity** | `hash(expr, env_id, capability-scope)`. Env identity is an incrementally-computed hash stored on each env node — O(1), not structural traversal. Same hash = same thunk in the global store. |
| **Dependencies** | Everything accessed during evaluation. Currently: full environment identity included in hash (pessimistic but correct; future: free-variable-only for broader sharing). |
| **Effects inside DAG** | Effects are not outside the DAG — they are capability-gated inputs whose observed results become part of the thunk's identity. A thunk that reads a file is cached by that file's content hash. |

| Deferred to v2 | Why |
|----------------|-----|
| Resource-access tracking during eval | File reads, network calls — record content hashes of accessed resources and include in thunk hash. Enables effectful caching. |
| Capability propagation for remote eval | Remote thunks receive only delegated capabilities — essential for distributed safety. |
| Persistent disk cache | In-memory only. Disk persistence needs serialization format + invalidation strategy. |
| Multi-shot continuations | Currently single-shot. Multi-shot enables non-determinism, generators, etc. |
| Parallel evaluation | Independent thunks evaluated concurrently. |
| Thunk-chain forcing (lazy space leaks) | Deeply-nested arithmetic thunks (e.g. `(- (- n 1) 1)`) overflow when forced all at once. Fix requires strictness annotations or a CPS/trampoline evaluator. |

### 6.2 v1.1 — "Fexprs and Capabilities" ✅ DONE

- `let*` sequential bindings (desugared in reader).
- `def-fexpr` — operatives that receive unevaluated arguments + calling environment.
- Capability constructors: `filesystem`, `network`, `process`, `cap-compose`, `cap-restrict`.

### 6.3 v1.2 — "Modules and O(1) Identity" ✅ DONE

- Environment nodes carry stable integer IDs and cached incremental hashes — thunk identity is O(1) regardless of env chain depth.
- Modules as environment-producing thunks: `(module defs...)` returns a `VEnvMap`.
- `(import mod-expr)` merges a module's bindings into scope via `do`-scoped env threading.
- `(load "file.pp")` evaluates a file in the current scope (like the REPL).
- `(load-module "file.pp")` evaluates a file in a clean env and returns its exports.
- Modules evaluate in a clean environment (builtins only), so identity is stable.
- Meta-circular evaluator (`meta.pp`) runs all test cases correctly.
- Tail-call optimization via `eval_tail`/`apply_tail` CPS transformation — OCaml stack does not grow across tail calls. Simple, multi-arg, and mutual recursion all pass at depth 10k+ (bytecode) / 100k+ (native).

### 6.4 v1.5 — "Parallelism"

- Parallel evaluation of independent thunks.
- Improved error reporting (source locations, stack traces).
- Basic IDE support (LSP).

### 6.5 v2 — "Remote Thunks"

- `remote-eval`: send thunks to other nodes for evaluation.
- Capability propagation: remote thunks only get delegated capabilities.
- Content-addressed distribution: nodes sync hashes, not source.
- Simple scheduler: round-robin, work stealing.
- Transport: gRPC or custom protocol over TCP+TLS.
- Failure handling: timeouts, retries, partial results.
- Multi-shot continuations in the effect system.

### 6.6 v3 — "Redundant and Cluster-Wide"

- Redundant execution: "run on N nodes, return first result."
- Cluster scheduler with resource awareness.
- Distributed cache: cache results shared across nodes.
- Node discovery and membership.
- Observability: tracing, metrics, logs as effects.

---

## 7. Implementation Notes

### 7.1 Implementation Language

**Chosen: OCaml.** Rationale:

- Algebraic data types + pattern matching are native — an evaluator is a giant `match`.
- GC handles thunk lifetimes automatically — no manual memory management.
- Type inference means less ceremony than Rust, but still catches structural mistakes.
- Development velocity matters more than runtime speed for v1 semantics validation.
- Zero external dependencies — everything comes from the OCaml stdlib.

**Bootstrap path**: v1 interpreter in OCaml (12-line Makefile). Meta-circular
evaluator in pp (`examples/meta.pp`) proves the language is self-describing.
v2: write a pp compiler in pp, eliminating the OCaml bootstrap.

### 7.2 Project Structure

```
pp/
├── TRD.md                  ← this document
├── Makefile                ← 12-line bootstrap build
├── .gitignore
├── pp                      ← the interpreter binary
├── build.pp                ← aspirational self-hosting build
├── examples/
│   ├── factorial.pp        ← recursion + laziness
│   ├── lazy.pp             ← thunks that never fire
│   ├── build.pp            ← DAG emerges from evaluation
│   ├── demo.pp             ← let*, fexprs, capabilities
│   ├── meta.pp             ← meta-circular evaluator (pp in pp)
│   ├── math.pp             ← example module (loaded by module_test.pp)
│   └── module_test.pp      ← module + import + load demo
├── stdlib/
└── src/
    ├── types.ml            ← types, env, hashing, pretty-printing
    ├── hasher.ml           ← thin re-export (all hashing lives in types.ml)
    ├── reader.ml           ← s-expression parser + rich literals
    ├── capabilities.ml     ← authority tokens
    ├── primitives.ml       ← built-in functions
    ├── evaluator.ml        ← lazy eval, force, apply, effects, modules
    ├── cache.ml            ← persistent cache (stub)
    ├── repl.ml             ← REPL loop + file runner
    └── main.ml             ← CLI entry point
```

---

## 8. Open Design Questions

*These are decisions to make during implementation, not blockers for the TRD.*

1. **Hash collision handling**: SHA-256 collisions are astronomically unlikely,
   but should the runtime detect and error on collision anyway?

2. **Garbage collection of cached thunks**: when do we evict from the
   persistent cache? LRU? Size-based? Explicit `pp cache clean`?

3. **Effect syntax**: settled on `(perform name args...)` with `(with-handler ((name handler) ...) body)`. No `defeffect` declaration needed — effects are identified by name at perform time.

4. **Module system**: ✅ Resolved. Modules are thunks that evaluate to environments (VEnvMap). `(import m)` forces the thunk and merges bindings via `do`-scoped env threading. No separate namespace, no compilation phase — modules are just DAG nodes at a higher granularity. See Section 2.1.2.

5. **Serialization format for cached values**: something fast and
   content-addressable. Candidates: CBOR, MessagePack, or a custom binary
   format keyed by hash.

6. **Capability serialization for remote eval (v2)**: how do you serialize a
   capability token and ensure the remote node enforces it correctly?

7. **Exact semantics of `force` on already-forced thunks**: ✅ Settled. Transparent no-op — `force` returns the memoized value without error. This is the natural consequence of memoization: forcing twice is harmless.

8. **Tail call optimization**: ✅ Implemented. `eval_tail`/`apply_tail` thread a continuation `k` through tail-position expressions. Function-call recursion does not grow the OCaml stack. Verified at 100k+ depth in native builds. See Section 6.3.

9. **Exception/error handling**: how do errors interact with laziness and
   effects? An error during thunk evaluation memoizes the error?

10. **Self-hosting strategy**: v1 has a working meta-circular evaluator (`examples/meta.pp`). The bootstrap chain is: 12-line Makefile → OCaml bytecode interpreter → meta.pp → (v2) pp compiler in pp. The Makefile is an axiom, not a feature — it will be replaced by pp itself.

---

## 9. Success Criteria

**v1 is successful if**:

- A user can write a `.pp` file with pure and effectful expressions. ✅
- Pure expressions are automatically memoized within a session (content-addressed thunk store). ✅
- Cross-run persistent caching is deferred to v2. ⚠️
- Effectful expressions are capability-scoped (capabilities are first-class values; `effect` blocks scope them). ✅
- A multi-file build demonstrates the DAG emerges from evaluation (see `examples/build.pp`). ✅
- The REPL is usable for exploration. ✅
- The language can implement itself — a meta-circular evaluator runs correctly (see `examples/meta.pp`). ✅
- Modules compose via the same thunk + DAG mechanism as expressions — no separate module system. ✅
