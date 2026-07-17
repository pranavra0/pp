# pp testing

pp's correctness rests on differential testing. Every test runs under both
back ends — the tree-walker and the bytecode VM — and their output must
match byte for byte. A fixed test suite and a fuzzer enforce this.

This file describes the machinery only. Each test file's own header
comment states what that test proves. Read the file, not a catalogue.

## Run the suite

```sh
dune runtest          # runs scripts/run-tests.sh
dune runtest --force  # re-run even if dune's cache says nothing changed
```

`scripts/run-tests.sh` does two things:

- runs every `tests/NNN-*.pp` under both back ends (`pp file` and
  `pp --bytecode file`) and fails on any output difference
- runs each `tests/*.sh` shell suite in turn

The shell suites cover what a single-process stdout diff cannot:
multi-process store scenarios (mutating files, grants or globals between
`pp` invocations), expected-output oracles, watch loops, and simulated
cluster members.

To run one differential file by hand:

```sh
pp --diff tests/007-phase0-laws.pp
```

The two checks are complementary. `--diff` compares the returned values
of top-level forms. The suite diffs stdout, so it also catches print and
effect-ordering divergences that do not change return values.

Two proofs run outside `dune runtest` because they invoke dune or the
network:

- `scripts/build-self.sh` — pp builds itself through a real `build.pp`;
  a null rebuild never executes dune
- `scripts/build-lua.sh` — the same rebuild guarantees on Lua 5.4.7; it
  downloads the pinned tarball on first use

The suite is slow: a full run takes about 3.5 minutes.

## Find what a test covers

Each test file's header comment states what it proves and which fixes it
pins. To list every test's first header line:

```sh
awk 'FNR==1{d=0} /^#!/{next} /^# pins:/{next} /^#/ && !d {print FILENAME ": " substr($0,3); d=1}' tests/*.pp tests/*.sh
```

## Add a test

A differential `.pp` test needs no wiring: drop `tests/NNN-name.pp` in
`tests/` and the driver's glob picks it up. A shell suite needs one
invocation added to `scripts/run-tests.sh`, which calls each suite
explicitly.

Conventions:

- start the file with a header comment stating what the test proves —
  this is the only place that information lives
- add a `# pins: LAW-<n>` line when the test pins a SPEC law; the marker
  is machine-parsed by tests/072-law-pins.sh, so keep the exact format
- use the `PP` variable for the interpreter (`PP=${PP:-bin/pp}`) and
  resolve it to an absolute path before changing directories
- isolate the store: `TMP=$(mktemp -d); export HOME="$TMP"` keeps
  `~/.pp/store` inside the sandbox and off the developer's real store
- run both back ends wherever the feature exists in both

## Standing gates

Five suites are gates rather than feature tests. They attach an
obligation to the build, so a change cannot ship unexamined.

- tests/072-law-pins.sh — law linkage. Every SPEC law whose status is
  "holds" must have a test carrying a matching `# pins: LAW-<n>` marker,
  or an explicit entry on the PENDING backfill list. A pin naming a
  nonexistent law fails, and a stale PENDING entry fails, so neither
  list can rot.
- tests/067-surface-tables-drift.sh — surface tables drift. The
  generated block in docs/SPEC.md must match `pp --dump-surface-tables`,
  and the grant descriptors must appear in exactly one `.ml` file
  (src/surface_tables.ml). A table edit not mirrored into SPEC, or a
  hand-copied table, is a red build.
- tests/074-adversarial-worlds.sh — adversarial worlds coverage. Every
  user-observable read head (`$env`, `$file`, `$probe` and the rest)
  must have either an adversarial fixture in
  `tests/fixtures/adversarial/<head>.sh` or a documented honest-edge
  entry in DESIGN.md. The head set comes from the surface table, so a
  new head fails the build until it gets a fixture or an edge entry.
- tests/071-kernel-props.sh and tests/075-cap-props.sh — kernel property
  sweeps. QuickCheck-style generators in src/kernel_props.ml prove hash
  injectivity, the quote round-trip and the print round-trip over random
  ASTs and values (071), and the capability algebra — restriction only
  narrows, composition is exactly union, the subset gate is sound, and
  the node-boundary ban catches buried authority (075). The generators
  match exhaustively on the constructor tags, so a new AST or capability
  kind breaks the build until it is generated and covered.
- tests/073-crash-injection.sh — crash injection. Every durable store
  write funnels through one atomic-write choke point. `PP_CRASH_AT`
  kills pp with SIGKILL at each write boundary of a real build, and a
  plain restart must neither crash nor produce anything but the
  byte-identical clean-build result.

