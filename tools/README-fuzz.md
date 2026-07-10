# pp differential fuzzer

`tools/fuzz.ml` is the correctness ratchet for the pp roadmap: it generates
random pp programs, runs each under **both** backends (tree-walker `./pp f`
and bytecode VM `./pp --bytecode f`), and asserts identical observable
behavior. Divergences are deduplicated by signature, shrunk to a minimal
repro, and written to a failure directory.

Zero dependencies beyond the OCaml distribution (`unix.cma`). Fully
deterministic: no `Random.self_init` anywhere; program *i* under seed *S* is
always the same program.

## Build and run

```sh
make            # build ./pp (the fuzzer shells out to it)
make fuzz       # build ./fuzz
./fuzz --grammar core --count 2000 --seed 0
./fuzz --grammar full --count 2000 --seed 0
```

Options (defaults in parens):

| flag | meaning |
|---|---|
| `--seed N` (0) | RNG seed. Program *i* is generated from `Random.full_init [|seed; i|]`. |
| `--count K` (1000) | number of programs |
| `--max-depth D` (6) | expression-tree depth limit |
| `--timeout-ms T` (5000) | per-backend wall-clock timeout; overrun = CRASH |
| `--out DIR` (`fuzz-failures`) | failure artifact directory |
| `--grammar core\|full` (core) | grammar profile, see below |
| `--start N` (0) | first iteration index (for reproducing a specific program) |
| `--dump N` | print program N (for the given seed/grammar) and exit |
| `--pp PATH` (`./pp`) | interpreter binary |
| `--stdlib PATH` (`$CWD/stdlib/list.pp`) | absolute path baked into generated `(load ...)` forms |
| `--shrink-budget N` (300) | max backend-pair executions per shrink |

Run from the repo root (or pass `--pp`/`--stdlib` explicitly).

## Grammars

- **`core`** — forms both backends are *supposed* to agree on: literals
  (non-negative ints, floats, bools, safe-ASCII strings, keywords, nil),
  `if`/`do`/`let`/`let*`, `fn` + immediate application, `def` (functions,
  arity >= 1, including terminating recursion), the arithmetic/comparison
  builtins verified to exist in `src/primitives.ml`
  (`+ - * / mod < > <= >= = not and or`), list/vector/map ops
  (`list cons car cdr nil? vector-get hash-map-get`), strings
  (`string-append string-length`), `print`, literal-key
  `with-config`/`config`, and the stdlib list functions
  (`map filter foldl range take length`) via `(load ".../stdlib/list.pp")`.
  **Any non-PASS on `core` is a real bug.** Its exit code is the CI gate.
- **`full`** = core **plus** the audit's known-divergent territory: type
  annotations (D3), `module`/`import`/`load-module` and computed `config`
  keys (D15), `effect`/`perform`/`with-handler` over the `log` effect only
  (D9/D20), deep tail and non-tail recursion and long `map`s (D4), `=` on
  structurally identical unforced lists (D7), sibling-referencing `let`
  bindings, and quoted special forms (D19). Expected to fail until Phase 0
  closes; each signature is a Phase-0 work item.

Never generated: `random`, `island`, wall-clock forms (nondeterministic),
file-write effects, capability constructors.

## Verdicts

| verdict | condition | CI effect |
|---|---|---|
| PASS | both exit 0, stdout identical, stderr identical | — |
| MISMATCH | stdout differs, effect-log (stderr) differs while both exit 0, or exactly one backend errors | **fails** |
| BOTH-ERROR | both exit non-zero; grouped by normalized error tag | whitelisted (soft class) for now |
| CRASH | either side times out, dies by signal, or exits > 128 | **fails** |

Exit code is non-zero iff MISMATCH + CRASH > 0.

Stderr is compared only when both backends exit 0 — at that point it contains
only builtin `log` effect output, so it doubles as the "identical effect
logs" check without tripping on error-message wording.

**Signatures** are `verdict-kind : normalized payload` (digits collapsed to
`#`, `builtin 'x' failed:` wrappers stripped, truncated), so thousands of
failures collapse to a handful of bug classes.

## Failure artifacts

```
fuzz-failures/<sanitized-signature>/
  <iter>.pp          # up to 3 raw failing programs
  <iter>.tw.out      # tree-walker status + stdout + stderr
  <iter>.bc.out      # VM status + stdout + stderr
  min.pp             # shrunk minimal repro (first exemplar; not for BOTH-ERROR)
  min.tw.out / min.bc.out
```

Shrinking is greedy-to-fixpoint over: dropping top-level forms, hoisting a
child expression over its parent, replacing subtrees with `0/1/true/nil/"a"`,
and halving integer atoms — accepting a reduction only if the *exact*
signature is preserved (re-verified by running both backends).

Caveat: the budget is counted in *executions*, not wall-clock, so shrinking a
`crash:*:timeout` signature is slow (every still-diverging candidate costs a
full timeout — observed ~8 minutes for one such shrink at the 5s default).
Lower `--timeout-ms` or `--shrink-budget` if that matters for your run.

## Reproducing a failure by seed

The summary and every artifact directory record the iteration number. To
regenerate program 1234 of a `--seed 0 --grammar full` run:

```sh
./fuzz --grammar full --seed 0 --dump 1234 > repro.pp   # just the program
./fuzz --grammar full --seed 0 --start 1234 --count 1   # regenerate + judge + shrink
./pp repro.pp; ./pp --bytecode repro.pp                 # eyeball both backends
```

`--max-depth` and `--stdlib` must match the original run for the program to
be byte-identical.

## Adding a grammar rule

1. **Verify the form against `src/` first** (reader syntax, primitive names,
   both backends' handling). Do not invent function names; several plausible
   ones (`min`, `max`, `str`) do not exist.
2. For a new *expression* production: add a weighted arm to the right typed
   generator (`gen_int`, `gen_bool`, `gen_string`, `gen_float`,
   `gen_list`/`gen_list_ne`) in `tools/fuzz.ml`. Keep it well-scoped (only
   symbols from `env`) and type-correct, or you will drown in BOTH-ERROR
   noise. Lists have a "statically nonempty" notion (`gen_list_ne`) — `car`
   is only applied to those.
3. For a new *top-level* production: write a `stmt_*` function returning
   `sx list` and register it with a weight in `gen_program`'s `core_stmts`
   or `full_stmts` table. Statements that make output observable should
   `print`. If it needs the stdlib, set `env.stdlib <- true` and rely on the
   `load` prelude.
4. Nondeterministic forms (`random`, `island`, time) are banned until the
   roadmap gates them.
5. Sanity-check with `./fuzz --dump 0..5` and a 100-program run; a new rule
   that produces matching BOTH-ERRORs on most programs is a generator bug,
   not a finding.

## Known generator-level exclusions (deliberate)

- Bare negative numeric literals: the pp reader lexes `-5` as a *symbol*
  (reader.ml:89-91 re-peeks `'-'` instead of the next char, so its
  `read_number` arm is unreachable). Both backends fail identically
  ("unbound symbol: -5") — found by this fuzzer's first run; excluded as
  non-differential noise until fixed.
- `(def x 5)` defines a **nullary closure**, not a constant (`x` evaluates
  to `#<fn x>`; arithmetic on it errors in both backends). The generator
  only defs functions with >= 1 parameter.
- Core `let` bindings never reference sibling bindings: the tree-walker
  evaluates bindings in the *outer* env (parallel let), the VM sequentially.
  The divergent case is generated deliberately in `full` (`stmt_seq_let`).
