# pp design: why it is shaped this way

This document holds the timeless rationale: 8 frozen design principles, the
unified runtime model, 13 resolved design decisions, the honest edges, prior
art, and a worked build example.

For the semantic laws pp must obey, see `SPEC.md`; for implementation
status, see `STATUS.md`; for definitions, see `GLOSSARY.md`.

---

## Frozen design principles

1. `force` is the only execution primitive. Where a computation runs is a
   scheduler decision, never something the language surface names — there is
   no `remote-eval`. Parallelism and distribution are the same feature at
   different scale: scheduling is a swappable effect handler that must not
   change results (see the scheduler decision below). Cluster membership is
   ambient configuration, not something an expression names.

2. Laziness prunes work at node granularity; a node's own body runs eagerly
   (see the strictness decision below). The dependency graph is not
   "emergent from per-expression laziness" — it is the demand-pruned subset
   of the wanted set defined by the root's desired-state formula, the same
   shape Bazel uses. `delay` still exists for ephemeral, in-memory laziness
   such as lazy sequences, and stays distinct from `node`.

3. Capabilities grant authority, not ordering, and cannot be forged. A
   capability is a ceiling on what a computation may touch, minted only at
   the root (see the capability model below). User code can restrict or
   compose a capability but never construct one, and capabilities are not
   linear or affine values. Ordering and determinism come from principle 5,
   not from capabilities.

4. One rebuilder drives 2 schedulers (see the scheduler decision below). A
   single rebuilder — verifying and constructive traces over one
   content-addressed store, with hash cutoff — is driven by a suspending
   pull scheduler for builds and provisioning, and a dirty-propagating push
   scheduler for reconciliation and services.

5. A program is a pure function from input cells to a desired-state value,
   for domains that can be observed and that converge; the runtime is a
   single-writer reconciler. Fenced actions — side effects that cannot
   safely repeat — are sequenced by the reconciler's intent journal and sit
   outside the desired-state law. User code never writes shared external
   state directly; every domain write goes through the reconciler. Because
   each domain has exactly one writer, there are no write-write races and
   nothing left to order.

6. Scope discipline: builds come first. Get hermetic, incremental builds
   solid before parallel or distributed ones. Provisioning is a build.
   Reconciliation is the same rebuilder running under the push scheduler.
   Orchestration is a library, never part of the core language.

7. Kinds are closed; instances are open. A closed set in the language — cell
   kinds, capability kinds, `with` clauses, `$` observation heads, grant
   descriptors — is justified only when both hold: the runtime must
   enumerate the set to verify traces or enforce authority, and there is an
   instance-level extension point users reach instead of extending the set
   itself. Observations extend through probes and domains; dynamic extent
   extends through effect names and configuration keys; grants extend
   through `cap-restrict`, `cap-compose` and `needs <expr>`. Capability
   kinds cannot run out, because every interaction with the world passes
   through a closed set of primitive effects, and the kinds gate exactly
   those primitives. A new domain's authority always reduces to an existing
   kind; a genuinely new kind means a new channel to the world, which is a
   change to the core by definition.
   Each closed set is defined once, as a typed table in one OCaml module.
   Every consumer — readers, the quasiquote grammar, the linter, the fuzzer,
   the SPEC appendix, error messages — derives from that table, so an
   unhandled case is a compile error, and a drift test in continuous
   integration keeps the generated SPEC block in sync.

8. Coverage is derived, never enumerated by hand. Every recurring
   obligation — each AST node needing a generator arm, each law needing a
   pinned test, each observation head needing an adversarial fixture, each
   write site needing crash coverage — must attach to a gate that fails
   mechanically when unmet: an exhaustive match over a variant that the
   compiler checks, a drift test against a table that continuous integration
   checks, or a harness at a single module interface that every instance
   must route through. A hand-maintained coverage checklist is a defect for
   the same reason a hand-duplicated closed set is (principle 7): memory
   drifts, and mechanical gates do not. The only decision left to a person is
   what makes the build red, never remembering to make it red.

Plain `write-file` in user code is dead as a way to write a domain: a
node may write only to sandbox-local scratch paths, thrown away after
the run — only an output blob's hash escapes — and anything written to
a reconciled domain goes exclusively through the reconciler. pp stays a
general scripting language for computation and observation, but stops
being one for uncontrolled side-effecting writes: the price of making
principle 5 true rather than aspirational. A `--unsafe-scripting` escape
hatch may exist outside nodes for REPL use, explicitly outside the
caching and determinism guarantees.

---

## The unified runtime model

### Vocabulary

This is a condensed vocabulary; see `GLOSSARY.md` for standalone definitions.

Input cell (`Var`): a stable identity naming a piece of the external
world, plus its current observed value as a content hash — for example
`file:<canonical-path>`, `glob:src/*.c`, `toolchain:cc` (see the
read-tracking decision below), or `proc:web`. Cells are mutable only
because reality is mutable; the observer — a prober or a watcher — is the
only writer of a cell's value. A cell id is canonicalised before hashing
— absolute real path with symlinks resolved, NFC Unicode, no trailing
slash — once, in `Runtime`, so a path-prefix bug cannot reappear at the
cell layer, and two syntactically different paths naming the same inode
are one cell.

Node: the cacheable computation — a suspended, strict computation
created only at explicit boundaries, such as `node { e }` or
`node name(...) { ... }`, never by `let` or an argument thunk, both of
which stay strict (see the strictness decision below). A node's key is
`H(code-hash, arg-value-hashes)`: a path argument such as `"src/a.c"`
contributes the hash of the string, not of the file's content, and an
argument that is a child node's result contributes that result's hash,
which is why children are forced before the parent's key can exist (call
by value). Capabilities and the handler stack are not part of the key
(see the capability model and the persistent-store decision below).
Validity is separate from identity: a cached result is valid only if
every entry in one of its stored traces still matches current
observations.

Trace: the cell-id and observed-hash pairs a node read, the keys of any
child nodes it forced, its result hash, and an outcome of ok or failed —
in Build Systems à la Carte terms, this makes pp both constructive and
verifying. The trace store maps each node's key to a set of traces, not
a single trace: one node can have been validly built under different
observed toolchains or platforms, and a hit succeeds if any stored trace
verifies. A failed outcome is stored as a trace too, so a rebuild with
unchanged inputs re-serves the failure without re-running, and it
becomes forceable again only when an input cell in its trace changes —
the error-memoisation law. Cutoff: if a recomputed result's hash matches
the prior result's hash, dependents are not marked dirty — content
addressing makes this free and exact.

