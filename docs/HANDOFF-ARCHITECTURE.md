# Architecture roadmap

## Purpose

This is the execution roadmap for making pp unusually easy to understand,
change, and verify. It describes the intended architecture and the ordered,
behavior-preserving migrations needed to reach it.

This is not a historical record. Delete a completed task from this file once
its result is represented by the code, tests, and current architecture
documentation. Do not mark finished tasks as done. Durable rationale belongs
in `DESIGN.md`, semantics in `SPEC.md`, current implementation claims in
`ARCHITECTURE.md`, and known discrepancies in `STATUS.md`.

The architecture may change any OCaml API: neither `pp` nor `pp.kernel` has a
published compatibility obligation. Language behavior, semantic laws, content
identity, authority boundaries, and durable data remain compatibility concerns.

## Non-negotiable constraints

- There is exactly one evaluator: the tree walker. Splitting its implementation
  must never create a second expression dispatcher or execution path.
- Preserve behavior before improving structure. Each migration is independently
  testable and leaves the repository green.
- A content key includes everything identity depends on and nothing that is
  merely an observation or authority. Keep `tests/009` passing for hashing or
  thunk-key work and `tests/010` through `tests/024` passing for store, trace,
  or node-key work.
- Capabilities grant authority, never identity or ordering. No refactor may
  create an ambient-authority bypass or allow authority to cross a node boundary.
- Every durable write continues to pass through an atomic-write choke point.
- OCaml effects remain the mechanism for genuinely dynamic evaluation scope.
  Explicit ownership replaces process-global state; it does not replace effects.
- Comments describe stable local facts, not project history, roadmap phases,
  test names, or workflows. If changing a test would make a comment false, the
  comment does not belong in source.
- Do not combine architecture changes with language features, store-format
  changes, or performance redesign unless the roadmap item explicitly requires
  it.

## Definition of a completed roadmap item

Every item below is a small migration, not a theme. Before deleting an item:

1. Add the smallest characterization or regression test that would fail if the
   relevant behavior changed.
2. Make the structural change without retaining parallel old and new paths.
3. Run the item's focused tests and `dune build`.
4. Run `dune runtest` for changes crossing evaluator, runtime, store, process,
   scheduler, or command boundaries.
5. After touching `evaluator.ml`, `core_model.ml`, or durable repository code,
   also run:

   ```sh
   dune exec ./tools/fuzz.exe -- --grammar full --count 2000
   ```

6. Update `ARCHITECTURE.md` or `STATUS.md` when their current claims changed.
7. Confirm `git diff` contains no unrelated cleanup, generated artifacts, or
   user work.
8. Commit with one terse Conventional Commit message.

If a task proves too large to keep these conditions true, split it at an API
seam before implementing it.

## Target architecture

### Dependency direction

The intended conceptual dependency graph is:

```text
app
├── frontend ──────────────────────────────> kernel
├── evaluator ───────────────> node runtime -> cache policy -> repositories
│   ├── dynamic scope ─────────────────────> kernel
│   └── host-service interfaces
├── reconciliation ──────────> world implementations
└── distribution ────────────> world implementations
                                      |
                                      └───────────────> repositories
```

Dependencies point downward. Lower layers do not call upward through mutable
global hooks. The application constructs concrete world services and passes
their narrow interfaces inward. When an upper-layer operation is required, the
lower operation receives a small immutable function record or callback as an
argument.

The likely physical layout is shown below. It is a destination, not permission
to move files before the dependency boundaries exist.

```text
src/
  kernel/       syntax, values, environments, identity, capability algebra
  frontend/     readers, printers, desugaring, macro expansion
  eval/         sole evaluator, dynamic scopes, node forcing adapter
  cache/        CAS objects, traces, observations, indexes, GC
  world/        filesystem, process, islands, transport, host services
  app/          commands, runtime construction, watch and reconciliation
```

Use fewer libraries if OCaml's recursive type relationships make a smaller
graph clearer. A directory earns its existence only when Dune and `.mli`
boundaries enforce its dependency direction.

### Ownership and effects

The target execution shape is:

```text
process
└── immutable host services
    └── command
        ├── invocation configuration
        ├── store handle
        ├── scheduler/session resources
        └── evaluation session
            ├── explicitly owned memo tables and registries
            └── OCaml dynamic scopes
                ├── capabilities
                ├── config
                ├── handlers
                ├── trace frames
                ├── current node and sandbox
                └── current domain
```

