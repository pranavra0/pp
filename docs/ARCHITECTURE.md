# pp architecture

This document describes the Common Lisp implementation. The ASDF system in
`lisp/pp.asd`, the package declarations in `lisp/packages.lisp`, and the
source files are the implementation source of truth. See [SPEC.md](SPEC.md)
for language laws and verified limits, and [DESIGN.md](DESIGN.md) for design
reasons.

## Repository layout

The repository keeps implementation, interfaces, tests, and generated
artefacts in separate owners:

| Path | Ownership |
|---|---|
| `lisp/` | Common Lisp source, ASDF systems, package declarations, and the local saved-image build output |
| `bin/` | Stable launcher used by developers and the test runner |
| `stdlib/` | pp libraries, including the filesystem, process, and external-build adapters |
| `scripts/` | Build, test, architecture, crash-recovery, and manual-site tooling |
| `tests/` | Active expected-output programs, shell scenarios, and committed fixtures |
| `examples/`, `demo/` | User-facing programs and demonstrations |
| `docs/` | Normative language/design documents and Typst manual source |
| `docs/manual/site/` | CI-owned generated manual site and PDF; rebuilt by `scripts/build-manual.sh` and not hand-edited |

The source tree has no second implementation under a native build directory.
Legacy native-build paths and metadata are rejected by
`tests/089-state-inventory.sh` and `tests/092-dependency-boundaries.sh`.

The manual's source is `docs/manual/`; its rendered site is a deployment
artefact. The GitHub Pages workflow builds the saved image, runs the manual
examples, renders the site, and publishes that directory, so generated output
does not need to be committed or reviewed as source.

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

`value-opaque` is runtime-only one-byte data for malformed ordinary file
contents. It has an identity hash but no canonical value codec or wire form;
the `blob` primitive is its explicit conversion to a raw content-addressed
blob. It is distinct from `value-sealed`, whose bytes remain confidential.

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

`dynamic-scope.lisp` brackets capabilities, configuration, handlers,
effects, nodes, and domains. It owns only the corresponding dynamic
stacks. Missing services fail closed rather than falling back to ambient
access.

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

## Self-build boundary

The initial saved-image build is itself described by `build/pp.pp`. That
definition uses `run-closed!` to invoke the selected SBCL runtime directly;
`build/bootstrap.lisp` loads the ASDF system and saves the executable image.
Run it explicitly as `pp build pp`.

At this initial scope the build graph is deliberately coarse:

```text
source tree + SBCL toolchain
            -> one build node
            -> pp artifact
```

ASDF remains responsible for the ordering of the Lisp sources loaded by that
node. This is an executable-image bootstrap, not compiler self-hosting;
self-hosting is a separate concern and is not a goal of this build path. The
graph describes scope and provenance only, not cache reuse.


The build definition's `source-tree` input is a source-only artifact tree:
it includes the intended Lisp/ASDF sources and the two build-definition
inputs, preserves directory parents, and excludes scripts, README files,
generated images/FASLs, build outputs, and symlinks. `sbcl-toolchain()` probes
the selected SBCL launcher, then snapshots its runtime, core, and `SBCL_HOME`
as immutable content-addressed file artifacts. The request's provider policy
also carries an explicit versioned capability/namespace contract. The
resulting build-id records the request, source tree, build definition, and
toolchain tree identities.

The current local closed-action provider is classified **scripting-only**.
This is provenance and diagnostics, not a hermetic or reproducible self-build
claim: the provider materializes immutable request artifacts and uses a
private working directory, but local host behavior remains semantic input and
does not permit cache or remote reuse.

### Closed-action cacheability contract

A provider **may** return `cacheable` only when its closure accounts for all
of the following: declared input and output trees; toolchain and loader
dependencies; `env`, locale, `TZ`, `HOME`, and `cwd`; network access; clocks
and randomness; platform, kernel, and resource-limit assumptions; and all
visible filesystem state. If any item is undeclared, ambient, or
unreproducible, the result is **scripting-only** and must not be reused from
cache or remotely.

