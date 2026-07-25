# pp glossary

Short definitions of the vocabulary. See [DESIGN.md](DESIGN.md) for the
concept model, [SPEC.md](SPEC.md) for the semantics, and
[ARCHITECTURE.md](ARCHITECTURE.md) for the code structure.

Terms marked (planned) do not exist in the code yet; see the status table in
[SPEC.md](SPEC.md) for current implementation limits.

The forms below are shown in `.pp`'s default brace surface. `.ppl` files,
and macros written with `quote`, `quasiquote`, or `defmacro`, use the
s-expression AST form instead: the same forms spelled `(node e)`,
`(defnode x e)`. See [SPEC.md](SPEC.md)'s lowering table for the full
brace-to-s-expression mapping.

### Core execution

- `thunk`: a suspended computation, created by a `let` binding, `delay`, or
  `node`. pp forces it on demand and memoizes it after the first force.
- `force`: the only execution primitive. It drives a thunk to a value, and
  leaves any other value unchanged. Where a force runs — this process,
  another process, or another machine — is a scheduler decision, never
  part of the language surface.
- `delay` and `force`: ephemeral, in-memory laziness for lazy sequences,
  never persisted, and distinct from `node`.
- strict, or call-by-value: a function's arguments are fully forced before
  its body runs. Node application is call-by-value with memoization, not
  call-by-need.
- demand-pruning: the surviving sense of "laziness" in pp: it builds only
  the nodes reachable from the root desired-state formula, and skips
  cached ones. This is not per-expression lazy demand.
- trampoline: the heap-allocated work queue that `force` switches to past
  a depth threshold, so deep chains do not overflow the OCaml stack.

### Identity and caching

- content address: a value's identity is its content hash, computed with
  SHA-256: two computations with the same code and input values are the
  same computation. Caching, dedup, cutoff, and distribution all follow
  from this one idea.
- `env_hash`: the precomputed, incrementally built content hash of an
  environment, giving it constant-time identity.
- thunk key: `hash(expr, env_hash, capabilities, config, handlers)`. Equal
  keys mean the same memoized thunk. The key must include everything the
  computation depends on, or distinct computations collide — leaving out
  the captured environment or the ambient handler stack once did exactly
  that; both are now fixed.
- node: the unit of persistence and caching: a strict, content-addressed,
  cacheable graph node. `node { e }` is wired into `force` in both back
  ends and caches across runs; see [ARCHITECTURE.md](ARCHITECTURE.md) for
  the key construction. `node x { e }` binds the node thunk of `e` (`let
  x = node { e }`); an applied `node f(x) { … }` is currently just a named
  closure, distinct from a `let` or argument thunk.
- trace: recorded during a node's evaluation: the `(cell, observed-hash)`
  pairs it read, its result hash, and an outcome. The store keys each node
  to a set of traces, and a cache hit succeeds if any stored trace still
  verifies against the world. Partly real today: file, config, and
  handler cells, plus ok- and failed-outcomes, where a raising node
  re-serves its failing trace until a read changes; child-keys and other
  kinds are still planned.
- cutoff (partly real): if a recomputed result's hash equals the prior
  result's hash, pp does not dirty its dependents. This works today at
  node granularity: a dependent node whose free variable is the
  recomputed node's value re-keys identically and hits the cache
  (`tests/016`). Cutoff for
  inline-nested nodes, and push-mode dirty-propagation over the
  reverse-edge graph, are still planned.
  (`objects/`, `traces/`), accessed through repositories and cache policy, used by the engine for `node { e }`
  thunks.

### The outside world

- cell, or `Var` (partly real): a stable identity that names a piece of
  the external world, plus its current observed value as a content hash.
  The observer is its only writer, and nodes compute over cells. Real
  today: `file:<path>`, `config:<key>`,
  `handler:<effect>`, `tool:<binary>`, `tree:<root>` (the coarse floor for
  `run`), `runtime:file:<path>`, `stat:<path>`, `env:<NAME>`, and `argv:`,
  plus `probe:<name>`, `sealed:<path>`, and `domain:<name>:<sub>` for
  registered domains (see below).
