# Architecture improvement handoff

## Current position

pp is a broad research prototype with a strong behavioral safety net. It has
one tree-walking evaluator, two readers, a content-addressed thunk/node cache,
capability checks, effects, a persistent store, scheduling, reconciliation,
remote execution, and a large integration suite.

The main architectural risk is not that the system lacks structure. It is that
important structure is implicit: `runtime.ml`, `evaluator.ml`, `store.ml`, and
`Backend.r` coordinate through global mutable state, mutable tables, mutable
thunks, dynamic effects, and initialization order. This makes extensions harder
to reason about and makes state-leak bugs easier to introduce.

The build currently reports an exhaustiveness warning around the `with-config`
branch in `evaluator.ml`. Treat warnings as possible semantic bugs until a
small executable test proves otherwise; do not silence this warning with a
catch-all without understanding which match it belongs to.

## Direction

Improve the architecture. Preserve behavior first; avoid a large
rewrite. Every refactoring step should keep `dune build`, the full suite, and
the required fuzzer green.

### Phase 1: make the state map explicit

- Inventory mutable state and classify it as per-run, per-node, persistent,
  or CLI-only.
- Group per-run state behind an explicit runtime/context record.
- Keep intentional mutation (thunk status, memo tables, atomic counters), but
  make ownership and reset points obvious.
- Replace ambiguous hook names such as `Backend.r` with a clearly documented
  runtime-services boundary, without reintroducing a second evaluator.

### Phase 2: narrow module boundaries

- Separate pure concerns from world-facing concerns:
  AST/hash/codec/value transformations versus files, processes, network, and
  store I/O.
- Extract trace collection/replay and store object/trace persistence behind
  small interfaces.
- Expand `.mli` files so modules expose operations rather than implementation
  tables and mutable internals.

### Phase 3: make feature growth systematic

For each new language feature, use this vertical-slice checklist:

```text
AST → reader(s) → evaluator → printer(s) → hash/quote conversion → tests/fuzzer
```

Add the smallest end-to-end behavior test first. Then add property or
metamorphic coverage where the feature affects identity, laziness, effects, or
serialization.

### Phase 4: improve feedback quality

- Fix every compiler warning.
- Add focused unit tests beneath the large shell integration tests.
- Keep expected-output tests for language behavior and integration tests for
  cache/store/world behavior.
- Keep historical design documentation separate from current implementation
  claims
- Don't leak things like "phases" into comments - don't overcomment - keep comments clear and focused on the task at hand. A comment is forever. The code around it moves, the tests move, the build moves, and the comment stays exactly as written with nothing to tell you it started lying. Comments have no tests. Write accordingly. If deleting a test or editing a workflow would make this sentence false, it does not belong in a comment.

## First recommended task

Investigate the `with-config` exhaustiveness warning. Add a minimal regression
test for a non-map config value, determine whether the fallback branch is being
parsed as intended, and fix the structure if necessary. Run the build, suite,
and fuzzer before moving on to broader state refactoring.
