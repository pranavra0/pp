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
  `with-caps`/`perform`/`with-handler` (the `effect` capability-union form is
  REMOVED — M3, a widening backdoor the instant capability values exist),
  `module`/`import`/`load`/`load-module`,
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
- **In-language capability attenuation (M3, docs/PLAN-m3-attenuation.md).**
  `(current-capabilities)` reifies the ambient set (never a mint);
  `cap-restrict` gained an optional `fs_mode` argument (`:ro`/`:rw`/`:wo`,
  matching `--grant`'s names) that only ever narrows — requesting a mode wider
  than the underlying capability holds at that scope is `Capability_error`;
  `(with-caps cap-expr body)` REPLACES the ambient with exactly the (⊆-checked,
  against the CURRENT ambient) requested value for `body`'s dynamic extent, in
  both backends, exception- and tail-safe (the VM's `WITH_CAPS` opcode runs the
  body via a nested call under a real OCaml exception handler, unlike the flat
  enter/exit opcode pairs `with-config`/the removed `effect` used — the only
  way to make an exception genuinely restore the ambient rather than just a
  normal return or tail call). The node boundary is now enforced in BOTH
  directions: a node's free variable that is or contains a capability
  (structurally, closure-env/frame-aware) is `Capability_error` at the key
  computation (`node_key_of`/`vm_node_key`); a node's RESULT containing a
  capability is rejected before it can be stored (`run_node_body`). **Node
  capture is now real**, not vacuous: `thunk.node_caps` is populated from the
  ambient at EACH `(node e)` occurrence's creation (ENode eval / VM
  `MAKE_NODE`), and `force_node`'s hit gate plus the miss recompute's ambient
  both use the forcing thunk's `node_caps` — "the caller's capabilities"
  (LAW 23b) is now defined as capture-at-creation, collapsing to the old
  per-process `--grant` set exactly when `with-caps` goes unused (so
  `tests/011`/`013`/`017` are unaffected byte-for-byte). The differential this
  makes possible for the first time: a node created under a narrowed ambient
  is denied even when later forced under the full grant, and a node created
  under the full ambient still succeeds when forced inside a narrower
  `with-caps` — both directions, both backends, `tests/040-caps-attenuation.sh`.
  Adversarial coverage (forged-from-print text is unparseable, composing two
  narrowed views doesn't resurrect the root, mode/with-caps widen rejection,
  with-caps exception/tail safety, node capture via a direct free var and via
  a closure, node result rejection, `effect` gone) extends
  `tests/capability-adversarial.sh`. Documented residual: a capability hidden
  behind an UNFORCED thunk is invisible to the free-var ban (forcing it just
  to check would violate LAW 14) — the use-time ⊆ gates (`with-caps`, the
  hit-gate) are the actual security floor for that case, not this hygiene
  check.