Desired-state value: an ordinary pp value the root returns — a map from
output path to blob hash for a build, from process name to spec for
services — pure, hashable and diffable. The reconciler is the single
privileged writer for a domain: it observes the domain as cells, diffs
desired against observed, applies the minimal change, and verifies after
writing. Domain stratification: nodes that feed a domain's desired-state
value may not read that domain's own cells, or a reconcile could change
a cell, dirty a node, and force a re-reconcile forever; read and write
strata are declared per domain and checked.

2 kinds of mutation exist, and neither is shared mutable state:
thunk-local scratch, sandboxed per node and discarded once only the
output blob hash escapes (the Nix/Bazel model), and shared external
state, where cells go in, a desired value comes out, and the reconciler
applies it (the React/Kubernetes model).

### The rebuilder and the 2 schedulers

```
force(key):                                    # THE REBUILDER (one impl)
  for trace in trace_store[key]:               # key → SET of traces
    if every (cell,hash) in trace matches current observation
       and caller's cap set permits the trace's transitive read closure:
      # a cache hit does NOT replay ephemeral effects (log/stdout); see SPEC
      return trace.result_blob                                          # HIT
  # miss:
  push fresh trace collector (records reads, child keys, outcome)
  run node body STRICTLY; performs record (cell,hash); child forces record key
  pop collector; add trace to trace_store[key] (SET); store result blob
  return result

# PULL scheduler (builds, provisioning): suspending; force root, recurse on demand.
# PUSH scheduler (services): dirty-propagate over the reverse-edge index derived
#   from traces; re-force only dirtied nodes in dependency order; stop at cutoff.
# Both call the SAME force/rebuilder above; neither has its own semantics.
```

A build runs once: force the root through the pull scheduler, then
reconcile the domain with the root's value as desired state.

A service runs forever: a watcher updates a cell, the push scheduler
stabilises the dirtied nodes, and the reconciler runs again.

### The 2 axes

2 independent things determine what a computation can do, and what it
actually did:

- authority ceiling, what it may touch: the capability set. It is
  unforgeable, minted at the root, checked at every `perform`, and
  checked again at hit time against the trace's transitive read closure
  (see the capability model below).
- actual dependencies, what it did touch: the trace set. Keys and cutoff
  live here, never on capability scope or handler identity.

---

## Design decisions

13 questions were open during the design of pp. Each is resolved below, in
the order they were raised.

### Why laziness is demand-pruning at node granularity

Node application is call by value with memoisation. A persistent `node`
differs from an ephemeral `delay`, and this is why fexprs are cut.

Because an aggregator's key is `H(code, child-result-hashes)`, its children
must be forced before its key can exist. The old idea that "every
expression is a thunk, and the graph emerges from laziness" is retired.
What survives as laziness is skipping recomputation on a cache hit, and
demand pruning: only nodes reachable from the root's desired-state formula
are built. The wanted set is defined by the root, in the same style as
Bazel.

Fine-grained call by need gave the codebase a class of stack overflows, a
storm of argument-thunk allocations, an unsound cache key, and
effect-escape hazards — for no build-relevant benefit.

2 constructs now do different jobs:

- `node` and `defnode` give the persistent, cacheable graph node. Both are
  reader special forms: `defnode` desugars like `def` but marks the binding
  as a node constructor; `node` behaves like `delay` but routes through the
  store.
- `delay` and `force` give an ephemeral, in-memory thunk that is never
  persisted, for lazy sequences. This keeps micro-entries out of the store.

Fexprs are cut. `def-fexpr` is removed: it was a thin wrapper over thunks
rather than syntax, and its only mechanism, argument thunking, disappears
once application is call by value. The metaprogramming need it served is
now met by making the reader's quote path total — `quote_to_value` handles
every form, plus quasiquote — together with `defmacro`. This gives a
cleaner homoiconicity story than operatives over thunks. `defmacro` is not
a reader special form: it parses as an ordinary application and is
recognised only at the one expansion point both backends pass through
before compiling or evaluating a top-level form. The code hash is
computed on the already-expanded AST, with no change to how expressions
are hashed.

### Tracking what a node reads: sound but coarse, refined per tool

The default is sound but coarse — the whole mounted-cell tree hash. Per-tool
adapters refine it using depfiles or a toolchain closure.

Sandbox v1 — a temp directory with hardlinked, read-only inputs — cannot
fail closed on absolute paths: `cc` reads `/usr/include/*` regardless of
what is mounted. So the sandbox is not what makes reads sound.

The soundness rule: a node's trace defaults to the content hash of every
mounted cell boundary it was granted — the whole `src/` tree hash, and the
`toolchain:cc` closure cell. `cc -MD` reports the exact headers read, and
an adapter converts those into precise cells, shrinking the trace below
the coarse ceiling. With no adapter, the trace stays coarse but sound.
Sound but coarse beats precise but unsound.

The `toolchain:cc` closure cell exists because system headers and
libraries are a staleness hole: it is modelled as one closure cell whose
hash covers the tool binary plus the system paths it resolves.

Plain `run` records `tool:<binary>` plus one
`tree:<root>` cell per filesystem-read grant. `run-dep!` parses the tool's
Makefile-style depfile and records precise `file:` cells for granted
dependencies, and `tool:<path>` cells for dependencies outside the grant
— system files — with no tree cells, superseding the
aggregate `toolchain:cc` closure cell wherever depfiles exist. For tools
with no depfile, the binary's `tool:` cell still covers upgrades, while
system-path reads outside the granted trees remain a documented hole —
one a closure cell could not have closed either, since the paths it
would need to cover are unknowable without the tool's own report.

### At-most-once effects: fenced actions stay in the reconciler

The idempotency epoch is one reconcile pass, backed by a write-ahead log
and an unknown-status policy.

Convergent effects — writing a file, making sure a process is running —
are safe to re-apply; these are what nodes may do inside a sandbox, and
what the reconciler applies. Fenced effects — sending an email, charging
a card — are not convergent, so the `fenced(KIND, SPEC-MAP)` primitive
raises an error if called inside a node body. The scripting tier
registers fenced actions in `Runtime.fenced_actions`, drained once per
pass, after all convergent work, by the reconciler or supervisor.

