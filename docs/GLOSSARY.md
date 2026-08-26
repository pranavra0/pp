# pp glossary

Short definitions of the vocabulary. See [DESIGN.md](DESIGN.md) for the
concept model, [SPEC.md](SPEC.md) for the semantics, and
[ARCHITECTURE.md](ARCHITECTURE.md) for the code structure.

The forms below are shown in `.pp`'s default brace surface. `.ppl` files,
and macros written with `quote`, `quasiquote`, or `defmacro`, use the
s-expression AST form instead: the same forms spelled `(node e)`,
`(defnode x e)`. See [SPEC.md](SPEC.md)'s lowering table for the full
brace-to-s-expression mapping.

### Core execution

- `thunk`: a suspended computation, created by a `let` binding, `delay`, or
  `node`. pp forces it on demand and memoizes it after the first force.
- `force`: the only execution primitive. It drives a thunk to a value, and
  leaves any other value unchanged. Where a force runs (this process,
  another process, or another machine) is a scheduler decision, never
  part of the language surface.
- `delay` and `force`: ephemeral, in-memory laziness for lazy sequences,
  never persisted, and distinct from `node`.
- strict, or call-by-value: a function's arguments are fully forced before
  its body runs. Node application is call-by-value with memoization, not
  call-by-need.
- demand-pruning: the surviving sense of "laziness" in pp: it builds only
  the nodes reachable from the root desired-state formula, and skips
  cached ones. This is not per-expression lazy demand.
- trampoline: the heap-allocated work queue used by `force` so deep chains do
  not overflow the host stack.

### Identity and caching

- content address: a value's identity is its content hash, computed with
  SHA-256: two computations with the same code and input values are the
  same computation. Caching, dedup, cutoff, and distribution all follow
  from this one idea.
- `env_hash`: the precomputed, incrementally built content hash of an
  environment, giving it constant-time identity.
- thunk key: ephemeral binding thunks use their expression and dynamic
  environment for in-process memoization. A persistent node instead uses
  `H(code, referenced free-variable values, argument values)`. Capabilities,
  configuration, and handlers stay out of node identity; observations of them
  belong in the validating trace.
- node: the unit of persistence and caching: a strict, content-addressed,
  cacheable graph node. `node { e }` caches across runs;
  [ARCHITECTURE.md](ARCHITECTURE.md) has the key construction. `node x { e }`
  binds the node thunk of `e`; an applied `node f(x) { … }` is currently just
  a named closure.
- trace: recorded during a node's evaluation: the `(cell, observed-hash)`
  pairs it read, its result hash, and an outcome. The store keys each node
  to a set of traces, and a cache hit succeeds if any stored trace still
  verifies against the world. File, tree, config, handler, probe, domain, and
  child-node cells are implemented. Successful and evaluative-failure
  outcomes share the same lifecycle.
- cutoff: if a recomputed result's hash equals the prior result's hash, pp
  does not dirty its dependents. Real today at node granularity: a dependent
  keyed on the recomputed value re-keys identically and hits (`tests/016`);
  child-result cells and push stabilization propagate through the same
  durable graph (`tests/032`, `tests/101`).

### The outside world

- cell: a stable identity that names a piece of
  the external world, plus its current observed value as a content hash.
  The observer is its only writer, and nodes compute over cells. Real
  today: `file:<path>`, `config:<key>`,
  `handler:<effect>`, `tool:<binary>`, `tree:<root>` (the coarse floor for
  `run`), `runtime:file:<path>`, `stat:<path>`, `env:<NAME>`, and `argv:`,
  plus `node:<key>`, `probe:<name>`, `sealed:<path>`, and
  `domain:<name>:<sub>` for child computations and registered domains.
- probe (real): the sanctioned way to depend on something nondeterministic
  (SPEC laws 37/38). `register-probe(name, observe-fn, read-cap)` registers
  an observer; `probe(name)` reads it anywhere. The observe function runs at
  most once per pass under exactly `read-cap`, recording only a
  capability-free `probe:<name>` cell. Never persisted: probe values live in
  the session and clear every pass — volatility, not cache material.
- sealed cell (real): a confidential read (SPEC law 39). `--grant
  secret:<path>` mints a `CapSecret`; a read covered by it, not by a
  filesystem grant, returns `VSealed` instead of `VString`. pp redacts a
  sealed value on print, excludes it from the store, and bans it at the
  node boundary like a capability; `unseal(v)` is the explicit, greppable
  way back to a `VString`.
- `run`, or the process effect: `perform run(CMD, ARG…)` executes an
  external command under `--grant process`, and returns
  `{"exit","out","err"}`. It is scripting-tier only because an ambient
  process cannot produce a complete validating trace (`tests/017`).
- `run-closed!`: executes immutable tool and input trees through the
  session's trusted executor. The provider classifies each request before
  execution. A node accepts only `Cacheable`; `Scripting_only` is rejected
  before work begins. The bundled Linux provider is scripting-only because
  clock, randomness, kernel behavior, and resource limits remain ambient.
  Provider policy is optional canonical pp data in the request; the core does
  not interpret it.
- sandbox, or per-node scratch: a throwaway directory that pp creates
  lazily for each node force and deletes when it completes (`slurp` and
  `write-file` resolve there, capability-free and
  unrecorded); an absolute path in a node write is an error instead (SPEC
  law 18): hygiene, not soundness; traces make the system sound.
