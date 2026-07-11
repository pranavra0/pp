# pp ARCHITECTURE — the moving parts

How a pp program flows through the system, and what each source file is
responsible for. For term definitions see [GLOSSARY.md](GLOSSARY.md); for the
semantics these parts must honor see [SPEC.md](SPEC.md).

## The pipeline

```
  source text
      │
      ▼
  ┌────────┐   expr (AST)        ┌──────────────────────┐
  │ reader │ ──────────────────► │ tree-walker          │  ← the oracle
  └────────┘        │            │ (evaluator.ml)       │
                    │            └──────────────────────┘
                    │                       ▲
                    │            ┌──────────┴───────────┐
                    │  expr      │   shared runtime     │  handler stack,
                    └──────────► │   state (runtime.ml) │  capabilities,
                       │         └──────────┬───────────┘  config, thunk store
                       ▼                    ▼
                 ┌──────────┐  bytecode  ┌──────────────┐
                 │ compiler │ ─────────► │ bytecode VM  │
                 │          │            │ (vm.ml)      │
                 └──────────┘            └──────────────┘
```

One front end, two back ends. The **reader** turns source into an `expr` AST.
That AST is then either interpreted directly by the **tree-walker** or compiled
to bytecode and run on the **VM**. Both back ends share one pool of runtime
state and one set of data-type and hashing definitions, so they can be run
against each other (`--diff`, the fuzzer) and must agree.

Why two back ends: the tree-walker is the simple, obviously-correct reference —
the **oracle**. The VM is the faster execution model. Any disagreement between
them is a bug, caught by differential testing ([TESTING.md](TESTING.md)). This
is the single most valuable correctness asset in the project.

## The data model (`types.ml`)

Everything hangs off a few mutually-recursive types:

- **`expr`** — the AST. Literals, symbols, `if`, `let`/`let*`, `fn`, application,
  `quote`/`force`/`delay`, `effect`/`perform`/`with-handler`, `node`/`defnode`,
  `module`/`import`/`load`, `island`, `with-config`/`config`, type annotations,
  source locations.
- **`value`** — the runtime representation: nil, bool, int, float, string,
  keyword, symbol, pair, vector, map, set, **closure**, builtin, **capability**,
  **thunk**, module-env-map, bytecode.
- **`thunk`** — a suspended computation with a mutable status
  (`Unevaluated`/`Evaluating`/`Evaluated`), a precomputed content hash, its
  expression and captured environment, and a `persist` flag (true for `node`,
  false for `let`/`delay`).
- **`env`** — an environment node: a list of `(name, value)` bindings plus a
  **precomputed `env_hash`** and a stable id. The hash is computed once,
  incrementally, and never changes — this is what makes environment identity
  O(1) instead of a recursive traversal.
- **`closure`** — captured params + body + env (tree-walker), or bytecode
  offset + captured frames (VM).
- **`capability`** — an authority token (filesystem/network/process/compose/
  restrict/none).
- **`frame`** — the VM's mutable, growable local-variable array.

`types.ml` also holds the **content-addressing** logic: `hash_value`,
`hash_expr`, `hash_capability`, and the incremental `env_hash` construction.
This is load-bearing — see below.

## Content-addressing (the heart)

Identity in pp is a content hash (SHA-256, via `hasher.ml` → Cryptokit).

- **`env_hash`** is built incrementally: extending an env with `(name, value)`
  hashes `(parent_hash, name, hash_value value)`. So an environment's identity
  folds in the hashes of everything bound in it.
- A **thunk's key** = `hash(expr, env_hash, capabilities, config, handlers)`.
  Two thunks with the same key *are* the same thunk — the tree-walker memoizes
  them in a shared `thunk_store`, so equal computations run once.
- A **closure's** hash folds in its captured `env_hash` (so different captures
  give different identities — this is the D6 fix; see [STATUS.md](STATUS.md)).

The subtlety that has bitten twice: the key must include *everything the
computation depends on*. Omitting the captured environment (D6) or the ambient
handler stack (D17) let distinct computations collide in `thunk_store` and
return stale results. Both are fixed and pinned by `tests/009`.

