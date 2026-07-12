# pp STATUS — what is real today

The living snapshot of what works and what doesn't, verified against source.
Update this file as reality changes; keep aspirations in [ROADMAP.md](ROADMAP.md)
and rationale in [DESIGN.md](DESIGN.md).

> Verified by *running* `dune runtest` and the fuzzer (`dune exec
> ./tools/fuzz.exe -- --grammar full`) in-tree, not by trusting prose.

## One-liner

pp is a two-backend interpreter for a Lisp with an unforgeable (at the
user-code surface) capability ceiling and a persistent, trace-verified,
content-addressed build engine. **Phase 0 is closed** — the core no longer
lies about scope, effects, types, or capability authority. **Phase 1 is
closed — pp is an incremental hermetic build engine, proven by running it:**
a 101-TU C project builds through a real `build.pp` with every ROADMAP exit
criterion met (null rebuild = 0 processes in ~130ms with the journal as
proof; mtime-only touch = 0 recompiles; one-file edit = exactly 1 compile +
1 link; `rm -rf build/` = byte-identical restore from the store with 0 tool
re-runs; comment-only header edit = dependents recompile, link cut off;
authority gates hits transitively — `tests/024`); `pp` builds itself via
`build.pp` (`scripts/build-self.sh`); and **Lua 5.4.7** builds, caches,
cuts off, and restores the same way (`scripts/build-lua.sh`).

The machinery: `(node e)` results + verifying traces persist to
`~/.pp/store`, shared byte-identically by both backends for data-keyed nodes
(D7). Identity is LAW-20 (`H(code ‖ free-var value-hashes)` — env, caps,
config, handlers all excluded); validity is the trace — `file:`, `config:`,
`handler:`, `tool:`, `tree:`, `stat:` (file predicates), `env:`, `argv:`,
and `runtime:file:` cells re-observed on every
hit, with hits gated on the caller's authority over the transitive read
closure (LAW 23b) and failures memoized as failing traces (LAW 28). Reads
are snapshot-consistent per run (CAS ingest + pins, Q11). Tools run via
`run`/`run-dep` under `--grant process` in per-node sandboxes, traced by the
coarse tree floor or refined by depfiles (Q2). The journaled, atomic,
verified, single-writer filesystem reconciler materializes desired-state
maps (inline or `blob:` CAS refs) under `pp --reconcile` (Q4/LAW 30), and
`pp why` / `--no-cache` / `--check` make the cache auditable. **Phase 2
groundwork is live:** `pp --watch` (polling pull-in-loop, re-evaluates on
cell change), `pp --once` (explicit one-shot), and `pp graph` (cell→node
dependency graph from stored traces) exist, proving exit criteria 3+4
(same keys, same store in `--once` vs `--watch`). Push `stabilize` is
now live (`pp --watch --stabilize`), and `tests/032` proves it produces
the same results as pull mode. **The process-domain reconciler is live:**
`pp --watch --supervise` takes a program whose final value is a map of
service-name → spec, starts/stops/restarts services on spec-hash change,
reaps zombie children, and restarts a `kill -9`'d service within one poll
interval (`tests/033`). **Fenced effects (LAW 31) are live:**
`(fenced KIND SPEC)` in the scripting tier, `--fenced-policy retry|abort|ask`,
an intent/done journal, and recovery of a killed mid-apply action without
silent double-execution (`tests/034`). **Phase 3 (M1) process-pool
parallelism is live:** `--schedule serial|parallel:N|race:N` forks worker
processes at the dispatch point for persistent-node misses — the same
101-TU build is 4-5x faster under `parallel:N` from cold, byte-identical to
serial (`tests/024`'s `p3-*` assertions, `tests/038`'s race/stress cases).

The scaffolding is good: the O(1) env-hash design, the CPS tail-call
optimization, and the dual backend with `--diff` are real assets.