An action runs at most once per pass. The write-ahead log records `intent fenced KEY EPOCH KIND
SPEC-HASH`, then performs the action, then records `done fenced KEY
RESULT-HASH`. The spec value is stored by content hash, so recovery can
re-run an action of unknown status with exactly the same inputs. On
replay, a `done` entry
means skip; an `intent` with no matching `done` means the status is
unknown, and a policy decides what happens next — retry, abort, or ask —
never a silent retry. On recovery, the epoch from the unknown intent is
reused for the resumed pass, so a re-registered identical action
deduplicates instead of running twice.

### Reconciler crash safety: a journal over the content store

Convergence is driven by re-observed reality, not a trusted state file.

Terraform's pain comes from a state file drifting from reality. pp avoids
this because desired state is cheap to recompute, thanks to the cache, and
observed state is always re-derived from cells. The steps are: the diff
plan is a pure, hashable value, so plans themselves can be cached; the pass
appends `(desired-root-hash, plan)` to the journal; it applies the plan,
materialising files via a temp file and `rename(2)`, applying convergent
process operations, and routing fenced actions through the mechanism above;
it verifies after writing; and it marks the pass complete. On restart,
unknown fenced actions are resolved by policy, and stabilise-then-reconcile
runs again.

### Cutoff and generative graphs

Dynamic dependencies are native. Separating key from validity makes
generators cheap, and keying is unified with the persistent-store decision
below.

Editing one file changes that file's cell, invalidating exactly the one
`compile` node whose trace mentions it. A generator re-runs only when the
manifest — the set of names — changes, and then it emits the same child
keys for unchanged files, each an O(1) trace check that hits.

### Why capabilities are authority, not ordering

Capabilities are unforgeable, minted only at the root, and act as a pure
ceiling. The check at cache-hit time is transitive.

Authority bootstrap: capabilities enter only at the root. `main` receives
a powerbox from the command line (`--grant fs:src:ro`, `--grant net:tcp`,
and so on) — the only mint. User code cannot construct capabilities:
`filesystem`, `network` and `process` are removed as constructor
builtins, leaving only `cap-restrict` and `cap-compose`, which narrow or
union what the code already holds.

In-language attenuation: `current-capabilities()` observes the ambient
ceiling as of the call — never a mint, since it reifies exactly what
every `perform` already checks against. `cap-restrict` gained an optional
mode argument that only ever narrows: requesting a mode wider than the
underlying capability holds raises a `Capability_error`. `with-caps(cap-expr)
{ body }` replaces the ambient capability set with a held,
checked-as-a-subset value for the extent of `body`, so a narrowing
composes correctly even where some other binding lexically retains a
broader value. The earlier `effect` capability-union form, which allowed
`caps @ ambient`, is removed: once capability values exist, unioning with
ambient becomes a widening backdoor, and could not be kept alongside
`with-caps`. This is what makes a domain's write capability narrowable to
exactly one function and ungrantable to node code, and what makes
node-captured capabilities (see the effect-ordering decision below) a
real, testable mechanism rather than a claim nothing tests.

Interpreter-level loads are runtime authority. `load`, `import`, `island`,
and module resolution run with the interpreter's own authority, bounded to
source roots plus the store, outside user capability accounting — they are
the loader, not user effects. Island fetching (`--fetch-islands` or
`--update`) extends the same runtime authority to procurement, opt-in
per invocation and distinct from user `net` or `process` capabilities
(see `docs/THREAT-MODEL-islands.md`).

Consider a node `PUB = f(SECRET)`
where `SECRET` reads `/etc/passwd`. `PUB`'s own trace records only the
child's key. A check against direct cells alone would let a caller with a
narrow capability hit `PUB` and learn that a broad read happened. So the
hit check must cover the transitive read closure — the union of cells
across `PUB`'s trace and, recursively, every child's. A hit is granted only
if the caller's capabilities permit every cell in that closure.

The tree-walker realises this: reads propagate to enclosing nodes,
so the recorded reads are the transitive closure, and `Store.hit
~authorized` refuses to serve a trace the caller cannot fully read (see
`SPEC.md`, law 23b). A capability denial raises a distinct
`Capability_error` and is not memoised (law 15). Three aspects are refined
further:

- cost: O(closure size), not O(1). Memoising a
  `closure-read-set-hash` and `closure-cap-requirement` per stored trace
  makes it O(1).
- runtime versus traced reads: loader reads are tagged `runtime` and
  excluded from the caller's requirement; only reads under user capability
  count.
- store-existence oracle: `pp why`, and any hit/miss surface, are
  capability-filtered from the start.

### One rebuilder, 2 schedulers

Re-forcing from the root is dropped as an approach.

Re-forcing from the root costs O(reachable trace checks) per tick —
exactly the cost the reactive machinery exists to avoid. The resolution
is the rebuilder-and-2-schedulers split from principle 4 above, with the
push scheduler driven by the reverse-edge index. The store-level
collapse is the claim worth keeping; the stronger claim that both
schedulers perform the same traversal is dropped as overclaim (see the
Adapton entry under prior art below).

### The persistent store wired into force

The store lives at `~/.pp/store/`: `objects/<hash>` holds result values and
file blobs; `traces/<node-key>` maps to a set of `{result-hash,
[(cell-id, hash, origin)], [child-keys], outcome, closure-read-set-hash,
closure-cap-req}`; and `journal` records reconciliation passes (see the
crash-safety decision above). Concurrency is handled by exclusive temp
files plus rename; hash-named objects are immutable, so races are benign.

The store is wired into the tree-walker's `force` for `node { e }` thunks.
The traces are a subset of the target schema —
`{outcome, result-hash, [(cell-id, observed-hash)]}` for file cells —
`child-keys`, `origin`, `closure-read-set-hash` and `closure-cap-req` are
the remaining fields. Both backends share it: the VM compiles `node { e }`
to a `MAKE_NODE` opcode and forces it through the same store, computing a
byte-identical key for data-valued free variables so the 2 backends
share entries.

