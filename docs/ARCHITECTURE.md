# pp architecture

This document describes the current implementation. It uses source and Dune
files as the source of truth. See [SPEC.md](SPEC.md) for language laws and
verified limits, and [DESIGN.md](DESIGN.md) for design reasons.

## Data flow

```text
source file or -e input
        |
        v
reader -> expr AST -> macro expansion -> tree-walking evaluator
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

The reader produces one `Core_model.expr` tree. Both readers produce the same
tree. The evaluator has one expression dispatch and one tail-call mechanism.
The helper modules called `evaluator_*` support this dispatch. They do not
define another evaluator.

The application creates the services for one command. It creates one session,
one scheduler, and one evaluator operation value. The session owns mutable
run state. Dynamic scope carries values that must follow the current call.

## Library boundaries

The four wrapped libraries and their Dune dependencies are:

| Library | Directory | Dependencies | Owns |
|---|---|---|---|
| `pp.kernel` | `src/kernel/` | `cryptokit`, `dune-build-info` | Core types, identity, capabilities, codecs, cells, effects, and pure operations |
| `pp.frontend` | `src/frontend/` | `pp.kernel` | Readers, printers, desugaring, surface tables, comments, and lint |
| `pp.runtime` | `src/runtime/` | `pp.kernel`, `pp.frontend`, `unix` | Evaluator, sessions, dynamic scopes, stores, cache policy, observations, worlds, domains, and scheduling |
| `pp.app` | `src/app/` | `pp.kernel`, `pp.frontend`, `pp.runtime`, `cryptokit`, `unix` | CLI validation, production service construction, command dispatch, and properties |

The dependency checks are in `tools/check-dependencies.sh` and
`tools/dependency-manifest`. `dune build @architecture` runs them with the
compiler-warning, state-inventory, API-surface, and vertical-slice checks.
The kernel and frontend do not depend on Unix.

## Core model and identity

`src/kernel/core_model.ml` contains the recursive types:

- `expr` is the language tree.
- `value` is a runtime value. It includes closures, builtins, capabilities,
  thunks, module maps, and sealed values.
- `env` is an environment node with bindings, an id, and an incremental hash.
- `thunk` is a suspended computation with a status, expression, environment,
  persistence flag, configuration hash, and captured capabilities.
- `pattern` is a match pattern.

Other kernel modules own operations over these types. `identity.ml` hashes
values, expressions, patterns, and capabilities. `environment.ml` creates
and queries environments, closures, and thunks. `free_vars.ml` computes node
inputs. `quotation.ml`, `pattern_match.ml`, `presentation.ml`, and
`value_analysis.ml` own their pure tree walks.

`hasher.ml` provides SHA-256 and length-framed input hashing.
`identity_types.ml` keeps node keys, result hashes, observed hashes, and cell
ids as separate abstract types. Store and transport code performs the only
conversion to durable text.

## Readers and surface forms

`reader.ml` reads the s-expression surface. `reader_braces.ml` reads the
brace surface. `desugar.ml` lowers shared reader forms. The printers emit
either surface from the same AST. `surface_tables.ml` defines closed surface
sets and generates the matching SPEC table.

The default file surface is braces (`.pp`). The s-expression surface uses
`.ppl`. `pp fmt --to-braces` and `pp fmt --to-sexpr` preserve the AST and
carry comments through the conversion. `tests/054` through `tests/067` and
the fuzzer check this boundary.

`macro.ml` expands top-level `defmacro` forms before ordinary evaluation.
Macros receive quoted syntax values and return syntax values. The evaluator
does not need a macro-specific expression path.

## Evaluation and dynamic scope

`src/runtime/evaluator.ml` is the only evaluator. It dispatches every
expression form and implements tail calls and deep thunk forcing. The
`evaluator_*` modules receive narrow callbacks for force, evaluation, and
application.

`evaluator_ops.ml` defines two immutable operation views:

- the core view provides `force`, `eval`, and `apply`;
- the node view provides key construction, node rebuilding, and hit
  resolution.

`session.ml` creates and owns the operation value. No caller installs a
mutable evaluator callback.

`dynamic_scope.ml` brackets OCaml effects for capabilities, configuration,
handlers, trace frames, nodes, domains, and observation collection. It owns
no registry or mutable table. `effects.ml` declares the effect operations.

`session.ml` owns evaluation state. This includes thunk and macro tables,
gensym state, domains, probes, observations, pins, fenced actions, node
thunks, and the scheduler handle. `begin_evaluation`, `begin_pass`, and
`begin_watch` define the reset and retention rules.

## Effects and authority

Capabilities enter at the application boundary through `--grant`. User code
can inspect, restrict, and compose held capabilities. It cannot mint a new
capability. `paths.ml` supplies the component-aware path check.

The evaluator checks authority when it performs an effect. User-visible reads
go through `observation.ml`. The loader has separate runtime authority for
source roots and the store. The loader records authority-exempt runtime cells.

The main effect paths are:

| Effect | Owner | Result or rule |
|---|---|---|
| `read-file`, `write-file`, `slurp` | `observation.ml`, `process.ml`, and evaluator effects | Capability check and cell recording; node writes stay in node scratch space |
| `run`, `run-dep!` | `process.ml` and `observation.ml` | Process result plus tool/tree or depfile cells |
| `http-get`, `http-post` | evaluator effect path | Network capability; not valid inside a persistent node |
| `probe` | `session.ml` and `observation.ml` | One pinned observation per pass |
| `fenced` | `fenced.ml`, `journal.ml`, and reconciliation | Intent/done journal with an explicit recovery policy |

## Persistent nodes and cache

`node { e }` creates a persistent thunk. `delay` creates an in-memory thunk.
`node.ml` is the evaluator's persistent-node adapter.

The node pipeline is:

```text
create thunk
    -> compute node key
    -> select and verify a trace
       -> authorized hit: read result and replay child reads
       -> miss: run body, validate result, write result and trace
