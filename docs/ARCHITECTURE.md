# pp architecture

This document describes the Common Lisp implementation. The ASDF system in
`lisp/pp.asd`, the package declarations in `lisp/packages.lisp`, and the
source files are the implementation source of truth. See [SPEC.md](SPEC.md)
for language laws and verified limits, and [DESIGN.md](DESIGN.md) for design
reasons.

## Data flow

```text
source file or -e input
        |
        v
pp reader -> expression AST -> macro expansion -> continuation evaluator
                                      |
                                      v
                         values, effects, and node forces
                                      |
             +------------------------+------------------------+
             |                         |                        |
       dynamic scope            session state              node runtime
             |                         |                        |
       effects and caps       memo tables and domains   cache, traces, store
```

The reader produces one `pp.kernel` expression tree. Brace and s-expression
input lower to the same constructors. The evaluator has one expression
dispatch and one tail-call mechanism. The application creates services for
one command, one session, and one evaluator operation value; session state is
never assembled from hidden registries.

The semantic spine for a persistent computation is:

```text
surface syntax
    -> reader AST
    -> macro-expanded expression
    -> evaluator dispatch
    -> node closure application
    -> persistent thunk
    -> node key (code + free-variable values + argument hashes)
    -> cache lookup and trace verification
    -> node rebuild -> store result and trace
```

There is one evaluator and one node rebuild operation along this path. A
scheduler changes placement and timing, while the key separates computation
identity from trace validity and hit authority.

## Library boundaries

The ASDF systems and their responsibilities are:

| System | Directory | Depends on | Owns |
|---|---|---|---|
| `pp/kernel` | `lisp/kernel/` | — | Core types, identity, capabilities, codecs, cells, and pure operations |
| `pp/frontend` | `lisp/frontend/` | `pp/kernel` | Readers, printers, desugaring, surface tables, comments, and lint |
| `pp/runtime` | `lisp/runtime/` | `pp/frontend` | Evaluator, sessions, dynamic scopes, store, effects, observations, cache, nodes, artifacts, distribution, and lifecycle |
| `pp/app` | `lisp/app/` | `pp/runtime` | CLI validation, service construction, command dispatch, and diagnostics |

`pp` depends on `pp/app` and is saved as an executable image by
`scripts/build-lisp.sh`. The kernel and frontend do not access host services.
Host interaction is confined to explicit runtime providers and the application
boundary.

## Core model and identity

`lisp/kernel/core-model.lisp` contains the recursive pp structures:

- expressions, values, environments, thunks, and match patterns;
- closures and builtins as explicit records;
- cells, capabilities, source ranges, and identity wrapper types.

`identity.lisp` hashes expressions, values, patterns, environments, and
capabilities. `identity-types.lisp` keeps node keys, result hashes, observed
hashes, and cell ids separate. Store and transport code performs the only
conversion to durable text. `hasher.lisp` provides SHA-256 and length-framed
input hashing, while `codec.lisp` defines the canonical durable encoding.

Durable data contains only canonical pp values and byte strings. Host
closures, conditions, pathnames, hash tables, and printed representations are
never persisted.

## Readers and surface forms

`lisp/frontend/frontend.lisp` reads both supported surfaces, lowers them to
shared expressions, preserves source ranges and comments, and provides the
printers and lint operations. The default file surface is braces (`.pp`);
s-expressions use `.ppl`. `pp fmt --to-braces` and `pp fmt --to-sexpr` convert
between them without changing expression hashes.

The frontend accepts source text as strings and never calls `CL:READ` or
interns user identifiers into host packages. Surface tables are data returned
by `pp --dump-surface-tables`; the application owns only the stream format.

## Evaluation and dynamic scope

`lisp/runtime/evaluator.lisp` is the only evaluator. It runs one explicit
continuation machine for every expression form and one work-queue force path
for ephemeral and persistent thunks. There is no host `EVAL`, host source
reader, depth-triggered fallback, or second evaluator.

`evaluator-support/state.lisp` owns continuation state and scope construction.
`language.lisp` owns pure quotation, pattern, presentation, macro, and builtin
operations. `session.lisp` owns operation views and mutable state grouped by
lifetime. `begin-evaluation`, `begin-pass`, and `begin-watch` are reset
boundaries; callers do not mutate evaluator records directly.

`dynamic-scope.lisp` brackets effects for capabilities, configuration,
handlers, trace frames, nodes, domains, and observations. It owns only the
corresponding dynamic stacks. Missing services fail closed rather than falling
back to ambient access.

## Effects and authority

Capabilities enter at the application boundary through `--grant`. User code
can inspect, restrict, and compose held capabilities, but cannot mint a new
capability. `paths.lisp` supplies component-aware path checks.