Keying follows the vocabulary above: the persistent key is `H(code-structure,
free-var-value-hashes)` (`node_key_of` and `free_vars`), excluding the
whole-environment hash and the capability set. This closes 2 leaks this
decision was meant to fix — an unrelated global rebind changing every key,
and a widened grant changing every key (see `SPEC.md`, law 20).
Configuration and the handler stack are
folded into the key conservatively (their treatment is the handler-caching
policy below, and `SPEC.md` law 33), and binding order is not
canonicalised (law 3).

Handler-caching policy: handlers split into 2 classes.

- result-transparent handlers, such as schedule or placement handlers,
  may not change observable results, only where or when work runs, so
  they are absent from keys and traces; a `--check` flag runs a node
  under 2 schedule handlers and asserts the result hashes match.
- semantic handlers, such as a mocked `read-file` or fault injection, change
  what a `perform` returns. An intercepted `perform` records a synthetic
  cell, `handler:<handler-code-hash>:<effect-name>:<arg-hash>` mapped to a
  result hash, into the trace. Swapping a mock for the real handler changes
  the handler's code hash, which changes the synthetic cell, which
  invalidates the trace. This is strictly better than putting the whole
  handler stack in the key, since only the effects actually intercepted
  enter the trace.

An in-memory treatment folds the handler stack into the thunk key (see
`STATUS.md`). The policy above is the trace-layer refinement that supersedes
it once the persistent store lands.

The `.ppc` bytecode disk cache is cut: the value and trace store
replaces it, and bytecode stays purely in memory as the VM's execution
form, never itself cached.

Introspection is via `pp why <key>`, capability-filtered. `pp graph` is
deferred to later work, since it needs the reverse index.

### Distribution: a scheduler handler over a process pool

The near-term plan ships process-pool parallelism only. Cluster support is
deferred.

This ships as a `parallel`/`race` schedule handler over local worker
processes, not OCaml 5 domains, because the interpreter is saturated with
global mutable state and processes give isolation that matches the
sandbox model already in place. Cluster forcing, by-hash object sync, and
signed capability tokens move to a later, speculative phase, gated behind
a written threat-model document.

Parallel dispatch forks at the point of dispatch, rather than keeping a
persistent worker pool: `Scheduler.dispatch_batch` forks up to the
policy's concurrency limit over a batch of `(key, run)` jobs, and each
child runs `Evaluator.run_node_body`, the same function the serial code
path calls, so there is no separate "evaluate in a worker" implementation.
This settles, in fork's favour, the problem of sharing ambient interpreter
state — the handler stack's live OCaml closures, current capabilities,
the configuration stack, and the thunk store — with a worker: `fork()`
inherits all of it byte-identically through copy-on-write, for free,
where a persistent pool or a fresh pp process would instead need to
marshal that state across a channel, which is impossible for handler
closures and buys nothing over a cheap `fork()` anyway. Because of this,
a refactor of `Runtime`'s global mutable state is not needed for parallel
dispatch — though a remote transport, needing named
or registrable handlers in place of closures, would need it.

Remote placement across a cluster works without forking or marshalling.
A batch job ships to a remote member only when every one of its free
variables' forced values re-encodes as data — the store's existing rule
that only data, not closures, can be marshalled.
One documented exception: a bare reference to a global primitive
(`VBuiltin`) is code identical on both sides by construction, so
referencing it does not count as "shipping code". A cluster member is a
genuinely separate process, so the ambient-state-sharing problem above
does not arise: it runs an ordinary second pp invocation of the
byte-identical program, independently re-deriving its own thunk graph —
duplicate cross-machine computation is sound, because results are
deterministic. Results are pulled back over the
`serve-hit`/`recv-hit` pair, re-verified by hash. See `STATUS.md`, and the
pre-seed mechanism described below under effect ordering.

2 further, additive pieces complete this work. First, host-qualified
domains: the desired-state map generalises by 1 level, from `{domain ->
desired}` to `{host -> {domain -> desired}}`, never inferred from shape,
only opted into with an explicit `--member-name <n>` flag — without it,
nothing changes, which is the whole backward-compatibility argument. A
by-hash seam for desired values is realised as a local-directory,
two-store version, without an SSH-backed variant.

Second, `pp gc`. Garbage collection is explicit, never automatic. Because
traces do not record child keys — there is no on-disk node graph to walk
— it marks live objects by replay: each recorded root re-runs as a
`--gc-mark` subprocess, driving the same `Store.hit` path a live pass
would, but skipping domain apply and fenced actions, which makes the
replay read-only on the world by construction. Concurrency safety comes
from a creation-time grace period plus a re-check of the roots manifest
immediately before each delete. Over-retention is always safe; deleting
live data is the only real hazard, so any doubt — a failed replay, or a
manifest that changed mid-sweep — biases toward keeping everything.

### Backend strategy: 2 engines, one executable spec

The tree-walker is the executable specification for pp's semantics; the VM
must conform to it, not the other way round.

`--diff` runs both backends against the same program and is the cheapest
correctness check available. The parity rule softens from "no feature may
exist in only one backend" to "no shipped feature may exist in only one
backend": divergence while a feature is mid-migration is allowed, but a
release with it is not.

### Effect ordering: one snapshot, capabilities captured early

4 residual races were identified, each with a fix or a contained trust
boundary.

Torn reads. The first observation of a cell ingests its bytes into the
content-addressed store and pins the pair `(cell, store hash)`; nodes read
only that pinned copy. `Store.read_file_cell` realises this one step
stronger than originally specified: the pin serves
every tier, not just nodes, so one run is one world snapshot. This was
needed because the in-memory content-addressed deduplication already
memoised identical read expressions, which would otherwise have made a
tier-by-tier freshness split incoherent. pp's own `write-file` advances the
snapshot for that cell, unpinning it.

External writers to a reconciled domain. Verify-after-write plus
converge-next-pass, under single ownership, handles this.

Hidden writes in user handlers. Domain write capabilities cannot be granted
to node code, which closes this off.

Laziness escape. Strict node application, plus capturing the capability set
at node creation, closes this off.

Capability capture is a real, tested mechanism, not an assumption
that holds vacuously. With `with-caps(cap-expr) { body }` in
place, the ambient capability set can change mid-process, so "captured at
creation" and "ambient at the moment of forcing" are genuinely
different, and testably so. `thunk.node_caps` is populated from
`current_capabilities` at each `node { e }` occurrence's creation;
`force_node` uses the forcing thunk's `node_caps`, not the live
`current_capabilities`, for both the hit check and a miss's recompute.
So a node created under a
narrowed `with-caps` extent is still denied when forced later under the
full grant, and vice versa. Where
`with-caps` is never used, capture collapses back to the pre-existing
per-process `--grant` set, so a program that never uses it behaves
identically.