```

The persistent node key contains the node code and the hashes of its resolved
free-variable values. It does not contain the whole environment or the
capability set. Config and handler reads are trace cells. A node key is not a
result hash and is not a cell id.

`observation.ml` constructs and checks cells. Reads propagate to enclosing
node frames. `cache_policy.ml` verifies traces, checks hit authority, selects
traces, reports misses, and marks data for GC. `stabilize.ml` uses the reverse
trace index from `store_index.ml` to dirty only affected in-memory thunks.

The repository layer is:

| Module | Responsibility |
|---|---|
| `store_layout.ml` | Store paths, version stamp, and atomic replacement |
| `object_repository.ml` | Immutable encoded values and fenced specifications |
| `blob_repository.ml` | Immutable byte blobs |
| `trace_repository.ml` | Locked trace sets and trace encoding |
| `cell_repository.ml` | File and sealed pins and snapshot reads |
| `repository_inventory.ml`, `store_gc.ml`, `gcroots.ml` | Explicit mark-by-replay GC |
| `transport.ml`, `remote.ml` | Hash-checked local sync and remote placement |

`codec.ml` defines the canonical durable encoding. The store does not use
OCaml `Marshal`. Every durable write uses the atomic replacement boundary.

## Domains and scheduling

`domains.ml` is the generic observe, diff, apply, verify, and epoch pipeline.
`domain_prims.ml` provides trusted file and process operations. The policy for
the filesystem and process domains is in `stdlib/domain-fs.pp` and
`stdlib/domain-proc.pp`.

`reconciliation.ml` binds a command to a session and runs domain passes.
`fenced.ml` and `journal.ml` handle non-repeatable actions. A domain observes
before a pass and verifies after apply.

`scheduler.ml` dispatches node misses with `serial`, `parallel:N`, `race:N`,
or `remote:MEMBER`. Local work uses child processes. Remote placement uses
the transport boundary and signed capability tokens. All workers call the
same node rebuild operation.

## Application and commands

`main.ml` starts the process, parses the CLI, builds production services, and
converts uncaught errors to exit status. `cli.ml` owns typed option parsing
and help rows. `app_context.ml` constructs host services, stores, schedulers,
sessions, evaluators, and reconciliation services.

Command ownership is split as follows:

| Module | Commands |
|---|---|
| `command_eval.ml` | Run, eval, pins, schedule, and determinism checks |
| `command_frontend.ml` | Formatting and surface conversion |
| `command_run.ml` | Source execution and domain setup |
| `command_reconcile.ml` | Reconcile and supervise passes and recovery |
| `command_watch.ml` | Watch polling and stabilization |
| `command_island.ml` | Island updates and pin inspection |
| `command_cluster.ml` | Cluster setup, sync, serve, and remote placement |
| `command_gc.ml` | Explicit store GC |
| `command_developer.ml` | Help, version, properties, lint, graph, and checks |
| `command_dispatch.ml` | Command precedence and signal scope |

Run `pp --help` for the full current CLI. Do not copy the flag list into this
document.

## Verification map

Use the smallest gate that matches the change, then run the full gate:

```sh
dune build @unit
dune build @architecture
dune exec ./tools/fuzz.exe -- --grammar full --count 2000
dune runtest
```

The focused executables cover kernel, repositories, observations, lifecycle,
and parsers. The shell tests cover process, filesystem, store, watch,
reconciliation, cluster, and crash behavior. See [TESTING.md](TESTING.md) for
the test machinery.

Important test groups:

| Area | Tests |
|---|---|
| Content identity and quotation | `009`, `011`, `041`, `042`, `070`, `071` |
| Nodes, traces, and authority | `010` through `024`, `036`, `040`, `053` |
| Readers and printers | `054` through `067` |
| Domains and fenced actions | `033`, `034`, `046`, `049`, `052` |
| Cluster and GC | `047` through `051` |
| Crash and adversarial coverage | `073`, `074`, `075` |

If a source change touches the evaluator, identity, or durable repository
code, run the full fuzzer and suite. The architecture gate must remain green.
