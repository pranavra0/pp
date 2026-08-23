#import "/lib.typ": example

= The evaluator

pp runs every program through one explicit continuation evaluator. It
interprets the shared AST directly and uses one force path for ephemeral and
persistent thunks. Source text is parsed by pp's readers; the host reader is
never exposed to a program.

Correctness is checked by expected-output programs, focused property sweeps,
and process-level shell scenarios. The expected-output suite checks stdout,
stderr, source ranges, and exit status. The shell scenarios cover store
persistence, authority, effects, watch loops, transport, reconciliation, and
crash recovery.

== The expected-output suite

Build a saved image and run the suite from the repository root:

```sh
scripts/build-lisp.sh --output lisp/pp
scripts/run-tests.sh bin/pp
```

The runner visits every `tests/NNN-*.pp` program and diffs its output against
the committed `tests/NNN-*.pp.expected` file. A missing `.expected` file is a
failure. Shell suites (`tests/*.sh`) exercise multi-process scenarios with
isolated stores and homes.

== Kernel properties

`pp --check-kernel-props` runs deterministic sweeps for hash injectivity,
quotation, print round-trips, and capability algebra. The generated structures
are checked exhaustively, so a new constructor requires a corresponding
property case.

```sh
bin/pp --check-kernel-props --seed 1 --count 3000
```