This in-memory dedup is the same idea as the **persistent** store, now live for
`(node e)` (see "The persistent node cache" below): keyed soundly and written to
`~/.pp/store` so cache hits survive across runs and machines
([ROADMAP.md](ROADMAP.md), DESIGN Q8).

## Evaluation and `force`

A `let` binding or `delay` produces a **thunk**; `force` drives it to a value.
`force` memoizes (`Evaluating` → `Evaluated`), detects self-reference
(infinite-recursion error), and switches from the native OCaml stack to a
heap-allocated **trampoline** past a depth threshold so deep chains don't
overflow. Application is **strict** (call-by-value): a function's arguments are
forced before its body runs. Tail calls run in constant stack in both back ends
(CPS continuations in the tree-walker; a `TAIL_CALL` frame-swap in the VM).

## Effects and capabilities

- **Effects**: `perform` looks up a dynamic **handler stack**; unhandled effects
  fall back to builtins (`read-file`/`write-file`/`log`). `with-handler`,
  `effect`, and `with-config` push/pop that state and restore it on normal
  return, exception, and tail call — in both back ends.
- **Capabilities** (`capabilities.ml`): authority tokens for filesystem/network/
  process. They enter **only** at the root via `--grant` (parsed in `main.ml`
  into the initial capability set); user code cannot construct them, only
  `cap-restrict`/`cap-compose` to narrow or union. Filesystem reads/writes and
  `slurp` are checked at perform time with full-path, component-aware scope.

## The VM path (`compiler.ml` + `vm.ml` + `bytecode.ml`)

`compiler.ml` lowers the `expr` AST to a flat array of **31 opcodes** operating
on a stack machine with `LOAD_LOCAL (depth, slot)` / `STORE_LOCAL slot` against
mutable **frames**. Locals get O(1) indexed access instead of name lookup. The
compiler tracks a compile-time environment (`cenv`) to resolve names to
`(depth, slot)`; a subtlety here — reusing a slot across binding lifetimes while
a captured frame is still live — was the D21 bug (fixed, pinned by `tests/008`).
`vm.ml` executes the opcodes, creating thunks (`MAKE_THUNK`) and closures
(`MAKE_CLOSURE`) that capture live frames. `bytecode.ml` can serialize bytecode
to `.ppc` — complete but currently **dead code**; the persistent value/trace
store supersedes it. The VM compiles `ENode` to a dedicated `MAKE_NODE` opcode
(carrying the body AST + free-var descriptors) and forces it through the same
persistent store as the tree-walker (D7 closed; see below).

## Shared state (`runtime.ml`)

Both back ends read and write one set of module-global refs: the handler stack,
the current capability set, the config stack, the thunk store, the trace-frame
stack (the collector nodes push while forcing, so world-reads land in the right
trace), and the initial `--grant` capabilities. Consolidating these into one `Runtime` module (done in
Phase 0) removed a class of parity bugs where the two back ends kept separate
copies. It is also what a future process-pool parallelism (Phase 3) must
refactor, since global mutable state can't be shared across worker processes.

## The persistent node cache (`store.ml`)