The local provider now advertises its capability and namespace contract
explicitly: workspace-materialized filesystem, explicit-only environment,
ambient network, and a direct child process. Its loader, clock, randomness,
kernel, and resource namespaces remain ambient, so both ordinary closed actions
and the direct-SBCL self-build are intentionally scripting-only.

The direct SBCL artifact closes the selected runtime/core/`SBCL_HOME` bytes,
but it does not yet include or attest the ELF interpreter's complete shared
library closure. The executor also does not enforce an OS filesystem/network
namespace or resource, platform, clock, and randomness controls. A cacheable
provider must close and attest those remaining inputs; until then the
executor rejects unsupported or incomplete contracts and never returns
`cacheable`.



## Application and commands

`lisp/app/main.lisp` starts the process, parses options, builds production
services, and converts uncaught conditions to pp diagnostics and exit status.
It owns language execution, formatting, lint, store/node inspection,
reconciliation, scheduling, transport, and lifecycle command boundaries.

Run `bin/pp --help` for the current command list. Do not duplicate flag rows
in this document.

## Final ownership map

The implementation has one owner for each semantic responsibility:

| Responsibility | Owner | Forbidden second owner |
|---|---|---|
| AST constructors and semantic dependencies | `pp.kernel` (`core-model.lisp`, `identity.lisp`) | frontend/runtime free-variable walkers |
| Value identity and node-key composition | `pp.kernel` (`identity.lisp`, `hasher.lisp`) | evaluator, lifecycle, distribution, or app key builders |
| Durable language-value policy and encoding | `pp.kernel` (`codec.lisp`) | node/config predicates with broad acceptance |
| Continuation evaluation and ephemeral delays | `runtime/evaluator.lisp`, `evaluator-support/state.lisp` | host evaluation or provider evaluators |
| Dynamic runtime context and brackets | `runtime/dynamic-scope.lisp`, session-owned context | evaluator field mirrors or process-global registries |
| Effect dispatch and observation cells | `dynamic-scope.lisp`, `effects.lisp`, `observations.lisp` | application effect dispatch loops |
| Persistent nodes, cache, traces, authority, and persistence | `runtime/nodes.lisp`, `cache.lisp`, `store.lisp` | evaluator or watch cache/persistence paths |
| Placement | `distribution.lisp` | semantic identity, trace, or authority decisions |
| Reconciliation and fencing | `lifecycle/domains.lisp`, `watch.lisp`, `fenced.lisp`, `journal.lisp` | application reconciliation loops |
| Concrete host providers and CLI | `lisp/app/`, lifecycle provider modules | kernel/frontend/runtime host access |

The dependency direction is:

```text
frontend -> kernel
runtime -> frontend -> kernel
app -> runtime -> frontend -> kernel
providers -> runtime operation/context boundaries
distribution -> node miss boundary (placement only)
lifecycle -> node/context/store boundaries
```

Reverse dependencies are forbidden: kernel cannot depend on runtime or app;
frontend cannot depend on app; runtime cannot import app; distribution cannot
construct semantic keys or validate traces; lifecycle planning cannot write
node objects/traces; and application code cannot reimplement evaluator, node,
or reconciliation semantics.

## Distinction table

| Distinction | First concept | Second concept | Boundary |
|---|---|---|---|
| Identity vs validity vs authority | node key | trace verification | hit-time capability check |
| Node vs delay | persistent reusable computation | ephemeral in-memory thunk | Node Engine vs evaluator force |
| Durable vs wire | canonical pp value | process-boundary descriptor | codec vs distribution validator |
| Handler vs scheduler | semantic effect precedence | execution placement | dynamic dispatcher vs distribution |
| Reconciliation vs fenced action | convergent observe/diff/apply/verify | non-repeatable intent/done action | lifecycle domains vs fenced journal |
| Observation vs effect | recorded world fact/cell | operation that may read or mutate | observation recorder and effect dispatcher |

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
