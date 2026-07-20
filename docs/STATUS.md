# pp status

This document records current behavior. It does not record the development
history. Verify a claim by running the cited test or command.

Run the main checks with:

```sh
dune build
dune build @architecture
dune exec ./tools/fuzz.exe -- --grammar full --count 2000
dune runtest
```

## Current implementation

pp is a Lisp with two readers and one tree-walking evaluator. The brace
surface is the default for `.pp` files. The s-expression surface is the
`.ppl` form used by the original reader and by syntax-valued macros. Both
readers produce the same AST. Formatting and round-trip checks are in
`tests/054` through `tests/067`.

The language supports control flow, functions, mutual and sequential
bindings, modules, imports, loading, islands, quotation, quasiquotation,
macros, pattern matching, configuration, effects, handlers, capabilities,
type annotations, and persistent nodes. `pp --help` is the source of truth for
the command surface.

## Evaluation

The evaluator applies functions by value. `let` and `delay` create in-memory
thunks. `node` creates a persistent thunk. Thunks memoise successful results.
The evaluator has tail calls and a trampoline for deep force chains.

OCaml effects carry dynamic capabilities, handlers, configuration, trace
frames, node frames, domains, and observation collection. `Session.t` owns
mutable tables and registries. A session has one scheduler and one complete
evaluator operation value. Independent sessions do not share evaluation state.

Capabilities enter through `--grant`. User code can restrict or compose a
held capability, but cannot mint one. Path checks use component boundaries.
Cache hits check the caller's authority over the complete transitive read
closure. Capability errors are not stored as node failures.

Evidence: `tests/009`, `tests/012`, `tests/013`, `tests/027`, `tests/040`,
`tests/071`, and `tests/075`.

## Nodes and the store

A persistent node key contains the node code and the hashes of its resolved
free-variable values. It excludes the whole environment and capabilities.
Configuration and handler reads are trace cells. This keeps authority out of
identity while still checking observed state at hit time.

On a miss, pp runs the node, records its reads, validates its result, and
writes the result and trace. On a hit, pp verifies the trace, checks authority,
reads the result, and replays child reads into enclosing nodes. A changed cell
causes a miss. A failing `Failure` result can be served from a failing trace
until one of its recorded cells changes.

The store uses canonical text and raw blobs. It does not use OCaml `Marshal`.
The store layout has a version stamp. Object, blob, trace, fenced-spec, and
process repositories use one atomic replacement boundary. `pp gc` performs
explicit mark-by-replay collection. `pp --watch --stabilize` uses reverse trace
edges to dirty affected in-memory thunks.

Evidence: `tests/010` through `tests/024`, `tests/036`, `tests/037`,
`tests/050`, `tests/053`, `tests/073`, and `tests/074`.

## Effects and external tools

`read-file`, `write-file`, and `slurp` check capabilities and record cells.
Writes from a persistent node go only to its scratch directory.
`perform run` returns a process result and records tool and tree cells.
`run-dep!` reads a depfile and records precise file cells when possible.
Network effects require a network grant and cannot run in a persistent node.

`probe` is the sanctioned volatile input. A pass observes it once and records
the value in session state. `--check` detects a node whose result changes
between two runs.

Evidence: `tests/017`, `tests/019`, `tests/022`, `tests/043`, and `tests/045`.

## Reconciliation and domains

`register-domain` provides a generic observe, diff, apply, verify, and journal
protocol. `stdlib/domain-fs.pp` defines the filesystem policy.
`stdlib/domain-proc.pp` defines the process policy. The OCaml runtime provides
the trusted operations and the generic pipeline.

`fenced` records an intent before a non-repeatable action and a done entry
after it. Recovery follows `retry`, `abort`, or `ask` policy.

Local scheduling uses child processes. `serial`, `parallel:N`, and `race:N`
use the same node rebuild operation. `remote:MEMBER` uses hash-checked
transport and signed capability tokens. Cluster membership still uses a local
members file or `PP_CLUSTER_MEMBERS`. The SSH transport remains a stub.

Evidence: `tests/018`, `tests/023`, `tests/024`, `tests/033`, `tests/034`,
`tests/046` through `tests/052`.

## Security boundaries

Secret reads return sealed values. Printers redact them. The codec rejects
them. Persistent nodes cannot capture or return capabilities or sealed values.
Network access uses a network capability. Island loading uses opt-in runtime
authority and verifies the pinned tree on every resolve.

Evidence: `tests/005`, `tests/020`, `tests/035`, `tests/044`, `tests/045`, and
`tests/047`.

## Open discrepancies

These limits are current and have executable evidence.

| Area | Current limit | Evidence |
|---|---|---|
| Non-tail recursion | The trampoline handles deep forcing. Deep non-tail evaluation can still exhaust the OCaml stack. | `tests/071`; full fuzzer error classes |
| Identity | Binding order is not canonical. Reordering bindings can change a hash. | SPEC laws 3 and 20 |
| Node cutoff | The persistent trace cache and push stabilizer work. Inline nested cutoff is not implemented. | `tests/016`, `tests/032` |
| Failure cache | `Failure` outcomes are cached. Other uncaught OCaml exceptions are not cached. | `tests/012`, `tests/014` |
| Cell names | Cell paths use canonical real paths. Unicode NFC normalization is not implemented. | `tests/036` |
| Cluster transport | Local-directory sync and remote placement work. SSH transport and service discovery are not implemented. | `tests/047`, `tests/048` |
| User experience | The standard library and error recovery remain small. | Manual review and current tests |

Do not turn an open discrepancy into a general promise. Add a focused test,
update this table, and update the relevant SPEC law when the behavior changes.