The node boundary is symmetric (`SPEC.md` law 20): a node's free variable
containing a capability is banned at the key — checked structurally,
never forcing an unforced thunk — and a node's result containing a
capability is banned before it can be stored. Both checks are
independent of the capture mechanism above, holding even where
`with-caps` is never used; the actual security floor is the subset check
that both `with-caps` and the hit gate perform at use time. The one
documented gap is a capability hidden behind an unforced thunk, invisible
to the free-variable ban without violating law 14.

A further narrowing surfaced once parallel dispatch (see the distribution
decision above) was in place: `Store.run_pins` is in-memory and
per-process, so a forked worker inherits the pin table as of the fork
instant through copy-on-write, but any cell it observes for the first
time afterwards pins independently, in its own copy. N workers racing, or
batch-computing under `parallel`/`race`, are no longer guaranteed to agree
on a cell that neither had pinned before dispatch — at most N world
snapshots agreeing on everything pinned before dispatch, not the
single-process guarantee of one run, one world snapshot. This is still
sound: a divergent observed world across workers is a
legitimate distinct trace, since the store already treats "the same code
validly built under different observed worlds" as one key with a set of
traces. The worst case is a spurious recompute, never a wrong result served. Closing
this gap fully — a pre-dispatch snapshot barrier, or moving pins into the
store itself so workers share one table — is later design work: today's
pin table rides fork's copy-on-write for free, which a barrier or a
shared table would have to stop assuming.

The pin machinery above is exposed directly, not only behind the
internal `--remote-node` machinery used for cluster members: `--pin-file`
exposes `preseed_pins_from_file` standalone, and `pin-probe("NAME",
<codec-value>)` generalises it to a probe's own value; `--dump-pins`
writes both tables back out. This is pure observability: no new
authority, no write path, and no change to any key, hash or codec
grammar — it only makes the claim that probe cells are pinned inputs
falsifiable for a program whose desired state folds in a volatile probe.

### Self-hosting: cut for now

`pc.pp` is unrunnable, for 3 independent reasons, and is deleted. The
thesis-proving dogfood goal is met differently: `pp` builds `pp` through an
ordinary `build.pp`. Self-hosting the compiler itself is left as a much
later curiosity.

### The in-language domain protocol

A domain is an observe/diff/apply triple of ordinary pp functions, run
under discipline enforced by the core. The reconciler and the supervisor
are no longer OCaml.

Registration: `register-domain({:name :namespace :observe :diff :apply
:write-cap [:observe-cell]})` is an ordinary primitive, available only at
the script tier; `:write-cap` is consumed into `Runtime.domain_registry`
and never re-exposed as a pp value. A probe is simply a domain with no
write authority — `register-probe` is sugar over the same call, with `:diff`
and `:apply` set to none — so there is one registry and one mechanism
behind both. There is no separate `CapDomain` kind: a domain's write
authority is the underlying resource capability itself, narrowed with
`cap-restrict`, never a second name for the same ceiling.

Types: `observe : () -> value` runs fresh every pass and is never cached
by the orchestrator, since caching it would bring back Terraform's
trusted-state-file bug (see the crash-safety decision above). `diff :
(observed, desired) -> plan` is pure, enforced by threading an empty
capability set for its extent — reusing the `with-caps` mechanism rather
than adding a new purity checker — so any gated `perform` inside `diff`
raises a `Capability_error`. A plan has 2 keys: `:items`, opaque to core
except for an emptiness check on verify-after-write; and `:summary`, an
ordered vector of `[key value]` pairs the domain assembles itself, echoed
verbatim into the journal line and the per-pass summary, so core never
needs to know what "create" means. `:summary` is a vector, not a map,
because the store's on-disk codec sorts a map's key order for
determinism but preserves a vector's — a cache hit reordering the
summary would silently break the byte-compatibility this format exists
to protect. `apply : plan -> nil` is not a node and is never
key-resolved; it runs under `with_ref current_capabilities [write_cap]`,
the `with-caps` mechanism used directly from OCaml, so a node built
inside `apply` that closes over the write capability still hard-errors
through the existing free-variable ban.

Plan caching: the key is `H("domain-plan", hash(diff-closure),
hash(observed), hash(desired))`. Since `diff` is pure over exactly
`(observed, desired)`, this key captures the whole identity of the call,
so a store entry with an empty read set is sound — a hit means exactly
"same key, same plan". `src/domains.ml` calls `Store.hit`, `store_object`
and `store_trace` directly rather than wiring a synthetic `node` AST,
giving the same key and store slot for free; `pp why` reports `domain
<name>: plan <key>: hit|miss`, exactly like a node.

A load-bearing problem surfaced while this was being built, not merely
anticipated: `observe` and `apply` must be cache-busted per call, not
just per pass. A zero-argument pp closure called twice in the same
dynamic extent — the plan pass followed by verify's re-observe, or 2
services' bookkeeping inside one `apply` — has an unchanging captured
environment and ambient, so pp's ordinary thunk memoisation silently
replayed the first call's `perform` results on the second instead of
re-reading reality. This was invisible corruption, not an error: a
killed process still looked alive one call later, with no exception
raised anywhere. The fix reuses an existing mechanism:
`Domains.call_uncached` pushes a fresh, unique configuration-stack layer
before each observe or apply call, folding into the thunk key to
guarantee a distinct key per call. `diff` deliberately does not get this
treatment, since its memoisation is the plan cache and must stay keyed
on content. The general fix for a domain's own code calling a
zero-argument accessor more than once per pass is mechanical: read the
value once, then thread it through as an ordinary argument, since a
differing value changes the environment hash and so is immune by
construction.

Stratification: `:namespace` is a list of cell-id string prefixes the
domain owns — `["file:" ^ root; "tree:" ^ root; "stat:" ^ root]` for the
filesystem domain, `["proc:"]` for the process domain, empty for a
probe, since it has nothing to stratify. After root evaluation, core
scans `Runtime.observed_all` for each registered write-domain and
rejects on a prefix match, generalised from being hardwired to one
domain to being declared per domain. One change was load-bearing here:
collection into `observed_all` is suspended, for exception safety, for
the whole extent of a domain's own observe, diff, apply and verify steps
— otherwise a domain's own bookkeeping, such as its tree-walk, would
trip its own stratification check. The trace stack is not suspended, so
node caching inside a domain's functions keeps working.