What the engine proof does NOT mean: pp is usable by strangers. Language
ergonomics, a real stdlib, portability (macOS-only *runtime*
verification — the store format itself is now portable: nothing in
`~/.pp/store` is Marshal, everything is canonical s-expr text or raw bytes
under a `VERSION` stamp, M2.2/`tests/037`; the one remaining Marshal use,
`types.ml` bytecode hashing, is in-memory identity only and never
persisted; Linux CI is now **authored** — `.github/workflows/ci.yml` runs
`dune build`/`dune runtest`/the fuzzer/`scripts/build-lua.sh` on
ubuntu-latest + macos-latest — but has not yet run on GitHub, so Linux
itself stays unproven until that first run is green), and release
mechanics (M2.3: `pp --version`/the REPL banner now report a real version
via `dune-build-info`, sourced from `dune-project`, verified to work from
both a git checkout and a `git archive` tarball with no `.git`;
[CHANGELOG.md](../CHANGELOG.md) and [docs/RELEASING.md](RELEASING.md)
exist; no `v0.2.0` tag has been cut yet) are
tracked as the **maturity track** in [ROADMAP.md](ROADMAP.md) — written down
precisely because each item there was hit in practice during Phase 1. (The
worst ergonomic item, the `(def x v)` nullary-closure footgun, is FIXED:
non-list `def` is a value binding — `tests/025`.)

## What actually works

- **Reader** — full s-expr syntax; mutual `let` and sequential `let*`,
  `and`/`or` (desugared to `if`), `def`/`fn`/`do` — `(def x v)` with a
  non-list head is a **value binding** (letrec* scope in blocks with a
  `referenced before its definition` error, sequential at top level;
  duplicate defs in one block are read errors; `(defnode x e)` binds the
  node thunk of `e` — SPEC LAW 4, `tests/025`),
  `effect`/`perform`/`with-handler`, `module`/`import`/`load`/`load-module`,
  `island`, `with-config`/`config`, `quote`/`quasiquote`, type annotations
  (checked at force time — per-parameter annotations desugar into located
  checks ahead of the body, LAW 32, `tests/026`). Source locations are
  emitted for top-level forms and around `def`/`fn`/`defnode` bodies; parse
  errors carry file and line.
- **Stdlib (ROADMAP §2)** — primitives: `string-index`/`string-trim`/
  `string-sub`, `number->string`/`string->number`, `map-keys`/`map-vals`/
  `map-remove`, `file-exists?`/`dir?` (capability-gated `stat:` cells),
  `argv` (args after `--`, an `argv:` cell), `env-get` (`env:` cells,
  absence included), `exit` (dedicated exception, never trace-cached).
  Library files: `stdlib/list.pp` (map/filter/foldl/foldr/range/take/length/
  each/append/reverse/nth/drop/member?), `stdlib/string.pp` (string-join/
  starts-with?/ends-with?/lines), `stdlib/map.pp` (map-has?/map-merge —
  load list.pp first). `assert` is a reader form that reports the failing
  form and its file:line. Pinned by `tests/028-stdlib.sh` + `tests/028-stdlib.pp`.
- **Tree-walking evaluator** — application is strict (call-by-value) per Q1;
  `let` bindings become thunks. Memoization via `thunk_status`; a trampoline
  switches to a heap work queue past a depth threshold.
- **In-memory content-addressed dedup — tree-walker only.** O(1)-incremental
  env hashes. Real, in-memory, single-run, one backend. Now sound (D6/D17
  fixed).
- **Persistent node store — both backends.** `(node e)` marks a thunk
  persistent; `force` (tree-walker) and the `FORCE`/`vm_force` path (VM) consult
  `~/.pp/store` (objects keyed by result hash, `traces/<node-key>` holding a SET
  of traces). Cross-process caching works: a second run of a pure node returns
  the stored result without re-running it (and, per LAW 17, without replaying its
  `log`/stdout). The VM's node key is byte-identical to the tree-walker's for
  data-valued free variables, so the two backends share store entries
  (`tests/014`).
- **Portable store format (M2.2).** Objects, traces, fenced specs, and
  supervisor proc state serialize with a canonical, byte-stable s-expr text
  codec (`src/codec.ml`) — no Marshal anywhere in `~/.pp/store` — under a
  `~/.pp/store/VERSION` stamp (`pp-store 1`) that invalidates old/foreign
  stores by wiping `objects/`, `traces/`, `fenced-specs/`, `procs/` (never
  `blobs/` or `journal/`) and re-stamping, never crashing. The store holds
  DATA only: a code-valued node result (closure/thunk) is process-local —
  its trace persists but no object is written, so a cross-process consumer
  recomputes via the object-gone path. Golden byte fixtures pin the
  encoding (`tests/fixtures/store-v1/`, `tests/037`).
