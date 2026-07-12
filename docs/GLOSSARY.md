# pp GLOSSARY

One-line definitions of the vocabulary. Deeper treatment: the concept model is
in [DESIGN.md](DESIGN.md), the semantics in [SPEC.md](SPEC.md), the code
structure in [ARCHITECTURE.md](ARCHITECTURE.md).

Terms marked *(planned)* do not exist in the code yet — see
[STATUS.md](STATUS.md) for what is real today.

### Core execution

- **thunk** — a suspended computation. Created by `let` bindings, `delay`, and
  `node`. Forced on demand, memoized after the first force.
- **`force`** — the only execution primitive: drive a thunk to a value.
  Idempotent on non-thunks. *Where* a force runs (this core, another process,
  another machine) is a scheduler decision, never language surface.
- **`delay` / `force`** — ephemeral, in-memory laziness (lazy sequences).
  Never persisted. Distinct from `node`.
- **strict / call-by-value** — a function's arguments are fully forced before
  its body runs. pp node application is call-by-value with memoization, not
  call-by-need.
- **demand-pruning** — the surviving sense of "laziness": only the nodes
  reachable from the root desired-state formula are built; cached ones are
  skipped. Not per-expression lazy demand.
- **trampoline** — the heap-allocated work queue `force` switches to past a
  depth threshold, so deep chains don't overflow the OCaml stack.

### Identity and caching

- **content address** — a value's identity *is* its content hash (SHA-256).
  Two computations with the same code and input values are the same computation.
  Caching, dedup, cutoff, and distribution are corollaries of this.
- **`env_hash`** — the precomputed, incrementally-built content hash of an
  environment. Gives O(1) environment identity.
- **thunk key** — `hash(expr, env_hash, capabilities, config, handlers)`. Equal
  keys ⇒ the same memoized thunk. Must include everything the computation
  depends on, or distinct computations collide (the D6/D17 bug class).
- **node** — the unit of persistence and caching: a strict, content-addressed,
  cacheable graph node. *Partly real:* `(node e)` is wired into `force` in **both
  backends** and caches across runs, keyed the LAW-20 way —
  `H(code-structure ‖ free-var value-hashes)`, whole-env and caps excluded
  (`node_key_of` / `vm_node_key`), with matching keys so the backends share the
  store. `(defnode x e)` binds the node thunk of `e` (i.e. `(def x (node e))`);
  applied `(defnode (f x) …)` is currently a named closure. Distinct from a
  `let`/argument thunk.
- **trace** — recorded during a node's evaluation: the `(cell, observed-hash)`
  pairs it read, its result hash, and an outcome. The store keys each node to a
  **set** of traces; a cache hit succeeds if any stored trace still verifies
  against the world. *Partly real:* file-read cells, config cells
  (`config:<key>`, absence included), handler cells (`handler:<effect>` —
  which handler, if any, intercepted a perform), ok-outcomes, and
  failed-outcomes (a raising node stores a failing trace re-served until a read
  changes — LAW 28) are recorded and re-verified today; child-keys and other
  cell kinds are *(planned)*.
- **cutoff** *(partly real)* — if a recomputed result's hash equals the prior
  result's hash, dependents are not dirtied. Content-addressing makes cutoff
  free and exact. Real today at node granularity via LAW-20 keying: a dependent
  node whose free variable is the recomputed node's *value* re-keys identically
  and hits (`tests/016`). Cutoff for inline-nested nodes and push-mode
  dirty-propagation (reverse-edge graph) are Phase 2.
- **store** — the persistent content-addressed store at `~/.pp/store`
  (`objects/`, `traces/`), `store.ml`. **Live in both backends** for `(node e)`
  thunks (D7 closed).

### The outside world

- **cell / `Var`** *(partly real)* — a stable identity naming a piece of the
  external world plus its current observed value as a content hash. The
  observer is its only writer. Cells are the *inputs*; nodes are the
  *computations* over them. Real today: `file:<path>`, `config:<key>`,
  `handler:<effect>`, `tool:<binary>`, `tree:<root>` (whole-tree hash — the Q2
  coarse floor for `run`), `runtime:file:<path>` (a loader read —
  validity-bearing but authority-exempt, Q6), `stat:<path>` (a file
  predicate's presence/kind observation — `file-exists?`/`dir?`, fs-read
  authority), `env:<NAME>` (environment variable, absence included), and
  `argv:` (the program-argument list after `--`). M4 (real): `probe:<name>`
  (an observer-written volatile cell — see **probe** below) and
  `sealed:<path>` (a confidential read's bytes-hash — see **sealed cell**
  below). Planned: `glob:`, `domain:<name>:<sub>` (Q13 third-party domains).