Journaling keeps byte-compatibility. Core wraps every domain's apply in
a generic per-pass bracket, `intent <hash> k1=v1 k2=v2 ...` followed by
`done <hash>`, where the `k=v` fields are exactly the domain's own
`:summary` pairs joined in order, identical in shape to the pre-existing
line. The identity hash is not bit-identical to the old bespoke
desired-state hash — it is now
`H("domain-pass", name, hash(desired))`, a deliberate simplification —
but no test or tool depends on the hash's digits, only on the field
names and order. Per-service journal lines are unchanged, moved verbatim
into the trusted primitives `proc-spawn`/`proc-stop`.

Verify-after-write: core re-runs `observe` after `apply` and re-diffs
against `desired`, using the same cached-diff machinery — genuinely a
miss, since what was observed changed. A non-empty plan at this point is a
hard error: "reconcile: verify-after-write failed for domain `<name>`."
This check runs over the whole domain, deliberately stronger than the old
per-file inline check.

`Cell.Domain {name; sub}` (written `domain:<name>:<sub>`) is for
third-party domains only; the filesystem and process domains keep their
existing `File`, `Tree`, `Stat` and `Proc` kinds, so there is no
store-format change. Authorisation is a subset check of the registered
`write_cap` against the caller's held capabilities — no new authority
code, the same narrowing check `with-caps` uses. `:observe-cell (fn (sub)
-> hash|nil)` gives `Store.observe_cell` an O(1) targeted re-observation,
generalising the existing process-observer and probe-observer hook
pattern.

Driver wiring connects the protocol to the CLI. `--reconcile ROOT`
auto-loads `stdlib/domain-fs.pp` and registers it with a write capability
restricted to ROOT, wrapping the program's value as `{"fs" -> v}`.
`--supervise` does the same with `stdlib/domain-proc.pp` and `{"proc" ->
v}`; the 2 flags compose. A program that calls `register-domain` itself,
with neither flag set, returns `{name -> desired}` directly, supporting N
domains from one evaluation. One deviation from the obvious design:
the filesystem domain's write capability requests write-only, not
read-write access, because a write-only grant must still let
the domain observe its own managed tree in order to converge it — there
is no other reader, so this is not a distinct authority concern.
`src/reconciler.ml` and `src/supervisor.ml` are deleted;
`src/domains.ml` and `src/domain_prims.ml` hold the orchestration and
trusted mechanics that remain in OCaml (see `ARCHITECTURE.md`).
`stdlib/domain-fs.pp` and `domain-proc.pp` hold all the policy — the
tree-walk diff, the start/stop/restart decision — as ordinary pp source.

This decision has a direct consequence for how much of the system is
trusted: see the domain-authority edge below.

---

## Honest edges

Each of these is a real limitation, with a mitigation rather than a fix.

- fenced effects do not converge: they are sequenced, not tamed. Mitigation:
  fenced actions run only in the reconciler, with a per-pass epoch, a
  write-ahead log, and an unknown-status policy (see the at-most-once
  effects decision above). The residual is that an `:ask` policy
  reintroduces a human into the loop, which is acceptable; a silent
  double-send is not.

- domain authority is no longer concentrated in a small trusted module.
  Before the domain protocol was rewritten, the reconciler's code was
  small and the only code holding domain write capabilities. Now the
  trusted core is the journal, the fence, stratification, capability
  threading and verify-after-write; `observe`, `diff` and `apply` are
  ordinary, untrusted pp library code, bounded by exactly one threaded
  capability and the node boundary. The worst case is a domain
  mis-converging its own namespace, under authority it was granted: it
  cannot touch another domain's namespace, because of stratification;
  cannot smuggle authority across the node boundary; and cannot bypass
  the journal/verify bracket, since core wraps every apply in it
  unconditionally. The mitigation chain — a journal, atomic
  materialisation, verify-after-write, and convergence driven by reality
  rather than a trusted state file — is unchanged in spirit, now
  enforced around arbitrary domain code rather than one small trusted
  module.

- dynamic discovery means there is no static answer to "what will this
  touch". Mitigation: the capability ceiling is static and sound, backed by
  the last run's traces. Cycles are runtime errors that report the force
  path. This is an explicit trade against Bazel's stronger static
  analysability.

- some tools are not deterministic — `__DATE__`, timestamp linkers, address
  space layout randomisation. Mitigation: per-tool canonicalisation
  adapters, and a `--check` flag that double-builds and flags volatile
  nodes. A volatile result is treated as a cell, observed fresh each pass,
  rather than a node result, so its instability is contained at one edge
  instead of poisoning everything downstream of it.

- moving to strict evaluation breaks some lazy idioms. This was done at
  zero users, early in the project; `delay` and `lazy-seq` are retained for
  the cases that need them, and the change is documented in `SPEC.md`.

- the zero-dependency story ends somewhere: hashing, sandboxing, and file
  watching all need libraries. The chosen posture is to use dune and opam,
  accept first-party-quality opam dependencies, but keep the interpreter
  core itself dependency-light so the oracle stays auditable, and isolate
  dependencies behind `Runtime`.

- the cache can act as an authority or existence oracle. Mitigation: the
  transitive hit-time capability check (see the capability model above),
  plus capability-filtered `pp why` output. The residual risk is
  hash-guessing side channels, out of scope until pp supports
  multi-tenant caches.

- high-churn cells can thrash the push scheduler. Mitigation: cell-design
  discipline, watcher debouncing, and cutoff absorbing no-op observations.

- the coarse-cell fallback is not incremental. Until a tool has a depfile
  adapter, its nodes invalidate on any change anywhere in the mounted tree.
  Mitigation: sound by default, with precision added adapter by adapter,
  and `pp why` showing coarse versus refined reads.