- probe (real): the sanctioned way to depend on something nondeterministic
  (SPEC laws 37 and 38). A script-tier call to
  `register-probe(name, observe-fn, read-cap)` registers an observer;
  `probe(name)` reads it from anywhere. The observe function runs at most
  once per pass, under exactly `read-cap`, recording only a
  capability-free `probe:<name>` cell. pp never persists this:
  Probe values live only in the session and clear every pass, since a
  probe is volatility, not something to cache.
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
- sandbox, or per-node scratch: a throwaway directory that pp creates
  lazily for each node force and deletes when it completes (`slurp` and
  `write-file` resolve there, capability-free and
  unrecorded); an absolute path in a node write is an error instead (SPEC
  law 18) — hygiene, not soundness; traces make the system sound.
- desired-state value (partly real): the pure, hashable value a pp
  program's root returns: `{path → blob-hash}` for a build,
  `{proc → spec}` for services. Real today for the filesystem domain as
  `{relative-path → content}` (an inline string or raw identity from
  `blob(S)`), consumed by `pp --reconcile ROOT`
  (`tests/018`, `tests/023`); and for the process domain as
  `{service-name → spec}`, consumed by `pp --supervise` (`tests/033`).
- reconciler: retired as a proper noun; there is no `reconciler.ml` any
  more. A domain is now an `observe`/`diff`/`apply` triple of pp functions
  running under core-enforced discipline (`src/runtime/domains.ml`), not a
  privileged OCaml module. The filesystem domain (`stdlib/domain-fs.pp`,
  `pp --reconcile ROOT`) and the process domain (`stdlib/domain-proc.pp`,
  `pp --supervise`) are both live, converging by content hash and
  journaling intent and done (`tests/033`); desired state may not read
  itself (stratification, SPEC law 30). See
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
- pull scheduler (real): suspending. It forces the root and recurses on
  demand, for builds and provisioning (`--once`). This is the current
  default and only scheduler: `--watch` runs it in a polling loop.
- push scheduler (partly real): dirty-propagating over the reverse-edge
  index derived from traces, re-forcing only dirty nodes. Meant for
  services, through `--watch`; true push-mode `stabilize`, with real
  dirty-propagation, is still planned (see pull scheduler, above, for
  what `--watch` runs today).

### Authority

- capability: an authority token, a ceiling on what a computation may
  touch, unforgeable and minted only at the root. User code can narrow it
  but never construct one; it is not an ordering mechanism.
- powerbox: the full authority set the CLI hands to `main` via `--grant`
  — the sole minter of capabilities.
- `cap-restrict` and `cap-compose`: the only capability operations user
  code can perform: narrowing a capability's scope, or combining two
  already held.
- `CapNetwork`, `http-get`, and `http-post` (real): a
  `CapNetwork {host; port option}`, granted with
  `--grant net:<host>[:<port>]` and wildcarded with `host = "*"`,
  authorizes `perform http-get(url)` and `perform http-post(url, body)`.
  These fork `curl` instead of adding OCaml networking code, and return
  `{"status" INT "body" STRING}`. pp bans them inside node bodies:
  a network call is not convergent; nondeterminism belongs to `probe`.

### Effects

- effect, or `perform`: a named operation, such as `read-file` or `log`,
  dispatched dynamically. pp resolves it against the handler stack; an
  unhandled effect falls back to a builtin.
- handler, or `with-handler`: an installation, active for a dynamic
  extent, that intercepts matching `perform` calls. pp restores the
  previous handler on normal return, on exception, and on tail call.
- result-transparent handler (planned): a scheduling or placement handler
  that may change only where or when work runs, never its observable
  results. It is left out of thunk keys.
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
  removed this; metaprogramming instead runs through total `quote`,
  the tree-walker at one shared expansion point, before the evaluator's own
  machinery — `hash_expr` or the evaluator — sees the form, so byte-identity
  is preserved (SPEC law 36).
### Process and testing

- engine: the tree-walking evaluator (`evaluator.ml`), pp's single execution
  engine.
- oracle: the tree-walker, taken as ground truth in tests. It can still be
  wrong — see the thunk key entry above and the status table in [SPEC.md](SPEC.md)
  for its now-fixed key bugs.
- metamorphic testing: generating semantics-preserving program twins and
  asserting identical output — pp's core correctness check, enforced by
  `dune runtest` and the fuzzer (see [TESTING.md](TESTING.md)).
</content>