## The differential fuzzer

`tools/fuzz.ml` generates random pp programs, runs each one under both
back ends, and checks that they behave identically. It deduplicates
divergences by signature, shrinks each one to a minimal repro, and
writes it to a failure directory. It depends only on OCaml's `unix`
library and is fully deterministic: program i under seed S is always the
same program.

Every generated program also passes through `pp --roundtrip-braces`,
which prints the sexpr AST as brace text, re-reads it with the brace
reader, and asserts structural AST equality and hash equality (SPEC law
20). Any failure gates the run like a backend mismatch.

```sh
dune build                                              # builds bin/pp + the fuzzer
dune exec ./tools/fuzz.exe -- --grammar core --count 2000
dune exec ./tools/fuzz.exe -- --grammar full --count 2000
```

The fuzzer shells out to the interpreter, defaulting to `bin/pp`. Run
from the repo root, or pass `--pp PATH`.

Options (defaults in parens):

| flag | meaning |
|---|---|
| `--seed N` (0) | RNG seed. Program i is `Random.full_init [|seed; i|]`. |
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

- `core` — forms both back ends must agree on: literals, control flow,
  functions, definitions, the arithmetic and collection builtins,
  strings, `print`, literal-key config, and the stdlib list functions.
  Any non-PASS on `core` is a real bug; its exit code is the CI gate.
- `full` — `core` plus everything that has ever divided the two back
  ends: type annotations with deliberate ill-typed calls, modules and
  computed config keys, effects and handlers, deep recursion, scoping
  edge cases, and `defmacro`.

The fuzzer never generates nondeterministic or security-sensitive
forms: `random`, wall-clock reads, file writes, capability constructors
and grants, probes, sealed cells, or network. Cluster distribution has
no language surface at all, so there is nothing to generate for it.

### Verdicts

| verdict | condition | CI effect |
|---|---|---|
| PASS | both exit 0, stdout identical, stderr identical | — |
| MISMATCH | stdout differs, effect-log (stderr) differs while both exit 0, or exactly one backend errors | fails |
| BOTH-ERROR | both exit non-zero; grouped by normalized error tag | soft class for now |
| CRASH | either side times out, dies by signal, or exits > 128 | fails |

Exit code is non-zero if and only if MISMATCH + CRASH > 0. Signatures
normalize the payload (digits become `#`, wrappers stripped) so
thousands of failures collapse to a handful of bug classes.

### Failure artifacts

```
fuzz-failures/<sanitized-signature>/
  <iter>.ppl         # up to 3 raw failing programs (sexpr text)
  <iter>.tw.out      # tree-walker status + stdout + stderr
  <iter>.bc.out      # VM status + stdout + stderr
  min.ppl            # shrunk minimal repro (not for BOTH-ERROR)
  min.tw.out / min.bc.out
```

Shrinking is greedy to a fixpoint: drop top-level forms, hoist a child
over its parent, replace subtrees with simple atoms, halve integers. A
reduction is accepted only if the exact signature is preserved. The
budget counts executions, not wall-clock, so shrinking a timeout crash
is slow — lower `--timeout-ms` or `--shrink-budget` for those.

### Reproducing a failure

Every artifact records its iteration number. To regenerate program 1234
of a `--seed 0 --grammar full` run:

```sh
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --dump 1234 > repro.ppl
dune exec ./tools/fuzz.exe -- --grammar full --seed 0 --start 1234 --count 1
pp repro.ppl; pp --bytecode repro.ppl
```

Generated programs are sexpr text, so the redirected file takes the
`.ppl` extension — `.pp` dispatches to the brace reader. `--max-depth`
and `--stdlib` must match the original run for byte-identity.

### Adding a grammar rule

1. Verify the form against `src/` first: reader syntax, primitive
   names, both back ends' handling. Do not invent function names.
2. For a new expression production, add a weighted arm to the right
   typed generator in `fuzz.ml`. Keep it well-scoped and type-correct.
3. For a new top-level production, write a `stmt_*` returning `sx list`
   and register it with a weight in `gen_program`. If it needs the
   stdlib, set `env.stdlib <- true`.
4. Nondeterministic forms stay banned until the roadmap gates them.
5. Sanity-check with `--dump 0..5` and a 100-program run. A rule that
   produces matching BOTH-ERRORs on most programs is a generator bug,
   not a finding.