OCaml effects answer “what is in dynamic scope at this call?” Records answer
“who owns this resource, how long does it live, and who resets it?” A value
must not be placed in a global record merely to avoid passing it through one or
two orchestration functions.

### Required boundaries

- `Host_services`: immutable world operations such as time, canonicalization,
  home discovery, and secret-file I/O. Production and test implementations are
  complete values; there are no “not installed” defaults.
- `Invocation`: immutable validated CLI inputs. Parsing mutable refs never escape
  option parsing.
- `Session`: command/run-owned state with explicit creation and reset operations.
- `Dynamic_scope`: effect declarations and handlers only. It does not own global
  tables.
- `Evaluator`: semantic operations over expressions, environments, and values.
  It receives required collaborators explicitly.
- `Node_runtime`: the sole adapter between evaluator forcing and persistent-node
  policy. Node identity, hit authorization, replay, and rebuilding remain
  visibly separate operations.
- `Object_store` and `Trace_store`: durable repositories. They know paths,
  codecs, locking, and atomic writes, but not evaluator behavior.
- `Observation`: typed cell construction, observation, authorization, recording,
  and replay. The record and re-observe paths share implementations.
- `Command`: one module per CLI behavior. `main.ml` only parses, validates,
  constructs dependencies, and dispatches.

### Interface rules

- Mutable tables, refs, and records are private unless mutation itself is the
  module's deliberate API.
- Constructors establish valid state. Callers cannot create half-initialized
  services and install fields later.
- Reset and retention are named lifecycle operations, not `Hashtbl.clear` at
  call sites.
- Prefer abstract types for stores, sessions, schedulers, registries, and parser
  states.
- Keep interfaces smaller than implementations. An `.mli` that exposes every
  helper has not created a boundary.
- Avoid umbrella modules whose purpose is to make all dependencies reachable.
- Callback records are capability-shaped: expose only what the consumer needs.
- Errors crossing a module boundary use structured variants or project
  exceptions; arbitrary `Failure` is not an interface.

## Current risks confirmed on `master`

- `evaluator.ml` still mixes language semantics, loading, capability gates, and
  lifecycle wiring.
- `primitives.ml` combines the builtin catalog with scheduler batching, probes,
  domains, and macro evaluation.
- `main.ml` owns option parsing, wiring, commands, watch loops, reconciliation,
  and cluster behavior.
- REPL, lint, scheduler, fenced-action, and several counter states
  remain process-global.
- Current documentation contains duplicated entries, incomplete prose, and
  implementation claims that have drifted.

## Ordered roadmap

The order matters. Later boundaries assume earlier ownership and tests.


### 15. Turn primitives into a declarative builtin layer

**Purpose:** separate language builtins from application orchestration.

**Work:**

- Define a builtin descriptor containing name, arity/shape where expressible,
  implementation, and relevant category metadata.
- Keep builtin implementations near their owning concern or register them from
  small modules: collections, strings, capabilities, observations, process,
  domains, and diagnostics.
- Move scheduler-aware deep forcing out of the builtin catalog.
- Move probe/domain registries and invocation helpers into session/domain
  modules.
- Remove `current_env_ref`; pass the environment/evaluator operation required by
  higher-order builtins explicitly.
- Generate or check user-facing builtin tables from the catalog where that
  removes duplicated facts.

**Likely files:** `src/primitives.ml`, force-deep, scheduler, domains, frontend
surface tables, documentation gates.

**Verify:** primitive and stdlib tests, surface drift gate, domains, scheduler,
suite.

**Exit:** the primitive catalog is easy to scan; adding a builtin has one clear
registration path; it does not mutate evaluator-global environment state.

**Non-goal:** expand the standard library or rename language operations.

### 16. Construct scheduler and distribution state explicitly

**Purpose:** remove scheduler globals and clarify process/fork ownership.

**Work:**

- Make scheduler policy, live-child bookkeeping, fork instrumentation, signal
  installation, and remote dispatch part of an explicit scheduler handle.
- Install and restore signal handling at the application boundary with defined
  ownership.
- Pass a narrow remote dispatcher when constructing a scheduler; remove mutable
  callback installation.
- Document and test which session state is intentionally inherited through
  fork-on-dispatch and which durable store channel returns results.
- Keep serial, parallel, race, and remote policies driving the same node
  rebuilder.

**Likely files:** `src/scheduler.ml`, `src/remote.ml`, `src/transport.ml`,
force-deep, main/commands.

**Verify:** parallel stress/fork count, race behavior, remote placement, cluster
sync/exit, sandbox cleanup, suite.

