# pp TESTING — the correctness ratchet

pp's correctness rests on **differential testing**: every test runs under both
backends (the tree-walker and the bytecode VM) and their output must be
byte-identical. Two mechanisms enforce it — a fixed test suite and a fuzzer.

## The test suite — `dune runtest`

```sh
dune runtest          # diff both backends on every tests/NNN-*.pp, then the
                      # capability adversarial suite
dune runtest --force  # re-run even if dune's cache says nothing changed
```

`tests/NNN-*.pp` are hand-written programs (each is also a regression pin —
e.g. `tests/008` pins the D21 slot-reuse fix, `tests/009` pins the D6/D17
content-key soundness fixes, `tests/030` pins four fuzzer-shrunk
nested-`let`-in-`let*`-RHS slot repros from the D21 family). The driver (`scripts/run-tests.sh`) runs each
file as `pp file` and `pp --bytecode file` and fails on any diff. Then it runs
two shell suites:

- `tests/capability-adversarial.sh` — capability-constructor removal,
  path-component scope, and gated `slurp` across both backends; extended for
  M3: a printed capability is unparseable text
  (`forge-from-print`); composing two capabilities each narrowed from the same
  broad root never resurrects the root's full authority
  (`compose-does-not-resurrect`); `cap-restrict`'s mode argument and
  `with-caps` both reject a widening request against a lexically-held broader
  value (`cap-restrict-mode-widen-rejected`, `with-caps-widen-rejected`);
  `with-caps` restores the prior ambient after a tail call and after a raised
  exception (`with-caps-tail-safe`, `with-caps-exception-safe` — via piped
  REPL input, since only a persistent session can observe ambient state across
  the error); a node's free variable that is (or, via a captured closure,
  contains) a capability is `Capability_error` at the key
  (`node-cap-capture-direct`, `node-cap-capture-via-closure`); a node's result
  containing a capability, bare or embedded, is rejected before storage
  (`node-cap-result-rejected`, `node-cap-result-embedded`); `effect(...)` is
  now an ordinary unbound-symbol error (`effect-removed`).
