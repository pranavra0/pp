# AGENTS.md

pp is a content-addressed, capability-scoped language, written in OCaml. It
has two back ends, a tree-walker (the oracle) and a bytecode VM, that must
produce identical output.

## Commands

```sh
dune build            # builds bin/pp and the fuzzer
dune runtest          # differential suite (slow — see docs/TESTING.md)
pp file.pp            # bin/pp is on PATH via direnv; else `opam exec -- dune exec pp --`
pp --diff file.pp     # run both back ends, fail on divergence
```

## Invariants

- The two back ends must agree. After touching `evaluator.ml`, `compiler.ml`,
  `vm.ml`, or `types.ml`, run `--diff` and the fuzzer.
- A content key must include everything the computation depends on. If you
  touch hashing or thunk keys, keep `tests/009` passing. If you touch the
  store, traces, or node keying, keep `tests/010` to `tests/024` passing.
  `pp why file.pp` explains hits and misses.
- Verify by running the binary, not by reading docs. Prose has lied before;
  the tests and fuzzer exist because of it.

## Commits

Use Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`,
`perf:`, or `chore:`, followed by one terse lowercase sentence. Do not add
trailers. Before release, never use `!` or `BREAKING CHANGE`. Done work
lives in git history, not in docs, so delete finished plan items rather
than marking them done.

## Read only when the task needs it

| Task | Read |
|---|---|
| Writing or editing pp code (style, sigils, forms) | [docs/SYNTAX.md](docs/SYNTAX.md) — the sigil table and the writing style section are normative |
| Language semantics, the laws | [docs/SPEC.md](docs/SPEC.md) |
| Learning the language by example | [docs/manual/](docs/manual/) |
| Which source file owns what; data flow | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Vocabulary (cell, node, trace, island, …) | [docs/GLOSSARY.md](docs/GLOSSARY.md) |
| What works today; discrepancy ledger | [docs/STATUS.md](docs/STATUS.md) |
| Why it's designed this way; rejected features (don't re-propose) | [docs/DESIGN.md](docs/DESIGN.md) |
| Running/adding tests, the fuzzer | [docs/TESTING.md](docs/TESTING.md) |
| CLI flags | `pp --help` |