- desired-state value: the pure, hashable value a program's root returns:
  `{path → blob-hash}` for a build, `{proc → spec}` for services. Real today:
  the filesystem domain as a canonical tree with raw blob identities
  (`pp --reconcile ROOT`; `tests/018`, `tests/023`) and the process domain as
  `{service-name → spec}` (`pp --supervise`; `tests/033`).
- reconciler: an `observe`/`diff`/`apply` triple of pp functions running under
  runtime-enforced discipline. The built-in filesystem domain
  (`pp --reconcile ROOT`) and process domain (`pp --supervise`) converge by
  content hash and journal intent and done (`tests/033`); equivalent pp-level
  policies are packaged as `stdlib/domain-fs.pp` and `stdlib/domain-proc.pp`
  for explicit registration. Desired state may not read itself (SPEC law 30).
  See
  [ARCHITECTURE.md](ARCHITECTURE.md) for the orchestration mechanics, and
  the fenced effect entry below for crash recovery.
- domain (real): a slice of external state under single ownership, such
  as an output subtree or a set of processes (the third-party example is
  `tests/046`). It is registered with
  `register-domain({:name :namespace :observe :diff :apply :write-cap})`.
  A probe (see above) is a domain with no write authority: one registry,
  owned by `Session`, serving both roles.

### Scheduling

- rebuilder (real): the one implementation of `force` over the store,
  verifying traces, applying cutoff on hash equality, and recording new
  traces on a miss. Both schedulers share it.
- scheduler: a result-transparent host service that dispatches node misses.
  `serial`, `parallel:N`, `race:N`, and `remote:MEMBER` share one node
  rebuilder and never enter computation identity.
  A pp runtime manifest may select the built-in local handlers; arbitrary
  remote placement remains a trusted host service. A custom pp scheduler may
  only return data-closed job batches; the runtime executes them.
- pull watch: reconstructs the demanded graph and validates traces on each
  pass.
- push stabilization: uses the reverse trace index and child-result edges to
  dirty only affected in-memory nodes (`--watch --stabilize`).

### Authority

- capability: an authority token, a ceiling on what a computation may
  touch, unforgeable and minted only at the root. User code can narrow it
  but never construct one; it is not an ordering mechanism. The CLI is
  the sole minter of capabilities: the powerbox hands its full authority
  set to `main` via `--grant`.
- `cap-restrict` and `cap-compose`: the only capability operations user
  code can perform: narrowing a capability's scope, or combining two
  already held.
- `CapNetwork`, `http-get`, and `http-post` (real): a
  `CapNetwork {host; port option}`, granted with
  `--grant net:<host>[:<port>]` and wildcarded with `host = "*"`,
  authorizes `perform http-get(url)` and `perform http-post(url, body)`.
  These fork `curl` through the runtime process provider and return
  `{"status" INT "body" STRING}`. pp bans them inside node bodies:
  a network call is not convergent; nondeterminism belongs to `probe`.

### Effects

- effect, or `perform`: a named operation, such as `read-file` or `log`,
  dispatched dynamically. pp resolves it against the handler stack; an
  unhandled effect falls back to a builtin.
- handler, or `with-handler`: an installation, active for a dynamic
  extent, that intercepts matching `perform` calls. pp restores the
  previous handler on normal return, on exception, and on tail call.
- result-transparent handler: a scheduling or placement handler
  that may change only where or when work runs, never its observable
  results. The installed scheduler is this class and is left out of keys and
  traces.
- semantic handler: a handler that changes results, such as a mock
  `read-file` or fault injection. It records a synthetic
  `handler:<effect>` cell into the trace, so swapping the handler
  correctly invalidates the cache (`tests/015`). pp treats every user
  handler as semantic today; a finer per-argument distinction is planned
  (SPEC law 26).
- fenced effect: a non-convergent, irreversible action, such as email or a
  card charge. pp bars it from node bodies, and instead
  surfaces it at the scripting tier as `fenced(KIND, SPEC-MAP)`, sequenced
  only during reconciliation, with an intent-and-done journal and at most
  one run per pass. If a crash leaves an entry with unknown status,
  `--fenced-policy retry`, `abort`, or `ask` resolves it; pp never retries
  silently (SPEC law 31, `tests/034`).

### Language surface

- the two tiers: the node tier, pure, strict, cached, and distributable;
  and the scripting tier, dynamic, imperative, uncached glue for the REPL.
  Purity is the price of a cache hit; caching is opt-in per node.
- mutual `let`: every binding is in scope in every right-hand side and in
  the body, regardless of position. `let*` adds explicit sequential
  ordering as sugar on top.
- module, or `import`: code whose exports are a value another module can
  import.
- island: a module that lives elsewhere, in a local directory or a git
  repository, referenced by a URI and pinned inline by the canonical
  content hash of its source tree, for example
  `island("github:owner/repo#ref", "64-hex-pin")`. The pin is part of the
  code hash: a pinned form denotes the same bytes wherever pasted, and
  any enclosing node is keyed on it too (SPEC law 20). An unpinned form
  is a hard error; fetching is opt-in runtime
  authority, through `--fetch-islands`, never ambient (SPEC law 24). See
  [ARCHITECTURE.md](ARCHITECTURE.md) for resolution and `--update`.
- fexpr (cut): an operative that receives unevaluated arguments. pp
  removed this; metaprogramming instead runs through total `quote`, a shared
  expansion point, before the evaluator sees the form, preserving
  byte-identity (SPEC law 36).

### Process and testing

- engine: the single tree-walking evaluator implemented by the saved Lisp image.
- testing: expected-output programs, property sweeps, and shell scenarios that
  assert identical observable behavior across supported process boundaries.