- ambient environment reads (`$env`) trust the launching process. `$env`
  observes the process environment inherited from whoever launched pp.
  There is no path-traversal or confused-deputy surface here to defend
  against, because a variable name is not a resource locator — unlike
  `$file`, `$glob` or `$secret`, there is no way to spell a name that
  resolves somewhere else. The trust assumption is that the launcher
  controls the environment — the same boundary as `argv` and the loader's
  interpreter authority; pp does not defend against a hostile parent
  process. The blast radius is whatever the launcher exports. Containment:
  an `$env` read enters the trace as an `env:` cell whose observed hash
  distinguishes present from absent, so a changed or newly set variable
  re-keys correctly and can never silently reuse a stale value.

- volatile probe cells (`$probe`) can change between observation and use.
  A probe is observer-written volatile state, subject to a
  time-of-check-to-time-of-use window, and to clock skew between
  successive reads. pp does not freeze or defeat this; it contains it. A
  probe read is treated as a cell, re-observed each pass,
  never memoised as a node result, so its instability is confined to one
  edge and poisons no downstream cache (see `SPEC.md`, law 38). The trust
  assumption is that the observer writing the probe is trusted — the
  adversary here is nondeterminism, not a confused deputy. The blast radius
  is that a stale probe value forces a re-observe, never a wrong cached
  result.

- scoped configuration reads (`$config`) trust the code that installs the
  extent. `$config(key[, default])` observes an ambient configuration value
  installed by an enclosing `with { config: ... }` extent, not a filesystem
  resource. A configuration key is not a resource locator either, so, as
  with `$env` above, there is no path-traversal or confused-deputy surface
  to defend against. The trust assumption is that the code installing the
  configuration extent is trusted, since configuration is set by the
  program itself through `with-config`, not by an outside party. The blast
  radius is whatever the enclosing extent sets. Containment: a `$config`
  read enters the trace as a `config:<key>` cell — the ambient
  configuration itself is kept out of the node key, only the read keys are
  (see `SPEC.md`, law 33) — so a changed value re-keys its observers and
  can never silently reuse a stale result.

---

## Prior art: pp against its neighbours

- Unison: content-addressed definitions, abilities, and a distributed
  runtime. This is pp's closest relative. pp hashes computations and world
  observations instead — the store holds traces of runs — which is why
  incremental builds and reconciliation fall out of the same mechanism.
  pp is build-framed, dynamically typed and demand-pruned; Unison is a
  general-purpose, statically typed, strict language.

- Build Systems à la Carte (Mokhov, Mitchell and Peyton Jones): the
  load-bearing framing for this design. pp is one rebuilder — verifying and
  constructive traces, content-addressed cutoff, one store — with 2
  schedulers, a suspending pull scheduler and a dirty-propagating push
  scheduler. This is exactly the vocabulary that resolves the scheduler
  decision above.

- Nix and content-addressed derivations: a shared content-addressed store
  plus hermetic builds. pp has no separate evaluation and derivation
  phase — the derivation is the node, discovered by running it — native
  early cutoff, and dynamic dependencies, where Nix's language is
  build-time only. pp adopts Nix's model of a realisation as a key mapped
  to a set of traces.

- Bazel, with remote cache and execution: a declared, static action graph,
  giving strong analysis but weak dynamism. pp trades static analysability
  for discovered dependencies and a general-purpose language, while keeping
  Bazel's sandbox trick as a precision layer over a soundness floor.

- Incremental and Bonsai: the reactive donor for pp's vocabulary of vars,
  discovered dependencies, stabilise, and cutoff. pp is close to a
  persistent Incremental whose cutoff is hash equality and whose vars are
  the outside world, adding cross-process persistence on top.

- Adapton and self-adjusting computation: the theory behind the push
  scheduler's correctness, from-scratch consistency, used here as a
  specification to test against rather than a mechanism implemented
  directly.

- Salsa, Skyframe and Shake: engineering proof points for red-green
  cutoff, graph-per-key invalidation at scale, and monadic dynamic
  dependencies in production.

- Terraform and Kubernetes: the reconciler's lineage. pp differs by
  deriving desired state from a cached, incremental computation, and by
  refusing to trust a state file (see the crash-safety decision above).

---

## Rejected surface decisions

These decisions were settled during the July 2026 surface consolidation
(see `SYNTAX.md`) and are recorded here so they stay settled. Reviving any
of these requires overturning the reason given, not just preferring the
feature again.

- `:=` mutation, at any tier. This forks the semantics of assignment: a
  mutable slot's identity is the cell, not its content, and the
  code-hashing law cannot key on that. The lesson from Erlang's process
  dictionary applies — an escape hatch anywhere migrates code towards it
  under deadline pressure. If this is ever revisited, the ban on mutation
  inside a node body must be rejected at the reader level, not checked at
  runtime.
- `{key: value}` data map literals. `reconcile {}` is identity sugar over
  the ordinary map literal (see `SPEC.md`, law 61): desired state is an
  ordinary map, and a second map notation would invent a distinction the
  runtime does not have. A colon is grammar, used for closed clause
  headers, annotations and keywords; an arrow is data.
- postfix `?` for error propagation. `?` is a name character carrying the
  predicate convention already; a postfix operator would make it mean 2
  different things at adjacent call sites. Rust's `?` is also a false
  cognate here, since it implies `From`-style error coercion that pp cannot
  offer. `<-` inside `try {}` is the one spelling for this.
- a `collect {}` block form. Statement-level accumulation was confusing
  enough that the design's own flagship example contradicted its own
  implementation. `collect` stays a function; the distinction between the
  monad form (`try`) and the validation form (`collect`) lives in the
  library, not the grammar.
- function clauses, meaning multiple `def`s sharing one name. This
  duplicates `match`, needs a multi-pass block parser, and special-cases
  exactly the duplicate-name invariant the language otherwise enforces (see
  `SPEC.md`, law 4). One dispatch primitive is enough.
- `@` attributes, such as `@cache`, `@needs`, `@reads` or `@deprecated`.
  `@cache def` would just be a second spelling of `node`, and the central
  abstraction deserves exactly one name, structural rather than inferred,
  following Unison's precedent. An `@needs` that parses without narrowing
  authority would be a lie in a capability language.
- `cond {}`. Subsumed by flat `else if` chains and `match` with guards, and
  removed rather than deprecated, since it was only weeks old.
- comprehensions, such as `[f(x) for x in xs]`. This is a second grammar
  for what a pipeline of `filter` and `map` already does, and reveals no
  domain concept pipelines lack. Pipelines are pp's comprehension.
