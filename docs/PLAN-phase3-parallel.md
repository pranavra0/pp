# Phase 3 / M1 design — placement as a handler (process-pool scheduler)

The implementation contract for MASTERPLAN M1, produced by an architect pass
and hardened by adversarial review. Line numbers reference the tree at commit
`ed2894d`; re-check before relying on them.

## The three findings that shaped the design (walls protocol)

**Wall A — no batch fan-out point exists in the language today.** `EApply`
forces every argument (evaluator.ml: apply forces `eval` of each arg), and
`{k v}` map literals desugar to `(hash-map ...)` applications, so any compound
value built by existing code forces its node elements one at a time, inline.
A batch of unforced sibling nodes can only exist if something builds a
compound value without forcing its elements. That something must be added
(§ map, below); the scheduler cannot merely be "wired in."

**Wall B — the Runtime global-state refactor is NOT on M1's critical path
(divergence from MASTERPLAN M1 as written).** The refactor is forced only by
worker shapes that construct workers independently of the dispatch point
(persistent pools, fresh processes) — those must marshal ambient state, and
`handler_stack` holds live OCaml closures, which the store's own non-data law
says cannot leave a process. fork() at the dispatch point inherits ALL
ambient state byte-identically via COW for free. Consequently M1 uses fork
and DOCUMENTS the state inventory (the map M5's remote transport needs —
where named/registrable handlers replace closures) instead of threading a
`Runtime.t` through the codebase now, against a fork-shaped M1 that could not
validate it. MASTERPLAN M1's wording is amended accordingly.

**Wall C — Q11 narrows under N workers (documented residual, M5 design item
"Q11-bis").** `Store.run_pins` is in-memory; forked workers inherit pins as
of the fork instant but pin later first-observations independently. One run
is therefore "at most N world snapshots agreeing on everything pinned before
dispatch" — sound under R9's trace-SET (divergent observed worlds are
legitimate distinct traces; worst case is a recompute, never a wrong hit),
but narrower than Q11's informal claim. Fix options (snapshot barrier /
pins-in-store) are M5 design work, out of M1 scope.

## Worker model: fork at dispatch, results via the store

1. A dispatch point holds a batch of `(key, run)` node-miss jobs.
2. `flush stdout/stderr` (unflushed buffers duplicate across fork), then
   `Unix.fork()` per job up to the concurrency bound.
3. **Child:** `Evaluator.run_node_body ~key ~run t` — the EXACT function the
   serial Miss arm calls (no second force path, principle 4); `exit 0` on
   success, `exit 1` on error (the failing trace was already persisted by
   `run_node_body` per LAW 28).
4. **Parent:** reap; never reads a value from the child. It falls through to
   the ordinary `Store.hit` — the child's trace+object make it a hit; a dead
   child makes it a Miss and the parent runs the node in-process, exactly
   today's serial path. Worker failure degrades to "computed serially,"
   never a wrong answer or a hang.

No value, closure, capability, or handler ever crosses a process boundary:
the store is already pp's cross-process value channel (tests/010/014).

Rejected: persistent pipe-fed pool (must marshal thunk closures — impossible
by the non-data law; buys nothing over cheap fork); fresh `pp` processes
targeting a node key (no derivation/eval split — would re-run the whole
program per node and need a tool-shaped "force only key K" CLI).

## What is parallelized: nodes only

Only thunks with `thunk_persist = true` (the `(node e)` boundary) — nodes are
persistent, content-keyed, sandbox-isolated, and safe to run redundantly.
Ephemeral thunks/`delay` stay in-process.

### The `map` primitive (closes Wall A)

`(map f lst)` as an OCaml builtin: applies `f` to each element via the apply
hook WITHOUT forcing the result, so a `(defnode (compile src) …)` mapped over
sources yields a list of UNFORCED node thunks. Zero placement semantics
(LAW 34 untouched); behaves identically under every policy including serial;
independently a correctness completion — principle 2's demand-pruning was
unreachable for compound values without it.

**Correction from adversarial review — the pairing trap:** the mapped
function's BODY must not pass the node through an argument position:
`(map (fn (n) (cons n (compile n))) names)` re-forces each node inline
(cons's argument evaluation forces it — Wall A applies inside the closure
body too), silently serializing the build. The exit-test build.pp maps the
node constructor directly — `(map compile names)` — force-deeps THAT list
through the scheduler, and only then pairs names with (now-hit) results.
Document this trap in the map primitive's doc line: parallel fan-out exists
exactly when the node thunk itself is the element.

### Scheduler interface

New `src/scheduler.ml`:

