#import "/lib.typ": example

= The two back ends

pp runs a program in one of two ways. The tree-walker interprets the AST
directly. It is small, obvious, and the reference for what every form means: the
oracle. The bytecode VM compiles that same AST to a compact stack machine with
O(1) indexed locals and tail-call optimization, then runs the result. The two
engines share one reader, one set of value and hashing definitions, and one pool
of runtime state. They are held to a single rule: on any program they must
produce identical output. A disagreement between them is a bug, never a feature.
The tree-walker says what the answer is, and the VM must match it.

That rule is what makes having two engines pay off. The tree-walker stays simple
enough to trust. The VM can be optimized freely, because any divergence it
introduces is mechanically caught against the oracle.

== Running each engine

`pp file.pp` runs the tree-walker. `pp --bytecode file.pp` compiles the same
file and runs it on the VM. Same source, same output:

#example("be-bytecode", sh: true)

== `--diff`: check them against each other

`pp --diff file.pp` runs the program under both back ends and compares the value
every top-level form returned. It exits `0` when they agree. It exits `1` when
they diverge, naming the file and printing both value lists. Because each engine
executes the program, its own `print` output appears twice. The exit code is the
verdict.

#example("be-diff", sh: true)

The tail-recursive loop above also exercises a property both engines must share:
tail calls run in constant stack. So the count to 100000 neither overflows nor
differs between back ends.

Note the scope of the comparison. `--diff` compares the returned values of the
top-level forms. The test suite (`dune runtest`) also diffs the two engines'
stdout. So it also catches `print`- and effect-ordering divergences that leave
the return values untouched. The two checks are complementary.

== The differential fuzzer

`--diff` only checks the programs you hand it. To find divergences you would
never think to write, pp ships a differential fuzzer (`tools/fuzz.ml`). It
generates random programs, runs each under both back ends, and asserts identical
observable behavior: same exit status, same stdout, same effect log. A mismatch
is deduplicated by signature, shrunk to a minimal repro, and written to a
failure directory. The generator is fully deterministic. Program i under a given
seed is always the same program, so any finding reproduces exactly.

The fuzzer runs against two grammars. `core` covers the forms both back ends
must always agree on: literals, `if`/`do`/`let`/`let*`, `fn` and application,
`def`, the arithmetic and collection builtins, and the stdlib list functions.
Any non-agreement on `core` is a real bug and fails CI. `full` adds the harder
surface: type annotations, modules, effects and handlers, deep recursion,
quotation, and `defmacro`. This is the project's single most valuable
correctness asset. Every optimization the VM gains is only as trustworthy as the
oracle it is diffed against. The fuzzer is what keeps that diff honest across
the whole language, not just the examples someone remembered to test.
