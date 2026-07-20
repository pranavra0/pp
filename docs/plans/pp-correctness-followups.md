# pp correctness follow-ups

This file contains only correctness work that remains open. Completed work is
recorded in git history and the current limits are tracked in `docs/SPEC.md`.

## Applied node keying — SPEC LAW 6/20

`node { body }` is persistent and keyed by code plus free-variable value hashes.
An applied `defnode`/named `node` function is still represented as a named
closure, so an aggregator cannot yet cache each application independently by
its argument values. The follow-up should make each application construct a
persistent node thunk keyed by those values.

Required proof:

- repeated `inc(5)` calls share a key while `inc(6)` does not;
- an aggregator maps independently cacheable node applications over inputs;
- captured values affect the key, while capabilities, handlers, and config do
  not become key inputs;
- both the tree-walker and any alternate backend agree on values and errors.

## Stack-safe non-tail evaluation — SPEC LAW 11

The tree-walker still exhausts the OCaml stack on sufficiently deep non-tail
recursion. A heap-allocated abstract machine is deferred until its design
matches the existing evaluator for symbol forcing, mutual `let`, `let*`, effect
handlers, config, modules, quotation, and node boundaries.

Required proof:

- deep non-tail recursion completes without `Out_of_memory`;
- tail calls retain constant-stack behavior;
- evaluator behavior remains differential with the existing test and fuzzer
  coverage;
- the machine preserves the identity and trace laws in `docs/SPEC.md`.
