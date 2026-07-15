# pp testing: the correctness ratchet

pp's correctness rests on differential testing. Every test runs under both
backends, the tree-walker and the bytecode VM, and their output must be
byte-identical. A fixed test suite and a fuzzer enforce this.

## The test suite — `dune runtest`

```sh
dune runtest          # diff both backends on every tests/NNN-*.pp, then the
                      # capability adversarial suite
dune runtest --force  # re-run even if dune's cache says nothing changed
```

`tests/NNN-*.pp` are hand-written programs. Each one is also a regression
pin: for example, `tests/008` pins the fix for a VM local-slot reuse bug,
`tests/009` pins two content-key soundness fixes (a closure's captured
environment must be part of its hash, and the handler stack must be part
of a thunk's cache key), and `tests/030` pins four fuzzer-shrunk repros of
that same slot-reuse bug, found in nested `let`-in-`let*`-RHS code. The
driver (`scripts/run-tests.sh`) runs each file as `pp file` and
`pp --bytecode file`, and fails on any difference. It then runs two shell
suites:

- `tests/capability-adversarial.sh` checks capability-constructor removal,
  path-component scope, and gated `slurp` across both backends, extended
  when capability attenuation landed to add: a printed
  capability that is unparseable text (`forge-from-print`); proof that
  composing two capabilities each narrowed from the same broad root never
  resurrects the root's full authority (`compose-does-not-resurrect`);
  `cap-restrict`'s mode argument and `with-caps` both rejecting a widening
  request against a lexically held broader value
  (`cap-restrict-mode-widen-rejected`, `with-caps-widen-rejected`);
  `with-caps` restoring the prior ambient after a tail call and after a
  raised exception (`with-caps-tail-safe`, `with-caps-exception-safe` — via
  piped REPL input, since only a persistent session can observe ambient
  state across the error); a node's free variable that is, or via a
  captured closure contains, a capability, raising `Capability_error` at
  the key (`node-cap-capture-direct`, `node-cap-capture-via-closure`); a
  node's result containing a capability, bare or embedded, being rejected
  before storage (`node-cap-result-rejected`, `node-cap-result-embedded`);
  and `effect(...)` now being an ordinary unbound-symbol error
  (`effect-removed`).
- `tests/010`–`tests/015` cover the persistent node cache. These can't be
  plain `.pp` diffs, because they run the interpreter across several
  processes, mutating files, grants, or globals between runs, under an
  isolated `$HOME`, never touching the developer's real `~/.pp/store`:
  - `tests/010` — verifying traces: an unchanged file hits, and does not
    replay the node's `log` (LAW 17); a changed file recomputes with fresh
    contents (the staleness fix); a reverted file re-hits the original
    trace in the set.
  - `tests/011` — node identity keying: an unrelated global rebind is a hit, a
    changed referenced free variable is a miss, and widening `--grant`
    does not invalidate (LAW 20).
  - `tests/012` — failure memoization: a failing node re-serves the same
    error without re-running, re-runs when a recorded read changes, and
    never reports a fake infinite-recursion error, a bug fixed earlier
    (LAW 28).
  - `tests/013` — authority-gated hits: a narrow-capability caller cannot get
    a hit on a node whose (transitive) read closure it can't cover, and a
    capability denial doesn't poison the cache (LAW 23b).
  - `tests/014` — VM parity: every one of the above under `--bytecode`, plus
    bidirectional cross-backend key sharing (a node built by one backend
    is reused by the other).
  - `tests/015` — trace cells for config and handlers: ambient config or
    handlers a node never observed don't invalidate it, because they sit
    outside the key; a config value or handler it DID observe recomputes
    on change and re-hits on revert (LAW 33 and LAW 26); a mock
    `read-file` and the real builtin coexist as two traces under one key
    with no cross-contamination; VM included.
  - `tests/016` — value-keyed cutoff: a null rebuild and a mtime-only `touch`
    recompute nothing; a header edit that leaves the derived value
    byte-identical re-runs the reader node but NOT the value-keyed
    dependent (compile re-runs, link is cut off); a real content edit
    re-runs the whole chain; VM included (LAW 21).
  - `tests/017` — the `run` effect and its sandbox: no process grant means a
    capability error; a run-node caches and re-runs when a granted tree
    changes (the coarse `tree:` cell catches reads pp never saw); tool
    outputs land in node-local scratch, never the caller's cwd; an
    absolute node `write-file` errors, while scripting-tier writes still
    work; VM included.
  - `tests/018` — the reconciler's first version: create, null, drift, and
    shrink reconciles converge with the right create/update/delete
    counts; manual edits and foreign files under the managed root are
    converged away, since there is a single writer; no write grant means
    nothing is materialized; a desired state that reads its own domain is
    a stratification error; intent/done pairs land in the journal; VM
    included.
  - `tests/019` — `pp why` / `--no-cache` / `--check`: why reports first-build
    miss, hit, and stale (naming the changed cell); an unauthorised cell
    in another trace is redacted and never named (LAW 23c); `--no-cache`
    recomputes but still refreshes the store; `--check` passes a
    deterministic node and flags a volatile one with a nonzero exit;
    VM included.
  - `tests/020` — loader authority: loading a file beside the program works
    with zero grants; loading outside every source root errors even with
    a broad grant; a node's `load` is a `runtime:file:` cell, so editing
    the module invalidates it, but a hit needs no fs grant over it;
    cwd-relative stdlib loads still work; VM included.
  - `tests/021` — content-addressed snapshot ingest: an external writer
    mutating a file between two nodes is invisible, since both observe
    the pinned snapshot, whose bytes land in `blobs/<sha256>`; the
    snapshot holds at every tier; pp's own `write-file` advances it; VM
    included.
  - `tests/022` — the depfile adapter for tracking observed reads: with
    `run-dep!`, an unrelated change under a granted root stays a HIT, with
    no coarse tree cell, while a dependency the tool actually read —
    granted or system — re-runs on change; a missing depfile falls back
    to the coarse floor; VM included.
  - `tests/023` — blob-hash desired values: `blob(S)` refs and inline strings
    coexist in one desired map; `rm -rf build/` followed by a
    re-reconcile restores from the store with zero tool re-runs — the
    same restore guarantee `tests/024` proves at full scale, here at unit
    scale; a dangling blob ref is a hard error; VM included.
  - `tests/032` — push stabilize differential test: a battery of cell-change
    sequences on a 4-node program; push (`--watch --stabilize`) and pull
    (`--watch`) produce identical re-evaluation patterns at each step;
    both backends.
  - `tests/033` — the process-domain reconciler: `--supervise` starts and
    stops services from a desired process map (LAW 30); `kill -9`
    restarts within one poll interval; config edits restart exactly the
    affected service; journal contains intent/done proc entries; both
    backends.
  - `tests/034` — fenced effects (LAW 31): `fenced(KIND, SPEC)` errors inside
    a node body, is a no-op without a reconciler, executes once and
    journals intent/done under `--reconcile`, has VM parity, and recovers
    a killed mid-apply action without silent double-execution under
    `--fenced-policy retry` or aborts under `--fenced-policy abort`.
  - `tests/029` — REPL: paren-balanced multi-line continuation,
    defs persisting across lines in BOTH backends, promptless piped
    output, `:why` toggling, `exit(N)` status control, deep-forced
    printing. (Arrow keys / `~/.pp/history` need a pty; verified by hand.)
  - `tests/028` — the stdlib: value oracle for the string/number
    primitives; `argv()` from after `--`; `env-get` incl. absence;
    `exit(N)` exit-code control; `assert` failures naming the form and its
    file:line; `file-exists?`/`dir?` capability gating and `stat:`
    trace-cell semantics (created/deleted paths invalidate; an absence
    trace re-hits after deletion); VM included. `tests/028-stdlib.pp` runs
    the pure parts under the differential diff.
  - `tests/027` — error messages (LAW 29): top-level runtime errors carry the
    form's file:line, arity errors name the callee, capability errors
    name the operation, no double locations, single-line `pp: error:`
    reporting with exit 1 — with stderr byte-identical across backends;
    case (g) pins the fix for a residual bug where an error inside a
    `load`ed file cited the loading form's line, not that file's own.
  - `tests/026` — per-parameter type annotations (LAW 32): well-typed calls
    pass, ill-typed calls raise the same located "type mismatch" on both
    backends (stderr byte-identical), unknown type names pass (gradual),
    vector param lists and return+param combinations enforce.
  - `tests/025` — `let x = v` value-binding semantics: the RHS evaluates at
    definition time (delay/node RHS binds the unforced thunk), blocks are
    letrec* with a `referenced before its definition` error and duplicate-def
    read errors, the top level is sequential, `node x { e }` binds a node
    thunk that caches on force; both backends.
  - `tests/024` — the six exit criteria for pp's incremental build engine, on
    a generated 101-translation-unit C project built by a real `build.pp`:
    a null rebuild runs 0 processes (under 1 second, journal-proven); a
    `touch` runs 0 recompiles; one edit is exactly compile+link; restore
    from the store is byte-identical; a comment-only header edit cuts off
    the link; authority gates hits transitively; and `pp` builds itself
    via a real `build.pp` (see below). The VM shares the compile cache,
    and the test skips cleanly without `cc`. The fixture generator and
    drift mutations are pp programs (`tests/gen-cproject.pp`,
    `tests/mutate-cproject.pp`); the pass/fail oracle stays shell.
    `build.pp` is written the pairing-trap-safe way — `map(compile,
    names)` (the non-forcing `map` builtin) force-deep'd as a batch, then
    paired back up with `names`. This same test also proves the parallel
    scheduler: the same cold build under `--schedule parallel:$(nproc)`
    produces the identical desired-state hash and byte-identical
    materialized tree as the serial build, the same exec count, a null
    rebuild with zero new execs under parallel too, and is measurably
    faster (asserted to be quicker than the serial wall-clock).
  - `tests/038` — parallel-scheduler stress testing: `race:3` on a
    deliberately slow node gives an identical result, exactly one
    surviving trace line, and a wall-clock close to one run rather than
    three; 64 independent nodes under `parallel:16` on one store, repeated
    cold, all round-trip their objects and traces, a serial re-run
    against the warm store is hash-identical, and one cold run's journal
    has exactly 64 parseable `exec` lines (`Journal.append`'s one
    `write_substring` hardening); `race:8` hammering a single key with the
    trace-lock disabled (`PP_TRACE_LOCK=0`, an internal test-only escape
    hatch) still yields a parseable trace and a correct subsequent hit;
    `fenced(...)` inside a node body still raises under `parallel:4` and
    `race:3`, proving the ban holds under every placement (LAW 31).
  - `tests/036` — cell-id canonicalization (LAW 23): a source tree reached via
    a symlink loads and hits identically to the real path, both
    directions; a `tree:`/`tool:` node cache hits when the SAME content is
    granted via a different spelling — a user symlink, or macOS's `/var`
    versus `/private/var` on whatever symlink layer the host's own tmp
    path already has (this case skips cleanly if there is none); a
    trailing-slash grant equals one without; a write-target's `stat:`
    cell-id (via `pp graph`) is byte-identical before and after the file
    exists. VM included.
  - `tests/037` — portable store format: the store's canonical s-expr text
    codec replaces Marshal. Golden bytes — a fixed program's object and
    trace files are byte-identical to fixtures in
    `tests/fixtures/store-v1/` (names and content, both backends); a
    codec round-trip battery (negative ints, `-0.0`, `1e308`, `nan`/`inf`,
    control-byte/UTF-8 strings, keywords, symbols, nested vectors,
    mixed-key maps, sets, improper pairs) stores in one process and HITS
    in a second, printing byte-identically, in all four backend
    directions; a VERSION bump ("pp-store 0") recomputes cold without
    crashing, re-stamps, and preserves journal/ + blobs/; a closure-valued
    node stores NO object (the non-data law) yet recomputes cleanly while
    a data node beside it still hits; a legacy Marshal-era store (garbage
    bytes, no VERSION) is wiped and rebuilt, exit 0.
  - `tests/039` — VM global-scope holes, fixed (a differential `.pp` test): a
    bare top-level `do { let x = ...; ... }` binds `x` block-local —
    referencing it after the `do` closes is an unbound-symbol error in
    both backends; a `module { ... }` body's later children (a function
    def, a value def, and a bare statement) see EARLIER siblings,
    letrec*-style, exactly like the tree-walker's `env_acc` fold.
  - `tests/040` — in-language capability attenuation: a two-direction
    differential test that was IMPOSSIBLE to write before `with-caps`
    existed — a node created under a NARROWED `with-caps` extent is still
    denied when forced later under the full grant (capture happens at
    creation, not ambient-at-force), and a node created under the full
    ambient still succeeds when forced inside a narrower `with-caps`
    (fixed at creation, mirroring lexical closure capture) — both
    directions, both backends; plus `with-caps` narrowing `slurp`
    (scripting tier) and `run` (an fs-only restrict drops process
    authority entirely, since `CapRestrict` is filesystem-scoped).
    Isolated `$HOME` per case, like `tests/011`/`013`/`017`.
  - `tests/041` — `defmacro`, redeeming the promise made when fexprs were cut
    (a `.pp` differential test): a control-flow macro (`unless`) via
    quasiquote; a `gensym`-based macro whose introduced temporary shares
    its TEXTUAL prefix with a caller variable of the same name, proving
    no capture; a macro building a `(force (node ...))` form; nested
    macro use (one macro's expansion calls another macro); a
    macro-generated `(def ...)`; a macro built with plain `list`/`quote`
    (no quasiquote); redefining a macro changes later expansions.
    Deliberately prints only VALUES, never node-body `log` side effects —
    a hit/miss-dependent print would make repeated `dune runtest` runs
    against a developer's real (non-isolated) `~/.pp` flaky, since this
    file is a plain stdout diff, not one of the isolated-`$HOME` shell
    suites.
  - `tests/042` — the node-identity guarantee for `defmacro`: a
    `build.pp`-style program whose node body comes from expanding a
    macro; editing ONLY the macro's definition (the call site
    `build-step()` byte-identical) is a MISS that recomputes — proven by
    the presence of the node's `log` output and by `pp why` reporting a
    hit only after that recompute (LAW 20) — and reverting the definition
    HITS again with no recompute; both backends. Also pins the
    macro-in-node-body rule: a `defmacro` textually inside a
    `node { ... }` body is never specially recognized (only a true
    top-level form registers a macro), so it fails as an ordinary
    "unbound symbol: defmacro" in both backends, byte-identically.
    Isolated `$HOME`, like `tests/011`/`040`.
  - `tests/043` — probes (LAW 37 and LAW 38): a file-backed counter as the
    observe-fn, so its value is controllable; a node reading
    `probe(name)` re-forces exactly when the counter changes and hits (no
    recompute) when it doesn't, across four separate `pp` invocations
    (cold/unchanged/changed/reverted, mirroring `tests/010`'s shape) —
    both backends. Also: a recursive `~/.pp/store` scan (excluding
    `blobs/`, which ordinary `slurp` inside the observe-fn legitimately
    populates) proves the raw probe payload never lands in `objects/`/
    `traces/`; a registered-but-never-read probe's observe-fn never fires
    (extending the demand-pruning half of LAW 7 to probes); an
    unregistered probe name is a hard error; `register-probe` inside a
    node body errors (script-tier only, mirroring `fenced`). A final
    section proves the SAME mechanism live under one long-running
    `pp --watch` process (portable `timeout` shim, like `tests/031`):
    with no probe-specific wiring at all, the existing generic watch-loop
    polling (`Runtime.observed_all` → `Store.observe_cell`) already
    detects a changed probe cell and re-evaluates exactly the dependent
    node.
  - `tests/044` — sealed cells (LAW 39): `--grant secret:<path>` reads redact
    on print (`#<sealed>`) and round-trip through `unseal(v)`; a
    recursive store scan (the WHOLE store, `blobs/` included this time —
    a sealed read must never call `store_blob`) finds no secret bytes
    after a program that only reads, and separately one that unseals at
    script tier only; the node-boundary ban fires both directions
    (free-var and result) with byte-identical stderr across backends;
    rotating the secret's bytes recomputes exactly the observing node,
    leaving a sibling node untouched; a caller re-run with NO grant at
    all cannot hit a node whose cached trace shows a covering grant
    existed once (LAW 23b); covered by both `secret:` and `fs:` grants
    behaves as plain fs.
  - `tests/045` — network: gated cleanly on `curl` and `python3` both being
    present (a tiny stdlib `http.server`-based loopback fixture, no real
    network). No `net:` grant, or a grant for a different host, denies
    `perform http-get/http-post(...)`; a covering grant (exact host, or a
    `net:*` wildcard) allows it against the local server, both backends;
    `http-post`'s body actually reaches the server (echoed back); `perform
    http-get` inside a node body errors and never touches the network; a
    `curl`-absent run (an emptied `PATH`) is a clean error, not a crash.
  - `tests/046` — the in-language reconciler-domain protocol. A THIRD-PARTY
    toy "kv" domain (a directory of one-file-per-key values) is defined
    and registered entirely INSIDE the test's own pp programs via
    `register-domain` — never touching `stdlib/domain-fs.pp`/
    `domain-proc.pp` — to prove the protocol is genuinely generic, not
    fs/proc-shaped: cap threading (no grant ⇒ `cap-restrict` itself
    refuses before the domain ever runs, nothing materializes); a cold
    pass converges and the generic per-pass journal bracket appears
    (`intent`/`done`, domain-agnostic); PLAN CACHING across two SEPARATE
    `pp` process invocations (proved via `pp why`'s `domain kv: plan …:
    hit`, not just an in-process reuse); stratification (a desired-state
    computation that reads a file under its own kv directory is refused,
    LAW 30 generalized); verify-after-write failure surfaced for a
    deliberately-registered domain whose `apply` is a no-op (a real
    `Capability_error`-free divergence the core must still catch); fenced-
    after-domains ordering (a `fenced(...)` action registered alongside
    the domain runs, and its journal `intent fenced` line lands AFTER the
    domain's own `done` line); VM parity. `tests/018-reconcile.sh` and
    `tests/033-process-reconciler.sh` (unchanged, byte-for-byte, across
    the whole migration) are this test's real companions.
  - `tests/047` — cluster transport, signed tokens, and by-hash sync
    (`docs/THREAT-MODEL-cluster.md` is the gate). Two (or three) `pp`
    PROCESS invocations differing only in `$HOME` stand in for distinct
    cluster members, sharing a WORK dir the way `tests/019` does.
    `pp cluster-init` mints `~/.pp/cluster/{secret,id}` (mode 0600,
    refuses to overwrite); the secret/id are copied to the other
    simulated members (out-of-band distribution). It covers:
    - a `--transport-push` then a flipped byte (object, blob) or
      truncation (trace) in the shared root, then `--transport-pull`
      exits nonzero naming the tampered artifact for all three kinds;
    - a `--serve-hit` with a flipped-MAC-byte token, and with a
      negative-TTL (already-expired) token, both reply `deny`, and
      neither creates the shared root (nothing crosses on denial);
    - the SAME node key gets `miss` from a token whose grant doesn't
      cover the node's read closure and `hit` from one that does — LAW
      23b across the wire, proven by holding the key fixed and varying
      only the token; `--recv-hit` pulls the hit's object+trace,
      re-hash-verifying, and the receiving member then hits LOCALLY with
      no recompute;
    - `pp why` under a narrow grant, run once on the builder and once
      (post-sync) on the receiver, produces byte-identical redaction
      (`<redacted unauthorized cell>`, never the real path in a
      `[why]`-tagged line) — scoped to `[why]` lines specifically, since
      the program's own subsequent capability-denied read legitimately
      names the path in an ordinary error line (the `tests/019` pattern);
    - a node touching a secret is refused at the existing node boundary
      before ever being stored, and a whole-tree grep after the attempt
      finds the secret's bytes nowhere outside their source file;
    - and, partially: a third, never-synced, independent build of the
      same program computes the identical node-key filename and a
      byte-identical result object, and the receiver's serve-hit-synced
      object is also byte-identical to the builder's own.
  - `tests/048` — remote placement. Two `pp` process invocations differing
    only in `$HOME` (dispatcher A, member B), addressed via
    `~/.pp/cluster/members`, over the same local-dir loopback `tests/047`
    uses. An 8-translation-unit real-cc build (scaled down from
    `tests/024`'s 101 for a two-process-per-node test) under
    `--schedule remote:B`: byte-identical materialized tree AND
    desired-state hash (the `--check` schedule-transparency audit,
    extended to `Remote` policy_name) vs a serial build — deliberately
    materializes via plain top-level `write-file` rather than
    `--reconcile`, working around a gap this test found (see STATUS.md:
    `--reconcile` preloads `stdlib/list.pp`, whose own `map` shadows the
    batching `map` builtin, silently defeating parallel/race/remote
    batching for any `--reconcile` build — fixing this was out of scope
    here). It also covers:
    - a cross-machine hit: the dispatcher's and member's trace-key sets
      intersect (the member genuinely forced compile nodes; the
      dispatcher's own subsequent `Store.hit` serves them, no local
      recompute);
    - `tool:` not pre-seeded: the member's own journal shows real `cc`
      execs (its own legitimate observation);
    - a synchronization race proved with a test-only seam
      (`PP_REMOTE_TEST_HOOK`/`_AFTER` in `src/remote.ml`, unset in every
      normal invocation) that mutates a shared data file to a DIFFERENT
      value in the exact window between the dispatcher pinning it and
      the member running, then reverts once the member has exited — the
      member's own stored object is the dispatcher's PINNED bytes, never
      the disk's transiently-different value, and the dispatcher's own
      post-pull `Store.hit` re-validation (against the reverted,
      now-matching world) produces a clean hit;
    - a non-data-closed (free-var closure) case that stays local: zero
      trace keys ever appear on the member;
    - an unreachable member (a bad members-file target): the build still
      succeeds, byte-identical to serial;
    - and VM parity: the same remote build under `--bytecode`.
  - `tests/049` — host-qualified domain distribution. Two separate `$HOME`s
    (the `tests/047`/`048` convention). `--member-name A` converges only
    host A's fs slice under its own `$HOME`; `--member-name B` only host
    B's, under a genuinely separate `$HOME` — neither's materialized tree
    ever gains the other's file. An unknown `--member-name` is a named
    hard error, not a silent no-op. `kill -9` recovery on a member's OWN
    slice under `--watch --member-name` (a proc domain registered by the
    member's own program) restarts within one poll interval, exactly like
    `tests/033`'s unqualified case, while a DIFFERENT host's service in
    the same desired map is never even started. For backward
    compatibility: a from-scratch third-party "kv" domain (the
    `tests/046` pattern) with no `--member-name` at all reconciles exactly
    as it always has — proving directly, not merely inferring from other
    files staying green, that detection is opt-in only through the
    explicit flag and never guessed from shape. VM parity.
  - `tests/050` — store GC (`pp gc`, explicit, never automatic). N
    `--reconcile` passes with CHURN (a per-pass file added then removed)
    show the store growing without `pp gc` between passes and staying
    bounded with it; the frozen journal gains exactly one `epoch HASH`
    line per successful pass. The kept (most recent) root's closure
    survives every sweep: a subsequent identical rebuild is a pure cache
    hit (zero new execs) with a byte-identical materialized tree. A
    genuine long-running `--watch` loop (not merely repeated one-shot
    invocations) races a CONCURRENT `pp gc` process against the same
    store across several ticks: no crash, bounded size, the loop's own
    converge still correct throughout. A `parallel:8` build (the
    `tests/038` shape) similarly races `pp gc` (a long grace period
    standing in for "genuinely still in flight"): no crash, correct
    result, and a subsequent rebuild is still byte-identical with zero
    new execs. The islands cache (`~/.pp/islands`) is untouched by any of
    the above. `pp gc` on a completely empty store is a clean no-op, not
    an error.
  - `tests/051` — the last gap in the cluster-distribution exit checklist
    (`docs/PLAN-m5-distribution.md` lists five exit tests; `tests/047`
    and `tests/048` cover four of them, `tests/050` covers the fifth).
    Two genuinely separate `$HOME`s exercise the by-hash desired-value
    seam this stage adds: a dispatcher `--publish-object`s a
    host-qualified value (including a `blob(...)` reference alongside
    inline content) into a shared local-dir root; a member, a SEPARATE
    `$HOME`, `--desired-object`s it by hash and converges only its own
    slice — the blob's actual BYTES cross (byte-identical to the source),
    not merely the small string reference; nothing beyond `objects/` and
    `blobs/` is ever published (no journal, no fenced-specs) under the
    shared root. A tampered published object is rejected on pull, through
    the same `ingest_object` choke point every other synced artifact goes
    through. `pp gc` on the receiving member's store, whose one epoch was
    sourced via `--desired-object` (the one `Gcroots` field no other test
    exercises), replays and sweeps correctly, and the kept root's closure
    still converges afterward.
  - `tests/052` — the devops-complete demo. `demo/deploy.pp`/`demo/agent.pp`/
    `demo/src/greeter.c` — an all-library composition, zero `src/*.ml`
    changes — build a C service, deploy it across two hosts, converge
    after drift and after `kill -9`, rotate a secret invalidating exactly
    its observers (bytes never under `~/.pp/store`), and audit via
    `pp why` (55 assertions across six clauses). The demo also runs its
    own diagonal oracle: six pull rows (backend×placement) publish the
    identical desired-state hash, both non-serial `--check` runs exit 0,
    and six push rows settle to a byte-identical materialized tree —
    needing no pinning, since this demo's desired state is a pure
    function of `file:`/`sealed:` cells.
  - `tests/053` — the observation-pinning seam. `demo/volatile-deploy.pp` is
    a deliberately ADVERSARIAL program, separate from `052`'s demo, that
    folds `probe("replica-count")` directly into its returned desired
    state. As an unpinned control: two `--publish-object` runs with
    different metrics-file content publish two DIFFERENT hashes (the
    probe is genuinely volatile, not a strawman). `--dump-pins` from one
    canonical run, then `--pin-file` replaying that dump across the 6
    pull combinations (backend×placement) with the metrics file mutated
    to a THIRD, divergent value: all 6 published hashes equal the
    canonical hash, and the observe-fn's sentinel file is proven ABSENT
    in every one (a `(pin-probe "NAME" <value>)` line short-circuits
    `probe_value_for` before it ever calls the registered observe-fn).
    Push/materialization combos aren't wired — this adversarial program
    registers no domain, so there is no tree for a `--watch --stabilize`
    pass to converge/diff.

Two proofs run outside `dune runtest`, because they invoke dune or the
network:

- `scripts/build-self.sh` proves pp can build itself: a `build.pp` whose
  one node wraps the dune invocation, keyed on `tree:src`, means a null
  rebuild never executes dune.
- `scripts/build-lua.sh` replicates the same guarantees on a real project,
  Lua 5.4.7: a cold build, a zero-process null rebuild, a comment-only
  `lua.h` edit with link cutoff, and a byte-identical store restore. It
  downloads the pinned tarball on first use.

To run a single file by hand:

```sh
pp --diff tests/007-phase0-laws.pp    # runs both backends; exits 1 if the
                                      # returned top-level VALUES differ
```

The two checks are complementary: `--diff` compares the returned values of
top-level forms, while `dune runtest` diffs stdout, so it also catches
`print`/effect-ordering divergences that don't change return values.

## The differential fuzzer — `tools/fuzz.ml`

`tools/fuzz.ml` generates random pp programs, runs each one under both
backends, and checks that they behave identically. It deduplicates
divergences by signature, shrinks each one to a minimal repro, and writes
it to a failure directory. It has zero dependencies beyond OCaml's `unix`
library, and it is fully deterministic: program *i* under seed *S* is
always the same program (no `Random.self_init` call).

### Two readers, two backends

Every generated program is pushed through
`pp --roundtrip-braces f`, which in one process reads the sexpr AST,
prints it as location-preserving brace text (`src/printer_braces.ml`),
re-reads that with the brace reader (`src/reader_braces.ml`), and asserts
per-form structural AST equality AND LAW-20 `hash_expr` equality. Any
nonzero exit is a gating MISMATCH (`roundtrip:*` signature; a
`<iter>.rt.out` artifact is saved alongside the backend outcomes), shrunk
like any other. The summary prints a `roundtrip N checked, M failed` line.
`tests/054-brace-reader.sh` runs the brace reader's own oracle battery (a
nontrivial `.ppb` under both backends, cross-surface `load`/islands,
assert-desugar parity, `--emit-braces` on a real test file, a whole-tree
`--roundtrip-braces` sweep) plus a 300-program full-grammar fuzz pass of
this gate inside `dune runtest`.

```sh
dune build                                              # builds bin/pp + the fuzzer
dune exec ./tools/fuzz.exe -- --grammar core --count 2000
dune exec ./tools/fuzz.exe -- --grammar full --count 2000
```

### `pp fmt`: the lossless transpiler

`pp fmt --to-braces`/`--to-sexpr <file> [-i]` reads one surface, prints
the other via the same location-preserving discipline as `--emit-braces`
(`src/printer_braces.ml`; `src/printer_sexpr.ml` for the reverse
direction), and carries comments losslessly through a side
channel (`src/comments.ml`) that never touches the AST both readers hand
the evaluator — LAW-20 hashes ignore comments by construction, so hash
equality alone can't catch a dropped one; comment COUNT and TEXT (mod the
`;`/`#` delimiter and whitespace) are checked separately. `-i`/
`--in-place` rewrites the file at its own path (never renaming it: hash
preservation requires the location file to stay identical across both
hops — this is the vehicle for the whole-tree migration described next).
`tests/055-fmt.sh` covers a tricky-comments fixture each direction
(trailing/standalone/comment-only/end-of-file comments, run identically
before and after), output determinism (`fmt` twice on the same input is
byte-identical), and a whole-tree in-place round-trip sweep asserting
every top-level form's `hash_expr` survives `to-braces` then `to-sexpr` —
the two internal test seams `--compare-hash`/`--list-comments` exist only
for this.

### The whole tree now uses the brace surface

Every `.pp` file in the tree (tests, stdlib, `build.pp`, demo, examples,
the manual's executed examples, the store-v1 golden fixture) was migrated
mechanically via `pp fmt --to-braces -i` — no file renamed, preserving
every node key (LAW 20); `scripts/build-self.sh` and `scripts/build-lua.sh`
null-rebuild with 0 recomputes against a store populated pre-migration.
Extension dispatch (`Reader_braces.read_dispatch`): `.pp` and `.ppb` read as braces,
`.ppl` ("the AST form") reads as sexpr — supported forever, it IS the
macro layer. Non-file sources (interactive/piped REPL input, `-e`, the
`--reconcile` glue's synthetic `<...>` tags) still read as sexpr —
flipping those display/input surfaces remains future work. Shell tests'
embedded programs were converted to braces except where a case
specifically targets the sexpr surface (`tests/054`'s cross-surface
fixtures and `--roundtrip-braces`/`--emit-braces` inputs, which take
`.ppl`); the fuzzer writes its generated sexpr programs to `.ppl` scratch
files.

The fuzzer shells out to the interpreter, defaulting to `bin/pp`
(`dune build`'s symlink). Run from the repo root, or pass `--pp PATH`.

Options (defaults in parens):

| flag | meaning |
|---|---|
| `--seed N` (0) | RNG seed. Program *i* is `Random.full_init [|seed; i|]`. |
| `--count K` (1000) | number of programs |
| `--max-depth D` (6) | expression-tree depth limit |
| `--timeout-ms T` (5000) | per-backend wall-clock timeout; overrun = CRASH |
| `--out DIR` (`fuzz-failures`) | failure artifact directory |
| `--grammar core\|full` (core) | grammar profile, see below |
| `--start N` (0) | first iteration index (to reproduce a specific program) |
| `--dump N` | print program N and exit |
| `--pp PATH` (`bin/pp`) | interpreter binary |
| `--stdlib PATH` (`$CWD/stdlib/list.pp`) | path baked into generated `(load …)` |
| `--shrink-budget N` (300) | max backend-pair executions per shrink |

### Grammars

- `core` — forms both backends must agree on: literals (negatives
  included), `if`/`do`/`let`/`let*`, `fn` + application, `def` (functions,
  arity ≥ 1, AND `(def x v)` value bindings referenced by later
  statements), the arithmetic/comparison builtins, list/vector/map ops,
  strings, `print`, literal-key `with-config`/`config`, and the stdlib
  list functions via `(load ".../stdlib/list.pp")`. Any non-PASS on `core`
  is a real bug — its exit code is the CI gate.
- `full` = `core` plus everything that used to divide the two backends in
  pp's early days: type annotations (return AND per-parameter — the
  latter with deliberate ill-typed calls as matched both-error probes),
  `module`/`import`/`load-module` and computed `config` keys,
  `perform`/`with-handler` over the `log` effect, deep tail/non-tail
  recursion and long `map`s, `=` on structurally identical unforced
  lists, sibling-referencing `let` bindings, quoted special forms, bare
  top-level `do` with a def that must NOT leak past the block, and
  `module` bodies whose function defs/value defs/bare statements
  reference EARLIER siblings (two VM global-scope bugs, both fixed —
  `stmt_do_scoped_def`, `stmt_module_sibling`), and `defmacro`: a fresh,
  well-scoped macro (`stmt_defmacro`) that doubles its (always-literal)
  argument via `list`/`quote` and calls it, exercising the shared
  expansion point (`macro.ml`) both backends pass through before compile
  or eval ever see the form.

Never generated: `random`, wall-clock forms, file-write effects,
capability constructors and the `with-caps`/`current-capabilities`/
`cap-restrict` surface (all nondeterministic or unsafe/security-sensitive),
and network islands. The `effect` special form (removed from the language
entirely) was previously generated by `stmt_effect`; that generator arm
is deleted too, since `(effect ...)` is no longer valid pp syntax. Pinned
`file:` islands over a fixed fixture ARE sampled in the `full` grammar
(the fixture is pinned once at fuzzer startup via `pp --update`, which
also exercises the pin rewriter); `tests/035-islands.sh` covers the rest,
with a network subcase against a local bare git repo behind
`PP_ISLAND_NET_TEST=1`.

### Verdicts

| verdict | condition | CI effect |
|---|---|---|
| PASS | both exit 0, stdout identical, stderr identical | — |
| MISMATCH | stdout differs, effect-log (stderr) differs while both exit 0, or exactly one backend errors | fails |
| BOTH-ERROR | both exit non-zero; grouped by normalized error tag | soft class for now |
| CRASH | either side times out, dies by signal, or exits > 128 | fails |

Exit code is non-zero if and only if MISMATCH + CRASH > 0. Stderr is
compared only when both exit 0 (at which point it holds only `log` effect
output), so it doubles as the "identical effect logs" check without
tripping on error wording. Signatures normalize the payload (digits → `#`,
wrappers stripped) so thousands of failures collapse to a handful of bug
classes.

### Failure artifacts

```
fuzz-failures/<sanitized-signature>/
  <iter>.ppl         # up to 3 raw failing programs (sexpr text)
  <iter>.tw.out      # tree-walker status + stdout + stderr
  <iter>.bc.out      # VM status + stdout + stderr
  min.ppl            # shrunk minimal repro (not for BOTH-ERROR)
  min.tw.out / min.bc.out
```

Shrinking is greedy-to-fixpoint (drop top-level forms, hoist a child over
its parent, replace subtrees with `0/1/true/nil/"a"`, halve integer
atoms), accepting a reduction only if the exact signature is preserved.
The budget is counted in executions, not wall-clock, so shrinking a
`crash:*:timeout` is slow — lower `--timeout-ms` or `--shrink-budget` for
those.

### Reproducing a failure

Every artifact records its iteration number. To regenerate program 1234
of a `--seed 0 --grammar full` run:

```sh
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --dump 1234 > repro.ppl
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --start 1234 --count 1
pp repro.ppl; pp --bytecode repro.ppl
```

(Fuzzer-generated programs are sexpr text, so the redirected file takes
the `.ppl` extension — `.pp` now dispatches to the brace reader.)

`--max-depth` and `--stdlib` must match the original run for
byte-identity.

### Adding a grammar rule

1. Verify the form against `src/` first (reader syntax, primitive names,
   both backends' handling). Do not invent function names — several
   plausible ones (`min`, `max`, `str`) do not exist.
2. New expression production: add a weighted arm to the right typed
   generator (`gen_int`/`gen_bool`/`gen_string`/`gen_float`/`gen_list`) in
   `fuzz.ml`. Keep it well-scoped (only symbols from `env`) and
   type-correct.
3. New top-level production: write a `stmt_*` returning `sx list` and
   register it with a weight in `gen_program`. If it needs the stdlib,
   set `env.stdlib <- true`.
4. Nondeterministic forms stay banned until the roadmap gates them.
5. Sanity-check with `--dump 0..5` and a 100-program run; a rule that
   produces matching BOTH-ERRORs on most programs is a generator bug, not
   a finding.

### Deliberate generator exclusions

- Core `let` never references sibling bindings (the tree-walker's
  parallel vs the VM's sequential handling); the divergent case is
  generated deliberately only in `full`.

(Three historical exclusions are gone: bare negative literals lex
correctly now; `(def x 5)` is a value binding — `stmt_def_value`
generates it and later statements reference the bound name; and bare
top-level `do` with defs plus module-body sibling references — two VM
global-scope bugs, both fixed and now generated in `full` by
`stmt_do_scoped_def` and `stmt_module_sibling` (see the grammar
description, above).)

- Probes, sealed cells, and network are not fuzzer-generated.
  `register-probe`/`probe`, `slurp`/`read-file` under a `secret:` grant,
  and `http-get`/`http-post` all depend on a `--grant` the fuzzer never
  mints (`tools/fuzz.ml` has no grant-generating arm at all — checked,
  not merely undocumented). Adding any of these to the grammar is
  meaningful future work, but it first
  requires teaching the generator to emit `--grant` specs, which does not
  exist today for any capability kind (`fs:`/`process` included).

- Cluster distribution features (tokens, transport, remote placement,
  host-qualified domain distribution, and store GC) have no pp-language
  surface at all, so there is nothing for the fuzzer to generate.
  `cluster-init`/`--mint-token`/`--serve-hit`/`--recv-hit`/
  `--transport-push`/`--transport-pull`/`--remote-node`/`--member-name`/
  `--publish-object`/`--desired-object`/`--gc-mark`/`gc` are all CLI-only
  administrative/test/orchestration entries (`src/token.ml`,
  `src/transport.ml`, `src/remote.ml`, `src/blobref.ml`,
  `src/gcroots.ml`, `src/store_gc.ml`); no reader syntax, builtin, or
  expression form exists for a token, a transport op, a placement
  (`--schedule remote:<member>` is a CLI flag, exactly like
  `parallel:N`/`race:N` before it), a host key, or a GC root.
  `dune exec ./tools/fuzz.exe -- --grammar core|full --count 2000` was
  re-run after every stage's change and came back clean (0
  mismatch/crash), confirming each addition is additive and doesn't touch
  the fuzzed surface.
