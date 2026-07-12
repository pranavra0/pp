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
  path-component scope, and gated `slurp` across both backends.
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
  - **023** — blob-hash desired values: `(blob S)` refs and inline strings
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
  - **034** — fenced effects (LAW 31): `(fenced KIND SPEC)` errors inside a
    node body, is a no-op without a reconciler, executes once and journals
    intent/done under `--reconcile`, has VM parity, and recovers a killed
    mid-apply action without silent double-execution under
    `--fenced-policy retry` or aborts under `--fenced-policy abort`.
  - **029** — REPL (ROADMAP §1): paren-balanced multi-line continuation,
    defs persisting across lines in BOTH backends, promptless piped output,
    `:why` toggling, `(exit N)` status control, deep-forced printing.
    (Arrow keys / `~/.pp/history` need a pty; verified by hand.)
  - **028** — the stdlib (ROADMAP §2): value oracle for the string/number
    primitives; `(argv)` from after `--`; `env-get` incl. absence; `(exit N)`
    exit-code control; `assert` failures naming the form and its file:line;
    `file-exists?`/`dir?` capability gating and `stat:` trace-cell semantics
    (created/deleted paths invalidate; an absence trace re-hits after
    deletion); VM included. `tests/028-stdlib.pp` runs the pure parts under
    the differential diff.
  - **027** — error messages (LAW 29/D12): top-level runtime errors carry
    the form's file:line, arity errors name the callee, capability errors
    name the operation, no double locations, single-line `pp: error:`
    reporting with exit 1 — with stderr byte-identical across backends.
  - **026** — per-parameter type annotations (LAW 32): well-typed calls pass,
    ill-typed calls raise the same located "type mismatch" on both backends
    (stderr byte-identical), unknown type names pass (gradual), vector param
    lists and return+param combinations enforce.
  - **025** — `(def x v)` value-binding semantics (ROADMAP maturity §1): the
    RHS evaluates at definition time (delay/node RHS binds the unforced
    thunk), blocks are letrec* with a `referenced before its definition`
    error and duplicate-def read errors, the top level is sequential,
    `(defnode x e)` binds a node thunk that caches on force; both backends.
  - **024** — the Phase-1 exit criteria on a generated 101-TU C project
    built by a real `build.pp`: null rebuild = 0 processes (<1s, journal-
    proven); touch = 0; one edit = exactly compile+link; restore from store
    byte-identical; comment-only header edit cuts off the link; authority
    gates hits; the VM shares the compile cache. Skips cleanly without cc.
    The fixture generator and drift mutations are pp programs
    (`tests/gen-cproject.pp`, `tests/mutate-cproject.pp` — the ROADMAP §2
    milestone); the pass/fail oracle stays shell.
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

```sh
dune build                                              # builds bin/pp + the fuzzer
dune exec ./tools/fuzz.exe -- --grammar core --count 2000
dune exec ./tools/fuzz.exe -- --grammar full --count 2000
```

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
  `effect`/`perform`/`with-handler` over the `log` effect, deep tail/non-tail
  recursion and long `map`s, `=` on structurally identical unforced lists,
  sibling-referencing `let` bindings, quoted special forms. This **now passes**
  (Phase 0 is closed); a regression here is a new bug.

Never generated: `random`, wall-clock forms, file-write effects, capability
constructors (all nondeterministic or unsafe), and **network** islands.
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
  <iter>.pp          # up to 3 raw failing programs
  <iter>.tw.out      # tree-walker status + stdout + stderr
  <iter>.bc.out      # VM status + stdout + stderr
  min.pp             # shrunk minimal repro (not for BOTH-ERROR)
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
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --dump 1234 > repro.pp
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --start 1234 --count 1
pp repro.pp; pp --bytecode repro.pp
```

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
- **Bare top-level `do` with defs and module-body sibling references** — the
  two known D22 VM scope divergences — are never generated.

(Two historical exclusions are gone: bare negative literals lex correctly
now, and `(def x 5)` is a value binding — `stmt_def_value` generates it and
later statements reference the bound name.)