The evaluator checks authority when it performs an effect. User-visible reads
go through observation cells; source and store loading use separate runtime
authority. Effects are recorded in canonical cells and traces.

| Effect | Owner | Result or rule |
|---|---|---|
| `read-file`, `write-file`, `slurp` | application and observations | Capability check and cell recording; node writes use node scratch space |
| `run` | lifecycle process service | Scripting-only ambient process |
| `run-closed!` | lifecycle executor | Session-owned request/result values; providers classify requests |
| `http-get`, `http-post` | runtime effect path | Network capability; not valid inside a persistent node |
| `probe` | session and observations | One pinned observation per pass |
| `fenced` | lifecycle fenced/journal services | Intent/done journal with explicit recovery |

Host substitution happens outside the evaluator: the application installs
the local scheduler, process provider, and optional closed-action executor
in the session; observers and domain drivers are registered pp functions;
the runtime keeps authority checks, observation recording, journaling, and
verification. With no registration, closed execution, observation, domain
mutation, and transport are unavailable — none falls back to ambient access.

An executor's cacheability classification is the complete trusted promise.
Inside a node, scripting-only requests are rejected before the provider runs.
The bundled Linux provider is scripting-only because clocks, randomness,
kernel behavior, and resource limits remain ambient.

## Persistent nodes and cache

`node { e }` creates a persistent thunk and `delay` creates an in-memory thunk.
`nodes.lisp` adapts persistent execution to the store:

```text
create thunk
    -> compute node key
    -> select and verify a trace
       -> authorized hit: read result and replay child reads
       -> miss: run body, validate result, write result and trace
```

The persistent node key contains node code and hashes of resolved
free-variable values. It does not contain the whole environment or capability
set. Config and handler reads are trace cells. A node key is not a result hash
and is not a cell id.

`observations.lisp` constructs and checks cells. A nested node records one
`node:<identity>` cell carrying its result hash; child world reads remain in
the child trace. `cache.lisp` verifies traces, checks transitive hit authority,
selects traces, reports misses, and marks data for GC. `lifecycle/watch.lisp`
uses the same durable verifier while rebuilding its in-memory graph.

The repository layer is:

| Module | Responsibility |
|---|---|
| `store.lisp` | Store paths, version stamp, raw bytes, atomic replacement, inventory, roots, and GC |
| `cache.lisp` | Trace selection, validation, hit/miss decisions, and reachability |
| `nodes.lisp` | Persistent node keys, rebuilds, and result callbacks |
| `artifacts.lisp` | Canonical trees, blob reachability, materialization, and snapshots |
| `effects.lisp`, `observations.lisp` | Effect cells, authority checks, and trace records |

Every durable write uses the atomic replacement boundary. Store contexts are
explicit command state; sessions isolate evaluator, pass, and lifecycle
state without exposing durable host objects.

## Domains and scheduling

`lifecycle/domains.lisp` owns the observe, diff, apply, verify, and epoch
pipeline. `lifecycle/process.lisp` and `lifecycle/sandbox.lisp` provide
confined process operations. `lifecycle/fenced.lisp` and `journal.lisp`
handle non-repeatable actions. `lifecycle/watch.lisp` observes before a pass
and verifies after apply.

`distribution.lisp` owns serial, parallel, race, and transport descriptors.
Parallel placement uses separate worker processes and the node boundary
rechecks the cache after placement. Transport receives descriptors or
hash-checked artifacts, never host object graphs.

`stdlib/domain-fs.pp` and `stdlib/domain-proc.pp` define the filesystem and
process domain policies. `stdlib/dune.pp` is an ordinary library adapter for
external Dune builds; Dune-specific policy remains in that library and is not
part of the evaluator.

## Application and commands

`lisp/app/main.lisp` starts the process, parses options, builds production
services, and converts uncaught conditions to pp diagnostics and exit status.
It owns language execution, formatting, lint, store/node inspection,
reconciliation, scheduling, transport, and lifecycle command boundaries.

Run `bin/pp --help` for the current command list. Do not duplicate flag rows
in this document.

## Verification map

Use the smallest gate that matches the change:

```sh
scripts/build-lisp.sh --output lisp/pp
scripts/check-architecture.sh
scripts/run-tests.sh bin/pp
```

Focused shell suites cover identity and laws, readers and printers, effects,
store, nodes, lifecycle, reconciliation, crash recovery, and adversarial
worlds. `tests/089-state-inventory.sh`, `tests/092-dependency-boundaries.sh`,
and `tests/094-architecture-gates.sh` ensure the saved-image build and source
layout remain coherent.

If a source change touches the evaluator, identity, or durable repository
code, run the relevant focused suites and a saved-image smoke command. The
architecture gate must remain green.