**Exit:** two scheduler handles can be constructed without shared policy or
callbacks; live-child cleanup has one owner.

**Non-goal:** change scheduling results or add a new transport.

### 17. Separate domain policy, reconciliation, and fenced actions

**Purpose:** make long-running orchestration lifecycles understandable without
runtime-global queues.

**Work:**

- Give domain registration an explicit session-owned registry.
- Keep domain policy in pp source and trusted mechanics in narrowly scoped OCaml
  modules.
- Make observation, diff, apply, verification, and stratification explicit
  steps with typed inputs.
- Give fenced-action collection and epochs an explicit command/reconciliation
  owner; remove global current epoch and action list.
- Isolate journal persistence from recovery policy and interactive prompting.
- Ensure watch/reconciliation retries create the intended fresh pass while
  retaining only specified state.

**Likely files:** `src/domains.ml`, `src/domain_prims.ml`, `src/fenced.ml`,
`src/journal.ml`, session, app commands, stdlib domain files.

**Verify:** reconciliation, process reconciler, fenced effects/crash behavior,
domains, host domains, full devops tests, suite.

**Exit:** reconciliation is a readable pipeline over explicit state; no domain
or fenced queue is process-global.

**Non-goal:** move trusted world mutation into pp source or weaken journaling.

### 18. Decompose the CLI into command modules

**Purpose:** make application composition obvious and `main.ml` disposable.

**Work:**

- Separate raw option parsing, validation, dependency construction, and command
  execution.
- Define one handler per coherent command family: run/eval, fmt/lint, why/graph,
  watch/stabilize, reconcile/supervise, island operations, cluster/transport,
  GC, and developer/property commands.
- Construct host services, invocation, store, session, scheduler, and evaluator
  once per command as required.
- Remove command behavior and lifecycle mutation from flag callbacks.
- Keep `main.ml` to startup, parse/validate, composition, dispatch, and top-level
  error-to-exit conversion.

**Likely files:** `src/main.ml`, new app modules, `src/repl.ml`, command-specific
modules.

**Verify:** `pp --help`, every CLI shell test, suite; compare exit codes and
stdout/stderr for representative commands.

**Exit:** `main.ml` contains no language, cache, reconciliation, or cluster
algorithm; each command's dependencies are visible in its constructor/call.

**Non-goal:** change CLI spelling or output.

### 19. Introduce physical libraries and directory boundaries

**Purpose:** make the intended dependency graph visible and mechanically
enforced for humans and agents.

**Work:**

- Generate the actual OCaml module dependency graph after prior cycle removals.
- Choose the smallest set of internal wrapped libraries that produces an
  acyclic, explainable graph. Start with kernel/frontend/cache/world/app only if
  the graph supports them; do not force the sketch.
- Move one library at a time, update Dune, and use wrapping/qualified module
  names to make ownership visible.
- Add a dependency-direction test using Dune/OCaml dependency output or a small
  checked manifest.
- Prevent lower libraries from linking Unix unless world-facing behavior
  requires it. Re-evaluate the claim that the entire current kernel is pure;
  effects and mutable hooks must no longer be used to preserve a misleading
  grouping.
- Remove transitional forwarding modules after callers migrate.

**Likely files:** `src/dune`, source layout, module names, architecture test.

**Verify:** clean `dune build`, dependency gate, suite, full fuzzer when moves
touch evaluator/types/store compilation units.

**Exit:** directory and library layout matches the documented dependency graph;
forbidden upward dependencies fail mechanically.

**Non-goal:** create a library per file or maximize abstraction count.

### 20. Decide durable-format evolution separately

**Purpose:** permit justified format improvement without hiding identity or data
loss inside refactoring.

**Default:** preserve byte compatibility throughout all preceding work.

**Decision work:**

- Audit whether extracted types or repositories expose a concrete benefit from a
  format change: portability, canonicality, validation, forward compatibility,
  or simpler recovery.
- If there is no material benefit, retain the current version and delete this
  task.
- If changing it, write a dedicated design decision covering format/version
  identifiers, object and trace compatibility, migration versus invalidation,
  island/blob treatment, mixed-version cluster behavior, rollback, and failure
  recovery.
- Implement the new codec/version as a standalone change with old and new golden
  fixtures. Never silently reinterpret old bytes.

**Likely files:** codec, repository layout/version module, transport, golden
fixtures, releasing/status/design documentation.

**Verify:** portable-store tests, crash injection at every durable boundary,
mixed-version transport tests, suite and required fuzzer.