- **LAW-20 node keying.** A node's persistent key is
  `H(code-structure ‖ free-var value-hashes)` (`node_key_of`, `free_vars`): the
  free variables the node references are resolved (forced, call-by-value) to
  their value hashes; the whole-env hash and the capability set are **excluded**.
  Rebinding an unrelated global is a hit; widening `--grant` does not invalidate;
  changing a referenced value re-keys. Pinned by `tests/011-node-key-law20.sh`.
  Ambient config and the handler stack are excluded too — what a node observed
  of them lives in its trace (next two bullets, `tests/015`).
- **Verifying traces — the cache-validity mechanism.** During a node's
  evaluation every world-read (`slurp`, `perform read-file`) is recorded as a
  `(file-cell, content-hash)` pair; reads propagate to every enclosing node so a
  parent's trace transitively subsumes nested reads. On a hit the store
  re-observes each recorded cell and serves the result only if every hash still
  matches — otherwise it recomputes. This fixes the staleness bug where
  `(node (slurp path))` returned the old contents after the file changed. Pinned
  by `tests/010-node-cache-trace.sh`.
- **Hash-equality cutoff at node granularity (LAW 21).** Because traces verify
  by content hash, a mtime-only `touch` rebuilds nothing (exit criterion 2);
  because a node's key includes its free variables' *value hashes* (LAW 20), a
  downstream node keyed on an upstream node's value hits when a recompute
  produces a byte-identical result — the comment-only-header-edit story (exit
  criterion 5: compile re-runs, link does not) works today when the build
  threads values through free vars. No dirty-propagation graph was needed for
  pull mode; the reverse-edge graph is now live for push `stabilize`
  (`tests/032`), while inline-nested cutoff remains future work. Pinned by
  `tests/016-cutoff.sh`, both backends.
- **Config and handler trace cells (LAW 33/26).** `(config k)` inside a node
  records a `config:<k>` cell (absence is a distinct observation); every
  `perform` records a `handler:<effect>` cell whose observed hash is the
  intercepting handler's value hash, or a builtin marker when none intercepts.
  Both re-observe the *caller's* ambient stacks on a hit, through the same
  `Runtime.observe_*` helpers that recorded them. Consequences: changing an
  ambient config value or handler a node never observed cannot invalidate it;
  a node cached under a mock `read-file` and one under the real builtin coexist
  as two traces under one key with no cross-contamination. Both backends —
  fixing this exposed that all same-arity VM closures hashed identically
  (placeholder body/env), which `hash_value` now solves by hashing bytecode
  identity + entry offset + cycle-guarded captured frames. Pinned by
  `tests/015-config-handler-cells.sh`.
- **Failure memoization.** A node that raises a `Failure` stores a *failing*
  trace (error value + reads made up to the failure); a later force re-serves the
  same error without re-running, and re-runs only when a recorded read changes
  (LAW 28). A raising thunk is reset off `Evaluating`, fixing the D16 fake
  "infinite recursion" report. Pinned by `tests/012-node-failure-trace.sh`.
- **Hit-time capability check (LAW 23b).** A stored result is served only if the
  caller's capabilities cover every file cell in the trace's read closure
  (`Store.hit ~authorized`); since reads propagate to enclosing nodes, the check
  is transitive — a narrow caller cannot launder a broad read through a cached
  aggregator. A capability denial raises the distinct `Capability_error` and is
  **not** cached (authority is not identity — LAW 15), so a later authorized run
  still hits. Pinned by `tests/013-node-hit-capability.sh`.
- **`run` process effect + per-node sandbox (D13).** `(perform run cmd args…)`
  in both backends: requires `--grant process` (denial raises
  `Capability_error`, never cached), returns `{"exit" int, "out" str,
  "err" str}`. Inside a node the child runs with the node's lazily-created
  scratch dir as cwd; relative `slurp`/`read-file`/`write-file` resolve into
  scratch (capability-free, unrecorded — node-local memory); absolute
  `write-file` inside a node errors (LAW 18); scratch is deleted when the
  node's frame pops. Trace recording is Q2's coarse floor: a `tool:<resolved
  binary>` cell plus a `tree:<root>` whole-tree hash cell per fs-read grant —
  any change to the tool or under a granted tree re-runs the node, including
  reads pp never saw. Hit authority: `tree:` needs the fs grant, `tool:` needs
  the process grant. Pinned by `tests/017-run-effect.sh`.