The persistent CAS (`~/.pp/store/objects` + `traces`) is **wired into the
tree-walker's `force`** for `(node e)` thunks. On a miss, `force` pushes a trace
frame, runs the node, and — because `slurp`/`read-file` call
`Store.record_file_read` — collects the `(file-cell, content-hash)` reads it
made; it then stores the result blob (keyed by result hash) and appends a trace
to the node key's SET. On the next force, `Store.hit` re-observes each recorded
cell and serves the stored result only if some trace still verifies, so a
changed input forces a recompute instead of serving stale data. Reads propagate
to every enclosing node frame, giving parents a transitive read closure. This is
pp's dynamic answer to Haskell's static IO type (SPEC LAW 21). The node key is
LAW 20 — `node_key_of` hashes the code structure plus the value hashes of the
free variables the node references (via `Types.free_vars`, forced call-by-value),
excluding the whole-env hash and the capability set. A node that raises a
`Failure` stores a *failing* trace and re-serves the same error until a recorded
read changes (LAW 28), and a raising thunk resets off `Evaluating` (D16). A hit
is served only if the caller is authorized to read the trace's whole closure
(`Store.hit ~authorized` + `cell_authorized`; LAW 23b), and a capability denial
(`Capability_error`) is never memoized. **The VM shares this store** (D7 closed):
`MAKE_NODE` records the free-var descriptors the compiler resolved, `vm_node_key`
rebuilds the LAW 20 key from the captured frames/globals (byte-identical to the
tree-walker for data free vars, so entries are shared), and `force_node_thunk`
runs the same hit/verify/trace/failure/cap logic. With `pp --watch --stabilize`,
the reverse-edge index (`Store.build_reverse_index`) maps changed cells to dirty node keys,
`Stabilize.reset_dirty` marks only those in-memory thunks `Unevaluated`, and `Runtime.keep_thunks`
keeps the `thunk_store` alive across watch iterations so clean nodes remain `Evaluated` and skip
`Store.hit` entirely. Still narrow: file cells only, config/handlers still folded into the key,
no inline-nested cutoff.

## Not yet wired

- **`island.ml`** — island resolution/pinning exists in stub form; `island`
  currently does a local file read and ignores the pin (D2).

## File-by-file responsibilities

| File | Role |
|---|---|
| `src/types.ml` | All core types (`expr`/`value`/`thunk`/`env`/`closure`/`capability`/`frame`/opcodes) **and** content-addressed hashing. The foundation. |
| `src/hasher.ml` | Thin re-export of the hashing functions from `types.ml`. |
| `src/reader.ml` | Lexer + parser: source text → `expr` AST. Also desugars `and`/`or`, quasiquote. |
| `src/runtime.ml` | Shared mutable runtime state used by both back ends. |
| `src/evaluator.ml` | The tree-walking evaluator — the oracle. `force`, `eval`, effects, the `thunk_store`. |
| `src/compiler.ml` | `expr` AST → bytecode; compile-time environment / slot allocation. |
| `src/vm.ml` | The bytecode stack machine. |
| `src/bytecode.ml` | `.ppc` serialization + disassembly (currently dead). |
| `src/capabilities.ml` | Capability scope checks (path-component-aware). |
| `src/primitives.ml` | Built-in functions and the initial environment. |
| `src/island.ml` | Island URI → pin → local path resolution (stub). |
| `src/store.ml` | Persistent content-addressed store + verifying traces; wired into the tree-walker's `force` for `(node e)`. |
| `src/reconciler.ml` | Filesystem-domain reconciler v1 (Q4/LAW 30). |
| `src/supervisor.ml` | Process-domain reconciler (Phase 2): desired process map → start/stop/restart on spec-hash change, zombie reaping, intent/done journal. |
| `src/repl.ml` | REPL and file-execution helpers for both back ends. |
| `src/stabilize.ml` | Push scheduler: side-table (`node_key` → `thunk`) + dirty reset; the reverse-edge index is in `store.ml`. |
| `src/main.ml` | CLI entry point: flag parsing, `--grant`, dispatch to REPL/file/`-e`/`--diff`. |
| `tools/fuzz.ml` | The differential fuzzer ([TESTING.md](TESTING.md)). |

## CLI surface (`main.ml`)

```
pp                       start the REPL (tree-walker)
pp <file.pp>             run a file (tree-walker)
pp --bytecode <file>     run via the bytecode VM
pp --diff <file>         run both back ends, exit 1 if returned values differ
pp -e '<expr>'           evaluate one expression
pp --grant <spec>        grant a capability (fs:/path:ro|rw|wo, net:<proto>, process)
pp --once <file.pp>      run once and exit (explicit; default behavior)
pp --watch <file.pp>     run, then watch cell changes and re-evaluate (polling)
pp --watch-interval <s>  poll interval for --watch (default 1.0)
pp --watch --stabilize <file.pp>  watch with push stabilize (dirty-propagation)
pp --supervise <file.pp>  reconcile program's process-map value (use with --watch)
pp graph <file.pp>       print the cell→node dependency graph from traces
pp --update              enable island pin-update mode (stub)
pp --version | --help
```