- **probe** *(real, M4)* — the sanctioned nondeterministic dependency (SPEC
  LAW 37/38). `(register-probe name observe-fn read-cap)` (script-tier) then
  `(probe name)` (anywhere): the observe-fn runs at most once per pass,
  OUTSIDE the reading node's trace stack, under exactly `read-cap`; the
  reader records only a `probe:<name>` cell, capability-free at the read
  site. Never persisted (`Runtime.probe_values` is in-memory, cleared every
  pass) — a probe is the volatility-containment mechanism, not a cache.
- **sealed cell** *(real, M4)* — a confidential read (SPEC LAW 39).
  `--grant secret:<path>` mints `CapSecret`; a read covered by it and NOT by
  an fs grant returns `VSealed` instead of `VString` — redacted on print,
  excluded from the CAS, banned at the node boundary like a capability.
  `(unseal v)` is the explicit, greppable way back to `VString`.
- **`run` / process effect** — `(perform run CMD ARG…)` executes an external
  command under `--grant process`, returning `{"exit","out","err"}`. Inside a
  node: cwd = the node's sandbox, and the trace records `tool:` + `tree:`
  cells (`tests/017`).
- **`run-dep` / depfile adapter** — `(perform run-dep DEPFILE CMD ARG…)`:
  like `run`, but the tool's Makefile-style depfile refines the trace to the
  exact files read — granted deps as `file:` cells, system deps as `tool:`
  cells, no coarse `tree:` cells (`tests/022`).
- **sandbox (per-node scratch)** — a throwaway directory created lazily per
  node force and deleted when it completes. `run` executes there; relative
  `slurp`/`write-file` resolve there, capability-free and unrecorded; absolute
  node writes error (LAW 18). Hygiene, not soundness — traces are soundness.
- **desired-state value** *(partly real)* — the pure, hashable value the
  program's root returns (build → `{path → blob-hash}`; services →
  `{proc → spec}`). Real today for the filesystem domain as
  `{relative-path → content}` where content is an inline string or a
  `blob:<sha256>` CAS reference from `(blob S)`, consumed by
  `pp --reconcile ROOT` (`tests/018`, `tests/023`), and for the process
  domain as `{service-name → spec}` consumed by `pp --supervise`
  (`tests/033`).
- **reconciler** — the one privileged writer per domain.  v1 filesystem
  (`reconciler.ml`, `pp --reconcile ROOT`): diff desired vs observed by
  content hash, journal `intent`/`done`, apply via temp+rename with
  verify-after-write, delete unmanaged files, refuse self-reading desired
  state (stratification, LAW 30). Watch mode live (`--watch --reconcile`
  polling loop). Process domain (`supervisor.ml`, `pp --supervise`) is live:
  start/stop/restart on spec-hash change, zombie reaping, journal intent/done
  (`tests/033`). Fenced effects (LAW 31) are sequenced after convergent work
  and recovered by `--fenced-policy retry|abort|ask` (`tests/034`).
- **domain** *(planned)* — a slice of external state under single ownership (an
  output subtree, a process set, a DB schema).

### Scheduling

- **rebuilder** *(real)* — the one implementation of `force` over the store:
  verify traces, cutoff on hash equality, record new traces on a miss. Shared by
  both schedulers.
- **pull scheduler** *(real)* — suspending; forces the root and recurses on
  demand. For builds/provisioning (`--once`). The current default (and only
  scheduler — `--watch` runs this in a polling loop).
- **push scheduler** *(partly real)* — dirty-propagating over the reverse-edge
  index derived from traces; re-forces only dirtied nodes. For services
  (`--watch`). The polling pull-in-loop `--watch` is live; true push `stabilize`
  (dirty-propagation) is planned.
### Authority