```
type policy = Serial | Parallel of int | Race of int
val policy : policy ref            (* ambient; set once from --schedule *)
type job = { j_key : string; j_run : unit -> value; j_width : int }
val dispatch_batch : job list -> unit
```

- `Serial`: in-process `List.iter` over `run_node_body` — byte-identical to
  today; the scheduler-aware paths check `Serial` first and take the
  original code (zero risk to existing behavior).
- `Parallel n`: wave loop — fork up to n, `waitpid` frees slots, refill.
- `Race n`: one job forked n times (homogeneous redundancy — identical
  `(key, run)`; sound because LAW 37 nodes are deterministic); first `exit 0`
  wins, losers get SIGTERM→SIGKILL, parent proceeds to `Store.hit`.
  Heterogeneous racing of different computations is OUT OF SCOPE until M4's
  declared-nondeterminism cells exist.

Call sites: (1) `force_node`/VM `vm_force` miss arms (singleton, width from
policy); (2) scheduler-aware `force_deep`: collect pass over the value graph
gathering unevaluated persistent thunks + keys (via `node_key_of` /
`vm_node_key` per `t.vm_code`), dedup by key, `dispatch_batch`, then run the
ORIGINAL recursive force_deep (now all hits).

### CLI: `--schedule serial|parallel:N|race:N`

Parsed in main.ml beside `--grant`. Ambient, never in node keys or traces
(policy is read only in miss arms and dispatch_batch; `node_key_of` /
`vm_node_key` untouched) — D17 class 1 / LAW 26 by construction. LAW 34's
negative half preserved: no language surface names a place.

### `--check` schedule transparency (D17's promised audit)

Under `--check` with a non-serial policy: after the scheduled run produces
desired-state value v, re-run the program with policy forced Serial against
the same store and compare `hash_value` — mismatch exits 1 like the existing
volatility failure.

## Store and journal under N writers

- objects/blobs: immutable, hash-named, check-then-write — already benign.
- `traces/<key>` read-modify-write: last rename wins; a concurrently-added
  trace can be dropped. Sound: the survivor either duplicates the loser
  (race case — determinism) or the loser's world re-misses and recomputes
  (never a wrong hit). Additionally harden with a per-key `lockf` around the
  RMW (serializes same-key writers only; contention ~zero across distinct
  keys) so drops don't happen in practice; the stress test still proves
  drop-soundness with the lock disabled.
- Journal: harden `Journal.append` to one `Unix.write_substring` on an
  O_APPEND fd per line — line-atomic regardless of length — so exec-count
  proofs survive N concurrent writers.

## Determinism: what "byte-identical" means in the exit tests

Compared: (1) `hash_value` of the desired-state value, serial vs parallel;
(2) recursive content diff of the reconciled tree; (3) journal exec COUNTS
(cold = TU+link, null = 0). Excluded: stderr/stdout interleaving (LAW 13
orders effects within a node's `do`, never across independent nodes) and
journal line ORDER.

## Failure & cancellation

- Dead worker: no committed partial writes (temp+rename; sandbox scratch
  only, LAW 18). Parent best-effort `rm -rf` of the child's pid-qualified
  sandbox dirs on every reap.
- Race losers: safe to kill by construction — `(fenced …)` raises inside any
  node body (LAW 31), so no non-convergent action can be half-done; assert
  this stays true under every policy (tests).
- SIGINT: parent kills all live children (TERM→KILL) before exiting.
- Fenced drain, reconciler, supervisor: root-process-only, untouched; their
  private force_deep copies stay serial by design.

## Exit criteria (tests)

1. **tests/024 parallel variant**: build.pp rewritten to `(map compile …)`
   (with the pairing-trap fix above); run serial and `parallel:$(nproc)`
   from cold: same desired-state hash, same tree bytes, same cold exec count
   (101 cc + 1 link), null rebuild still 0 execs, wall-clock speedup
   reported (assert parallel < serial only).
2. **race:3**: a deliberately slow node, cold, under serial then race:3 —
   identical result hash, byte-identical program text (only the flag
   differs), exactly one surviving trace, wall-clock ≈ single-run not 3×.
3. **tests/038 N-writer stress**: 64 independent nodes under parallel:16 on
   one cold store, repeated ~20×: every object decodes, every trace line
   parses, serial re-run hash-identical; race:8 same-key collision with the
   trace lock disabled still yields a parseable trace file and a correct
   subsequent hit; N concurrent journal appends → exactly N parseable exec
   lines.

SPEC flips on completion: LAW 35 → holds; LAW 34 scheduler half → holds.
MASTERPLAN M1 wording amended per Wall B; DESIGN Q11 gains the Q11-bis note
(Wall C); STATUS gains the scheduler bullet.
