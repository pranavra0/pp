#import "/lib.typ": example

:= The engine

pp runs every program through a single tree-walking evaluator. It interprets
the AST directly — small, obvious, and the reference for what every form means.

Correctness is checked by a metamorphic fuzzer: it generates random programs,
applies semantics-preserving transforms to produce a twin (do-wrap,
let-identity, eta-identity), and asserts the original and the twin produce
identical output. It also runs a reader round-trip gate: every generated
program is printed and re-read, and the ASTs must be structurally equal with
identical hashes. Any mismatch is shrunk to a minimal repro and written to a
failure directory.

== The metamorphic fuzzer

The fuzzer (`tools/fuzz.ml`) is the project's single most valuable correctness
asset. It generates random pp programs under two grammars. `core` covers
literals, control flow, functions, definitions, the arithmetic and collection
builtins, and the stdlib list functions — any non-PASS on `core` is a real bug
and fails CI. `full` adds the harder surface: type annotations, modules,
effects and handlers, deep recursion, quotation, and `defmacro`.

```sh
dune exec ./tools/fuzz.exe -- --grammar core --count 2000
dune exec ./tools/fuzz.exe -- --grammar full --count 2000
```

The fuzzer shells out to the interpreter, defaulting to `bin/pp`. The
generator is fully deterministic: program i under a given seed is always the
same program, so any finding reproduces exactly.

== The expected-output suite

The test suite (`dune runtest`) runs every `tests/NNN-*.pp` program and diffs
its stdout against a blessed `tests/NNN-*.pp.expected` file. A missing
`.expected` file is a failure — it means the test hasn't been blessed yet.
This catches print- and effect-ordering changes that the fuzzer's twin oracle
might not.

The suite also runs shell suites (`tests/*.sh`) for multi-process scenarios:
store persistence across runs, watch loops, cluster members, and crash
injection.

== Kernel properties

`src/kernel_props.ml` runs QuickCheck-style property sweeps: hash injectivity,
the quote round-trip, and the print round-trip over random ASTs and values.
The generators match exhaustively on constructor tags, so a new AST or
capability kind breaks the build until it is generated and covered.
