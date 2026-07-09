# pp

pp is a lazy, cached, dynamic, capability-scoped Lisp.

Build systems, package managers, container builders and cluster orchestrators all manage the same thing: dependency graphs, execution order, caching, and side effects. We built separate tools for each. pp makes the language itself do all of it. Every expression is a thunk — the dependency graph is not something you author by hand. It emerges from evaluation. Thunks are content-addressed, so caching and deduplication are automatic across runs and across machines. The same mechanism handles compiling C, pulling a package, or running a migration — there is no separate cache layer.

Side effects need capabilities. A function cannot touch the network unless you give it permission. Capabilities are ordinary values: you compose them, restrict them to a subdirectory, pass them around, and audit exactly what authority each line of code holds.

## Quick start

You need OCaml (4.14 or later) and `ocamlc`.

```sh
make              # build
./pp              # REPL
./pp file.pp      # run a file
./pp --bytecode f # compile to bytecode first
./pp --diff f     # run both backends, compare output
./pp -e '(+ 1 2)' # evaluate one expression
```

## A tour

pp is a Lisp-1. Functions and variables live in the same namespace.

```clojure
;; values
42 3.14 "hello" true false nil :keyword 'symbol

;; arithmetic (variadic)
(+ 1 2 3)           ; 6
(* 2 3 4)           ; 24

;; conditionals
(if (> x 0) (print "positive") (print "not"))

;; bindings — parallel and lazy. y's value is a thunk that sees x.
(let [x 10
      y (+ x 20)]
  (print x y))

;; sequential bindings
(let* [x 10
       y (+ x 20)]
  (print x y))

;; functions
(def (square x) (* x x))
(fn (x) (* x x))    ; anonymous

;; do forces each expression, returns the last
(do (print "a") (print "b") 42)
```

### Laziness

Nothing runs until you ask for it.

```clojure
;; This thunk is never forced — the error never fires
(let [unused (delay (error "boom") 42)]
  (print "safe"))

;; Results are cached after the first force
(let [big (delay (do (print "working...") (* 100 200)))]
  (print (force big))   ; prints "working..." then 20000
  (print (force big)))  ; prints 20000, no recompute
```

Identical thunks with the same inputs, environment and capabilities are the
same thunk. Computed once, shared everywhere. This is how pp replaces build
caches, package registries and memoisation libraries.

### Effects and capabilities

Side effects need permission. Capabilities are first-class values.

```clojure
;; Read-only access to /etc
(effect :capabilities [(filesystem "/etc" :ro)]
  (print (perform read-file "/etc/hostname")))

;; Compose and restrict
(let [scope (cap-restrict (filesystem "/tmp" :rw) "myapp")]
  (effect :capabilities [scope]
    (perform write-file "/tmp/out.txt" "done")))
```

### Modules and islands

A module is a block of code whose exports are a value you can import.

```clojure
(let [m (module (def (double x) (* x 2))
                (def (triple x) (* x 3)))]
  (import m)
  (print (double 5)))  ; 10
```

An island is a module that lives somewhere else — a Git repository, a URL,
another machine. You write the URI and a version tag. On first use, pp fetches
it, pins the commit hash, and caches the result. On every later use, you get
the same pinned code with no network call and no lockfile to maintain.

```clojure
(island <github:cull-os/packages> "v2.1.0")
```

Where a module is for code you write, an island is for code someone else
wrote. Both produce a value you import with `import`. Both are
content-addressed, so two islands with different pins are different thunks.

Loading a file directly into your scope is a third option — useful during
development, but without the isolation or pinning that modules and islands
give you.

```clojure
(load "stdlib/list.pp")          ; merge into current scope
(load-module "examples/math.pp") ; isolated, returns exports
```

### Fexprs

Fexprs get their arguments unevaluated. They choose what to run.

```clojure
(def-fexpr (my-if condition then else)
  (if (force condition) (force then) (force else)))

(my-if true  (print "yes")  (print "no"))
```

### Type annotations

Annotations are optional. Annotated code is checked at runtime, when the
value is first forced. Errors report the definition site, not a stack trace
50 frames deep.

```clojure
(def (square x : int) : int (* x x))
(let [x : int 42] (print x))
```

### Ambient configuration

Configuration flows implicitly through the call tree. It is not threaded
through every function signature.

```clojure
(with-config {:host "db1" :port 5432}
  (print (config :host))              ; "db1"
  (print (config :missing "fallback"))) ; "fallback"
```

Configuration is distinct from capabilities. Config is data (what host to
connect to). Capabilities are authority (whether you may connect at all).

## Two backends

pp has two execution engines that produce identical output.

| Backend | How to use | What it does |
|---------|-----------|--------------|
| Tree-walker | `./pp file.pp` | Interprets the AST directly. The correctness baseline. |
| Bytecode VM | `./pp --bytecode file.pp` | Compiles to a stack VM with 31 opcodes. O(1) variable lookup, tail-call optimisation, serialisable bytecode. |

Use `./pp --diff file.pp` to run both and check they agree.

## Project map

```
src/
  types.ml           types — expr, value, thunk, opcode, frame
  reader.ml          lexer and parser
  hasher.ml          content-addressed hashing
  capabilities.ml    capability checks
  island.ml          island resolution and pin storage
  primitives.ml      built-in functions
  evaluator.ml       tree-walking evaluator (oracle)
  bytecode.ml        .ppc serialization and disassembly
  compiler.ml        AST to bytecode compiler
  vm.ml              stack virtual machine
  cache.ml           persistent bytecode cache
  repl.ml            read-eval-print loop
  main.ml            entry point
tests/               test files
examples/            example programs
stdlib/              standard library
```

## Requirements

OCaml 4.14 or later with `ocamlc`. For a native binary: `ocamlopt`.

```sh
make          # bytecode interpreter
make native   # native binary (./pp-native)
make test     # run tests under both backends
```