- **Filesystem reconciler v1 (Q4/LAW 30).** `pp --reconcile ROOT prog.pp`
  treats the program's final value — a map of relative paths to string
  contents — as the desired state of the domain under ROOT: diffs against
  observed reality (content hashes re-derived from the tree, no trusted state
  file), journals `intent`/`done` to `~/.pp/store/journal`, applies via
  temp + `rename(2)` with parents created and verify-after-write, and deletes
  unmanaged files (single writer — the fs:rw grant over ROOT is required and
  is the consent). Stratification (LAW 30): under `--reconcile` every cell
  observation the program makes is collected (`Runtime.observe_all`), and a
  desired state that observed its own domain is refused. Both backends.
  Pinned by `tests/018-reconcile.sh`. Desired contents may be inline strings
  or CAS references: `(blob S)` ingests bytes into `blobs/` and returns
  `blob:<sha256>`; the reconciler diffs refs by hash without loading bytes
  and materializes from the store — `rm -rf build/` + re-reconcile restores
  the tree with zero tool re-runs when the desired-map nodes hit
  (`tests/023`). Grant the output domain WRITE-ONLY (`fs:<root>:wo`): a
  read-capable grant over it would make `run`'s coarse tree cell observe the
  domain and trip stratification. v1 limits: filesystem domain only;
  combine with `--watch` for continuous reconciliation.
- **Process-domain reconciler (Phase 2).** `pp --supervise prog.pp`
  (typically `pp --watch --supervise`) treats the program's final value as a
  map of service-name → spec, and keeps observed processes in sync with the
  desired specs: starts missing services, stops removed ones, restarts a
  service when its spec hash changes, and reaps/restarts a process killed
  with `kill -9` within one poll interval. Process state lives in
  `~/.pp/store/procs/` and every start/stop is journaled intent/done.
  Requires `--grant process`; a desired state that observed a `proc:` cell
  (its own domain) is refused (LAW 30 stratification). Both backends.
  Pinned by `tests/033-process-reconciler.sh`.
- **Fenced effects (LAW 31).** `(fenced KIND SPEC)` is a scripting-tier
  primitive that registers a non-convergent action (e.g., send email, charge
  card) for reconciler sequencing.  It raises an error if used inside a node
  body.  Under `--reconcile` or `--supervise`, actions are executed once per
  pass with an `intent fenced KEY EPOCH KIND SPEC-HASH` → perform →
  `done fenced KEY RESULT-HASH` journal in `~/.pp/store/journal/log`.  On
  recovery, an intent without a matching done is resolved by
  `--fenced-policy retry|abort|ask`, never by silent retry.  Both backends.
  Pinned by `tests/034-fenced-effects.sh`.
- **`pp why`, `--no-cache`, `--check`.** `pp why file.pp` explains every node
  force to stderr: first build, per-trace stale cell, unauthorized (with the
  offending cell REDACTED when the caller lacks authority over it — LAW 23c,
  so `why` can't probe a broader caller's reads), or hit with the verified
  trace. `--no-cache` skips cache reads (everything recomputes) but still
  stores fresh results/traces. `--check` re-runs each missed node's body and
  compares result hashes: a divergence flags the node volatile and fails the
  run (LAW 38's detection half; containment-as-cell is future). Both
  backends. Pinned by `tests/019-why-nocache-check.sh`.
- **`pp --watch`, `pp --once`, `pp graph` (Phase 2 groundwork).** `pp --once
  file.pp` is the explicit one-shot mode (the current default). `pp --watch
  file.pp` runs the program, then polls observed cells for content-hash
  changes and re-runs on change — a pull scheduler in a loop, using the
  persistent store's trace verification to skip unchanged nodes (hits) and
  recompute changed ones (misses), proving the store-level collapse between
  `--watch` and `--once` (exit criteria 3+4). `pp graph file.pp` runs the
  program then scans `~/.pp/store/traces/` and prints the cell→node
  dependency graph (the reverse-edge index, computed lazily). Both backends.
  Pinned by `tests/031-watch-once.sh`.
- **`pp --watch --stabilize` (push scheduler).** Uses a reverse-edge index
  from stored traces to compute the dirty node-key set when cells change;
  only those thunks are reset to `Unevaluated`, so clean nodes skip
  `Store.hit` entirely on re-execute. Produces identical results to the
  pull-mode `--watch` loop on the `tests/032` battery of cell-change
  sequences. Pinned by `tests/032-stabilize.sh`.
- **Loader authority bounded + runtime cells (Q6/D8c, LAW 24).**
  `load`/`load-module`/`island` go through `Runtime.loader_read`: confined to
  the CLI programs' directories, the cwd, and `~/.pp` (anything else errors,
  grants or no), and recorded as `runtime:file:` cells — validity-bearing,
  authority-exempt. Pinned by `tests/020-loader-authority.sh`.