**Exit:** either an explicit decision to retain the format or a tested versioned
transition with no ambiguous bytes.

**Non-goal:** change semantic content keys merely because storage encoding
changes.

### 21. Standardize errors and resource safety

**Purpose:** make failure contracts as understandable as success paths.

**Work:**

- Inventory `Failure`, wildcard exception catches, ignored Unix errors, and
  process exits by boundary.
- Define structured error variants for reader, evaluator, capability, store,
  transport, command validation, and recoverable operational failures where
  callers make decisions based on kind.
- Preserve the rule that evaluative failures may be cached while capability
  failures may not; make that decision exhaustive in types.
- Use protected/bracket operations for files, locks, sandboxes, child processes,
  dynamic scopes, and temporary directories.
- Keep best-effort cleanup explicitly distinguished from correctness-critical
  cleanup.
- Test normal return, language error, OCaml exception, signal/child death, and
  relevant effect-continuation paths.

**Likely files:** all world and evaluator boundaries, with focused tests per
module.

**Verify:** error-message/location tests, capability adversarial tests, crash
injection, scheduler cleanup, suite and fuzzer where evaluator changes.

**Exit:** cross-module control flow does not depend on parsing error strings;
resource ownership and cleanup are visible at construction sites.

**Non-goal:** expose internal OCaml errors as new language-visible distinctions
without a semantic decision.

### 22. Add permanent architecture and feedback gates

**Purpose:** keep the resulting architecture from decaying.

**Work:**

- Keep compiler warnings fatal.
- Enforce library dependency direction.
- Keep the mutable-global drift check with a minimal intentional allowlist.
- Add an API-surface check or review rule for growth of foundational `.mli`
  files.
- Extend the existing vertical-slice gate so every new AST form covers both
  readers where applicable, evaluator dispatch, printers, hash/quote conversion,
  properties, and the fuzzer.
- Add focused unit-test executables for pure kernel, repository, observation,
  lifecycle, and parser behavior so most refactors fail quickly before the shell
  suite.
- Keep integration tests for real process, filesystem, cache, watch,
  reconciliation, and cluster behavior.
- Measure test categories and document how to run the smallest relevant gate;
  do not weaken the full-suite requirement for sensitive files.

**Likely files:** Dune test stanzas, test scripts, CI, `docs/TESTING.md`.

**Verify:** demonstrate each gate failing on a controlled temporary violation,
then reverting it; run all gates.

**Exit:** warnings, forbidden dependencies, unowned globals, and incomplete
feature slices fail automatically.

**Non-goal:** replace behavioral integration tests with mocks.

### 23. Rewrite current documentation from executable facts

**Purpose:** finish with a concise map that stays useful after this roadmap is
deleted.

**Work:**

- Rewrite `ARCHITECTURE.md` around the final data flow, dependency graph,
  ownership tree, dynamic scopes, node/cache pipeline, and file/library map.
- Remove duplicated entries, historical transitions, stale names, and claims
  better suited to design or status documents.
- Reconcile `STATUS.md` against the binary and tests, not the old architecture
  prose.
- Move only timeless rationale to `DESIGN.md`; avoid copying implementation
  detail there.
- Generate mechanical tables where the code is the source of truth.
- Check every command and observable claim by running the binary.
- Delete this roadmap after all remaining work is either represented in code or
  moved to a specific unresolved discrepancy with an executable acceptance
  condition.

**Likely files:** `docs/ARCHITECTURE.md`, `docs/STATUS.md`, `docs/DESIGN.md`,
generated documentation checks, this file.

**Verify:** documentation drift gates, manual command checks, suite where docs
are machine-checked.

**Exit:** a new human or agent can identify ownership, dependencies, extension
points, and relevant tests without reading project history; this file no longer
exists.

**Non-goal:** preserve roadmap history in permanent documentation.

## Feature work during the migration

Avoid feature work that crosses a boundary actively being migrated. When a
feature cannot wait, implement it as one vertical slice:

```text
semantic law or decision
  -> AST/model
  -> both readers or an explicit surface exception
  -> macro/lowering boundary
  -> sole evaluator
  -> both printers
  -> hashing and quote/unquote
  -> focused behavior test
  -> properties/fuzzer
  -> current documentation
```

Features affecting identity, laziness, effects, capabilities, observations,
serialization, or durable state require adversarial and cross-process coverage,
not only expected stdout.

## Immediate next action

Execute roadmap item 15 only: turn primitives into a declarative builtin
layer.