- **`defmacro` (M3, D10's promise).** A macro is a function from
  syntax-as-values to syntax-as-values: `(defmacro (name params...)
  body...)` receives its argument FORMS already converted by
  `quote_to_value` (the total base, D10/D19), runs its body through the
  tree-walker (LAW 36: expansion is backend-independent by construction,
  since it happens before either backend is even chosen), and the result
  value is converted back to syntax by the new `Types.value_to_expr`
  (quote_to_value's inverse). Expansion is the ONE shared step (`macro.ml`)
  both backends pass through before their own machinery ever sees a form —
  `hash_expr` (the tree-walker's node key, LAW 20) and the compiler both
  operate on already-EXPANDED ASTs, so LAW 20 needed no change: a node whose
  body comes from a macro call is keyed on the EXPANDED code, and an edit to
  only the macro's definition (same call sites) re-keys it
  (`tests/042-defmacro-rekey.sh`, the MASTERPLAN M3 exit-3 criterion). Not a
  reader special form: `(defmacro ...)` parses as an ordinary application
  (reader.ml's own fallthrough for an unrecognized car symbol), so the
  `.ppc`/compiler paths never need to know macros exist. Scope: macros are
  recognized ONLY at the true top level of a file/REPL input (sequential,
  like a value def — used-before-definition is an ordinary unbound-symbol
  error); a `load`ed file shares the loader's macro table (load is
  sequential evaluation). NOT recognized inside `do`/`module`/`fn`/`node`/
  etc. bodies — including node bodies specifically (MASTERPLAN's explicit
  ask): a `defmacro` there is simply left alone by the expander and fails
  as an ordinary unbound-symbol error at eval/compile time, in both
  backends identically (`tests/042`). Hygiene is NOT automatic (not
  required by M3): `(gensym ["prefix"])` produces a fresh symbol using `~`
  as the marker character — genuinely unwritable by the reader
  (`is_symbol_char` excludes it, and no lexer rule claims it either, so a
  bare `~` is a lex error), reset every run for LAW 20 stability. Fuzzer
  arm `stmt_defmacro` (full grammar); differential test `tests/041-defmacro.pp`
  (control-flow macro, gensym-hygiene, a macro building a `(node ...)` form,
  nested macro use, a macro-generated `def`, macro redefinition).
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
- **Q13 — the in-language reconciler-domain protocol (PLAN-m4-cells.md
  §Q13).** `(register-domain {:name :namespace :observe :diff :apply
  :write-cap [:observe-cell]})` — script-tier, consumes `:write-cap` into
  `Runtime.domain_registry` (ONE registry; `register-probe` is now sugar
  for the ⊥-write-authority case). `observe : () -> value` runs fresh
  every pass (never cached); `diff : (observed, desired) -> plan` runs
  PURE under an EMPTY capability set and is itself plan-cached (a direct
  `Store.hit`/`store_object`/`store_trace` key `H(diff-code, observed,
  desired)` with a trace-less, vacuously-verifying entry — no synthetic
  node needed); `apply : plan -> nil` runs under the domain's own
  threaded write-cap, journaled in a generic per-pass `intent <hash> k=v
  …` / `done <hash>` bracket whose fields are the domain's own ordered
  `:summary` (fs: `root=… create=… update=… delete=…`; proc: `started=…
  restarted=… stopped=…`) — core knows nothing about what the fields
  mean. Stratification generalizes to per-domain `:namespace` prefixes,
  with `observed_all` collection SUSPENDED for the whole extent of a
  domain's own observe/diff/apply/verify (the load-bearing new dynamic
  scope). Core re-observes and re-diffs after apply (verify-after-write);
  a non-empty result is a hard error. New trusted primitives
  (`src/domain_prims.ml`): `tree-observe`, `materialize-file`,
  `remove-file`, `proc-spawn`, `proc-alive?`, `proc-stop`, `proc-reap`,
  `domain-state-get/put` (a generic per-domain KV store, replacing
  `procs/`'s role). `src/reconciler.ml` and `src/supervisor.ml` are
  **deleted** — `src/domains.ml` is the generic orchestrator;
  `stdlib/domain-fs.pp` and `stdlib/domain-proc.pp` hold ALL the policy
  (the tree-walk diff, the start/stop/restart decision) as real pp
  source. A third-party toy domain unrelated to fs/proc (`tests/046-
  domains.sh`, "kv": a directory of one-file-per-key values, registered
  from an ordinary pp program via `register-domain` with neither CLI
  flag) exercises plan caching, stratification, cap threading (a missing
  grant is a `Capability_error` from `cap-restrict` itself, before the
  domain ever runs), verify-after-write failure for a deliberately
  under-converging `apply`, the generic journal bracket, and
  fenced-after-domains ordering — proving the protocol is genuinely
  generic, not fs/proc-shaped.
- **Filesystem domain (Q4/LAW 30), now `stdlib/domain-fs.pp` over Q13.**
  `pp --reconcile ROOT prog.pp` auto-loads `stdlib/domain-fs.pp` and
  registers it (write-cap `cap-restrict`'d to ROOT, `:wo` — write-only
  suffices, since the domain observing its OWN managed tree to converge
  is not a distinct authority concern), treating the program's final
  value — a map of relative paths to string contents — as the desired
  state of the domain under ROOT: diffs against observed reality (content
  hashes re-derived from the tree via the `tree-observe` primitive, no
  trusted state file), journals `intent`/`done` to `~/.pp/store/journal`,
  applies via `materialize-file` (temp + `rename(2)`, parents created)
  with verify-after-write, and deletes unmanaged files via `remove-file`
  (single writer — the fs write grant over ROOT is required and is the
  consent). Stratification (LAW 30): every cell observation the program
  makes is collected (`Runtime.observe_all`, now unconditional — a
  register-domain program needs it with no CLI flag at all), and a
  desired state that observed its own domain is refused. Both backends.
  Pinned by `tests/018-reconcile.sh`, UNCHANGED byte-for-byte across the
  Q13 migration. Desired contents may be inline strings or CAS
  references: `(blob S)` ingests bytes into `blobs/` and returns
  `blob:<sha256>`; the domain's diff (`stdlib/domain-fs.pp`) compares by
  hash without loading bytes and materializes from the store — `rm -rf
  build/` + re-reconcile restores the tree with zero tool re-runs when
  the desired-map nodes hit (`tests/023`). Grant the output domain
  WRITE-ONLY (`fs:<root>:wo`): a read-capable grant over it would make
  `run`'s coarse tree cell observe the domain and trip stratification.
  Combine with `--watch` for continuous reconciliation (every registered
  domain, not just this one, is now re-checked every tick).
- **Process domain (Phase 2), now `stdlib/domain-proc.pp` over Q13.**
  `pp --supervise prog.pp` (typically `pp --watch --supervise`)
  auto-loads `stdlib/domain-proc.pp` and registers it; the program's
  final value is a map of service-name → spec, kept in sync with observed
  processes: starts missing services, stops removed ones, restarts a
  service when its spec changes (compared STRUCTURALLY via `hash-value`,
  which canonicalizes map-key order the same way the on-disk codec does —
  a spec round-tripped through `domain-state-get/put` must not spuriously
  compare "different" purely from key reordering), and reaps/restarts a
  process killed with `kill -9` within one poll interval. Process state
  lives in `~/.pp/store/domain-state/proc/` (the generic per-domain KV
  store, replacing `procs/`'s role — the domain maintains its own
  "known-services" index, since there is still no OS process
  enumeration) and every start/stop is journaled intent/done, owned
  verbatim by the `proc-spawn`/`proc-stop` primitives. Requires `--grant
  process`; a desired state that observed a `proc:` cell (its own domain)
  is refused (LAW 30 stratification). Both backends. Pinned by
  `tests/033-process-reconciler.sh`, UNCHANGED byte-for-byte across the
  Q13 migration.
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
- **Probes (LAW 37/38, docs/PLAN-m4-cells.md).**
  `(register-probe name observe-fn read-cap)` (script-tier, `Runtime.
  domain_registry` — unified with Q13's `register-domain` in stage 2: a
  probe is now sugar for the ⊥-write-authority case, `:diff`/`:apply =
  None`, one registry not two) and `(probe name)` (inside or outside
  nodes) are the one
  sanctioned nondeterministic dependency: the observe-fn runs at most once
  per pass, OUTSIDE the reading node's trace stack (`trace_stack` saved to
  `[]` via `with_ref`, exception-safe) and under exactly the registered
  read-cap (`with_ref current_capabilities`), so its own world-reads never
  contaminate the reading node's trace; the reading node records only a
  `probe:<name>` cell (hash of the observed value) via ordinary
  `record_read`, capability-free at the read site — the authority was spent
  evaluating the probe, once. Results pin in `Runtime.probe_values`,
  in-memory only, cleared at the same three points the `--watch` loop clears
  `Store.run_pins`; nothing a probe returns is ever written to
  `~/.pp/store`. An unregistered probe name is a hard error; a probe never
  read never fires. `Cell.Probe`/`Store.observe_cell`'s `probe:` arm
  re-evaluate the SAME cached-per-pass value a live `(probe name)` read
  would (`Runtime.probe_observer` hook, mirroring `proc_observer`), so a
  node's cached trace and a fresh read can never disagree. Both backends
  (ordinary primitives — the VM shares `Primitives.builtins`). Pinned by
  `tests/043-probes.sh`.
- **M4 stage 1 — sealed cells (LAW 39).** `--grant secret:<path>` mints
  `CapSecret {path}` (canonicalized at mint like fs grants). `slurp`/`(perform
  read-file ...)` now dispatch on GRANT coverage (`Process.read_dispatch`,
  shared by both primitives): covered by `CapFilesystem` (with or without
  ALSO `CapSecret`) → ordinary `VString`, unchanged; covered by `CapSecret`
  and NOT `CapFilesystem` → a new value kind `VSealed`, read via
  `Store.read_sealed_cell` (bytes pinned in `Runtime.sealed_pins`,
  in-memory only, `store_blob` NEVER called) and recorded as a
  `sealed:<canonical-path>` cell (hash of the bytes). `string_of_value`
  redacts every `VSealed` to `#<sealed>` (every printer goes through it, so
  redaction is total); `Codec.encode_value` returns `None` for it (the
  non-data law covers it for free); the M3 node-boundary walk
  (`contains_capability` → `contains_authority`) bans `VSealed` exactly like
  `VCapability`, both directions, both backends, wording the error
  distinctly ("... a sealed value" vs "... a capability" — `Hasher.
  contains_sealed` disambiguates). `cell_authorized_for` requires a covering
  `CapSecret` grant to serve a `sealed:` hit (LAW 23b/23c fall out: a narrow
  caller cannot launder a cached secret through an aggregator; `pp why`
  redacts it). `(unseal v)` is the one explicit, greppable way to `VString`
  — no dataflow tainting beyond it, by design. A recursive scan of
  `~/.pp/store` after a program that reads (and, separately, one that
  unseals only at script tier) finds no secret bytes. Pinned by
  `tests/044-sealed.sh`.
- **M4 stage 1 — network.** `CapNetwork` is now `{host; port option}` (a
  shape change from the earlier bare `{protocol}`); `--grant
  net:<host>[:<port>]` mints it (`host = "*"` wildcards, an unspecified port
  is unrestricted). `(perform http-get url)` / `(perform http-post url
  body)` fork `curl` (`Process.http_request` — zero new OCaml
  networking/TLS surface, E6) but are authorized against `CapNetwork`
  host[:port], never `CapProcess` (granularity: "may read this host" ≠
  "may exec anything"); banned inside node bodies outright (a `trace_stack`
  guard, the same shape as `fenced`/`write-file`'s node arm — a network read
  is not the declared-nondeterminism mechanism and is not convergent, so it
  has no sound cached meaning). Result shape: `{"status" INT "body"
  STRING}`. A missing `curl` is a clean error, not a crash. Both backends
  (an ordinary `perform_effect` dispatch, shared). The differential fuzzer
  never generates `--grant` specs at all (checked: no grant-generating arm
  exists), so the CapNetwork shape change needed no fuzzer update — noted
  rather than silently skipped. Pinned by `tests/045-network.sh` (skips
  cleanly without `curl`/`python3`).
- **M5 stage A — cluster transport, signed tokens, by-hash sync**
  (docs/PLAN-m5-distribution.md; gated on docs/THREAT-MODEL-cluster.md,
  now written). `pp cluster-init` mints `~/.pp/cluster/{secret,id}` (a
  32-byte Cryptokit-RNG secret, hex-encoded, mode 0600, `O_EXCL`-refuses to
  overwrite); a signed cluster token (`src/token.ml`) is canonical TEXT —
  `(cluster-token (SPECS...) "cluster-id" issued expires "mac")`, never a
  pp value — minted from the SAME `--grant`-grammar spec strings and
  parsed back with the SAME `Capabilities.parse_grant` `pp --grant` uses
  (moved there from a local main.ml closure so both share it). `Token.verify`
  checks MAC -> cluster id -> expiry -> caps, in that order, so a forged
  token never reaches the capability parser. `src/transport.ml`'s
  `TRANSPORT` module type (push/pull of hash-named objects/blobs/traces +
  a control request/reply channel in canonical text) has a `LocalDir`
  implementation (a second store-shaped root, plain file copy, the CI
  loopback) and an `Ssh` stub (every operation a clear "not yet" error —
  stage B's real remote member). The receiving side ALWAYS re-hashes
  before accepting: `ingest_object`/`ingest_blob` decode-and-hash-compare,
  `ingest_trace_lines` rejects any unparseable line, and these are the
  ONLY functions in the module that write a remote-sourced artifact into
  the local store — structurally, not just conventionally, unbypassable.
  `Transport.serve_hit` — given (node-key, token) — verifies the token,
  then calls the UNCHANGED `Store.hit ~authorized:(cell_authorized_for
  (token_to_caps token))`: zero new authority code, the existing LAW 23b
  gate fed a wire-verified capability list. A hit pushes only the trace(s)
  the token's own caps cover (defense in depth on top of LAW 23c, which
  already redacts at read time regardless); a miss or a denied token
  pushes nothing at all. Two `pp` process invocations differing only in
  `$HOME` stand in for two cluster members (Store.store_root is a
  process-wide singleton fixed at startup — see transport.ml's header for
  why this, not a true single-process dual-store, is the CI shape).
  Sealed values remain unshippable by construction (M4's existing node
  boundary; a defense-in-depth re-check in `decide`/`push_object` refuses
  to ship anything that fails to re-encode as data, though this is
  unreachable given `Codec`'s grammar). Remote placement, host-qualified
  domain distribution, and store GC (M5's remaining stages) are NOT part
  of this work. Pinned by `tests/047-cluster-sync.sh` (T1 corruption
  rejected for objects/blobs/traces; T2 tampered-MAC and expired tokens
  denied; T3 LAW 23b across the wire; T4 why-redaction survives sync,
  byte-identical to a local run; T5 no secret bytes cross; T6-partial:
  identical key/result hash whether built locally, independently, or via
  serve-hit).
- **M5 stage B — remote placement** (docs/PLAN-m5-distribution.md "Remote
  placement" / "Q11-bis"). `Scheduler.policy` gains `Remote of string`
  (`--schedule remote:<member>`); membership is ambient
  (`~/.pp/cluster/members` or `$PP_CLUSTER_MEMBERS`, mapping a member name
  to its store-root path — never `--grant`, an address is not an
  authority ceiling). A batch's data-closed predicate
  (`Evaluator.is_data_closed`) reuses `Codec.encode_value` at the free-var
  values — the store's own non-data check — with one necessary, documented
  carve-out: a bare reference to a global primitive (`VBuiltin`, present in
  the base env `Primitives.initial_env` populates) is code identical on
  both sides by construction and is not "shipping code" the way a captured
  `VClosure` would be, so it doesn't block shipping; a genuinely captured
  closure still correctly fails and stays local. `src/remote.ml`
  (compiled after Evaluator/Transport/Token, wiring itself into a new
  `Scheduler.remote_dispatch_hook` — the same cycle-breaking indirection
  the `Primitives.*_ref` values already use) ships a data-closed batch to a
  member by: pre-observing the granted fs-read scope (Q11-bis,
  coarse-but-sound) and pushing every file directly into the member's own
  store as blobs; minting a cluster token from this process's own
  top-level `--grant` specs; spawning the member as an ORDINARY second
  `pp` invocation of the byte-identical program (own $HOME, `--schedule
  serial`, a new internal `--remote-node` flag) — no "force only key K"
  surface, no second evaluate-on-member function, the member simply runs
  `run_node_body` via its own completely normal `main.ml` control flow;
  and pulling each assigned key back via the UNCHANGED stage-A
  `Transport.serve_hit`/`recv_hit` pair, re-hash-verified same as every
  other synced artifact — extended (in `remote.ml`, not `transport.ml`) to
  also ship "blob:" refs embedded in a node's RESULT value (the
  `(blob (slurp ...))` compile-output pattern; `blob`/`blob-get` are
  deliberately untraced, so `Transport.decide`'s `tr_reads`-derived
  blob_hashes alone miss them). Q11-bis pre-seeding is unbypassable by
  construction: `Store.run_pins`/`read_file_cell`/`observe_cell` already
  consult the pin table FIRST, unconditionally, before ever touching disk
  for a `file:` cell; populating it before `run_files` executes a single
  expression means the disk-read branch is structurally unreachable for a
  pre-seeded cell, proven by a differing-file test (`tests/048`, via a
  test-only `PP_REMOTE_TEST_HOOK`/`_AFTER` synchronization seam simulating
  the network-latency window a real dispatcher/member gap occupies).
  `tool:` cells are deliberately NOT pre-seeded (the member's own `cc` is a
  legitimate distinct observation, proven via the member's own journal).
  Every degrade path (unknown/unreachable member, a nonzero/crashed
  member, a non-data-closed free var, a malformed reply) leaves the
  affected keys an ordinary store Miss — the caller's existing
  `force_deep_plain`/`force_node` Miss path computes them in-process
  exactly like a dead local Parallel/Race worker; never a wrong answer or
  a hang. **Wall (found, not fixed — out of stage-B scope):** `--reconcile`
  unconditionally preloads `stdlib/list.pp` as domain glue, and list.pp's
  own pp-level `map` SHADOWS the batching-aware `map` BUILTIN Phase 3
  added, silently defeating `collect_unevaluated_nodes` (so parallel/race/
  remote all degrade to serial-shaped one-at-a-time forcing) for ANY
  `--reconcile`-based build — masked in `tests/024`'s own parallel exit
  criterion by exec-count-only assertions plus a soft timing check that
  already accepts "no speedup" as a pass. `tests/048` avoids `--reconcile`
  (direct top-level `write-file` materialization) to exercise the
  scheduler correctly; a real fix belongs to Phase 3/reconcile, not M5.
  Pinned by `tests/048-remote-placement.sh` (an 8-TU real-cc build,
  byte-identical materialized tree + desired-state hash vs serial;
  cross-machine hit; the differing-file Q11-bis case; non-data-closed
  stays local; unreachable member degrades; VM parity).
- **M5 stage C — host-qualified domain distribution + store GC, CLOSING
  M5** (docs/PLAN-m5-distribution.md "Host-qualified domain distribution" /
  "Store GC"). Two additive pieces; neither changes a byte of
  `src/domains.ml`'s `run_all`/`run_domain`.

  *Host-qualified distribution.* The desired map generalizes ONE level:
  `{host -> {domain -> desired}}`. Detection rule (the least-magic option
  the contract asked for, picked over shape-sniffing): a NEW `--member-name
  <n>` CLI flag (main.ml), explicit opt-in only. `select_member_slice`
  (main.ml) is the identity function when the flag is absent — so
  `all_desired` reaches `Domains.run_all` completely unchanged, and every
  program/flags combination that never mentions `--member-name` (every
  test predating this stage: `tests/018`, `tests/033`, `tests/046`, `047`,
  `048`, all still green unchanged) is the back-compat proof, not merely
  an assertion about it. With the flag, `select_member_slice` indexes the
  one matching host key (string or keyword) and hands `Domains.run_all`
  only that slice; an unknown `--member-name` is a hard, named error, not
  a silent no-op. `kill -9` convergence is the local supervisor's existing
  per-machine story, verbatim: a member is simply `pp --watch [--supervise]
  --member-name <n>` on its own slice, re-derived from scratch every pass
  exactly as before — M5 adds a new SOURCE for the desired value, no new
  mechanism (`tests/049-host-domains.sh`).

  *The by-hash desired-value seam.* Built: a LOCAL-DIR two-store version
  proving the mechanism (deferred: an ssh-backed variant — stage A's `Ssh`
  stub already covers that gap; a real deployment's own "which member,
  when" policy). `--publish-object <shared-root>` runs a program, stores
  its fully-forced value as an ordinary content-addressed object
  (`Types.hash_value`), and pushes it PLUS every `blob:` ref it names into
  `shared-root` via the UNCHANGED stage-A `Transport.LocalDir.push_*`;
  `--desired-object <hash> <shared-root>` pulls both (re-hash-verified —
  T1 unchanged) and SUBSTITUTES them for the derivation of the desired
  state entirely (`compute_all_desired`, main.ml) — the recorded program
  still runs, for domain-registration side effects only, and its own
  return value is discarded. `Blobref.blob_refs_in` (new: `src/blobref.ml`)
  factors the "blob:<hash>" structural scan out of `src/remote.ml` — GC's
  mark (below) needs the identical scan and is compiled before `remote.ml`,
  so duplicating it a second time was the wrong call. Never syncs fenced
  actions or journals — only the value object and its blob: refs ever
  cross (`tests/051-cluster-exit.sh`).

  *Store GC (`pp gc` — explicit, never automatic).* Roots = the last N
  successful `Domains.run_all` passes' desired-state root hashes: a NEW
  frozen journal entry, `Journal.Epoch { hash }` (line `epoch HASH`, never
  rotated, greppable — the one honest bookkeeping addition the contract
  asked for), plus a companion REPLAYABLE manifest, `src/gcroots.ml`
  (`~/.pp/store/gc-roots`, one Codec-encoded record per root — not the
  frozen journal grammar, since it needs richer, evolvable structure:
  files/grants/`--bytecode`/`--reconcile`-root/`--supervise`/
  `--member-name`/`--desired-object`, capped to the last
  `--gc-keep-epochs` (default 5) entries). **Mark by REPLAY**, the
  contract's own load-bearing finding (traces do not record child-keys —
  there is no on-disk node graph to walk, so the only way to discover what
  a root's closure touches is to re-run it): `pp gc` spawns each recorded
  root as an ordinary `pp <same files/grants/flags> --gc-mark <outfile>`
  subprocess (`src/store_gc.ml`) that runs the program EXACTLY as a live
  pass would — so every `Store.hit` it makes marks its trace/object/
  blob(s) live (`Store.gc_marking`/`gc_live`/`mark_live`, store.ml, plus
  the embedded-`blob:`-ref scan via `Blobref.blob_refs_in`) — but SKIPS
  `run_domains_pass` and `Fenced.recover_unknown`/`drain` entirely: no
  domain apply, no fenced action, ever, during a replay (main.ml's
  `--gc-mark` branch). This makes mark read-only on the world BY
  CONSTRUCTION: the only way a replay could still perform a real write or
  subprocess exec is if the world genuinely drifted since the epoch and a
  node MISSES — documented as an honest residual (a drifted replay behaves
  like any ordinary rebuild: real but idempotent recomputation, never a
  hidden unsoundness; over-marking from a fresh recompute is always safe).
  Swept: ONLY `objects/`, `traces/`, `blobs/` — `fenced-specs/`, `procs/`,
  `journal/`, and the islands cache (`~/.pp/islands`, an explicitly
  separate lifecycle) are never touched. Concurrency safety
  (`src/store_gc.ml`): a creation-time grace period (`--gc-grace-seconds`,
  default 2.0s — nothing younger is EVER a deletion candidate) plus a
  delete-time re-check of the roots manifest's raw bytes immediately
  before each unlink (a reconcile pass completing concurrently aborts the
  rest of that sweep rather than risk deleting something the new epoch
  needs); if even ONE recorded root fails to replay, the WHOLE sweep is
  refused outright — every choice biases toward "keep it", since
  over-retention is always safe and deleting live data is the only hazard.
  Pinned by `tests/050-gc.sh`: store size stays bounded across repeated
  one-shot `--reconcile` passes AND a genuine long-running `--watch` loop
  racing a concurrent `pp gc` (not merely simulated by separate
  invocations); the kept root's closure survives (a subsequent identical
  rebuild is a pure cache hit, byte-identical materialized tree); the T7
  concurrent-parallel-build-races-GC stress (no crash, correct result,
  byte-identical subsequent rebuild); the islands cache untouched; an
  empty store is a clean no-op.

  *What's genuinely proven vs. what a real (non-loopback) cluster still
  needs:* host-keying's OWN mechanism (`select_member_slice`) and the
  by-hash pull/push seam are both real and tested across genuinely
  separate `$HOME`s (the same "two machines" convention stages A/B use);
  what remains loopback-only is the TRANSPORT underneath both (local-dir,
  same residual stages A/B already carry — ssh is stubbed, not this
  stage's job) and the "which member runs which host's slice" policy
  (still a hand-authored members file / explicit flags, not service
  discovery). GC's mark-by-replay is real (a genuine subprocess re-run
  with a real mark side-channel), not simulated; its own residual is the
  documented drift-behaves-like-a-rebuild case above.

## Discrepancy ledger (D1–D26)

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
| D10 | Fexprs are operatives over syntax | **Cut, promise redeemed.** `def-fexpr` removed. Metaprogramming is served by total `quote`/`quasiquote` and `defmacro` (M3, `macro.ml`): a shared expansion point ahead of both backends, `value_to_expr` as `quote_to_value`'s inverse, `gensym` for manual hygiene (`tests/041`, `tests/042-defmacro-rekey.sh`). |
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
| D24 | VM dynamic-extent scoping under OCaml exceptions (found during M3 attenuation) | **Open.** The VM's flat enter/exit-opcode pattern for `with-handler`/`with-config` is not exception-safe: an OCaml exception raised mid-body unwinds past the exit opcode, leaking the installed handler/config past the error (confirmed by direct test). The tree-walker's `with_ref` restores correctly, so the backends diverge on error paths that install then observe dynamic extent — narrower than D9's claim (D9 fixed normal-return and tail-call restore, not exception unwind). `with-caps` deliberately does NOT use the flat pattern (its VM body runs via nested `run_isolated` under a real try/with) and is immune. Fix: give with-handler/with-config the same nested-run shape or an unwind-protect discipline. |
| D26 | Parallel batching defeated under `--reconcile` — two compounding causes (found integrating M5 stage B, via a new deterministic fork-count guard) | **Fixed.** Two bugs stacked. (a) `stdlib/list.pp` defined a pp-level `(def (map f lst) (cons (f (car lst)) …))` that SHADOWED the batching-aware `map` BUILTIN; because application is strict (LAW 20 / `EApply` forces every argument, incl. `cons`'s), the pp `map` forced each `(compile n)` node inline — so `force-deep`'s `collect_unevaluated_nodes` saw zero unevaluated persistent thunks and dispatched nothing. `--reconcile`/`--supervise` auto-load `list.pp` for the domain libraries, so every reconcile build silently ran its compiles one-at-a-time under `parallel:`/`remote:`. Fix: removed the pp `map` (the builtin supersedes it) with a NOTE forbidding re-adding it. (b) The `bin/pp` binary loads stdlib from `_build/default/stdlib/` — dune's mirror — which was remirrored ONLY by `dune runtest`'s rule, never by a plain `dune build`. So the source fix to (a) was invisible to `bin/pp --reconcile` until a `runtest` happened to refresh the mirror — which is why the same program forked 6 one run and 0 the next (a stale-mirror heisenbug that misdirected the whole first investigation). Fix: root `dune` now ties `(source_tree stdlib)` to the `@default` alias (`dune build`), so the mirror can never go stale relative to `main.exe`. The masking meta-bug: M1's original wall-clock speedup assertion accepted "no speedup" as "no spare cores," hiding (a) after M4 introduced the auto-load. Now `tests/024`'s deterministic `p3-parallel-forked` assertion (fork count via `PP_FORK_LOG`) requires ≥ TU forks — 101/101 after the fix, ~3.3x speedup, from a clean `_build`. |
| D25 | Content-addressed `let`-memoization silently caches repeated `perform` calls (found landing Q13) | **Fixed, with a residual discipline, not a language change.** `(perform domain-state-get …)` sat behind an ordinary `let` in `stdlib/domain-proc.pp`'s `proc-known-names` — LAW 20's `make_thunk_ca` keys a `let`-thunk on `(expr, env_hash, caps_hash, cfg_hash, handlers_hash)`, and a ZERO-ARGUMENT closure called twice in the same dynamic extent (once for `domains.ml`'s plan pass, once for its verify re-observe; or twice within one `apply`, for two services' bookkeeping) has an UNCHANGING env and, under `with_domain`'s fixed cap, an unchanging ambient — so the key is IDENTICAL and the second call silently replayed the first's memoized result instead of re-reading reality. Invisible: no exception, no error text — a killed service looked "still alive" one call later, entirely in-process. Repro: register a domain whose `:observe` reads `domain-state-get` inside a 0-arg helper, run reconcile, observe verify-after-write fail (or, worse, silently "succeed" while stale). Fix, two-part: (1) `Domains.call_uncached` pushes a fresh, unique `config-stack` layer before every `observe`/`apply` call — folded into `make_thunk_ca`'s key, guaranteeing each of the two TOP-LEVEL calls a pass makes gets a distinct key (`diff` is deliberately EXCLUDED — its memoization IS the plan cache and must stay content-keyed); (2) within a single call, the general/robust rule is mechanical, not automatic: never call a zero-argument `perform`-containing accessor more than once per dynamic extent — read once, thread the result through explicitly as an ordinary argument (a parameterized call is immune by construction, since a differing argument value changes the env hash). `stdlib/domain-proc.pp`'s `known-services` bookkeeping was restructured this way (`proc-apply` reads it once, via `foldl`'s seed, and writes it once at the end). No core semantics changed; this is a documented authoring discipline for domain policy code (and, latently, for ANY pp code that calls a 0-arg impure accessor more than once per extent), surfaced because Q13 was the first feature to call the SAME pp closure twice, deliberately, from OCaml orchestration. |