# Changelog

All notable changes to pp are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions before
v0.2.0 predate this file and are reconstructed from history for context.

## [Unreleased] — v0.2.0

- **M5 stage A: cluster transport, signed tokens, by-hash sync**
  (docs/PLAN-m5-distribution.md; gated on docs/THREAT-MODEL-cluster.md).
  Remote placement, host-qualified domain distribution, and store GC are
  later stages of M5 and are NOT part of this change.
  - **Threat model** (docs/THREAT-MODEL-cluster.md): scope, assets,
    adversaries considered/not-considered, trust anchors, and seven
    falsifiable claims (T1–T7), in `docs/THREAT-MODEL-islands.md`'s house
    style.
  - **Signed capability tokens** (`src/token.ml`): `pp cluster-init` mints
    `~/.pp/cluster/{secret,id}` (a 32-byte Cryptokit-RNG secret, hex,
    mode 0600, `O_EXCL`-refuses to clobber an existing one). A token is
    canonical TEXT — `(cluster-token (SPECS...) "cluster-id" issued
    expires "mac")` — never a pp value, minted from the same `--grant`
    spec strings and parsed back with the same parser (`Capabilities.
    parse_grant`, moved out of a local main.ml closure so both share it).
    `Token.verify` checks MAC -> cluster id -> expiry -> caps, in that
    order; `token_to_caps` hands back a capability list usable directly as
    `Store.hit ~authorized:(cell_authorized_for ...)` — zero new authority
    code.
  - **Transport** (`src/transport.ml`): a `TRANSPORT` module type
    (push/pull of hash-named objects/blobs/traces + a control
    request/reply channel in canonical text) with a `LocalDir`
    implementation (a second store-shaped root, plain file copy — the CI
    loopback) and a stubbed `Ssh` (every op a clear "not yet", drops in
    later behind the identical shape). The receiving side ALWAYS
    re-hashes an artifact against its claimed name before accepting it —
    `ingest_object`/`ingest_blob`/`ingest_trace_lines` are the ONLY
    functions that write a remote-sourced artifact into the local store,
    so there is no bypass path; a mismatch is a hard error naming the
    artifact, never a silent accept.
  - **serve-hit**: given (node-key, token), verifies the token, then calls
    the UNCHANGED `Store.hit ~authorized:(cell_authorized_for
    (token_to_caps token))` and, on a hit, pushes only the result object +
    the trace(s) the token's own caps cover + any file-cell-backed blobs —
    nothing crosses on a miss or a denied token. Exercised via two `pp`
    process invocations differing only in `$HOME` (Store.store_root is a
    process-wide singleton fixed at startup, so two stores means two
    processes — documented in transport.ml's header) rather than a
    single-process dual-store or a real ssh round trip.
  - **Sealed non-regression**: a node touching a sealed value already
    fails at M4's existing node boundary, so there is nothing for
    serve-hit to ever find for that key; a defense-in-depth re-check in
    `decide`/`push_object` refuses to ship anything that fails to
    re-encode as data, even though this is unreachable given `Codec`'s
    grammar.
  - `tests/047-cluster-sync.sh`: T1 (corrupted object/blob/trace rejected
    on `--transport-pull`), T2 (tampered-MAC and expired tokens denied),
    T3 (LAW 23b across the wire — an out-of-scope token's closure gets a
    miss, a covering token gets a hit, for the identical key), T4 (`pp
    why` redaction over a synced trace is byte-identical to a local run
    under the same narrow grant), T5 (no secret bytes anywhere the sync
    touched), T6-partial (identical key/result hash whether built locally,
    independently, or fetched via serve-hit).
- **M5 stage B: remote placement** (docs/PLAN-m5-distribution.md "Remote
  placement" / "Q11-bis", over the stage-A transport above). Host-
  qualified domain distribution and store GC are the remaining M5 stages
  and are NOT part of this change.
  - **`Scheduler.policy` gains `Remote of string`** (`--schedule
    remote:<member>`), dispatched exactly like `Parallel`/`Race` via
    `dispatch_batch`, through a new `remote_dispatch_hook` ref wired at
    startup by `src/remote.ml` — the same cycle-breaking indirection
    Evaluator/VM already use for `Primitives.*_ref` (Transport depends on
    Evaluator, so the remote dispatcher needs to sit above both, not
    inside Scheduler itself).
  - **Data-closed predicate** (`Evaluator.is_data_closed`): a batch job
    ships only when every free var's forced value re-encodes under
    `Codec.encode_value` — the store's own non-data law, reused verbatim,
    with one documented carve-out (a bare `VBuiltin` reference is code
    identical on both sides by construction, not "shipping code," so it
    doesn't block shipping the node; a genuinely captured `VClosure`
    still correctly fails). Non-data-closed jobs are simply left alone —
    the caller's existing local Miss path computes them in-process.
  - **Members file** (`~/.pp/cluster/members` or `$PP_CLUSTER_MEMBERS`):
    `name store-root-path` lines, ambient config, never `--grant` (an
    address is not an authority ceiling).
  - **Remote dispatch** (`src/remote.ml`): pre-observes the granted
    fs-read scope and pushes every file directly into the member's store
    as blobs (Q11-bis); mints a cluster token from this process's own
    top-level `--grant` specs; spawns the member as an ORDINARY second
    `pp` invocation of the byte-identical program (own `$HOME`,
    `--schedule serial`, new internal `--remote-node` flag) — no second
    "evaluate on a member" code path, the member calls
    `Evaluator.run_node_body` via its own completely normal `main.ml`;
    pulls each assigned key back via the UNCHANGED stage-A `serve-hit`/
    `recv-hit` pair. Extended (in `remote.ml`, not `transport.ml`) to
    also ship "blob:" refs embedded in a node's RESULT value — the
    `(blob (slurp ...))` compile-output pattern `blob`/`blob-get` use,
    deliberately untraced so stage A's `tr_reads`-derived `blob_hashes`
    alone would miss it.
  - **Q11-bis (sandbox-inputs-by-hash)**: the member pre-seeds
    `Store.run_pins` from the wire BEFORE `run_files` executes a single
    expression; `read_file_cell`/`observe_cell` already consult the pin
    table first, unconditionally, so a pre-seeded cell's own-disk read is
    structurally unreachable, not merely avoided by convention. `tool:`
    cells are deliberately NOT pre-seeded (the member's own toolchain is
    a legitimate distinct observation).
  - **Degrade paths**: an unreachable/unknown member, a nonzero/crashed
    member subprocess, a malformed reply, or a failed pull all leave the
    affected keys an ordinary store Miss — computed in-process exactly
    like a dead local Parallel/Race worker; never a wrong answer or a
    hang.
  - **Wall found, not fixed (out of stage-B scope):** `--reconcile`
    unconditionally preloads `stdlib/list.pp`, whose own pp-level `map`
    shadows the batching-aware `map` builtin Phase 3 added — silently
    defeating `collect_unevaluated_nodes` (so parallel/race/remote all
    degrade to one-at-a-time forcing) for ANY `--reconcile`-based build.
    Masked in `tests/024`'s own parallel exit criterion by exec-count-only
    assertions plus a soft timing check that already accepts "no speedup"
    as a pass. `tests/048` works around it (direct top-level `write-file`
    materialization); a real fix belongs to Phase 3/reconcile.
  - `tests/048-remote-placement.sh`: an 8-TU real-cc build under
    `--schedule remote:<member>`, byte-identical materialized tree +
    desired-state hash vs serial; cross-machine hit; the differing-file
    Q11-bis case (a test-only `PP_REMOTE_TEST_HOOK`/`_AFTER`
    synchronization seam proves the member used the dispatcher's pinned
    bytes, never its own transiently-different disk); non-data-closed
    stays local; unreachable member degrades; `tool:` not pre-seeded; VM
    parity.
- **M4 stage 1: probes, sealed cells, network** (docs/PLAN-m4-cells.md).
  Three additive features, one model — a cell whose write-discipline core
  enforces mechanically.
  - **Probes** (SPEC LAW 37/38, now holds): `(register-probe name observe-fn
    read-cap)` (script-tier, `Runtime.probe_registry`) and `(probe name)`
    (inside or outside nodes) are the sanctioned nondeterministic
    dependency. The observe-fn runs at most once per pass, OUTSIDE the
    reading node's trace stack (`trace_stack` saved to `[]` via the
    exception-safe `with_ref` pattern) and under exactly the registered
    read-cap; the reading node records only a `probe:<name>` cell (hash of
    the observed value) via ordinary `record_read`, capability-free at the
    read site. Results pin in `Runtime.probe_values`, in-memory only,
    cleared at the same three points `--watch`'s loop clears
    `Store.run_pins`; `Store.observe_cell`'s new `probe:` arm re-observes
    through the same cache (`Runtime.probe_observer` hook, mirroring
    `proc_observer`) — including live under a running `pp --watch` process,
    with no probe-specific polling logic at all. New `Cell.Probe` kind.
  - **Sealed cells** (new SPEC LAW 39): `--grant secret:<path>` mints a new
    `CapSecret {path}` capability kind (canonicalized at mint like fs
    grants). `slurp`/`(perform read-file ...)` dispatch on grant coverage
    (`Process.read_dispatch`, shared): fs-covered (with or without ALSO a
    secret grant) is unchanged plain `VString`; secret-covered and NOT
    fs-covered returns a new value kind, `VSealed` — bytes pinned in-memory
    only (`Runtime.sealed_pins`, `store_blob`/the CAS NEVER called) and
    recorded as a `sealed:<canonical-path>` cell (hash of the bytes).
    `string_of_value` redacts every `VSealed` to `#<sealed>`;
    `Codec.encode_value` returns `None` for it; the M3 node-boundary walk
    (renamed `contains_capability` → `contains_authority`, plus a new
    `contains_sealed` for precise error wording) bans `VSealed` exactly like
    `VCapability`, both directions, both backends; `cell_authorized_for`
    requires a covering `CapSecret` grant to serve a `sealed:` hit.
    `(unseal v)` is the one explicit way out to `VString`.
  - **Network**: `CapNetwork` is now `{host; port option}` (was `{protocol}`
    — `--grant net:<host>[:<port>]`, `host = "*"` wildcards). `(perform
    http-get url)` / `(perform http-post url body)` fork `curl`
    (`Process.http_request` — zero new OCaml networking/TLS surface)
    authorized against `CapNetwork` host[:port], not `CapProcess`; banned
    inside node bodies (`trace_stack` guard, mirroring `fenced`). Result
    shape: `{"status" INT "body" STRING}`.
  - New tests: `tests/043-probes.sh`, `tests/044-sealed.sh` (whole-store
    recursive scans prove no secret bytes ever land in the store),
    `tests/045-network.sh` (gated cleanly on `curl`/`python3`, a loopback
    fixture, no real network). All 592 pre-existing tests and the fuzzer
    (`core`+`full`, 2000 programs each) are unaffected. See
    [docs/SPEC.md](docs/SPEC.md) (LAW 37, LAW 38, LAW 39, LAW 22/26
    amendments), [docs/STATUS.md](docs/STATUS.md),
    [docs/MASTERPLAN.md](docs/MASTERPLAN.md) (M4).
- **M4 stage 2: Q13, the in-language reconciler-domain protocol**
  (docs/PLAN-m4-cells.md §Q13) — the M4 exit criterion. `src/reconciler.ml`
  and `src/supervisor.ml` are **deleted**; `(register-domain {:name
  :namespace :observe :diff :apply :write-cap [:observe-cell]})` is the
  new script-tier primitive (`Runtime.domain_registry` — unified with
  stage 1's probe registry: `register-probe` is now sugar for the
  ⊥-write-authority case). `observe : () -> value` runs fresh every pass;
  `diff : (observed, desired) -> plan` runs PURE under an empty capability
  set and is itself plan-cached (a direct `Store.hit`/`store_object`/
  `store_trace` key, no synthetic node); `apply : plan -> nil` runs under
  the domain's threaded write-cap. A plan is `{:items :summary}` —
  `:summary` an ORDERED VECTOR of `[key value]` pairs the domain itself
  assembles (a vector, not a map, so plan-cache round-trips through the
  store's canonicalizing codec cannot reorder it). New generic per-pass
  journal bracket (`Journal.DomainIntent`/`DomainDone`, replacing the
  fs-only `FsIntent`/`FsDone`) reproduces the pre-Q13
  `root=R create=C update=U delete=D` shape for fs and a different
  vocabulary for any other domain, verbatim from that domain's own
  `:summary`. Stratification (LAW 30) generalizes to per-domain
  `:namespace` cell-prefix lists, with `Runtime.observed_all` collection
  SUSPENDED for a domain's own observe/diff/apply/verify extent (load-
  bearing; does not suspend `trace_stack`) — and is now collected
  UNCONDITIONALLY (previously gated on `--reconcile`/`--watch`/
  `--supervise`), since a bare `register-domain` program needs it with no
  CLI flag at all. New trusted primitives (`src/domain_prims.ml`, moved
  from the deleted modules): `tree-observe`, `materialize-file`,
  `remove-file`, `proc-spawn`, `proc-alive?`, `proc-stop`, `proc-reap`,
  `domain-state-get/put` (a generic per-domain KV store replacing
  `procs/`'s role); plus two small new pure builtins, `hash-string` (raw
  SHA-256 of a string — domain-fs.pp's content-hash) and `hash-value` (a
  canonical, map/set-order-INDEPENDENT structural hash — needed because
  `=` on two maps is plain order-sensitive assoc-list equality, and a spec
  value round-tripped through `domain-state-get/put` compares "different"
  from the in-memory original purely because the store's codec sorts map
  keys canonically). New `Cell.Domain {name; sub}` kind
  (`domain:<name>:<sub>`) for third-party domains (fs/proc keep their
  existing cell kinds). `stdlib/domain-fs.pp` and `stdlib/domain-proc.pp`
  now hold ALL the fs/proc POLICY (the tree-walk diff, the start/stop/
  restart decision) as real pp source; `--reconcile ROOT` auto-loads the
  former (write-cap `:wo`, not `:rw` — a write-only grant must still let
  the domain observe its own tree) and wraps the program's value as
  `{"fs" -> v}`; `--supervise` likewise with the latter, `{"proc" -> v}`;
  both compose; a program calling `register-domain` itself (neither flag)
  returns `{name -> desired}` directly. Found and fixed while landing this
  (docs/STATUS.md D25): pp's ordinary content-addressed `let`-memoization
  silently replays a zero-argument closure's `perform` effects when called
  twice in one dynamic extent (the plan pass and its verify re-observe;
  or twice within one `apply`) — fixed by a per-call config-stack cache-
  busting nonce (`Domains.call_uncached`) plus restructuring
  `domain-proc.pp`'s bookkeeping to read its own index once and thread it
  explicitly, never re-query it mid-pass. `tests/018-reconcile.sh` and
  `tests/033-process-reconciler.sh` pass UNCHANGED (the exit criterion);
  new `tests/046-domains.sh` registers a from-scratch third-party "kv"
  domain (a directory of one-file-per-key values, unrelated to fs/proc) to
  prove the protocol is genuinely generic: plan caching across separate
  process invocations, stratification, cap threading, verify-after-write
  failure for a deliberately under-converging apply, the generic journal
  bracket, and fenced-after-domains ordering. All 681 tests (663
  pre-existing + 18 new) and the fuzzer (`core`+`full`, 2000 programs
  each) pass; `scripts/build-self.sh` and `scripts/build-lua.sh` (both go
  through `--reconcile`) pass unchanged. See [docs/DESIGN.md](docs/DESIGN.md)
  (Q13, the E2 revision), [docs/SPEC.md](docs/SPEC.md) (LAW 30 now
  *holds*, full form), [docs/STATUS.md](docs/STATUS.md) (D25),
  [docs/MASTERPLAN.md](docs/MASTERPLAN.md) (M4 exit criterion 1, M4 DONE).
- **M3: in-language capability attenuation** (docs/PLAN-m3-attenuation.md).
  `(current-capabilities)` reifies the ambient set as of the call (never a
  mint); `cap-restrict` gains an optional `fs_mode` argument
  (`:ro`/`:rw`/`:wo`) that only ever narrows — requesting a mode wider than
  what the underlying capability holds at that scope is `Capability_error`,
  never a silent widen; the new `(with-caps cap-expr body)` special form
  REPLACES the ambient capability set with a held, ⊆-checked value for
  `body`'s dynamic extent (checked against the CURRENT ambient, so a
  narrowing composes even when some other binding lexically retains a
  broader value), exception- and tail-safe in both backends (the VM's new
  `WITH_CAPS` opcode runs the body via a nested call under a real OCaml
  exception handler, unlike the flat enter/exit opcode pairs the removed
  `effect` used, which could not restore the ambient after a raised error).
  The `effect` form (the prior capability-union block, rule `caps @
  ambient`) is REMOVED — a widening backdoor the instant capability values
  exist, and it was vacuous/untested before this landed (`with-handler`/
  `perform` are unaffected). The node boundary (LAW 20) is now enforced
  symmetrically: a node's free variable that is or structurally contains a
  capability (including inside a captured closure's environment/frames) is
  `Capability_error` at the key (`node_key_of`/`vm_node_key`); a node's
  RESULT containing a capability is rejected before it can be stored
  (`run_node_body`). Node capture (DESIGN Q11) is real for the first time:
  `thunk.node_caps` captures the ambient at each `(node e)` occurrence's
  creation, and `force_node`'s hit gate and miss recompute both use the
  forcing thunk's `node_caps` rather than the live ambient — "the caller's
  capabilities" (LAW 23b) is now capture-at-creation, collapsing to the
  pre-M3 per-process `--grant` set exactly when `with-caps` goes unused
  (`tests/011`/`013`/`017` hold byte-for-byte, unmodified). Fixed, along the
  way: `Capabilities.list_fs_paths`'s `CapRestrict` arm previously
  `Filename.concat`ed the scope onto each underlying path (a latent,
  uncalled/untested bug producing a bogus synthesized path); it now computes
  the actual scope/path containment intersection, becoming load-bearing via
  the new `cap_subseteq`. New `tests/040-caps-attenuation.sh`: the
  two-direction capture-vs-ambient differential (impossible to write before
  `with-caps` existed) plus basic `with-caps` narrowing on `slurp`/`run`.
  `tests/capability-adversarial.sh` extended: forged-from-print text is
  unparseable, composing two narrowed views never resurrects the root,
  mode/`with-caps` widen rejection, `with-caps` exception/tail safety, node
  capture via a direct free var and via a closure, node result rejection,
  `effect` gone. See [docs/SPEC.md](docs/SPEC.md) (LAW 20, LAW 22b, LAW 23),
  [docs/DESIGN.md](docs/DESIGN.md) (Q6, Q11), [docs/STATUS.md](docs/STATUS.md).
- **M3: D22 VM global-scope holes fixed, LAW 29 `load` residual closed**:
  (a) a bare top-level `(do (def x ...) ...)` no longer leaks its defs into
  the VM's globals table — `EDo` now always binds its defs as local slots
  (`extend_cenv`/`STORE_LOCAL`), matching the tree-walker's block-local
  `env_ref`; (b) `module`-body children (function defs, value defs, and
  bare statements) now see EARLIER siblings letrec*-style in the VM —
  `EModule` compiles its whole body as a fresh 0-param closure, immediately
  called, so sibling references resolve through local slots in a brand-new
  runtime frame instead of the globals table (previously "unbound symbol").
  Pinned by `tests/039-vm-global-scope.pp` and two new fuzzer generators
  (`stmt_do_scoped_def`, `stmt_module_sibling`); the two `full`-grammar
  generator exclusions this closes are gone from
  [docs/TESTING.md](docs/TESTING.md). Separately, the LAW 29/D12 residual —
  an error inside a `load`ed file citing the LOADING form's line instead of
  the loaded file's own — is closed: `Reader.read_string` now reads a
  loaded file under its own path (it previously fell back to the reader's
  `"<?>"` placeholder), and each of the loaded file's top-level forms is
  evaluated/compiled-and-run one at a time under the same never-doubled
  location-decoration discipline as the outer top-level driver
  (`Runtime.with_form_location`, one implementation shared by both
  backends). See [docs/STATUS.md](docs/STATUS.md) (D12, D22),
  [docs/SPEC.md](docs/SPEC.md) (LAW 4, LAW 29), `tests/027` case (g).
- **M3 closed: `defmacro`** (D10's promise, the total quote/quasiquote
  base). `(defmacro (name params...) body...)` is not a reader special
  form — it parses as an ordinary application, exactly like any
  unrecognized head symbol — and is recognized only at ONE shared
  expansion point (`macro.ml`) both backends pass through before their own
  machinery (the tree-walker's `hash_expr`/`node_key_of`, the compiler)
  ever sees a form. A macro receives its argument forms already converted
  by `quote_to_value`, runs its body through the tree-walker (LAW 36: the
  oracle), and the result value is converted back to syntax by the new
  `Types.value_to_expr` — `quote_to_value`'s exhaustive inverse, including
  the flat-vector binding shape a quasiquoted `` `(let [,g ,v] ...) ``
  naturally produces and the merged `(name params...)` shape a quasiquoted
  `` `(def (,name ,@params) ,body) `` naturally produces (neither matches
  `quote_to_value`'s OWN internal encoding, which keeps those parts
  separate — both are now accepted). Because expansion happens before
  either backend's own machinery, LAW 20 needed no change: a node whose
  body came from a macro call is keyed on the EXPANDED code, so editing
  ONLY the macro's definition (same call sites) re-keys it — the MASTERPLAN
  M3 exit-3 criterion, `tests/042-defmacro-rekey.sh`. New `gensym`
  primitive mints a fresh symbol using `~` as an unwritable marker
  character (excluded from the reader's `is_symbol_char`, unclaimed by any
  lexer rule — a bare `~` is a lex error), reset every run so the SAME
  source expands identically run to run (gensym'd names are baked into a
  node's expanded code; a counter that did not reset would make the node
  key drift across runs of unchanged source). Scope decisions, documented:
  macros are recognized ONLY at the true top level of a file/REPL input,
  sequentially like a value def (used-before-definition is an ordinary
  unbound-symbol error); a `load`ed file shares the loader's macro table
  (load is sequential evaluation); NOT inside `do`/`module`/`fn`/`node`/etc.
  bodies — so a `defmacro` inside a node body is simply an ordinary
  unbound-symbol error, in both backends, with no special-cased detection
  code. Hygiene is manual, not automatic (not required by M3): use
  `gensym` for a macro's own introduced bindings. `tests/041-defmacro.pp`
  (differential: control flow, gensym hygiene, a macro building a node
  form, nested macro use, a macro-generated `def`, redefinition);
  `tests/042-defmacro-rekey.sh` (the LAW 20 exit criterion plus the
  node-body error pin); fuzzer `stmt_defmacro` (full grammar). See
  [docs/MASTERPLAN.md](docs/MASTERPLAN.md) (M3), [docs/SPEC.md](docs/SPEC.md)
  (LAW 12, LAW 20, LAW 36), [docs/STATUS.md](docs/STATUS.md) (D10).
- **Phase 1 closed**: pp is a proven incremental hermetic build engine — a
  101-TU C project builds through a real `build.pp` meeting every exit
  criterion (null rebuild, mtime-only touch, single-file recompile+link,
  byte-identical store restore, header-edit cutoff, authority-gated hits);
  `pp` builds itself (`scripts/build-self.sh`) and builds real-world Lua
  5.4.7 the same way (`scripts/build-lua.sh`). See
  [docs/STATUS.md](docs/STATUS.md), [docs/ROADMAP.md](docs/ROADMAP.md).
- **Phase 2 groundwork closed**: `pp --watch`/`--once`/`graph`, push
  `stabilize`, the process-domain reconciler (`--supervise`), and fenced
  effects (LAW 31, `(fenced KIND SPEC)` with retry/abort/ask policies) are
  all live with cross-backend parity. See
  [docs/STATUS.md](docs/STATUS.md).
- **Islands (D2) closed**: `(island <uri> "64-hex-pin")` is a
  content-addressed module — the inline pin is part of the code hash, no
  lockfile or synthetic cell — with tamper detection, opt-in fetch
  (`--fetch-islands`), and `pp --update`/`pp island-pins` tooling. See the
  discrepancy ledger in [docs/STATUS.md](docs/STATUS.md) and `tests/035`.
- **LAW 23 cell-id canonicalization (M2.1)**: absolute realpath
  canonicalization applied uniformly at every cell/grant/loader-bound site,
  so a symlinked source tree and macOS `/var` vs `/private/var` are one
  cell. See [docs/ROADMAP.md](docs/ROADMAP.md) (maturity §3), `tests/036`.
- **Portable store format (M2.2)**: `~/.pp/store`'s `objects/`, `traces/`,
  `procs/`, and `fenced-specs/` moved off OCaml `Marshal` onto a versioned,
  canonical s-expr text/byte codec (`src/codec.ml`), gated on a `VERSION`
  stamp with clean upgrade-wipe of legacy stores. See
  [docs/TESTING.md](docs/TESTING.md), `tests/037`.
- **MASTERPLAN**: added [docs/MASTERPLAN.md](docs/MASTERPLAN.md), sequencing
  the milestones (M1–M6) from the proven engine to "devops solved
  in-language."
- **CI + versioning (M2.3)**: GitHub Actions CI on Linux + macOS
  (`.github/workflows/ci.yml`); `pp --version`/REPL banner now report a
  real version via `dune-build-info` instead of a hardcoded string; see
  [docs/RELEASING.md](docs/RELEASING.md).
- **Phase 3 (M1) closed — process-pool parallelism**: `--schedule
  serial|parallel:N|race:N` (new `src/scheduler.ml`) forks worker processes
  at the dispatch point for persistent-node misses. A new non-forcing `map`
  builtin closes Wall A (the missing batch fan-out point — `EApply` forces
  every argument, so no compound value could hold several unforced node
  thunks at once); `force-deep` collects a batch of unevaluated nodes and
  dispatches them before its ordinary recursive walk. A worker runs
  `Evaluator.run_node_body` — the exact function the serial miss arm
  calls, no second force path — and the parent only ever re-enters
  `Store.hit`, so a dead worker degrades to an ordinary serial recompute,
  never a wrong answer. `--check` under a non-serial policy re-runs the
  program forced serial against the same store and fails on any
  desired-state hash mismatch (the schedule-transparency audit). Landed as
  fork-at-dispatch rather than the `Runtime` global-state refactor
  MASTERPLAN M1 originally called for — `fork()` inherits ambient state
  byte-identically via copy-on-write, so the refactor isn't on this
  critical path (documented as an M5 design item instead — see
  [docs/DESIGN.md](docs/DESIGN.md) Q9/Q11-bis,
  [docs/MASTERPLAN.md](docs/MASTERPLAN.md) M1). Store hardening: a per-key
  `lockf` around `store_trace`'s read-modify-write, and `Journal.append` as
  one `Unix.write_substring` on an O_APPEND fd, so N concurrent writers
  can't drop or tear each other's lines. The Phase-1 101-TU build is 4-5x
  faster under `parallel:N` from cold with a byte-identical result to
  serial. See [docs/STATUS.md](docs/STATUS.md), `tests/024`'s `p3-*`
  assertions, `tests/038`.