- **Cell-id canonicalization (LAW 23, DESIGN §2.1).** `Runtime.canonical_path`
  is the ONE canonicalization function: absolute realpath (symlinks
  resolved), no trailing slash; a path that does not yet exist canonicalizes
  its longest existing prefix and appends the rest lexically, so a
  write-target's cell-id is stable across the file's creation. Applied at
  every `file:`/`tree:`/`stat:`/`tool:`/`runtime:file:` construction site,
  at `--grant fs:...` parse time, and at the loader bound; every authority
  check (`Capabilities.path_grants`) canonicalizes both the grant scope and
  the target, so a grant spelled one way authorizes a cell observed another
  way. Closes the D8 path-prefix bug class at the cell layer for real:
  a symlinked source tree, macOS `/var` vs `/private/var`, and a
  trailing-slash grant are all one cell (M2 exit criterion 3 — "symlinked
  trees are undefined behavior" ends here). NFC Unicode normalization is
  **not** implemented — a documented residual, deferred rather than
  half-done. Both backends. Pinned by `tests/036-canonical-cells.sh`.
- **Snapshot-as-CAS-ingest (Q11).** The first observation of a file cell
  ingests its bytes into `~/.pp/store/blobs/<sha256>` and pins
  `(cell → hash)` for the rest of the run; every later read — any tier —
  serves the pinned copy, so one run observes ONE world snapshot and torn
  reads are dead (an external writer mutating a file between two nodes is
  invisible until the next run). pp's own scripting `write-file` unpins the
  cell so its writes stay coherent. Trace verification observes through the
  pins, keeping validity decisions consistent with what the run read.
  Q11's "node-captured caps" is resolved as vacuous for now: the ambient
  capability set cannot change mid-run (no in-language attenuation surface),
  so capture-at-creation is indistinguishable from ambient-at-force — see
  DESIGN Q11. Pinned by `tests/021-cas-ingest.sh`. **Q11-bis (Phase 3
  narrowing):** N forked workers each inherit `run_pins` as of the fork
  instant via COW but pin their own later first-observations
  independently — one parallel run is therefore "at most N world snapshots
  agreeing on everything pinned before dispatch," not Q11's single-process
  "one run, one snapshot." Still sound under R9 (a divergent observed world
  is a legitimate distinct trace; the worst case is a recompute, never a
  wrong hit) but narrower than stated; a snapshot barrier or pins-in-store
  is M5 design work (DESIGN.md Q11).
- **`parallel`/`race` schedule handler — process-pool parallelism (M1 /
  Phase 3).** `--schedule serial|parallel:N|race:N` (`src/scheduler.ml`)
  forks worker processes at the dispatch point for persistent-node misses:
  `map` (a new non-forcing builtin — Wall A's missing batch fan-out point)
  builds a batch of unforced node thunks, `force-deep` collects every
  reachable unevaluated node, dispatches the batch (`Parallel n`: a
  fork/waitpid wave capped at `n` concurrent workers; `Race n`: n redundant
  forks of one job, first success wins, losers killed SIGTERM→SIGKILL), and
  only then does its ordinary recursive walk — every node it reaches is
  now a store hit. A singleton `force`d node miss forks too, but ONLY under
  `Race n` (n redundant workers); under `Serial`/`Parallel n` a lone miss
  stays in-process (forking one job buys nothing — only a batch benefits).
  A worker runs `Evaluator.run_node_body` — the EXACT function the serial
  miss arm calls, no second force path — and exits 0/1; the parent never
  reads a value from a child, only `Store.hit` after reaping, so a dead
  worker degrades to an ordinary serial recompute. `--schedule` is ambient:
  read only by the miss arms and the scheduler, never by
  `node_key_of`/`vm_node_key`, never in a trace. `--check` under a
  non-serial policy re-runs the program forced Serial against the same
  store and fails on any desired-state hash mismatch (the promised
  schedule-transparency audit). Store hardening: a per-key `lockf` around
  `store_trace`'s read-modify-write (disableable via the internal
  `PP_TRACE_LOCK=0` escape hatch, exercised by `tests/038`) and
  `Journal.append` as one `Unix.write_substring` on an O_APPEND fd, so N
  concurrent writers can't drop or tear each other's lines. The Phase-1
  101-TU build under `--schedule parallel:N` is 4-5x faster than serial
  from cold with byte-identical desired-state hash and tree
  (`tests/024`'s `p3-*` assertions); `race:3`/N-writer/same-key-no-lock
  stress and `(fenced ...)` still raising inside a node under every policy
  are `tests/038`. The `Runtime` global-mutable-state refactor MASTERPLAN
  M1 originally called for is **not** on this critical path — `fork()`
  inherits all ambient state (handler closures, capabilities, config,
  thunk_store) byte-identically via COW, so M1 ships with fork workers and
  documents the state inventory as M5's design item instead (Wall B,
  docs/PLAN-phase3-parallel.md; MASTERPLAN.md M1).
- **Depfile adapter (Q2 refinement).** `(perform run-dep DEPFILE CMD ARG…)`
  runs the tool, then parses its Makefile-style depfile: granted deps become
  precise `file:` cells (Q11-pinned + CAS-ingested), out-of-grant (system)
  deps become `tool:` cells, and no coarse `tree:` cells are recorded — so
  touching an unrelated file under a granted root no longer re-runs the
  node. A missing depfile falls back to the coarse floor. The aggregate
  `toolchain:cc` closure cell is superseded by per-file `tool:` cells where
  depfiles exist (DESIGN Q2 resolution). Pinned by `tests/022-depfile.sh`.
- **Tail-call optimization in both backends** — CPS `eval_tail`/`apply_tail`
  in the tree-walker; `TAIL_CALL` frame-swap in the VM.
- **Effects + handlers** — dynamic handler stack, builtin fallbacks
  (read-file/write-file/log). `do` is strict per step; effect/handler/config
  scopes restore state on normal return, exception, and tail call in both
  backends.
- **Capability checking** — fs read/write at perform time and for `slurp`;
  capability constructors removed from user code (D18); authority enters only
  via `--grant`.
- **Modules** — the tree-walker produces module values (`VEnvMap`).
- **REPL** — multi-line input (paren-balanced, string/comment-aware),
  `~/.pp/history` with Up/Down recall, raw-mode line editing on a tty,
  deep-forced result printing, `:why on|off` / `:help` / `:quit`. Piped
  sessions are promptless and banner-free; the VM REPL keeps globals across
  lines. Pinned by `tests/029-repl.sh`.
- **Bytecode VM + compiler** — 31 opcodes; `--diff` compares the two backends.
- **Bytecode `.ppc` serialization** — complete but **dead** and lossy;
  `cache.ml` deleted; the value/trace store (`store.ml`) supersedes it and is
  now live in the tree-walker.

## Discrepancy ledger (D1–D23)

The punch list. "Fixed" means fixed and covered by a test; open items link to
their phase in [ROADMAP.md](ROADMAP.md).

| # | Claim | Reality |
|---|---|---|
| D1 | Caching "across runs" | **Partial (Phase 1 underway).** `store.ml` is now wired into the tree-walker's `force`: `(node e)` results and their verifying traces persist to `~/.pp/store` across processes; a hit re-verifies the node's recorded `(file-cell, content-hash)` reads before serving (fixes the stale-read bug; `tests/010`); nodes are keyed the LAW-20 way, `H(code ‖ free-var value-hashes)` with the env/caps excluded (`tests/011`); failures are memoized as failing traces (LAW 28, `tests/012`); and hits are gated on the caller's authority over the transitive read closure (LAW 23b, `tests/013`). The VM shares the same store and key (D7 closed; `tests/014`). Config/handler observations are trace cells, not key material (LAW 33/26; `tests/015`); value-keyed cutoff works (LAW 21; `tests/016`); the `run` effect records `tool:`/`tree:` cells (D13; `tests/017`). Still open: no reconciler (Q4). The `.ppc` serializer remains dead. |
| D2 | Islands "fetch, pin, cache" | **Fixed.** `(island <uri> "64-hex-pin")` is a content-addressed module: the INLINE pin is part of the code hash (LAW 20 — identity is structural; no lockfile, no synthetic cell) and names an immutable tree under `~/.pp/islands/src/<pin>/`, verified against the pin on every resolve (tamper = hard error). Both backends evaluate the pinned `entry.pp` as a module (`ISLAND` opcode in the VM) and share node-store entries. Unpinned forms are a hard error naming the fix; `pp --update` re-resolves and rewrites pins in the source (refuses rather than half-writes); `git:`/`github:` fetch is opt-in (`--fetch-islands`), journaled, and governed by THREAT-MODEL-islands.md; `pp island-pins` introspects; `pp why` reports source-dir drift. `tests/035` + `tests/005`. |
| D3 | Tree-walker is the correctness oracle | **Fixed.** Both backends enforce type annotations via matching `check_type`; tests 004/005 run in the suite. |
| D4 | Deep thunk chains | **Partial.** Trampoline handles forced thunk chains; deep non-tail *eval* recursion is still bounded by the OCaml stack. |
| D5 | "SHA-256" | **Fixed.** `hash_string` uses Cryptokit SHA-256. |
| D6 | "Same hash = same thunk" is sound | **Fixed.** Closure hashes omitted the captured env, so a colliding closure propagated through `env_hash` into thunk keys and `make_thunk_ca` returned a **wrong** memoized thunk (tree-walker only). Repro: `(def (make x) (fn () x)) (def (run c) (let [r (c)] r))` — `(run (make 1))` then `(run (make 2))` returned `1,1`. Fix: fold the captured env's precomputed `env_hash` into the closure hash — O(1), no traversal, terminates for recursive/mutual closures. Over-approximates (whole env, not free-vars-only); sound. Pinned by `tests/009`. |
| D7 | VM shares the CA story | **Mostly fixed.** The VM now compiles `(node e)` to a `MAKE_NODE` opcode carrying the body AST + free-var descriptors, and forces it through the same `~/.pp/store` with the same LAW 20 key, verifying traces, failure memoization, and hit-time capability gate as the tree-walker — sharing store entries for data-valued free vars (`tests/014`). Remaining gap: the VM's *in-memory* thunk dedup still doesn't exist (only the persistent node path is wired); closures as free vars key per-backend (VM closures carry no captured env), so those don't share. |
| D8 | Capabilities are the security story | **Mostly fixed.** Path checks are component-aware and full-path; `slurp` gated; `random` removed; `CapTime`/`CapMemory` removed. Cache hits are now gated on the caller's authority over the trace's transitive read closure (LAW 23b); capability denials raise a distinct `Capability_error` and are not memoized. Loader reads (`load`/`island`) run under interpreter authority BOUNDED to source roots + `~/.pp` (D8c closed) and are traced as authority-exempt `runtime:file:` cells (Q6 runtime/traced split; `tests/020`). |
| D9 | VM effect/handler scoping | **Fixed.** Save-stacks restore the exact prior scope; bodies compiled non-tail so exits run before tail calls. |
| D10 | Fexprs are operatives over syntax | **Cut.** `def-fexpr` removed. Metaprogramming is served by total `quote`/`quasiquote` and a future `defmacro`. |
| D11 | Quasiquote | **Fixed.** Reader parses quasiquote/unquote/splicing; a runtime walker expands (splicing, nested, vectors, maps). |
| D12 | Source locations | **Fixed.** Reader emits locations and wraps def/fn/defnode bodies; the shared top-level driver appends the enclosing form's `file:line` to any unlocated runtime error in BOTH backends (never doubled). Arity errors name the callee, capability errors name the operation, unbound-symbol text is backend-identical, and uncaught errors print as one `pp: error: …` line, exit 1 (`tests/027`). The `load` residual (errors inside a loaded file citing the loading form's line, not the inner file's) is also closed: `Reader.read_string` is now called with the loaded file's own path in every `load` path (tree-walker `eval_expressions`, VM `LOAD_FILE`), and each loaded top-level form is evaluated/compiled-and-run individually under the SAME location-decoration discipline as the outer driver (`Runtime.with_form_location`, one implementation shared by both backends and both nesting levels) — so an error inside a loaded file is located against THAT file before it can unwind past the `load` (`tests/027` case (g)). |
| D13 | Build-system-as-language | **Mostly fixed.** `(perform run cmd args…)` executes a process in both backends: gated on `--grant process` (`CapProcess`, LAW 22), returns `{"exit","out","err"}`, runs with the node's sandbox as cwd, and records `tool:`/`tree:` trace cells (Q2's coarse soundness floor) so tool or granted-tree changes invalidate cached run-nodes. Node `write-file` is sandbox-scratch-only (LAW 18); scripting tier unchanged. Pinned by `tests/017-run-effect.sh`. Remaining: depfile/toolchain-closure refinement, and `build.pp` itself (needs nothing more to be written). |
| D14 | Self-hosting `pc.pp` | **Cut.** `pc.pp` and its test deleted (Q12). |
| D15 | Backend parity, misc | **Fixed.** VM `module` compiles all children; computed config keys work; non-final top-level expressions are forced. |
| D16 | Error semantics | **Mostly fixed.** A raising thunk is no longer left `Evaluating` — it resets to `Unevaluated` and re-raises the real error, so the fake "infinite recursion" report is gone (`tests/012`). Failing `(node e)` runs are memoized as failing traces and re-served until a recorded read changes (LAW 28), in both backends (`tests/012`, `tests/014`). Exception-safe state restore for effect/handler/config was already fixed. Remaining: only `Failure` exceptions are cached; reconciler-scoped failure epochs (Q3) are Phase 2. |
| D17 | Handlers × caching | **Fixed.** `handler_stack` was not in the thunk key, so a thunk memoized under handler A was returned under handler B (tree-walker). Repro: `(def (ask-run) (let [r (perform ask 0)] r))` under `[ask (fn (n) 1)]` then `[ask (fn (n) 2)]` returned `1,1`. Fix: each handler-stack entry carries its handler's value-hash, folded into the thunk key alongside caps+config. Pinned by `tests/009`. At the *node* tier the handler stack is no longer key material at all: each perform records a `handler:<effect>` trace cell re-observed at hit time (LAW 26; `tests/015`). |
| D18 | Capability mint | **Fixed.** `filesystem`/`network`/`process` are no longer builtins; capabilities enter only via `--grant`. |
| D19 | Homoiconicity | **Fixed.** `quote_to_value` handles all expr forms; quasiquote expands at runtime. |
| D20 | VM load-module + handler stack | **Fixed.** `LOAD_MODULE_FILE` returns a module value; handler invocation saves/restores the operand stack. |
| D21 | VM local-slot reuse (found by the fuzzer) | **Fixed.** The VM frame is one mutable array shared with every thunk/closure that captures it; the compiler's slot-restore truncated the compile-time frame, letting a later binding reuse a slot. A nested `let` in a `let*` binding RHS compiled to a thunk that, when forced, clobbered the sibling's reused slot. Fix: slots are reserved for a frame's whole lifetime (freed names marked dead, not truncated). Pinned by `tests/008`. |
| D22 | VM global-scope holes (verified while fixing the `(def x v)` footgun) | **Fixed.** Two tree-walker/VM divergences, both from the VM resolving names it cannot place in a frame via the globals table: (a) a bare top-level `(do (def …) …)` stored its defs as VM globals, leaking them past the block; fix: `EDo` always binds its defs as LOCAL slots (`extend_cenv`/`STORE_LOCAL`), never globals, regardless of `st.cenv = []` — the tree-walker's block-local `env_ref` was already the oracle, and top-level def-visibility-across-forms is a property of the top-level driver (`EDef`/`EDefValue`), not of `do`. (b) module-body expressions (including value defs) resolved *sibling* module defs globally instead of seeing earlier siblings letrec*-style; fix: `EModule` compiles its whole body as a fresh 0-param closure (immediately `CALL`ed) so sibling defs/value-defs get LOCAL slots in a brand-new runtime frame — isolated from both the enclosing scope's slots (no collision) and the enclosing scope's names (matches the tree-walker's fresh `base_env`). Pinned by `tests/039-vm-global-scope.pp` (differential) and by two new fuzzer generators (`stmt_do_scoped_def`, `stmt_module_sibling`, `tools/fuzz.ml`) exercised in `--grammar full`; the two generator exclusions in `docs/TESTING.md` are gone. |

| D23 | Module scope × top-level `let` (found while fixing D22) | **Open.** A module body can see a name bound by a top-level `let` in the VM (top-level `let` is special-cased to bind as a VM global) but not in the tree-walker (a module evaluates in a fresh `base_env`). Pre-existing, unrelated to D22 — confirmed present before and after the D22 fix. The tree-walker is the oracle: a module should NOT see enclosing `let` bindings. Not fuzzer-generated; avoid relying on it until fixed. |