- dot-method calls, such as `x.f(args)`. A dot is a name character, so this
  form would silently parse as a call to a global function literally named
  `x.f` — a trap, not a feature. `|>` is pp's method syntax; identifiers
  containing a dot outside grant descriptors are linted against.
- cell-literal observations, such as `file:"P"`, `env:"N"` or `tree:"R"`. A
  single fused string token cannot spell a default, such as
  `$env("CC", "gcc")`, or a computed path, and an observation is an
  operation, not a literal. These were removed in favour of the `$` family,
  and `pp fmt` rewrote existing uses in a hash-preserving way.
- a second observation notation, ever. The world-reading surface is only
  auditable if there is exactly one thing to search for. New kinds of
  observation join as new `$` heads, not a parallel notation.
- call-site node markers. Node application and function application are
  deliberately identical at the call site (see `SPEC.md`, law 6); a marker
  would advertise a difference that does not exist there, and would tax
  every refactor from `def` to `node`. A `node` keyword at the definition
  site, plus `pp why`, is the audit surface instead.
- multi-shot effect resumption. Re-entering a `perform` twice has no answer
  to which trace entry the second resumption should write, in a linear
  trace log. One-shot resumption, checked dynamically, is the near-term
  target; multi-shot waits for a linearity story, following OCaml 5's
  precedent.
- a declaration syntax for algebraic data types. `[:ok, v]` and `[:err, e]`
  form a checked convention — matched tagged patterns plus a linter — not
  a type system. Static sum types are a different project.
- implicit string interpolation. Every string becomes a parser in a
  language that generates code for other languages, which is a landmine.
  Interpolation requires the `f` prefix.

---

## Appendix: a 2-file C build, traced through the model

2 source files, `a.c` and `b.c`, both include `shared.h`.

### The program

A sketch of the current surface, showing capability attenuation:

```
node compile(src) {                       # key = H(compile-code, hash "src/a.c")
  with-caps(cap-compose(cap-restrict(current-capabilities(), "src", :ro),
                        cap-restrict(current-capabilities(), "toolchain", :ro))) {
    perform run("cc", ["-c", src, "-o", scratch(".o")], :inputs, [src])
  }
}
                                           # sandbox + depfile refine the trace
node link(objs) {                         # key = H(link-code, [child result hashes])
  with-caps(cap-restrict(current-capabilities(), "toolchain", :ro)) {
    perform run("cc", concat(["-o", scratch("app")], objs), :inputs, objs)
  }
}
node app() {
  let (srcs = perform list-dir("src", "*.c")) {   # observes glob:src/*.c
    link(map(compile, srcs))
  }
}
{"build/a.o" -> compile("src/a.c"),
 "build/b.o" -> compile("src/b.c"),
 "build/app" -> app()}                    # desired-state root: {path → blob-hash}
```

Each `with-caps` here narrows the ambient set — arriving through `--grant`
— for exactly the node body's extent, fixed at that `node { e }`
occurrence's creation per the capture rule above, not re-derived from
whatever is ambient when the node is later forced.

### Cells and the first, cold build

Input cells: `file:.../src/a.c` = h_a, `file:.../src/b.c` = h_b,
`file:.../src/shared.h` = h_s, `glob:src/*.c` = h_m (a header edit does not
dirty this manifest), `toolchain:cc` = h_cc.

`pull.force(root)` calls `app`, which calls `list-dir` and records
`(glob:src/*.c, h_m)`, then calls `compile("src/a.c")`. The first
observation of each input ingests its bytes into the content-addressed
store (see the effect-ordering decision above); `cc` runs in the
read-only sandbox, and the depfile refines the trace below the coarse
ceiling. This is stored, as one member of the key's trace set:

```
K_ca = H(compile-code, H "src/a.c") →
  { result: h_ao,
    reads:  {file:src/a.c=h_a (user), file:src/shared.h=h_s (user),
             toolchain:cc=h_cc (toolchain-closure)},
    outcome: ok, closure-cap-req: {read src/, toolchain} }
```

`K_link = H(link-code, [h_ao, h_bo])`. The reconciler observes `tree:build/` = empty
(a downstream observation, not a node input), materialises 3 blobs through
a temp file and rename, verifies, and journals the pass complete. A null
rebuild after this runs zero processes, since every trace verifies.

### Rebuild 2: editing shared.h

h_s changes to h_s′. Both `K_ca` and `K_cb`'s traces contain
`file:src/shared.h=h_s`, so both are stale and recompile, producing
h_ao′ and h_bo′; `K_link` re-keys on `[h_ao′, h_bo′]` and runs again. The
glob manifest is unchanged, so there is no spurious re-expansion of the
graph.

A comment-only header edit gives a smaller result: h_s′ still differs
from h_s, so both compiles re-run, but `cc` emits byte-identical objects,
so h_ao is unchanged — a cutoff. `K_link`'s argument hashes are
unchanged, so link never runs, and the reconciler's diff is empty.

### Rebuild 3: editing only a.c

`K_ca` goes stale and recompiles. `K_cb`'s trace still verifies, so `b.o`
is not recompiled. `K_link` re-keys and runs. The reconciler writes exactly
`build/a.o` and `build/app`. If the edit adds `#include "extra.h"`, the
depfile-refined trace simply gains `file:src/extra.h` — dynamic discovery,
with no separate declaration step.

### What the trace found and fixed

- identity and validity are different things. Keying on `hash(expr,
  full-env, caps, config)` leaks: any change to an unrelated global or the
  standard library rebuilds everything, and a widened capability grant
  rebuilds everything. The fix is to key on code plus argument value
  hashes, and keep validity as the trace set — the single most important
  divergence from earlier code.
- capabilities move out of the key and into a transitive check at hit time
  (see the capability model above).
- capabilities are captured at node creation, not read from the dynamic
  stack at force time, since a watcher can force nodes far from any
  lexical capability block (see the effect-ordering decision above).
- the snapshot equals the content-addressed store's ingest, which makes
  torn reads impossible (see the effect-ordering decision above).
- cell boundaries are part of the program's API: the glob had to be
  scoped to `*.c` for a header edit not to dirty the generator.
- link's keying implies strict child forcing, which is what motivated
  call-by-value application in the first place (see the strictness
  decision above).