- `tests/010`–`tests/015` — the persistent node cache. These can't be `.pp`
  diffs: they run the interpreter several times *across processes*, mutating
  files / grants / globals between runs, under an isolated `$HOME` so they never
  touch the developer's real `~/.pp/store`:
  - **010** — verifying traces: unchanged file hits (and doesn't replay the
    node's `log`, per LAW 17), changed file recomputes with fresh contents (the
    staleness fix), reverted file re-hits the original trace in the set.
  - **011** — LAW 20 keying: an unrelated global rebind is a hit, a changed
    referenced free variable is a miss, widening `--grant` doesn't invalidate.
  - **012** — LAW 28 failure memoization: a failing node re-serves the same
    error without re-running, re-runs when a recorded read changes, and never
    reports the D16 fake "infinite recursion".
  - **013** — LAW 23b: a narrow-capability caller cannot get a hit on a node
    whose (transitive) read closure it can't cover, and a cap denial doesn't
    poison the cache.
  - **014** — VM parity: every one of the above under `--bytecode`, plus
    bidirectional cross-backend key sharing (a node built by one backend is
    reused by the other).
  - **015** — LAW 33/26 trace cells: ambient config/handlers a node never
    observed don't invalidate it (they're out of the key); a config value or
    handler it DID observe recomputes on change and re-hits on revert; a mock
    `read-file` and the real builtin coexist as two traces under one key with
    no cross-contamination; VM included.
  - **016** — LAW 21 cutoff (Phase-1 exit criteria 2/5): a null rebuild and a
    mtime-only `touch` recompute nothing; a header edit that leaves the
    derived value byte-identical re-runs the reader node but NOT the
    value-keyed dependent (compile re-runs, link cut off); a real content
    edit re-runs the chain; VM included.
  - **017** — D13 `run` effect + sandbox: no process grant ⇒ capability
    error; a run-node caches and re-runs when a granted tree changes (the
    coarse `tree:` cell catches reads pp never saw); tool outputs land in
    node-local scratch, never the caller's cwd; absolute node `write-file`
    errors while scripting-tier writes work; VM included.
  - **018** — Q4 reconciler v1: create/null/drift/shrink reconciles converge
    with the right create/update/delete counts; manual edits and foreign
    files under the managed root are converged away (single writer); no
    write grant ⇒ nothing materialized; a desired state that read its own
    domain ⇒ stratification error; intent/done pairs land in the journal;
    VM included.
  - **019** — `pp why` / `--no-cache` / `--check`: why reports first-build
    miss, hit, and stale (naming the changed cell); an unauthorized cell in
    another trace is redacted, never named (LAW 23c); `--no-cache`
    recomputes but still refreshes the store; `--check` passes a
    deterministic node and flags a volatile one with a nonzero exit;
    VM included.
  - **020** — Q6/D8c loader authority: loading beside the program works
    with zero grants; loading outside every source root errors even with a
    broad grant; a node's `load` is a `runtime:file:` cell — editing the
    module invalidates, but a hit needs no fs grant over it; cwd-relative
    stdlib loads still work; VM included.
  - **021** — Q11 CAS ingest: an external writer mutating a file between
    two nodes is invisible — both observe the pinned snapshot, whose bytes
    land in `blobs/<sha256>`; the snapshot holds at every tier; pp's own
    `write-file` advances it; VM included.
  - **022** — Q2 depfile adapter: with `run-dep`, an unrelated change under
    a granted root stays a HIT (no coarse tree cell) while a dep the tool
    actually read — granted or system — re-runs on change; a missing
    depfile falls back to the coarse floor; VM included.
  - **023** — blob-hash desired values: `blob(S)` refs and inline strings
    coexist in one desired map; `rm -rf build/` + re-reconcile restores from
    the store with zero tool re-runs (exit criterion 4 at unit scale); a
    dangling blob ref is a hard error; VM included.
  - **032** — push stabilize differential test: a battery of cell-change
    sequences on a 4-node program; push (`--watch --stabilize`) and pull
    (`--watch`) produce identical re-evaluation patterns at each step;
    both backends.
  - **033** — process-domain reconciler (Phase 2, LAW 30): `--supervise`
    starts/stops services from a desired process map; `kill -9` restarts
    within one poll interval; config edits restart exactly the affected
    service; journal contains intent/done proc entries; both backends.
  - **034** — fenced effects (LAW 31): `fenced(KIND, SPEC)` errors inside a
    node body, is a no-op without a reconciler, executes once and journals
    intent/done under `--reconcile`, has VM parity, and recovers a killed
    mid-apply action without silent double-execution under
    `--fenced-policy retry` or aborts under `--fenced-policy abort`.
  - **029** — REPL (ROADMAP §1): paren-balanced multi-line continuation,
    defs persisting across lines in BOTH backends, promptless piped output,
    `:why` toggling, `exit(N)` status control, deep-forced printing.
    (Arrow keys / `~/.pp/history` need a pty; verified by hand.)
  - **028** — the stdlib (ROADMAP §2): value oracle for the string/number
    primitives; `argv()` from after `--`; `env-get` incl. absence; `exit(N)`
    exit-code control; `assert` failures naming the form and its file:line;
    `file-exists?`/`dir?` capability gating and `stat:` trace-cell semantics
    (created/deleted paths invalidate; an absence trace re-hits after
    deletion); VM included. `tests/028-stdlib.pp` runs the pure parts under
    the differential diff.
  - **027** — error messages (LAW 29/D12): top-level runtime errors carry
    the form's file:line, arity errors name the callee, capability errors
    name the operation, no double locations, single-line `pp: error:`
    reporting with exit 1 — with stderr byte-identical across backends;
    case (g) pins the D12 `load` residual fix: an error inside a `load`ed
    file cites THAT file's line, not the loading form's.
  - **026** — per-parameter type annotations (LAW 32): well-typed calls pass,
    ill-typed calls raise the same located "type mismatch" on both backends
    (stderr byte-identical), unknown type names pass (gradual), vector param
    lists and return+param combinations enforce.
  - **025** — `let x = v` value-binding semantics (ROADMAP maturity §1): the
    RHS evaluates at definition time (delay/node RHS binds the unforced
    thunk), blocks are letrec* with a `referenced before its definition`
    error and duplicate-def read errors, the top level is sequential,
    `node x { e }` binds a node thunk that caches on force; both backends.
  - **024** — the Phase-1 exit criteria on a generated 101-TU C project
    built by a real `build.pp`: null rebuild = 0 processes (<1s, journal-
    proven); touch = 0; one edit = exactly compile+link; restore from store
    byte-identical; comment-only header edit cuts off the link; authority
    gates hits; the VM shares the compile cache. Skips cleanly without cc.
    The fixture generator and drift mutations are pp programs
    (`tests/gen-cproject.pp`, `tests/mutate-cproject.pp` — the ROADMAP §2
    milestone); the pass/fail oracle stays shell. `build.pp` is written the
    pairing-trap-safe way — `map(compile, names)` (the non-forcing `map`
    builtin) force-deep'd as a batch, THEN paired back up with `names` —
    per Phase 3's `p3-*` assertions (M1): the same cold build under
    `--schedule parallel:$(nproc)` produces the identical desired-state
    hash and byte-identical materialized tree to the serial build, the
    same exec count, a null rebuild with zero new execs under parallel too,
    and is measurably faster (asserted `<` the serial wall-clock).
  - **038** — Phase 3 parallel-scheduler stress (M1, exit criteria 2/3):
    `race:3` on a deliberately slow node — identical result, exactly one
    surviving trace line, wall-clock ≈ one run rather than 3x; 64
    independent nodes under `parallel:16` on one store repeated cold —
    every run's objects/traces round-trip, a serial re-run against the
    warm store is hash-identical, and one cold run's journal has exactly
    64 parseable `exec` lines (`Journal.append`'s one-`write_substring`
    hardening); `race:8` hammering a single key with the trace-lock
    disabled (`PP_TRACE_LOCK=0`, an internal test-only escape hatch) still
    yields a parseable trace and a correct subsequent hit; `fenced(...)`
    inside a node body still raises under `parallel:4` and `race:3` (LAW
    31's negative half holds under every placement).
  - **036** — cell-id canonicalization (SPEC LAW 23, M2): a source tree
    reached via a symlink loads and hits identically to the real path, both
    directions; a `tree:`/`tool:` node cache hits when the SAME content is
    granted via a different spelling (a user symlink, and macOS `/var` vs
    `/private/var` on whatever symlink layer the host's own tmp path
    already has — skips cleanly if none); a trailing-slash grant equals one
    without; a write-target's `stat:` cell-id (via `pp graph`) is
    byte-identical before and after the file exists. VM included.
  - **037** — portable store format (M2.2, ROADMAP maturity §3): the store's
    canonical s-expr text codec replaces Marshal. Golden bytes — a fixed
    program's object and trace files are byte-identical to fixtures in
    `tests/fixtures/store-v1/` (names and content, both backends); a codec
    round-trip battery (negative ints, `-0.0`, `1e308`, `nan`/`inf`,
    control-byte/UTF-8 strings, keywords, symbols, nested vectors,
    mixed-key maps, sets, improper pairs) stores in one process and HITS
    in a second, printing byte-identically, in all four backend
    directions; a VERSION bump ("pp-store 0") recomputes cold without
    crashing, re-stamps, and preserves journal/ + blobs/; a closure-valued
    node stores NO object (the non-data law) yet recomputes cleanly while
    a data node beside it still hits; a legacy Marshal-era store (garbage
    bytes, no VERSION) is wiped and rebuilt, exit 0.
  - **039** — D22 VM global-scope holes (`.pp` differential): a bare
    top-level `do { let x = ...; ... }` binds `x` block-local — referencing it
    after the `do` closes is an unbound-symbol error in both backends; a
    `module { ... }` body's later children (a function def, a value def, and
    a bare statement) see EARLIER siblings, letrec*-style, exactly like the
    tree-walker's `env_acc` fold.
  - **040** — M3 in-language capability attenuation: the
    two-direction differential that is
    IMPOSSIBLE to write before `with-caps` exists — a node created under a
    NARROWED `with-caps` extent is still denied when forced later under the
    full grant (capture-at-creation, not ambient-at-force), and a node
    created under the full ambient still succeeds when forced inside a
    narrower `with-caps` (fixed at creation, mirroring lexical closure
    capture) — both directions, both backends; plus `with-caps` narrowing
    `slurp` (scripting tier) and `run` (an fs-only restrict drops process
    authority entirely, since `CapRestrict` is filesystem-scoped). Isolated
    `$HOME` per case, like `tests/011`/`013`/`017`.
  - **041** — `defmacro` (M3, D10's promise; `.pp` differential): a
    control-flow macro (`unless`) via quasiquote; a `gensym`-based macro
    whose introduced temporary shares its TEXTUAL prefix with a caller
    variable of the same name, proving no capture; a macro building a
    `(force (node ...))` form; nested macro use (one macro's expansion
    calls another macro); a macro-generated `(def ...)`; a macro built with
    plain `list`/`quote` (no quasiquote); redefining a macro changes later
    expansions. Deliberately prints only VALUES, never node-body `log`
    side effects — a hit/miss-dependent print would make repeated
    `dune runtest` runs against a developer's real (non-isolated) `~/.pp`
    flaky, since this file is a plain stdout diff, not one of the isolated-
    `$HOME` shell suites.
  - **042** — the LAW 20 exit criterion for `defmacro`
    (M3 exit 3): a `build.pp`-style program whose node body comes
    from expanding a macro; editing ONLY the macro's definition (the call
    site `build-step()` byte-identical) is a MISS that recomputes — proven
    by the presence of the node's `log` output and by `pp why` reporting a
    hit only after that recompute — and reverting the definition HITS again
    with no recompute; both backends. Also pins the macro-in-node-body rule:
    a `defmacro` textually inside a `node { ... }` body is never specially
    recognized (only a true top-level form registers a macro), so it fails
    as an ordinary "unbound symbol: defmacro" in both backends, byte-
    identically. Isolated `$HOME`, like `tests/011`/`040`.
  - **043** — M4 probes (M4; SPEC LAW 37/38): a
    file-backed counter as the observe-fn, so its value is controllable; a
    node reading `probe(name)` re-forces exactly when the counter changes
    and hits (no recompute) when it doesn't, across four separate `pp`
    invocations (cold/unchanged/changed/reverted, mirroring `tests/010`'s
    shape) — both backends. Also: a recursive `~/.pp/store` scan (excluding
    `blobs/`, which ordinary `slurp` inside the observe-fn legitimately
    populates) proves the raw probe payload never lands in `objects/`/
    `traces/`; a registered-but-never-read probe's observe-fn never fires
    (an unrecorded side effect, the demand-pruning half of LAW 7 extended to
    probes); an unregistered probe name is a hard error; `register-probe`
    inside a node body errors (script-tier only, mirroring `fenced`). A
    final section proves the SAME mechanism live under one long-running
    `pp --watch` process (portable `timeout` shim, like `tests/031`): with
    no probe-specific wiring at all, the existing generic watch-loop
    polling (`Runtime.observed_all` → `Store.observe_cell`) already detects
    a changed probe cell and re-evaluates exactly the dependent node.
  - **044** — M4 sealed cells (SPEC LAW 39): `--grant secret:<path>` reads
    redact on print (`#<sealed>`) and round-trip through `unseal(v)`; a
    recursive store scan (the WHOLE store, `blobs/` included this time —
    a sealed read must never call `store_blob`) finds no secret bytes after
    a program that only reads, and separately one that unseals at script
    tier only; the node-boundary ban fires both directions (free-var and
    result) with byte-identical stderr across backends; rotating the
    secret's bytes recomputes exactly the observing node, leaving a sibling
    node untouched; a caller re-run with NO grant at all cannot hit a
    node whose cached trace shows a covering grant existed once (LAW 23b);
    covered by both `secret:` and `fs:` grants behaves as plain fs.
  - **045** — M4 network: gated cleanly on `curl` and `python3` both being
    present (a tiny stdlib `http.server`-based loopback fixture, no real
    network). No `net:` grant, or a grant for a different host, denies
    `perform http-get/http-post(...)`; a covering grant (exact host, or a
    `net:*` wildcard) allows it against the local server, both backends;
    `http-post`'s body actually reaches the server (echoed back); `perform
    http-get` inside a node body errors and never touches the network; a
    `curl`-absent run (an emptied `PATH`) is a clean error, not a crash.
  - **046** — Q13, the in-language reconciler-domain protocol
    (M4, Q13; the M4 exit criterion). A THIRD-PARTY toy
    "kv" domain (a directory of one-file-per-key values) is defined and
    registered entirely INSIDE the test's own pp programs via
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
    the whole Q13 migration — the exit criterion itself) are this test's
    real companions, not duplicated here.
  - **047** — M5 stage A: cluster transport, signed tokens, by-hash sync
    (M5; docs/THREAT-MODEL-cluster.md is the
    gate). Two (or three) `pp` PROCESS invocations differing only in
    `$HOME` stand in for distinct cluster members, sharing a WORK dir the
    way tests/019 does. `pp cluster-init` mints `~/.pp/cluster/{secret,id}`
    (mode 0600, refuses to overwrite); the secret/id are copied to the
    other simulated members (out-of-band distribution). T1: `--transport-
    push` then a flipped byte (object, blob) or truncation (trace) in the
    shared root, then `--transport-pull` exits nonzero naming the tampered
    artifact for all three kinds. T2: `--serve-hit` with a flipped-MAC-byte
    token, and with a negative-TTL (already-expired) token, both reply
    `deny`, and neither creates the shared root (nothing crosses on
    denial). T3: the SAME node key gets `miss` from a token whose grant
    doesn't cover the node's read closure and `hit` from one that does —
    LAW 23b across the wire, proven by holding the key fixed and varying
    only the token. `--recv-hit` pulls the hit's object+trace, re-hash-
    verifying, and the receiving member then hits LOCALLY with no
    recompute. T4: `pp why` under a narrow grant, run once on the builder
    and once (post-sync) on the receiver, produces byte-identical
    redaction (`<redacted unauthorized cell>`, never the real path in a
    `[why]`-tagged line) — scoped to `[why]` lines specifically, since the
    program's own subsequent capability-denied read legitimately names the
    path in an ordinary error line (the tests/019 pattern). T5: a node
    touching a secret is refused at the existing M4 node boundary before
    ever being stored, and a whole-tree grep after the attempt finds the
    secret's bytes nowhere outside their source file. T6 (partial): a
    third, never-synced, independent build of the same program computes
    the identical node-key filename and a byte-identical result object,
    and the receiver's serve-hit-synced object is also byte-identical to
    the builder's own.
  - **048** — M5 stage B: remote placement (M5,
    "Remote placement" / "Q11-bis"). Two `pp` process invocations
    differing only in `$HOME` (dispatcher A, member B), addressed via
    `~/.pp/cluster/members`, over the same local-dir loopback stage A
    uses. An 8-TU real-cc build (scaled down from tests/024's 101 for a
    two-process-per-node test) under `--schedule remote:B`: byte-
    identical materialized tree AND desired-state hash (the `--check`
    schedule-transparency audit, extended to `Remote` policy_name) vs a
    serial build — deliberately materializes via plain top-level
    `write-file` rather than `--reconcile`, working around a WALL this
    test found (see STATUS.md/report: `--reconcile` preloads
    `stdlib/list.pp`, whose own `map` shadows the batching `map` builtin,
    silently defeating parallel/race/remote batching for any
    `--reconcile` build — out of stage-B scope to fix). Cross-machine
    hit: the dispatcher's and member's trace-key sets intersect (the
    member genuinely forced compile nodes; the dispatcher's own
    subsequent Store.hit serves them, no local recompute). `tool:` not
    pre-seeded: the member's own journal shows real `cc` execs (its own
    legitimate observation). Q11-bis: a `PP_REMOTE_TEST_HOOK`/`_AFTER`
    test-only synchronization seam (src/remote.ml, unset in every normal
    invocation) mutates a shared data file to a DIFFERENT value in the
    exact window between the dispatcher pinning it and the member
    running, then reverts once the member has exited — the member's own
    stored object is the dispatcher's PINNED bytes, never the disk's
    transiently-different value, and the dispatcher's own post-pull
    Store.hit re-validation (against the reverted, now-matching world)
    produces a clean hit. Non-data-closed (a free-var closure) stays
    local: zero trace keys ever appear on the member. Unreachable member
    (a bad members-file target): the build still succeeds, byte-identical
    to serial. VM parity: the same remote build under `--bytecode`.
  - **049** — M5 stage C: host-qualified domain distribution
    (M5, "Host-qualified domain distribution").
    Two separate `$HOME`s (the tests/047/048 convention). `--member-name A`
    converges only host A's fs slice under its own `$HOME`; `--member-name
    B` only host B's, under a genuinely separate `$HOME` — neither's
    materialized tree ever gains the other's file. An unknown
    `--member-name` is a named hard error, not a silent no-op. `kill -9`
    recovery on a member's OWN slice under `--watch --member-name` (a proc
    domain registered by the member's own program) restarts within one
    poll interval, exactly like tests/033's unqualified case, while a
    DIFFERENT host's service in the same desired map is never even
    started. Back-compat: a from-scratch third-party "kv" domain (the
    tests/046 pattern) with no `--member-name` at all reconciles exactly
    as it always has — the least-magic detection rule (opt-in only via the
    explicit flag, never shape-sniffed) proven directly, not merely
    inferred from other files staying green. VM parity.
  - **050** — M5 stage C: store GC (`pp gc`, explicit, never automatic;
    M5, "Store GC"). N `--reconcile` passes with
    CHURN (a per-pass file added then removed) show the store growing
    without `pp gc` between passes and staying bounded with it; the
    frozen journal gains exactly one `epoch HASH` line per successful
    pass. The kept (most recent) root's closure survives every sweep: a
    subsequent identical rebuild is a pure cache hit (zero new execs) with
    a byte-identical materialized tree. A genuine long-running `--watch`
    loop (not merely repeated one-shot invocations) races a CONCURRENT
    `pp gc` process against the same store across several ticks: no
    crash, bounded size, the loop's own converge still correct throughout.
    T7: a `parallel:8` build (the tests/038 shape) races `pp gc` (a long
    grace period standing in for "genuinely still in flight"): no crash,
    correct result, and a subsequent rebuild is still byte-identical with
    zero new execs. The islands cache (`~/.pp/islands`) is untouched by
    any of the above. `pp gc` on a completely empty store is a clean
    no-op, not an error.
  - **051** — the M5 exit battery's own remaining gap (docs/PLAN-
    m5-distribution.md "Exit tests" 1–5 are otherwise covered: 1/2/3/5 by
    047/048, 4 by 050). Two genuinely separate `$HOME`s exercise the
    by-hash desired-value seam stage C adds: a dispatcher `--publish-object`s
    a host-qualified value (including a `blob(...)` reference alongside
    inline content) into a shared local-dir root; a member, a SEPARATE
    `$HOME`, `--desired-object`s it by hash and converges only its own
    slice — the blob's actual BYTES cross (byte-identical to the source),
    not merely the small string reference; nothing beyond `objects/` and
    `blobs/` is ever published (no journal, no fenced-specs) under the
    shared root. A tampered published object is rejected on pull (T1, this
    seam's own call site — the same `ingest_object` choke point every
    other synced artifact goes through). `pp gc` on the receiving member's
    store, whose one epoch was sourced via `--desired-object` (the one
    `Gcroots` field no other test exercises), replays and sweeps
    correctly, and the kept root's closure still converges afterward.
  - **052** — M6 stage A: the devops-complete demo (M6).
    `demo/deploy.pp`/`demo/agent.pp`/`demo/src/greeter.c` — an all-library
    composition, zero `src/*.ml` changes — build a C service, deploy it
    across two hosts, converge after drift and after `kill -9`, rotate a
    secret invalidating exactly its observers (bytes never under
    `~/.pp/store`), and audit via `pp why` (55 assertions across six
    clauses). Then the demo's OWN diagonal oracle: six pull rows
    (backend×placement) publish the identical desired-state hash, both
    non-serial `--check` runs exit 0, and six push rows settle to a
    byte-identical materialized tree — needing no pinning, since this
    demo's desired state is a pure function of `file:`/`sealed:` cells.
  - **053** — M6 stage B: the observation-pinning seam (M6,
    "Stage B — the pin seam"). `demo/volatile-deploy.pp` is a deliberately
    ADVERSARIAL program, separate from 052's demo, that folds
    `probe("replica-count")` directly into its returned desired state.
    Unpinned control: two `--publish-object` runs with different
    metrics-file content publish two DIFFERENT hashes (the probe is
    genuinely volatile, not a strawman). `--dump-pins` from one canonical
    run, then `--pin-file` that dump across the 6 pull combinations
    (backend×placement) with the metrics file mutated to a THIRD, divergent
    value: all 6 published hashes equal the canonical hash, and the
    observe-fn's sentinel file is proven ABSENT in every one (a
    `(pin-probe "NAME" <value>)` line short-circuits `probe_value_for`
    before it ever calls the registered observe-fn). Push/materialization
    combos aren't wired — this adversarial program registers no domain, so
    there is no tree for a `--watch --stabilize` pass to converge/diff.

Two proofs run OUTSIDE `dune runtest` (they invoke dune / the network):

- `scripts/build-self.sh` — exit criterion 6: pp builds itself via a
  `build.pp` whose one node wraps the dune invocation, keyed on `tree:src`;
  a null rebuild never executes dune.
- `scripts/build-lua.sh` — real-world replication on Lua 5.4.7: cold build,
  zero-process null rebuild, comment-only `lua.h` edit with link cutoff, and
  byte-identical store restore. Downloads the pinned tarball on first use.

To run a single file by hand:

```sh
pp --diff tests/007-phase0-laws.pp    # runs both backends; exits 1 if the
                                      # returned top-level VALUES differ
```

Note the two checks are complementary: `--diff` compares the *returned values*
of top-level forms, while `dune runtest` diffs *stdout* (so it also catches
`print`/effect-ordering divergences that don't change return values).

## The differential fuzzer — `tools/fuzz.ml`

Generates random pp programs, runs each under both backends, and asserts
identical observable behavior. Divergences are deduplicated by signature,
shrunk to a minimal repro, and written to a failure directory. Zero
dependencies beyond the OCaml `unix` library. Fully deterministic: program *i*
under seed *S* is always the same program (no `Random.self_init`).

**M7 S1 — the suite is 2 readers × 2 backends.** Every generated program is
additionally pushed through `pp --roundtrip-braces f`, which in one process
reads the sexpr AST, prints it as location-preserving brace text
(`src/printer_braces.ml`), re-reads that with the brace reader
(`src/reader_braces.ml`), and asserts per-form structural AST equality AND
LAW-20 `hash_expr` equality. Any nonzero exit is a gating MISMATCH
(`roundtrip:*` signature; a `<iter>.rt.out` artifact is saved alongside the
backend outcomes), shrunk like any other. The summary prints a
`roundtrip N checked, M failed` line. `tests/054-brace-reader.sh` runs the
brace reader's own oracle battery (a nontrivial `.ppb` under both backends,
cross-surface `load`/islands, assert-desugar parity, `--emit-braces` on a
real test file, a whole-tree `--roundtrip-braces` sweep) plus a 300-program
full-grammar fuzz pass of this gate inside `dune runtest`.

```sh
dune build                                              # builds bin/pp + the fuzzer
dune exec ./tools/fuzz.exe -- --grammar core --count 2000
dune exec ./tools/fuzz.exe -- --grammar full --count 2000
```

**M7 S2 — `pp fmt`, the lossless transpiler.** `pp fmt --to-braces`/
`--to-sexpr <file> [-i]` (docs/M7-SYNTAX.md "S2") reads one surface, prints
the other via the same location-preserving discipline as `--emit-braces`
(`src/printer_braces.ml`; the new `src/printer_sexpr.ml` for the reverse
direction), and additionally carries comments losslessly through a side
channel (`src/comments.ml`) that never touches the AST both readers hand the
evaluator — LAW-20 hashes ignore comments by construction, so hash equality
alone can't catch a dropped one; comment COUNT and TEXT (mod the `;`/`#`
delimiter and whitespace) are checked separately. `-i`/`--in-place` rewrites
the file at its own path (never renaming it: hash preservation requires the
location file to stay identical across both hops — this is the S3 migration
vehicle). `tests/055-fmt.sh` covers a tricky-comments fixture each direction
(trailing/standalone/comment-only/end-of-file comments, run-identically
before and after), output determinism (`fmt` twice on the same input is
byte-identical), and a whole-tree in-place round-trip sweep asserting every
top-level form's `hash_expr` survives `to-braces` then `to-sexpr` — the two
internal test seams `--compare-hash`/`--list-comments` exist only for this.

**M7 S3 — the tree is brace surface; `.pp` dispatches to the brace reader.**
Every `.pp` file in the tree (tests, stdlib, build.pp, demo, examples, the
manual's executed examples, the store-v1 golden fixture) was migrated
mechanically via `pp fmt --to-braces -i` — no file renamed (LAW-20 hashes
the `ELocated` file name, so `pp fmt -i` at the same path preserves every
node key; `scripts/build-self.sh` and `scripts/build-lua.sh` null-rebuild
with 0 recomputes against a store populated pre-migration). Extension
dispatch (`Reader_braces.read_dispatch`): `.pp` and `.ppb` read as braces,
`.ppl` ("the AST form") reads as sexpr — supported forever, it IS the macro
layer. Non-file sources (interactive/piped REPL input, `-e`, the
`--reconcile` glue's synthetic `<...>` tags) still read as sexpr — flipping
those display/input surfaces is S4's remaining scope. Shell tests' embedded
programs were converted to braces except where a case specifically targets
the sexpr surface (tests/054's cross-surface fixtures and
`--roundtrip-braces`/`--emit-braces` inputs, which take `.ppl`); the fuzzer
writes its generated sexpr programs to `.ppl` scratch files.

The fuzzer shells out to the interpreter, defaulting to `bin/pp` (the symlink
`dune build` targets). Run from the repo root, or pass `--pp PATH`.

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

- **`core`** — forms both backends must agree on: literals (negatives
  included), `if`/`do`/`let`/`let*`, `fn` + application, `def` (functions,
  arity ≥ 1, AND `(def x v)` value bindings referenced by later statements),
  the arithmetic/comparison builtins, list/vector/map ops, strings, `print`,
  literal-key `with-config`/`config`, and the stdlib list functions via
  `(load ".../stdlib/list.pp")`. **Any non-PASS on `core` is a real bug** — its
  exit code is the CI gate.
- **`full`** = core **plus** what was the Phase-0 divergence surface: type
  annotations (return AND per-parameter — the latter with deliberate
  ill-typed calls as matched both-error probes),
  `module`/`import`/`load-module` and computed `config` keys,
  `perform`/`with-handler` over the `log` effect, deep tail/non-tail
  recursion and long `map`s, `=` on structurally identical unforced lists,
  sibling-referencing `let` bindings, quoted special forms, bare top-level
  `do` with a def that must NOT leak past the block, and `module` bodies
  whose function defs/value defs/bare statements reference EARLIER siblings
  (the D22 VM scope holes, both fixed — `stmt_do_scoped_def`,
  `stmt_module_sibling`), and `defmacro` (M3, D10's promise): `stmt_defmacro`
  defines a fresh, well-scoped macro that doubles its (always-literal)
  argument via `list`/`quote` and calls it, exercising the shared expansion
  point (`macro.ml`) both backends pass through before compile/eval ever see
  the form. This **now passes** (Phase 0 is closed); a regression here is a
  new bug.

Never generated: `random`, wall-clock forms, file-write effects, capability
constructors and the `with-caps`/`current-capabilities`/`cap-restrict` surface
(all nondeterministic or unsafe/security-sensitive), and **network** islands.
The `effect` special form (the pre-M3 capability-union block) was previously
generated by `stmt_effect`; M3 removed the form from the language entirely,
so that generator arm is deleted too — `(effect
...)` is no longer valid pp syntax to generate, not merely excluded.
Pinned `file:` islands over a fixed fixture ARE sampled in the `full`
grammar (the fixture is pinned once at fuzzer startup via `pp --update`,
which also exercises the pin rewriter); `tests/035-islands.sh` covers the
rest, with a network subcase against a local bare git repo behind
`PP_ISLAND_NET_TEST=1`.

### Verdicts

| verdict | condition | CI effect |
|---|---|---|
| PASS | both exit 0, stdout identical, stderr identical | — |
| MISMATCH | stdout differs, effect-log (stderr) differs while both exit 0, or exactly one backend errors | **fails** |
| BOTH-ERROR | both exit non-zero; grouped by normalized error tag | soft class for now |
| CRASH | either side times out, dies by signal, or exits > 128 | **fails** |

Exit code is non-zero iff MISMATCH + CRASH > 0. Stderr is compared only when
both exit 0 (at which point it holds only `log` effect output), so it doubles
as the "identical effect logs" check without tripping on error wording.
**Signatures** normalize the payload (digits → `#`, wrappers stripped) so
thousands of failures collapse to a handful of bug classes.

### Failure artifacts

```
fuzz-failures/<sanitized-signature>/
  <iter>.ppl         # up to 3 raw failing programs (sexpr — M7 S3)
  <iter>.tw.out      # tree-walker status + stdout + stderr
  <iter>.bc.out      # VM status + stdout + stderr
  min.ppl            # shrunk minimal repro (not for BOTH-ERROR)
  min.tw.out / min.bc.out
```

Shrinking is greedy-to-fixpoint (drop top-level forms, hoist a child over its
parent, replace subtrees with `0/1/true/nil/"a"`, halve integer atoms),
accepting a reduction only if the *exact* signature is preserved. The budget is
counted in executions, not wall-clock, so shrinking a `crash:*:timeout` is slow
— lower `--timeout-ms` or `--shrink-budget` for those.

### Reproducing a failure

Every artifact records its iteration number. To regenerate program 1234 of a
`--seed 0 --grammar full` run:

```sh
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --dump 1234 > repro.ppl
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --start 1234 --count 1
pp repro.ppl; pp --bytecode repro.ppl
```

(M7 S3: fuzzer-generated programs are sexpr text, so the redirected file
takes the `.ppl` extension — `.pp` now dispatches to the brace reader.
Failure artifacts under `fuzz-failures/` are likewise named `<iter>.ppl`/
`min.ppl`.)

`--max-depth` and `--stdlib` must match the original run for byte-identity.

### Adding a grammar rule

1. **Verify the form against `src/` first** (reader syntax, primitive names,
   both backends' handling). Do not invent function names — several plausible
   ones (`min`, `max`, `str`) do not exist.
2. New *expression* production: add a weighted arm to the right typed generator
   (`gen_int`/`gen_bool`/`gen_string`/`gen_float`/`gen_list`) in `fuzz.ml`.
   Keep it well-scoped (only symbols from `env`) and type-correct.
3. New *top-level* production: write a `stmt_*` returning `sx list` and register
   it with a weight in `gen_program`. If it needs the stdlib, set
   `env.stdlib <- true`.
4. Nondeterministic forms stay banned until the roadmap gates them.
5. Sanity-check with `--dump 0..5` and a 100-program run; a rule that produces
   matching BOTH-ERRORs on most programs is a generator bug, not a finding.

### Deliberate generator exclusions

- **Core `let` never references sibling bindings** (the tree-walker's parallel
  vs the VM's sequential handling); the divergent case is generated
  deliberately only in `full`.

(Three historical exclusions are gone: bare negative literals lex correctly
now; `(def x 5)` is a value binding — `stmt_def_value` generates it and later
statements reference the bound name; and bare top-level `do` with defs plus
module-body sibling references — the two D22 VM scope divergences — are
fixed and now generated in `full` by `stmt_do_scoped_def` and
`stmt_module_sibling` respectively: the former asserts a `do`-local def is
unbound afterward in both backends, the latter has a module's function def,
value def, and a bare statement all reference EARLIER siblings.)

- **M4 probes/sealed cells/network are not fuzzer-generated.** `register-probe`/
  `probe`, `slurp`/`read-file` under a `secret:` grant, and `http-get`/
  `http-post` all depend on a `--grant` the fuzzer never mints (`tools/fuzz.ml`
  has no grant-generating arm at all — checked, not merely undocumented — so
  the `CapNetwork` shape change from `{protocol}` to `{host; port option}`
  needed no fuzzer update). Adding any of these to the grammar is meaningful
  future work but requires teaching the generator to emit `--grant` specs
  first, which does not exist today for ANY capability kind (`fs:`/`process`
  included).

- **M5 stages A/B/C (tokens/transport/remote placement/host-qualified
  distribution/GC) have no pp-language surface at all, so there is nothing
  for the fuzzer to generate.** `cluster-init`/`--mint-token`/`--serve-hit`/
  `--recv-hit`/`--transport-push`/`--transport-pull`/`--remote-node`/
  `--member-name`/`--publish-object`/`--desired-object`/`--gc-mark`/`gc`
  are all CLI-only administrative/test/orchestration entries (src/token.ml,
  src/transport.ml, src/remote.ml, src/blobref.ml, src/gcroots.ml,
  src/store_gc.ml); no reader syntax, builtin, or expression form exists
  for a token, a transport op, a placement (`--schedule remote:<member>`
  is a CLI flag, exactly like `parallel:N`/`race:N` before it — LAW 34's
  negative half), a host key, or a GC root. `dune exec ./tools/fuzz.exe
  -- --grammar core|full --count 2000` were re-run after every stage's
  change and came back clean (0 mismatch/crash), confirming each addition
  is additive and doesn't touch the fuzzed surface.
