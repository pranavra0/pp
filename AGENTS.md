# AGENTS.md

pp is a content-addressed, capability-scoped language in OCaml — brace/infix
surface syntax by default (`.pp`), with a Lisp-family s-expression AST still
underneath and fully supported (`.ppl`; it's what macros author/consume) —
with two back ends (a tree-walking interpreter and a bytecode VM) that must
produce identical output.

## Build, run, test

Toolchain is **opam + dune** (not npm). Dependencies: `dune`, `cryptokit`.

```sh
dune build            # builds the interpreter (targets bin/pp) and the fuzzer
dune runtest          # differential test suite: both back ends diffed per file
pp file.pp            # run (bin/pp is on PATH via direnv; else `dune exec pp --`)
pp --diff file.pp     # run both back ends, fail if their results differ
dune exec ./tools/fuzz.exe -- --grammar full --count 1000   # differential fuzzer
```

If direnv isn't active, prefix commands with `opam exec --` and use `bin/pp` or
`dune exec pp --` instead of bare `pp`.

## What you need to know

- **The two back ends must agree.** Any divergence between `pp file` and
  `pp --bytecode file` is a bug. `--diff` and the fuzzer exist to catch it;
  run them after touching `evaluator.ml`, `compiler.ml`, `vm.ml`, or `types.ml`.
- **Verify by running, not by reading the docs.** This project has a history of
  docs claiming things that weren't true; that's why the fuzzer and
  [docs/STATUS.md](docs/STATUS.md) exist. Confirm behavior against the binary.
- **The content-addressed key must include everything a computation depends on.**
  Omitting captured environments (D6) or the handler stack (D17) caused stale
  cache hits. If you touch hashing (`types.ml`) or thunk keys (`evaluator.ml`),
  keep `tests/009` passing.
- **The persistent node cache is validated by traces, not just the key.**
  `node { e }` writes results + verifying traces to `~/.pp/store` in **both
  backends** (the VM via `MAKE_NODE`/`vm_node_key`/`force_node_thunk`). A hit
  re-checks the cells the node recorded — `file:`, `config:`, `handler:`,
  `tool:`, `tree:`, `stat:`, `env:`, `argv:` — and the caller's authority
  over them, so what a node
  *observed* governs validity while the key (`H(code ‖ free-var value-hashes)`,
  nothing else — caps/config/handlers excluded) governs identity. The two
  backends compute the same key for data free vars and share store entries.
  If you touch `store.ml`, the read primitives (`slurp`/`read-file`), the
  `run` effect or sandbox (`process.ml`), the free-var/keying logic
  (`types.ml free_vars`, `node_key_of`, `vm_node_key`), or the
  `force`/trace-frame plumbing (`evaluator.ml`, `vm.ml`, `runtime.ml`), the
  reconciler (`reconciler.ml`), or the why/no-cache/check tooling, keep
  `tests/010`–`tests/024` passing (plus `tests/028`, which pins the `stat:`
  file-predicate cells). `pp why file.pp` explains hits/misses when
  debugging cache behavior.
- **Phase 1 is closed and its exit criteria are executable.** `tests/024`
  builds a 101-TU C project through a real `build.pp` inside `dune runtest`;
  `scripts/build-self.sh` (pp builds itself — run OUTSIDE dune) and
  `scripts/build-lua.sh` (real Lua 5.4.7) replicate the proof. If a change
  makes any exit criterion regress, that change is wrong, not the test.

## Where things are

- Learning the language: [docs/manual/](docs/manual/) — the reference manual,
  built by pp (`scripts/build-manual.sh`); every example is run by pp, so it
  can't drift. Authoring conventions in [docs/manual/AUTHORING.md](docs/manual/AUTHORING.md).
- Code structure and data flow: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Vocabulary: [docs/GLOSSARY.md](docs/GLOSSARY.md)
- What's real vs planned + the D-list: [docs/STATUS.md](docs/STATUS.md)
- Semantics (normative): [docs/SPEC.md](docs/SPEC.md)
- Plan and rationale: [docs/ROADMAP.md](docs/ROADMAP.md), [docs/DESIGN.md](docs/DESIGN.md)
- Testing: [docs/TESTING.md](docs/TESTING.md)

## Style

pp code follows [docs/CONVENTIONS.md](docs/CONVENTIONS.md). Key rules:

- **Suffix conventions:** `?` for predicates (`nil?`), `!` for effects (`run!`), `->` for conversions (`string->number`), no suffix for pure functions.
- **Truthiness:** Only `nil` and `false` are falsy. Use `if x` not `if not(nil?(x))`.
- **Flat `let`:** One `let (a = …, b = …) { … }`, not nested single-binding ladders. Use `let*` for sequential shadowing.
- **`else if` chains:** `else if` is a flat chain — do not nest the second `if` inside braces.
- **Naming:** Functions are verb-led (`longest-palindrome`, not `expand-around-centre`). Values are full words (`max-len`, not `ml`). Inner helpers name the step (`scan`, not `loop`).
- **`car`/`cdr`:** Built-in; alias to `first`/`rest` in a prelude if needed. Pick one style per file.
- **Tier awareness:** `!`-suffixed functions may appear in node bodies when they perform traced effects. Pure computations in nodes should not carry `!`.
- **Comments:** Why, not what — algorithm choice, complexity, edge cases. Library files get a header listing every export.
- **List/vector literals:** Use `[...]` for lists and `vec[...]` for vectors. Lists are immutable singly-linked; vectors provide random access.
- **World observations:** Use `$file("path")`, `$env("VAR")`, `$glob("pattern")`, `$probe("name")`, and `$secret("path")` to read from the outside world. The `$` sigil makes every capability-gated read visually distinct.
- **Error propagation:** Use `try { a <- f(); ... }` to unwrap `[:ok, v]` / `[:err, e]` pairs. The `?` suffix (`let x = expr?`) is shorthand for the same pattern.
- **Multi-way conditionals:** Use `cond { test1 => result1; true => fallback }` instead of deeply nested `else if` chains.

When writing or editing pp code in this repo, apply these conventions.
