# pp design

This document explains why the current architecture has its shape. It does
not list implementation status. See [ARCHITECTURE.md](ARCHITECTURE.md) for
ownership, and [SPEC.md](SPEC.md) for laws and current limits.

## Principles

1. `force` is the only execution primitive. A scheduler can choose where a
   node runs, but it cannot change the node's meaning.
2. A persistent node is the unit of cacheable work. `delay` is only for
   in-memory laziness.
3. Capabilities grant authority. They do not define identity or ordering.
4. There is one evaluator and one node rebuild operation. Serial, parallel,
   race, and remote scheduling call that operation.
5. World reads are observations. A trace records what a node read. A cache
   hit is valid only when those reads still match.
6. Reconciliation is single-writer. It observes, plans, applies, verifies,
   and journals each pass.
7. Durable writes use one atomic replacement boundary. Repositories store
   data and traces, not evaluator policy.
8. Closed runtime sets have one source of truth. Readers, printers, tests,
   and generated specifications use the same tables where possible.

## Why the evaluator stays single

The evaluator is the executable language specification. A second evaluator
would create two meanings for the same AST and would make cache identity hard
to audit. Helper modules reduce the size of the main dispatch, but each helper
receives explicit operations from the same evaluator.

The operation value also gives the application a narrow construction seam.
Tests can provide complete host services and a scheduler without installing
global callbacks. This keeps ownership visible and makes session isolation a
checkable property.

## Why observations are trace data

A node can depend on a file, a tool, a configuration value, or a handler
without the dependency appearing in its source code. The trace records the
observed cell and its content hash. The next force re-observes the cell before
it serves the result.

This gives pp a dynamic dependency model. It avoids putting every possible
world input into the node key. The key contains code and free-variable value
hashes. The trace contains the world reads.

Reads also propagate to enclosing nodes. This prevents a parent hit from
hiding an unauthorized child read. The hit check covers the full transitive
read closure.

## Why authority is not identity

A capability says what a caller may read or write. It does not say what a
computation is. Two callers with different grants can therefore use the same
node key. The cache checks authority before it serves a hit.

If a capability were part of the key, every grant change would duplicate
results. If it were ignored at the hit boundary, a broad caller could expose a
result to a narrow caller. The separate key and hit checks avoid both errors.

User code receives only root-minted capabilities. Restriction and composition
can reduce or combine held authority. They cannot create authority outside the
current ceiling.

## Why sessions own state

Evaluation state has a lifetime. Some state lasts for one expression. Some
state lasts for a pass. Some state lasts for a watch loop. A `Session.t` names
these lifetimes and provides reset operations.

OCaml effects still carry values that must follow dynamic control flow, such as
the current handler or node frame. Effects do not own registries. This split
prevents a dynamic-scope value from becoming process-global state.

## Why domains own writes

A desired state is easy to compare and retry. An arbitrary write is not. The
domain protocol puts observation, planning, writing, verification, and
journaling in one lifecycle. A domain owns its namespace and write authority.

The filesystem and process policies live in pp source. The OCaml runtime owns
only the trusted primitives and the generic protocol. This keeps new policy
out of the evaluator and gives domains the same cache and observation rules as
other programs.

Fenced actions are different. They cannot always be repeated safely. The
reconciler records intent before it runs one and records completion after it
returns. Recovery requires an explicit policy.

## Why processes provide parallelism

The runtime has mutable state and filesystem sandboxes. Child processes give
each worker an isolated session and store view. They also match the transport
boundary used for remote placement.

The scheduler batches node misses, but workers still call the same rebuild
operation. Scheduling changes placement and timing only. `--check` can compare
results across schedules.

## Why the store has separate repositories

Objects, blobs, traces, fenced specifications, and process state have different
lifetimes and validation rules. Separate repositories keep those rules local.
`Store_layout` owns paths, versions, locks, and atomic replacement. The cache
policy receives repository handles and does not construct paths.

Canonical text makes the data portable and inspectable. Hash-named values are
immutable. A version change invalidates repositories that use the old format;
it does not reinterpret old bytes as new data.

## Security limits

The model protects authority at the evaluator, node, cache, loader, and
transport boundaries. It does not protect against a trusted cluster owner,
timing side channels, traffic analysis, or a compromised host.

Secret values remain sealed until an explicit `unseal`. The printer redacts
them and the codec rejects them. A persistent node cannot capture or return a
capability or sealed value.

Island fetching is runtime authority. It is opt-in, journaled, and checked
against the requested content pin. It is not a capability that user code can
construct.

## Honest edges

The machine-checked records are in
`tests/fixtures/adversarial/honest-edges.tsv`. The entries below explain the
same trust boundaries for readers.

- `$config` trusts the session configuration supplied by the current command.
  A program can change that configuration only through its explicit forms.
  The trace records a config value that a node reads.
- `$env` trusts the process environment. pp records the observed value, but it
  does not control changes made by the host or by another process.
- `$probe` is deliberately volatile. The probe owner supplies its value once
  per pass. The value stays in session state and does not enter the durable
  object store.
- `run` launches ambient POSIX processes and is scripting-tier
  only.
- `run-closed!` closes the environment, filesystem, and network around
  immutable blobs through a session-owned executor. Its first Linux provider
  accepts only the exact Linux platform constraint and does not mediate time,
  randomness, CPU instructions, kernel behavior, or resource limits. It fails
  unavailable when Bubblewrap cannot create every requested namespace and
  remains scripting-tier while reporting those ambient facts as ordinary
  evidence.

## Extension rules

Add a new AST form only with its reader, printer, quote conversion, identity,
evaluator, property coverage, and fuzzer coverage. Add a new observation only
with a cell representation and adversarial world coverage. Add a durable
write only through the atomic replacement boundary.

Keep comments local and factual. Do not use comments to record roadmap steps,
old module names, or test history. Put stable reasons here and current facts
in `ARCHITECTURE.md` or the status table in `SPEC.md`.
