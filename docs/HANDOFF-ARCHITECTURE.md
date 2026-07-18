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

The physical layout now established by item 19 is:

```text
src/
  kernel/       syntax, values, environments, identity, capability algebra
  frontend/     readers, printers, desugaring, and surface tables
  runtime/      sole evaluator, dynamic scopes, cache, and world implementations
  app/          commands, runtime construction, watch and reconciliation
```

The actual module graph is intentionally smaller than this conceptual
ownership list: evaluator, cache, and world implementations share the wrapped
`pp.runtime` boundary because their existing module dependencies are acyclic
but interleaved. The checked graph is `pp.kernel -> pp.frontend -> pp.runtime
-> pp.app`, with `pp.runtime` also depending on `pp.kernel` and
`pp.frontend`; `dune build @architecture` enforces the declared edges.

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
- REPL, lint, fenced-action, and several counter states
  remain process-global.
- Current documentation contains duplicated entries, incomplete prose, and
  implementation claims that have drifted.

## Ordered roadmap

The order matters. Later boundaries assume earlier ownership and tests.


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

Execute roadmap item 21 only: standardize errors and resource safety.