- **capability** — an authority token: a ceiling on what a computation *may*
  touch. Unforgeable, minted only at the root, narrowable but not constructible
  by user code. **Not** an ordering mechanism.
- **powerbox** — the full authority set handed to `main` from the CLI
  (`--grant`). The sole mint of capabilities.
- **`cap-restrict` / `cap-compose`** — the only capability operations in user
  code: narrow a capability's scope, or union two the code already holds.
- **`CapNetwork` / `http-get` / `http-post`** *(real, M4)* — `CapNetwork
  {host; port option}` (`--grant net:<host>[:<port>]`, `host = "*"`
  wildcards) authorizes `(perform http-get url)` / `(perform http-post url
  body)`, which fork `curl` (no new OCaml networking code) and return
  `{"status" INT "body" STRING}`. Banned inside node bodies — not
  convergent, not the declared-nondeterminism mechanism (that's **probe**).

### Effects

- **effect / `perform`** — a named, dynamically-dispatched operation
  (`read-file`, `log`, …). Resolved against the handler stack; unhandled effects
  hit builtin fallbacks.
- **handler / `with-handler`** — a dynamic-extent installation that intercepts
  matching `perform`s. Restored on normal return, exception, and tail call.
- **result-transparent handler** *(planned)* — a scheduling/placement handler
  that may change only *where/when* work runs, never observable results. Absent
  from keys.
- **semantic handler** — a handler that changes results (mock `read-file`,
  fault injection). Records a synthetic `handler:<effect>` cell into the trace
  so swapping it invalidates correctly (`tests/015`). Today every user handler
  is treated as semantic; the per-arg refinement in LAW 26 is *(planned)*.
- **fenced effect** — a non-convergent, irreversible action (send email,
  charge card).  Barred from node bodies; surfaced as scripting-tier
  `(fenced KIND SPEC-MAP)`; sequenced reconciler-only with an intent/done
  journal and at-most-once-per-pass.  Unknown-status entries after a crash
  are resolved by `--fenced-policy retry|abort|ask`, never silent retry
  (LAW 31; `tests/034`).

### Language surface

- **the two tiers** — the **node tier** (pure, strict, cached, distributable —
  where the build/DevOps thesis lives) and the **scripting tier** (dynamic,
  imperative, uncached REPL glue). Purity is the price of a cache hit; caching
  is opt-in per node.
- **mutual `let`** — every binding is in scope in every right-hand side and the
  body, position-free. "A `let` is a local Excel sheet." (`let*` is explicit
  sequential sugar.)
- **module / `import`** — a block of code whose exports are a value you import.
- **island** — a module that lives elsewhere (a local dir, a git repo),
  referenced by URI and pinned **inline** by the canonical content hash of
  its source tree: `(island <github:owner/repo#ref> "64-hex-pin")`. The pin
  is part of the code hash, so a pinned island form is a *closed*
  expression — paste it anywhere and it denotes the same bytes — and an
  enclosing **node** is keyed on it (LAW 20). Resolution serves only the
  verified, immutable cache copy; unpinned forms are a hard error;
  `pp --update` re-resolves and rewrites pins in the source; fetching is
  opt-in runtime authority (`--fetch-islands`, LAW 24), never ambient. D2.
- **fexpr** *(cut)* — operatives that receive unevaluated arguments. Removed;
  metaprogramming is served by total `quote`/quasiquote and `defmacro` (M3,
  `macro.ml`): a macro's body runs through the tree-walker at a single
  shared expansion point, before either backend's own machinery (hash_expr,
  the compiler) ever sees the form — so LAW 20 needs no change and both
  backends stay byte-identical (LAW 36) by construction.

### Process and testing

- **the two back ends** — the **tree-walker** (`evaluator.ml`, the reference
  interpreter) and the **bytecode VM** (`compiler.ml` + `vm.ml`, the faster
  execution model). They must produce identical output.
- **oracle** — the tree-walker, taken as ground truth in differential tests
  (though it too can be wrong — see D6/D17 in [STATUS.md](STATUS.md)).
- **differential testing** — running both back ends and asserting identical
  behavior. Enforced by `dune runtest` and the fuzzer ([TESTING.md](TESTING.md));
  the project's core correctness ratchet.
