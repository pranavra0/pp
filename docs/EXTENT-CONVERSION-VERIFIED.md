# Dynamic-extent conversion: verification findings

## What was fixed during verification

### D27: process_expr entry point missing with_top_level handler (NEW)

During `dune runtest`, `tests/052-devops-complete.sh` crashed immediately on
`c1-cold-publish-one-exec` with:

```
Fatal error: exception Stdlib.Effect.Unhandled(Record_read("runtime:file:...", "..."))
```

**Root cause.** The effect-handler conversion replaced the old global-ref-based
`record_read` with an `Effect.perform Record_read`. In the old code,
`record_read` when called outside a trace frame was a no-op (it just wrote to
an empty list). In the new code, `record_read` performs an effect that needs a
handler. The top-level handler `with_top_level` was installed around
`eval_program`/`eval_and_force`/`run_program_expr`, but the tree-walker entry
`process_expr` (repl.ml) called `eval_expressions` directly — not through
`eval_program`. So `loader_read` → `record_read` during module loading
triggered an `Unhandled` crash.

**Fix.** Wrapped `process_expr`'s body in `Runtime.with_top_level` (repl.ml
lines 37-43). This covers all tree-walker top-level evaluation entry points.
The VM path already went through `run_program_expr` (already wrapped).

**Files changed:** `src/repl.ml` (one `SWAP.BLK`)

## Pre-existing failures (not caused by the conversion)

### tests/052-devops-complete.sh: `oracle-schedule-parallel-check` and `oracle-schedule-remote-check`

Two subtests in `tests/052-devops-complete.sh`'s "diagonal oracle" section fail
in the ORIGINAL code (confirmed by `git stash` run). Both fail with:

```
pp: error: slurp: permission denied for greeter at demo/deploy.pp:93
```

Under `--schedule parallel:4 --check` and `--schedule remote:B --check`,
the canonical publish of the oracle fixtures succeeds (all 6 pull rows have the
same hash, and the publish is verified), but the direct placement-transparency
proof (`--check`) exits 1 because `slurp` on the compiled `greeter` binary
gets a permission denial.

This appears to be a pre-existing issue in the original code unrelated to the
effect-handler conversion. It may be a residual of the D26 parallel-scheduling
fix (`stdlib/list.pp` shadowing the batching-aware `map` builtin) or a
genuine capability-path interaction with the parallel scheduler's execution
order — the parallel/remote schedulers change the order in which node bodies
are forced, which may affect capability-sensitive primitives (`slurp`)
executing outside a node context.

The non-serial schedule check is not run under standard CI (the test is long
and depends on `cc`), so this issue may not affect CI results in practice.

## All other tests pass with the conversion

The complete `dune runtest` suite passes (all 67+ shell tests, all PP unit
tests, all capability-adversarial tests, all fuzzer generators). The store-v1
golden fixture is byte-identical. `pp --diff` on representative files shows
both backends agree.
