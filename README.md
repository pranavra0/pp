# pp

pp is a content-addressed, capability-scoped Lisp — and an experiment in
collapsing build systems, package managers, and orchestrators into one
substrate.

Build systems, package managers, container builders, and cluster orchestrators
all manage the same thing: dependency graphs, execution order, caching, and
side effects. We build separate tools for each. pp's thesis is that the
*language* can be that substrate. Every value has a content hash, so two
computations with the same code and inputs *are* the same computation —
caching, deduplication, and early cutoff are corollaries of identity, not a
bolted-on cache layer. Side effects require **capabilities**: unforgeable
authority tokens, minted only at the root, that a computation must hold to touch
the world.

> **Status:** pp is early. The interpreter, two back ends, effects,
> capabilities, and in-memory content-addressed dedup work today. **Phase 1
> is closed: pp is an incremental hermetic build engine**, and the claim is
> executable — a 101-TU C project builds through a real `build.pp` with
> every exit criterion journal-proven (null rebuild = 0 processes in ~130ms;
> touch = 0 recompiles; one edit = exactly compile+link; `rm -rf build/` =
> byte-identical restore with 0 tool re-runs; comment-only header edit cuts
> off the link; authority gates cache hits transitively), pp builds itself,
> and **Lua 5.4.7** builds/caches/restores the same way
> (`tests/024`, `scripts/build-self.sh`, `scripts/build-lua.sh`). Under the
> hood: verifying traces over file/config/handler/tool/tree/loader cells,
> LAW-20 keying, per-run world snapshots (CAS ingest), per-node sandboxes,
> depfile-refined process tracing, a journaled single-writer reconciler, and
> `pp why` / `--no-cache` / `--check` auditability. Next: the Phase-2 push
> scheduler — see [docs/STATUS.md](docs/STATUS.md) for exactly what is real
> and [docs/ROADMAP.md](docs/ROADMAP.md) for where it's going.

## Documentation

| Doc | What it is |
|---|---|
| [docs/manual/](docs/manual/) | **The reference manual** — a Lua/Zig-style guide to the language, built by pp itself (`scripts/build-manual.sh`), with every example executed by pp. **Start here to learn pp.** |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The moving parts: how a program flows through the reader, the two back ends, and the shared runtime. **Start here to understand the code.** |
| [docs/GLOSSARY.md](docs/GLOSSARY.md) | One-line definitions of the vocabulary. |
| [docs/SPEC.md](docs/SPEC.md) | The normative semantic laws, each with a status marker. |
| [docs/STATUS.md](docs/STATUS.md) | What works today + the D1–D21 discrepancy ledger. |
| [docs/ROADMAP.md](docs/ROADMAP.md) | The phased plan with falsifiable exit criteria, plus the maturity track (ergonomics, stdlib, portability, releases). |
| [docs/DESIGN.md](docs/DESIGN.md) | Why it's shaped this way: principles, the Q1–Q12 decisions, prior art. |
| [docs/TESTING.md](docs/TESTING.md) | The differential test suite and fuzzer. |
| [AGENTS.md](AGENTS.md) | Orientation for AI coding agents. |

## Quick start

Requires [opam](https://opam.ocaml.org/) with OCaml, `dune`, and `cryptokit`.
[direnv](https://direnv.net/) is optional but recommended.

```sh
opam install dune cryptokit
dune build            # builds the interpreter and the fuzzer; targets bin/pp
```

With direnv, run `direnv allow` once and then `dune`/`pp` are on your PATH
directly. Without it, use `dune exec pp --` or the `bin/pp` symlink:

```sh
pp                    # REPL
pp file.pp            # run a file
pp --bytecode file.pp # run via the bytecode VM instead of the tree-walker
pp --diff file.pp     # run both back ends, fail if their results differ
pp -e '(+ 1 2)'       # evaluate one expression
```

Run the tests with `dune runtest` (see [docs/TESTING.md](docs/TESTING.md)).

## A tour

pp is a Lisp-1: functions and variables share one namespace.

```clojure
;; values
42 3.14 "hello" true false nil :keyword 'symbol

;; arithmetic and comparison (variadic)
(+ 1 2 3)                 ; 6
(if (> 5 0) "pos" "neg")  ; "pos"

;; bindings are MUTUAL: every binding sees every other, position-free.
(let [y (+ x 1)
      x 1]
  y)                      ; 2  — y sees x though x is written second

;; let* is explicit sequential sugar
(let* [x 1
       x (+ x 1)]
  x)                      ; 2

;; functions
(def (square x) (* x x))
(square 7)                ; 49
((fn (x) (* x x)) 7)      ; 49

;; value bindings: (def x v) evaluates v at definition time, binds the value
(def answer (* 6 7))
answer                    ; 42

;; parameter and return type annotations are checked when the body runs
(def (inc n : int) : int (+ n 1))
(inc "oops")              ; type mismatch: expected int, got "oops" at …

;; do sequences effects and returns the last value
(do (print "a") (print "b") 42)
```

### Laziness

`delay` builds an unforced thunk; `force` runs it, and the result is memoized.

```clojure
(let [t (delay (do (print "working...") (* 100 200)))]
  (print (force t))     ; prints "working..." then 20000
  (print (force t)))    ; prints 20000 — no recompute
```

Identical thunks with the same inputs, environment, and capabilities are the
*same* thunk: computed once, shared everywhere. Wrapping a computation in
`(node e)` extends this *across runs*: its result is cached in `~/.pp/store` and
reused by a later process, while a **verifying trace** records the files it read
so a cache hit is re-checked against the world and never serves stale data.

### Effects and capabilities

Side effects go through `perform`; capabilities are the authority to run them,
and they enter only via `--grant` on the command line.

```clojure
;; perform dispatches to the ambient handler
(with-handler [ask (fn (q) 42)]
  (perform ask "the answer?"))     ; 42

;; reading a file requires a granted filesystem capability:
;;   pp --grant fs:/etc:ro read-hostname.pp
(print (perform read-file "/etc/hostname"))
```

User code cannot *construct* a capability — only narrow one it already holds
with `cap-restrict` / `cap-compose`. Authority is a ceiling, checked at every
`perform`.

### Modules

A module is a block of code whose exports are a value you `import`.

```clojure
(let [m (module (def (double x) (* x 2)))]
  (import m)
  (double 21))          ; 42
```

`(load "stdlib/list.pp")` merges a file into the current scope;
`(load-module "f.pp")` loads it isolated and returns its exports. **Islands** —
modules pinned by content hash and inlined into the code — resolve from a
`file:`, `git:`, or URL source; `pp --update` derives a pin and writes it into
the source, and the pinned tree is content-addressed so it resolves
reproducibly (see D2 in [docs/STATUS.md](docs/STATUS.md)).

### Type annotations and config

Annotations are optional and checked at force time; config is ambient,
dynamically-scoped data (distinct from capabilities, which are authority).

```clojure
(def (square x : int) : int (* x x))
(square 7)                            ; 49

(with-config {:host "db1"}
  (config :host))                     ; "db1"
```

## Two back ends

pp has two execution engines that must produce identical output:

| Back end | How | What it is |
|---|---|---|
| Tree-walker | `pp file.pp` | Interprets the AST directly. The correctness oracle. |
| Bytecode VM | `pp --bytecode file.pp` | Compiles to a 31-opcode stack machine: O(1) locals, tail-call optimization. |

`pp --diff file.pp` runs both and fails if they disagree. Divergences are the
main thing pp's fuzzer hunts for — see [docs/TESTING.md](docs/TESTING.md).
