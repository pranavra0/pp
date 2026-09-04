# pp SPEC: the semantic laws

> Law statements with status markers; design rationale lives in
> [DESIGN.md](DESIGN.md), current limits in the Appendix A table. Markers:
> - holds: satisfied within the tested scope cited for that law.
> - partial: mechanism exists but is buggy or incomplete; the status cites
>   the gap.
> - unimplemented: a target only.
>
> `tests/072-law-pins.sh` fails the build if a holds law has no
> `# pins: LAW-<n>` marker in some test and no pending-backfill entry, or if
> a pin names a nonexistent law.

## The two tiers

- the node tier: pure, strict at node boundaries, content-addressed, cached,
  and distributable. A node (`node` / `defnode`) is the unit of persistence
  and caching; to be cacheable it must be pure and analyzable.
- the scripting tier: dynamic, imperative, REPL glue. Uncached, unkeyed,
  unrestricted — free effects live here.

The bargain connecting them: purity is the price of a cache hit. A cache hit
means the node does not run, so a cached node must not perform uncontrolled
shared-state writes; caching is opt-in per node. Node-visible runtime inputs
are closed (LAW 16, LAW 18): capability inspection, runtime manifests, and
fresh-name allocation cannot silently vary a cached node
(`tests/109-node-ambient.sh`).

---

## 1. Binding and scope: the centrepiece

A binding form whose meaning depends on the textual order of its bindings
would smuggle positional order back into the core. Two independent axes are
in play; conflating them is how languages get this wrong:

- scope: which bindings can see which others
- timing: when does each binding's value get computed

### [LAW 1] A scope is a local DAG: `let` bindings are mutually visible

In `let (a = e_a, b = e_b, …) { body }`, every binding name is in scope in
every right-hand side and in the body, regardless of textual order. A `let`
is a local Excel sheet: a set of named cells that may reference each other
freely, without regard to position.

**Status: holds**: the engine builds a mutual environment for `ELet`
bindings; sibling references evaluate correctly and reordering independent
bindings does not change the result (`tests/007-phase0-laws.pp`).

### [LAW 2] Evaluation order within a scope is derived from dependencies; genuine cycles are force-time errors

The runtime computes bindings in an order derived from their actual
references, not their positions. A dependency cycle among bindings is a
runtime error at force time, reporting the cycle, unless the cycle is
mediated by a function value: a lambda delays demand, so mutually recursive
functions are legal and ordinary, as in Haskell and at pp's own top level.

Timing: local `let` bindings are ephemeral — never persisted, keyed, or
stored — so they are free to be lazy on-demand thunks regardless of the node
tier's strictness (LAW 6). Node-level strictness protects cached nodes; a
local binding is not one. An unreferenced binding never runs.

**Status: holds**: force-time cycles are reported from the active force path,
including the binding names (for example `a -> b -> a`). Function values still
delay demand, so mutually recursive functions remain valid.

### [LAW 3] Binding order is not part of a computation's identity

Two `let` forms that differ only in the textual order of their bindings
denote the same computation and must have the same content hash: the code
hash canonicalises binding sets.

**Status: holds**: the expression hasher sorts the named bindings of a
mutually visible `let`; `let*` and statement-bearing scopes retain source
order.

### [LAW 4] One scope model everywhere: `let` = `do`-block `def`s = `module` = top level

A scope (local `let`, a `def` block, a module body, the top level of a
program) is one thing: a set of mutually visible DAG nodes ordered by
dependency. Top-level `def`s already behave this way, since later `def`s are
visible to earlier bodies. LAW 1 extends the same model downward so the
language has one scoping story, not three.

Value defs. A definition binding a bare name to an expression (AST
`EDefValue`; s-expression surface `(def x v)`, brace surface `let x = v`) is
a value binding: the right-hand side evaluates when the definition executes,
and `x` binds to the result, never to a nullary closure (`tests/025` closed
that early footgun). Evaluation does not force: a value def whose right-hand
side is a `delay` form binds the unforced thunk, and a name-binding `defnode`
is exactly a value def of the node thunk: `EDefValue (x, ENode e)`, whatever
the surface. Scope follows LAW 4, with statement timing:

- blocks (`do` bodies, multi-expression `fn`/`def` bodies, modules) are
  letrec*: every def name, function or value, is visible to the whole block.
  A value demand that runs before its defining statement has executed raises
  `<name>: referenced before its definition`; function definitions are
  callable throughout the block. Defining the same name twice in one block
  is a read error (`duplicate definition in block`).
- the top level is processed form by form: a value def's right-hand side is
  still evaluated at its statement, but all names are already in scope. A
  demand on a later value def therefore reports that named binding as
  referenced before its definition. Function defs are available throughout
  the scope, so top-level mutual recursion between functions is ordinary.

Exception: `try {}` `<-` bindings are sequential, and rebinding shadows. A
`try {}` block is not a letrec* scope: its `<-` bindings execute top to
bottom, each visible only to statements after it — a `<-` right-hand side
sees earlier binds, never later ones, so there is no mutual visibility to
poison. Because the block lowers to nested `let`s, binding the same name
twice is allowed: the second `<-` shadows the first for what follows, exactly
as re-`let`-ing in nested lets would. This is the one place LAW 4's
duplicate-definition rule does not apply. Pinned by
`tests/065-try-rebind-shadow.sh`, which rebinds a `<-` name twice and checks
later uses see the shadowing value.

**Status: holds**: top level, `do` blocks, and modules predeclare the same
binding set before executing statements. Function bindings are available
throughout that scope; value bindings retain statement timing and report a
named "referenced before its definition" error when demanded early. Modules
remain fresh scopes, while `let*` remains explicitly sequential.

### [LAW 5] `let*` survives only as explicit sequential sugar

`let* (a = e1, b = e2) { body }` is the scripting-tier form for "I really do
mean a sequence": shadowing, staged reads, REPL work. Because mutual `let`
makes every right-hand side visible to every other right-hand side in the
same binding set, `let*` is implemented as a distinct sequential form: each
right-hand side is compiled in an environment that contains only the
preceding bindings, and the body sees the final binding. The default, and the
primitive form, remains mutual `let`.

**Status: holds**: the reader emits `ELetStar`; the evaluator handles it
sequentially and tests pin shadowing (`tests/007-phase0-laws.pp`).

---

## 2. Evaluation: strict nodes, pruned demand

The README once claimed "every expression is a thunk; the DAG emerges from
laziness". Retired: the DAG is the demand-pruned wanted-set defined by the
root desired-state formula, shaped like Bazel's. Fine-grained laziness bought
a class of stack overflows, an allocation storm, an unsound cache key, and
effect-escape hazards, for no build-relevant benefit. What survives as
"laziness" is demand-pruning and skip-on-hit, at node granularity.

### [LAW 6] Node application is call-by-value with memoization

A node's arguments are forced before the node's body runs, because the node's
key is `H(code-hash ‖ arg-value-hashes)` (LAW 15): the key cannot exist before
the argument values do. Within the node tier, application is strict, and
results are memoized by key.

**Status: holds**: `node { e }` and applied `defnode` computations memoize
persistently under the LAW 20 key. Node arguments are forced before the body,
and equal applications share one computation across processes.

### [LAW 7] Laziness is demand-pruning at node granularity

Only nodes reachable from the root's desired-state value are ever forced. A
forced node may expand into many: a glob manifest can define 50,000 compile
nodes; unchanged ones hit the cache, undemanded ones never run. LLVM's build
as one thunk expanding into 50,000 units on force survives — at node
granularity, not per expression.

**Status: holds**: the fully forced desired object plus the node keys used to
derive it form the explicit wanted root. Push watch selects affected work
through child-result edges while pull watch reconstructs keys from pinned
source and island values in a fresh process. Cache validation, stabilization,
transport, and GC use the same child/result/tree edges (`tests/032`,
`tests/050`, `tests/101`).

### [LAW 8] `delay`/`force` is ephemeral, in-memory laziness: a different thing from `node`

`delay(e)` makes an ephemeral thunk: computed at most once per process, never
persisted, never keyed into any store. `force` is idempotent and is the
identity on non-thunks. Lazy sequences (`lazy-seq`, stdlib `cons` chains)
live here. `node` is persistence; `delay` is timing.

**Status: holds**: `node { e }` persists to `~/.pp/store` while `delay` and
local bindings are fresh, in-memory thunks. Only persistent node thunks use the
session's content-addressed deduplication table.

### [LAW 9] `if` evaluates exactly one branch

The untaken branch of a conditional is never evaluated: no effects fire, no
errors raise, and no nodes are demanded from it. `and`/`or` inherit this by
desugaring to `if`.

**Status: holds**: the explicit heap-continuation evaluator forces the
condition before entering exactly one selected branch; focused language tests
cover this boundary.

### [LAW 10] Tail calls run in constant stack

A tail-recursive computation runs at unbounded depth (at least a million
calls deep) without stack growth.

**Status: holds**: the heap-continuation evaluator and CPS-aware
dynamic-scope frames keep recursive calls through `with-caps`,
`with-handler`, and `with-config` bounded in native stack and linear in depth
(`tests/007-phase0-laws.pp`, `tests/110-tail-scopes.sh`).

### [LAW 11] Non-tail depth is a heap problem, not a crash

Non-tail recursion, such as the standard library's `map` over a
million-element list, completes without native stack overflow: evaluation
uses an explicit heap-allocated work stack.

**Status: holds**: the evaluator always uses its heap-allocated continuation
machine. Builtin list traversal is iterative, so evaluator and primitive
frames both remain bounded.

### [LAW 12] Quotation is total; the language is data

Every form a reader accepts, whichever surface it parses, `quote` can turn
into a value, and quasiquote/unquote work over that structure. Quotation is
defined against the AST (`Core_model.expr`), so every surface shares one
quoted-data language. A Lisp whose quoted conditional (`'(if a b c)`) crashes
is not homoiconic.

**Status: holds**: `quote_to_value` handles all expr forms; the reader
parses quasiquote/unquote/unquote-splicing and a runtime walker expands them,
including splicing, nested quasiquote, vectors, and maps. `defmacro` receives
argument forms as quoted data, computes over them with
`quote`/`quasiquote`/`list`/`cons`/`gensym`, and converts the result back to
syntax; its shape is recognised structurally at the single expansion point
before the evaluator and expression hasher consume it, so every reader
surface shares the same macro semantics.

---

## 3. Effects and ordering

### [LAW 13] Effects are strict within `do` and fire in program order

Each step of `do { e1; e2; …; en }` is forced to completion, in order, before
the next begins; `en`'s value is the block's value. A `perform` fires eagerly
when its expression is evaluated. `do` is the sequencing form, the one place
where program order is the semantics, by explicit request.

**Status: holds**: the evaluator forces every `do` step; focused process tests
verify the deterministic effect stream for each program.

### [LAW 14] Undemanded values fire no effects

Outside `do` and node boundaries there is no program-order guarantee: an
effect embedded in a value that is never demanded never fires. One embedded
in a demanded value fires when demand reaches it. If you need an effect to
happen, sequence it in `do` or make it a node input; do not rely on the
evaluation order of pure positions.

**Status: holds** for the current thunk semantics: an unforced binding's
`perform` does not fire. Its interaction with LAW 6's strictness follows by
construction, since node arguments are demanded.

### [LAW 15] Ordering never comes from capabilities

Capabilities answer "may this computation touch X", never "in what order do
writes happen". Ordering comes from data flow (a consumer forces its
producer) and from the single-writer reconciler (section 9). No law in this
spec may be enforced by making a capability linear, affine, or consumable.

**Status: holds** as a constraint on current code: capabilities play no
ordering role anywhere in the implementation, and the single-writer
reconciler enforces ordering through data flow rather than capability
consumption (`tests/018`, `tests/023`, `tests/033`). Capabilities remain
authority and security only.

---

## 4. Purity and caching: the bargain

### [LAW 16] Purity is the price of a cache hit; caching is opt-in per node

Only nodes are cached. A node must be pure up to its declared effects: no
uncontrolled shared-state writes, no unrecorded reads. Code that refuses the
bargain lives in the scripting tier: uncached, unrestricted, unsurprising.

**Status: holds for the provider-classified contract**: `node { e }` is
opt-in and cached persistently: the same
node forced in two processes runs once, the store serves
the second, and a scripting-tier expression is never cached (`tests/010`,
`tests/014`). `$glob` records the tree snapshot it returns (`tests/100`).
Node writes are confined to per-node sandbox scratch and absolute node writes
error (LAW 18, `tests/017`). Ambient `run` is scripting-tier only because it
cannot produce a complete trace. `run-closed!` accepts an immutable request
through a session-owned executor. Tools, inputs, and selected outputs use the
canonical ordinary tree value; every file is backed by a hash-verified blob.
Evidence and resource maps are canonicalized independently of provider ordering.
The bundled Linux provider materializes the declared tool and input trees in a
private working directory and supplies only the request's explicit environment
to its direct child. This is not OS namespace isolation: absolute filesystem
access, the ELF interpreter and shared-library loader, network access,
subprocess creation, and other kernel interfaces remain host-mediated. It
reports clocks, randomness, CPU/kernel behavior, and resource limits as
ambient, so it classifies every request as scripting-only. The runtime rejects
such a request inside a node before execution.
The executor interface can instead classify a request cacheable, which is the trusted guarantee that every semantic input is accounted for;
the runtime then permits it in a node. The optional `:policy` field is
canonical ordinary pp data; the runtime preserves it but interprets none of it
(`lifecycle_unit`, `tests/102`). Thus no cacheable foreign process runs without
an explicit provider guarantee.

### [LAW 17] A cache hit does not replay ephemeral effects

A hit returns the stored result; `log`/stdout emitted during the original run
are not re-emitted. A hit and a miss may differ only in ephemeral output and
wall-clock time. Any observable difference beyond that is a caching-soundness
bug.

**Status: holds** (for the node tier): a `node { e }` hit serves the stored
result and does not re-emit the `log`/stdout produced on the miss. This is
verified by the persistent-node tests (`tests/010` and `tests/014`), where a
node's in-body `COMPUTE` log fires only on the miss.

### [LAW 18] A cached node's writes are sandbox-scratch only

Inside a node, `write-file` targets a sandbox-local scratch path; only output
blob hashes escape. Writes to any reconciled domain go exclusively through
the reconciler (LAW 28). In the scripting tier, `write-file` is free.

**Status: holds**: the node/scripting split and output boundary are enforced.
Inside a node, a relative `write-file` targets the node's sandbox scratch, a
lazily created temp directory deleted when the node's frame pops; reads and
writes there are capability-free and unrecorded. An absolute `write-file`
errors, even with a read-write grant. The scripting tier is unchanged
(`tests/017`). The reconciled-domain write path is now generic: filesystem and
process domains apply desired state through the single writer
(`stdlib/domain-fs.pp`, `stdlib/domain-proc.pp`), while a tool's own absolute-
path writes remain outside the sandbox's control.

---

## 5. Content-addressing and cutoff

### [LAW 19] Value identity is a content hash, and equal hashes mean equal values

Every value has a deterministic content hash; identity is structure, not
position or time. The hash function must make collisions cryptographically
negligible (this project uses SHA-256) and must cover everything
semantically part of the value, in particular, a closure's hash covers its
captured free-variable values.

**Status: holds.** Closure captures are folded into the hash so two closures over
different referenced captures hash differently while unrelated environment
bindings are ignored, and the ambient handler stack is
folded in too. Stored values are content-addressed by result hash and shared
across runs. Persistent computation identity is LAW 20; ephemeral memo tables
need not be durable.

### [LAW 20] Node key = H(code-hash ‖ arg-value-hashes); authority and handlers are not identity

A node's key covers exactly its code, with free variables resolved to the
hashes of their values, and its argument value hashes. Not in the key: the
capability set (authority is checked at hit time, LAW 23), the handler stack
(LAW 26/27), or the ambient environment beyond referenced free variables.
What a node reads during execution is recorded in its trace, and that governs
validity, not identity.

**Status: holds**: the persistent node key is
`H(code-structure ‖ free-var value-hashes ‖ argument-value-hashes)`. The free
variables the node references are resolved, forced call-by-value, to their
value hashes from captured frames and globals — no whole-environment hash —
giving data-valued free variables a stable key so store entries are shared
across runs.
The two catastrophic leaks this law names are closed: rebinding an unreferenced
global is a cache hit, and widening the grant does not invalidate anything
(`tests/011`, `tests/014`, `tests/097`). Config and the handler stack are now fully out of
the key: a config read or a perform inside a node records a `config:`/
`handler:` trace cell instead (LAW 33/26, `tests/015`).

`defmacro` needs no change to this law. The expression hasher consumes an
already expanded tree; expansion is the one shared step every top-level form
passes through before the evaluator sees it (REPL and source-loader paths).
The code hash includes the expanded form: editing only the macro's own
definition changes the expanded code, hence the key, hence forces a recompute
(`tests/042-defmacro-rekey.sh`).

The node boundary is symmetric: authority may not cross it in either
direction. Once capability values exist (`current-capabilities` and related
forms), a node's free variables and its result are both potential smuggling
routes, so both are banned outright, independently of each other.

- import side (the free-variable ban): if a node's free variable's forced
  value contains a `VCapability` anywhere in its structure, including inside
  a captured closure's environment or frames, `node_key_of` raises
  `Capability_error` naming the variable rather than keying on authority. A
  capability hidden behind an unforced thunk is a documented gap — LAW 14
  forbids forcing it just to check — and the use-time gates in LAW 22b and
  LAW 23b are the actual floor for that case.
- export side (the result ban): if a node's result contains a `VCapability`,
  `run_node_body` raises `Capability_error ("a node may not return a
  capability")` before anything is stored. Otherwise `node {
  current-capabilities() }` would be an ambient-dependent result invisible to
  both key and trace, and a broad capability could ride a cached result out to
  a caller narrower than the node's creator.

### [LAW 21] Cutoff is hash equality; validity is the trace, not the key

If a recomputed node's result hash equals the prior result hash, dependents
are not dirtied, even though an input changed. A cached result is valid only
if some stored trace's every `(cell, hash)` observation still matches; one
key may hold many traces, for example from different observed toolchains or
platforms.

**Status: holds**: each node key maps to a set of traces; every trace records
the `(file-cell, content-hash)` observations the node made, plus `config:` and
`handler:` cells (LAW 33/26), and a hit is granted only if some trace's every
observation still matches the world. Editing a file invalidates the node,
reverting re-matches an older trace, an unchanged file hits, and a touch
(mtime only) is a non-event (`tests/010`, `tests/016`). The cutoff half is
real at node granularity through LAW 20's keying: when a recompute produces a
byte-identical result, a downstream node keyed on that value re-keys
identically, so the compile re-runs but the value-keyed link hits
(`tests/016`). Nested traces contain child-result cells instead of copying
the child's world reads; the cells use the durable child node key, so a fresh
process can recursively validate a parent hit and reconstruct a stale inline
child by rerunning the parent (`tests/032`, `tests/101`). Push stabilization
dirties direct trace readers first; an evaluated parent checks its
child-result cells and is dirtied only when a child result hash changes.
`$glob` records an exact tree cell, `run` records the resolved tool binary
plus coarse readable-tree cells; changes and reverts are covered by
`tests/100`. Legacy `run` dynamic-library closure tracking remains coarse.

---

## 6. Capabilities

### [LAW 22] Capabilities are unforgeable and enter only at the root

There is no expression that creates authority. `main` receives a powerbox
from the command line (`--grant ...`), and that is the sole mint. User code
holds capabilities, passes them, narrows them with `cap-restrict`, and unions
what it already holds with `cap-compose`; it never constructs one.
`filesystem("/", :rw)` is an unbound symbol, not a value.

**Status: holds**: `filesystem`/`network`/`process` and similar names are
unbound symbols; only `--grant` at process startup mints capabilities.
`cap-restrict` and `cap-compose` only narrow or union capabilities the code
already holds. `CapNetwork` is now `{host; port option}`, a shape change from
the earlier bare `{protocol}` (`--grant net:<host>[:<port>]`; `host = "*"`
wildcards, and an unspecified port is unrestricted). `CapSecret {path}` is a
newer kind (`--grant secret:<path>`, canonicalised at mint like filesystem
grants). Both mint only via `--grant`, the same as every other kind, adding
kinds does not change the root-mint invariant.

### [LAW 22b] `with-caps` narrows to a held value, never widens

`current-capabilities()` reifies the ambient set as of the call: an
observation of the ceiling the code already exercises on every `perform`,
never a mint. `with-caps(cap-expr) { body }` replaces the dynamic ambient
with exactly `cap-expr`'s value for `body`'s extent, gated by a subset check.
The check runs against the ambient live at the `with-caps` form, not the
process's root grant, so narrowing composes even when some in-scope binding
lexically retains a broader value. `cap-restrict`'s optional mode argument is
symmetric: requesting a mode wider than what the underlying capability grants
at that scope is `Capability_error`, never a silent widen. The prior
capability-union `effect` form is removed: with capability values in the
language, union-with-ambient is a widening backdoor and cannot sit alongside
`with-caps`.

**Status: holds**: `current-capabilities`, `with-caps`, and `cap-restrict`'s
mode argument are implemented. The subset check evaluates per capability kind
via the per-kind check functions LAW 25 describes, with `CapRestrict`'s
authority computed as its effective `(path, mode)` grants — scope/mode
intersection with the underlying capability, not a mint. `with-caps`
establishes a dynamic extent restored on every exit: normal return, tail
call, raised exception alike (LAW 27). It runs the body via a nested call
wrapped in a real exception handler — specifically so a raised error still
restores the ambient.

### [LAW 23] Authority checks are component-wise, full-path, and transitive at hit time

Three requirements apply. Path scope matching is by path component on the
canonicalised full path, so a grant of `/tmp` covers `/tmp/x` and never
`/tmpevil`. A cache hit is granted only if the caller's capability set covers
the transitive read closure of the stored trace: every cell read by the
node, and recursively by every child node, so a narrow caller cannot
launder a broad read through an aggregating parent, for example
`PUB = f(SECRET)`. Introspection surfaces, such as `pp why` and other
hit/miss observability, are capability-filtered, because the mere existence
of a key is itself an oracle.

**Status: holds**: path checks are component-aware and full-path (`/tmp` does
not grant `/tmpevil`), and the full path is uniformly canonicalised first:
`World_path.canonical` (absolute realpath, symlinks resolved, no trailing
slash) runs at every `file:`/`tree:`/`stat:`/`tool:`/`runtime:file:`
construction site, at `--grant` parse time, and at the loader bound
(`Loader.authorized`). `Capabilities.path_grants` re-applies it to both sides
of every scope check, so a grant spelled one way authorises a cell observed
another way — a symlinked source tree, macOS `/var` versus `/private/var`, a
trailing slash (`tests/036`).
A path that does not yet exist canonicalises its longest existing prefix and
appends the rest lexically, so a write-target's cell id is stable before and
after creation (`tests/036`); components otherwise keep host byte identity.
The transitive-closure requirement holds: a hit is served only if the
caller's capabilities cover every cell in the stored trace's read closure,
and reads propagate to enclosing nodes, so a narrow caller cannot launder a
broad read through a cached aggregator (`tests/013`, `tests/014`).
A capability denial raises the distinct `Capability_error` and is deliberately
not memoized — authority is not identity or validity (LAW 15) — so granting
the capability later still yields a hit.
`pp why` explains each node's hit or miss (first build, stale cell,
unauthorized, verified trace) to stderr and redacts cells outside the caller's
authority (`tests/019`).

### [LAW 24] Loader reads are runtime authority, not user effects

`load`, `import`, `island`, and standard-library and module resolution are
the loader's own reads, bounded to the program's source roots and the store.
They run under the interpreter's runtime authority, are tagged `runtime` in
traces, and are excluded from user capability accounting, both at perform
time and in the hit-time closure check.

`island` is a genuine resolve: the form's inline 64-character hex pin names
an immutable, verified tree in the island cache, and the mapping from URI to
pin is identity: it lives in the code hash (LAW 20), never in a trace cell.
An unpinned island form is a hard error. Fetching new pins (`git:`/`github:`)
is opt-in runtime authority (`--fetch-islands`/`--update`, journaled; see
docs/THREAT-MODEL-islands.md), so with it disabled, evaluation never touches
the network.

**Status: holds**: every loader read goes through `Loader.read`: bounded to
the directories of the programs named on the command line, the working
directory, and `~/.pp`. Loading anything else errors, with or without a
grant.
Each read is recorded as a
`runtime:file:<path>` trace cell that participates in cache validity (
editing a loaded module invalidates the nodes that loaded it), while being
exempt from the hit-time authority requirement (`tests/020`). The bound is
now realpath-canonical (LAW 23, `tests/036`): a symlinked source tree is
authorised identically to the real path.

### [LAW 25] Unenforced authority may not exist

A capability kind that nothing enforces (`CapTime` and `CapMemory` today)
must not appear in the surface language. Resource budgets return only when a
scheduler enforces them.

**Status: holds**: `CapTime`/`CapMemory` have been removed from the
capability type and surface language.

---

## 7. Handlers

### [LAW 26] Two handler classes: result-transparent and semantic

Result-transparent handlers, such as the schedulers covering placement, may
change only where or when work runs, never observable results. They cross
node boundaries freely and appear in no key and no trace. Semantic handlers (
a mock `read-file`, fault injection, an alternate `run`) change meaning:
each intercepted `perform` inside a node records a synthetic trace cell
`handler:<effect> → handler-identity`.

**Status: holds**: every `perform` inside a node records a `handler:<effect>`
trace cell whose observed hash is the intercepting handler's value hash, or a
builtin marker when none intercepts, re-observed against the caller's handler
stack on a hit. So a node cached under a mock `read-file` and one cached
under the real builtin coexist as two traces under one key and never
cross-contaminate (`tests/015`). The result-transparent class is implemented
by the scheduler's opaque handler service. A handler supplies
only a name, redundant width, best-effort miss dispatch, and cancellation; it
cannot replace key construction, hit authorization, or rebuilding. The
host-provided serial/parallel/race/remote handlers are excluded from node
identity and traces; scheduler stress covers their result transparency
(`tests/038`), and the kernel property
suite checks installation, cancellation, redundant width, and session
isolation.
`http-get`/`http-post` are newer builtin semantic-class effects, dispatched
through the same `perform_effect`/`handler:<effect>` machinery as
`read-file`/`run`; no new handler category. Network and process builtins are
banned inside node bodies outright by a trace-stack guard shaped like
`fenced`/`write-file`'s node-body ban, rather than given a trace cell: a
network read is not the declared-nondeterminism mechanism (LAW 37/38's probes
are) and is not convergent, so it has no sound node-cached meaning. It is
legal only in probe observe functions, domain observe/apply functions, and
the scripting tier.

### [LAW 27] Effect, handler, and config scopes are dynamic extent: exception-safe and tail-safe

`effect`, `with-handler`, and `with-config` establish dynamic-extent state
restored on every exit: normal return, tail call, raised error alike. Scope
state never leaks out of the form that established it.

**Status: holds**: `effect`, `with-handler`, and `with-config` now restore
capabilities, handlers, and config on normal return, exception, and tail
call. Handler invocation saves and restores the operand stack.

---

## 8. Errors

### [LAW 28] An evaluative failure is a value with a trace

A node that reaches an evaluative failure stores a failing trace: the result
is the error's hash, and the outcome is marked failed. A later force with
unchanged inputs re-serves the failure without re-running; changing its
validating trace permits re-execution. Authority denials and internal host
exceptions are not computation results and are never cached.

**Status: holds**: successful and failing outcomes use the same object and
trace persistence path. Evaluator and operational errors retain the reads made
before failure and are re-served until that trace changes; authority-dependent
errors reset the thunk without persisting. A raising thunk cannot retain an
`Evaluating` marker (`tests/012`, `tests/014`, `tests/103`).

### [LAW 29] Errors carry structured source diagnostics

A runtime error carries a structured diagnostic with an optional source range,
stable error code, message, and related ranges. Source ranges use a source
name, byte offset, and one-based line and column positions; ranges are
half-open. Human-readable rendering is a CLI presentation concern.

**Status: holds**: every reader attaches token-precise ranges to its
`ELocated` forms, and the shared error boundary fills an absent primary range
without inspecting formatted message text. Reader, evaluator, and capability
errors carry stable codes and can be converted to LSP-compatible diagnostics.
The CLI continues to render one clean `pp: error: …` line with exit code 1.

A loaded file's forms are ranged against that file, not the loading form:
`read-source` reads it with its own path, each top-level form is evaluated
one at a time under the same never-doubled range decoration as the outer
driver, and an error inside the loaded file is decorated with its own range
before unwinding past `load`.

---

## 9. Desired state and the single-writer reconciler

### [LAW 30] Program = pure function from input cells to a desired-state value; the runtime is the single writer

For observable, convergent domains, such as an output tree or a process set,
a pp program computes and returns a desired-state value: `{path →
blob-hash}`, `{proc-name → spec}`, a pure, hashable, diffable value. It
performs no domain writes. The reconciler, the one privileged writer per
domain, diffs desired against observed cells, applies the minimal change,
and verifies after the write. A single writer means no write-write races,
which means no ordering discipline is needed in user code (LAW 15). Nodes
feeding a domain's desired state may not read that domain's own cells,
stratification; because otherwise reconciling would loop forever.

Runtime policies are also available to pp libraries through
`configure-runtime`. A manifest may select built-in schedules, install a
reporter, and provide canonical build/execution policy data. A custom schedule
function receives only data-closed job descriptors and returns validated
batches; it cannot execute a thunk or obtain authority. CLI schedule options
override a manifest. Explicit request `:policy` values override a manifest's
default `:execution-policy` when constructing `run-closed!` requests.

**Status: holds** (the full form, with per-domain stratification): the
write-discipline law is now enforced generically, for any registered domain,
not hardwired to the filesystem. A domain is an `observe`/`diff`/`apply`
triple of ordinary pp functions (`register-domain`, scripting tier), and
the runtime domain service wraps every domain's `apply` in the same journal
bracket, observed-state suspension, plan cache, and verify-after-write,
regardless of what the domain converges. The trusted mechanics (atomic
materialize/remove, process launch/reap, and per-domain state persistence)
live in runtime providers (`tree-observe`, `materialize-file`, `remove-file`,
`proc-spawn`, `proc-alive?`, `proc-stop`, `proc-reap`, and domain-state
operations), while all policy (the tree-walk diff and start/stop/restart
decision) lives in the built-in domain implementations, with equivalent
pp-level policies packaged as `stdlib/domain-fs.pp` and
`stdlib/domain-proc.pp` for explicit registration.

`pp --reconcile ROOT prog.pp` registers the built-in native fs domain with a
write capability restricted to ROOT, taking the program's final
canonical tree value as the filesystem domain's desired state. It diffs file
entries against observed reality by blob identity, applies atomically,
deletes unmanaged files (single writer), journals, requires a filesystem
write grant, and refuses stratification (`tests/018`). Desired file entries
carry modes and raw content-addressed blob identities (`tests/023`);
directory entries make parent structure explicit.

Watch mode: `pp --watch --reconcile ROOT prog.pp` runs the program,
reconciles, polls cells for changes, and re-runs on change (`tests/031`).
Every registered domain is re-observed, re-diffed, and re-applied on every
tick regardless of which cells changed, so a killed service or externally
drifted file is caught within one poll interval; the plan cache turns a no-op
pass into a cache hit, so this stays cheap.

Push stabilize: `pp --watch --stabilize prog.pp` uses the reverse-edge index
from stored traces to reset only dirty thunks, so clean nodes skip repository
lookup entirely (`tests/032`).

The process domain: `pp --supervise prog.pp` registers the built-in
native process domain (`runtime-process-domain-entry`), which implements
the same start/stop/restart-on-spec-change policy that
`stdlib/domain-proc.pp` packages for explicit third-party registration
through `register-proc-domain` (`tests/049`); `--supervise` itself loads
no pp library. The program's final value is a map
of service name to spec, kept in sync with observed reality: starts missing
services, stops removed ones, restarts on spec change (specs compared
structurally via `hash-value`, which canonicalises map-key order like the
on-disk codec, so a round-trip through `domain-state-get`/`put` never
compares spuriously different). It reaps zombies and restarts a service
killed with `kill -9` within one poll interval. Requires `--grant process`,
journals intent/done pairs owned verbatim by the `proc-spawn`/`proc-stop`
primitives, refuses stratification on `proc:` observations (`tests/033`).

A third-party toy "kv" domain in `tests/046-domains.sh`, registered from an
ordinary pp program via `register-domain` with neither `--reconcile` nor
`--supervise`, proves the protocol is genuinely generic: plan caching across
separate process invocations (proved via `pp why`), stratification,
capability threading (`cap-restrict` itself refuses before the domain ever
runs), verify-after-write failure for a deliberately under-converging
`apply`, the generic journal bracket, and fenced-after-domains ordering.

Fenced effects (LAW 31) are live: `fenced(KIND, SPEC)` registers a
scripting-tier action, drained once per pass after all domains' convergent
work; `--fenced-policy retry|abort|ask` resolves unknown-status intents; a
killed mid-apply action is recovered without silent double-execution
(`tests/034`).

Host-qualified domain distribution: the desired map generalises one level,
never inferred, makes the application select that one host's `{domain -> desired}`
slice and hand it to the lifecycle domain runner above, which never learns
host-keying exists. Without the flag, the desired value
passes through untouched, so every pre-existing program and flag combination
(this law's own `tests/018`/`tests/033`/`tests/046`) is byte-identical to
before. A member's recovery from `kill -9` is this law's existing
per-machine story, unchanged (`tests/049-host-domains.sh`).

### [LAW 31] Fenced effects are reconciler-only, journaled, at-most-once per pass

Non-convergent actions, such as sending an email or charging a card, may not
appear in node bodies at all: nodes are cache-replayable and must not
contain irreversible actions. The scripting-tier primitive `fenced(KIND,
SPEC-MAP)` registers an action for reconciler sequencing. Under `--reconcile`
or `--supervise`, the reconciler executes fenced actions after all
convergent work, journaling `intent fenced KEY EPOCH KIND SPEC-HASH`, then
performing the action, then `done fenced KEY RESULT-HASH`. Action identity
within a pass is `KEY = H("fenced", EPOCH, KIND, SPEC-HASH)`. The epoch is a
fresh nonce per reconcile pass, and on crash recovery the resumed pass reuses
the epoch from the unknown intent, so a re-registered identical action
deduplicates. An `intent` without a matching `done` after a crash has status
unknown, and resolves by `--fenced-policy retry | abort | ask`, never by
silent retry.

**Status: holds**: the engine uses the same primitive and journal
format; a `fenced(…)` inside a node body raises an error; an unknown-status
action is resolved by policy; a killed mid-apply action is retried exactly
once under `--fenced-policy retry` and marked done under `--fenced-policy
abort` (`tests/034`).

---

## 10. Types

### [LAW 32] Types are optional, gradual, and checked at force time

pp is dynamically typed. A type annotation is a checked claim: when an
annotated value is forced, a mismatch is a runtime error reporting the
annotation's definition site. No annotation, no check. The evaluator enforces
the same claim on every supported execution path.

**Status: holds**: the evaluator enforces type annotations at force time.
`def`/`fn`/`defnode` bodies carry their definition-site location, so type
errors cite the annotation site. Per-parameter annotations are checked too,
however a surface spells them (s-expressions: `(def (f x : int) …)`,
`(fn [x : int] …)`; braces: `def f(x: int) { … }`, `fn(x: int) { … }`).
Reader desugaring rewrites each into a located type check that runs ahead of
the body (`tests/026-param-types.sh`).

---

## 11. Config

### [LAW 33] Config is ambient, dynamically scoped data; nested scopes shadow; keys may be computed

`with-config({..}) { body }` pushes a config frame for `body`'s dynamic
extent; `config(k, [default])` reads the nearest frame, falling through to
the default. Inner frames shadow outer ones. The key expression is an
ordinary expression, so computed keys are legal. Config is data, what to
build; capabilities are authority, whether you may. A node that reads
config has observed an input: the read participates in the node's identity
and validity like any other observation, so the same code under different
config is a different computation.

**Status: holds**: computed config keys work, nested scopes shadow, and
config frames are restored on every exit: normal, tail, and exception
(`tests/006-config-test.pp`, `tests/007-phase0-laws.pp`). The "config read is
an observed input" clause is real at node granularity: a `config(k)` inside a
node records a `config:<k>` trace cell, where absence is
itself a distinct observation, re-observed against the caller's config stack
on a hit, and ambient config is excluded from the node key (`tests/015`).

---

## 12. Location transparency and distribution

### [LAW 34] `force` is the only execution primitive; location has no surface syntax

There is no `remote-eval`, no placement annotation, no node-pinning form, and
there never will be. Where a force runs is decided by the active,
result-transparent (LAW 26) schedule handler; cluster membership is ambient
config or capability. A program is byte-identical whether it runs on one
core, eight, or a cluster.

**Status: holds** for the negative half: no location surface exists in any
reader, and this absence is verified. The positive half now lands for local
process-pool parallelism: `--schedule serial|parallel:N|race:N` selects a
result-transparent handler (`distribution.lisp`) that forks worker processes
at the dispatch point. A worker runs the exact `run_node_body` the serial
miss arm calls, with no second force path, and communicates only through the
store; a dead worker degrades to an ordinary in-process recompute, never a
wrong answer. `--schedule` is read only by the miss arms and the
scheduler, never by `node_key_of`, and it never enters a
trace, so "a program is byte-identical whether it runs on one core or eight"
holds by construction, not merely by intent.

This extends to a cluster: `--schedule remote:<member>` uses the same
result-transparent distribution service, gated to data-closed batches, since
every free variable re-encodes under the canonical value codec.
Membership comes from `~/.pp/cluster/members`/`$PP_CLUSTER_MEMBERS`, ambient
config, never `--grant`: an address is not an authority ceiling.
A member is an ordinary second `pp` invocation of the byte-identical program;
node, an unreachable member, or a crashed member all degrade to local
compute, never a wrong answer (`distribution.lisp`).

A future extension adds cluster membership's write-domain half: the desired
map generalises to `{host -> {domain -> desired}}`, indexed by the same kind
of ambient identifier this law uses for `remote:<member>` plus an explicit
`--member-name <n>` flag, never `--grant`, so the negative half stays intact.
It hands the lifecycle domain runner (LAW 30) only that host's slice; a
member is simply `pp --watch [--supervise] --member-name <n>`, the local
supervisor's existing per-machine story verbatim. Explicit store GC (`pp gc`,
never automatic) is orthogonal to placement: it runs only as its own command,
documented alongside LAW 30.

### [LAW 35] "Run on N, take the first" is a handler, not a feature

Redundant, parallel, or distributed execution policies (fan-out, racing,
work-stealing, locality) are swappable schedule handlers: library code, with
zero change to the language surface. Parallelism and distribution are the
same feature at different scales.

**Status: holds** at the runtime boundary. Schedule handlers are ordinary
opaque service values rather than branches in the evaluator or force path.
The current host installs the built-in CLI handlers; exposing safe composition
to pp libraries remains unimplemented. For local process-pool fan-out,
`race:N` forks N redundant workers for one
singleton node miss — homogeneous redundancy only. LAW 37 nodes are
deterministic, so racing identical `(key, run)` jobs is sound; heterogeneous
racing of different computations stays out of scope until LAW 37/38's
declared-nondeterminism cells exist. The first success wins, losers are
killed, and the parent re-enters cache lookup exactly as the batch path does.
Cluster and distributed racing remains bounded by its declared threat model.

---

## 13. Evaluator correctness

### [LAW 36] The evaluator is the single reference engine

The evaluator is the executable specification. Its shared frontend and
continuation machine own every expression form, and its printers preserve
round-trip structure and hashes. No shipped feature may exist outside this
verified surface.

**Status: holds**: the saved-image evaluator handles both readers, signed
integer and float literals, macros, persistent nodes, and source locations
under the focused language, frontend, node, and store suites. Signed literals
survive formatting and remain distinct from subtraction and hyphenated names
(`tests/105`). Macro expansion runs once before evaluation, producing the
expanded AST; `tests/041-defmacro.pp` exercises that boundary.

VInt persistence uses the signed 63-bit range supported by the current
Common Lisp image.

## 14. Reproducibility and volatility

### [LAW 37] Same inputs, same output, and nondeterminism must be declared

A node given the same input value hashes produces the same result hash.
There is no ambient entropy: `random`, wall-clock, and similar sources are
either trace-recorded cells — a nondeterministic read is an observation of
the world — or unavailable inside nodes.

**Status: holds**: `random` remains removed; the sanctioned nondeterministic
dependency is now the probe (`register-probe(name, observe-fn, read-cap)`,
scripting tier; `probe(name)`, inside or outside nodes). The observe function
runs at most once per pass, outside any node's trace stack, so its own reads
never contaminate the reading node's trace, under exactly the registered
`read-cap`. The reading node records only a `probe:<name>` trace cell, a
hash of the observed value, capability-free at the read site, since the
authority was already spent evaluating the probe. A node itself still has no
ambient entropy: nondeterminism enters only through a declared probe cell,
never through an effect with no cell.

### [LAW 38] Volatile nodes are contained as cells and barred from shared caches

A node whose tool is irreducibly nondeterministic (`__DATE__`, timestamp
linkers, address-space layout randomisation) is detected by `--check`,
which double-builds and compares hashes, and its result is treated as a
cell, observed and pinned per pass, so its instability stops at one edge
instead of re-keying its whole ancestor cone on every build. Volatile
results never enter a shared cache. Canonicalisation adapters
(`-frandom-seed`, `ZERO_AR_DATE`) are preferred where they exist.

**Status: holds**: the detection half already exists:
`pp --check` runs every missed node's body twice, compares result hashes,
and flags a divergence as volatile (`tests/019`). The containment half is
now the same probe mechanism as LAW 37: wrapping a volatile read as
`register-probe(name, observe-fn, read-cap)`/`probe(name)` moves it out of
the node body and into its own `probe:<name>` cell, observed and pinned once
per pass, exactly the cell treatment this law asked for. So a node reading
it re-forces only when the probe's value actually changes, and its
instability never re-keys or invalidates anything beyond that one cell edge.
Probe results are never written to `~/.pp/store` at all: the session's probe cache
is in-memory and cleared every pass, which is stronger than merely being
excluded from shared caches, since there is no cache to exclude them from.

### [LAW 39] Sealed cells: confidential reads are a distinct value kind, banned at the node boundary

`--grant secret:<path>` mints `CapSecret {path}`. A read covered by
`CapSecret` and not by `CapFilesystem` returns a new value kind, `VSealed`,
instead of `VString`. The cell records `sealed:<canonical-path>`, a hash of
the bytes for rotation invalidation; the bytes pin in-memory only, never via
`store_blob` or the store, so a sealed read that is not explicitly unsealed
cannot put secret plaintext in a store-wide scan; every printer redacts to
`#<sealed>`. `VSealed` joins the node-boundary ban exactly like `VCapability`
— free-variable ban and result ban, both directions — and
`Observation.authorized` requires a covering `CapSecret` grant to serve a hit
on a `sealed:` cell. LAW 23's transitive closure and introspection filtering
fall out unchanged: no laundering through an aggregator, `pp why` redacts.
`unseal(v)` is the one explicit, greppable way out to `VString`; derived data
is ordinary data afterward, by design, no tainting — the line Vault and SOPS
draw. For non-text sealed bytes, `unseal` exposes one-byte string characters
and a subsequent text `blob` uses UTF-8 encoding; raw-byte disclosure is not
promised. Unsealing inside a node makes the result cacheable ordinary data, a
documented residual like any other cache holding what a node returns. When a
path is covered by both `secret:` and `fs:` grants, filesystem behaviour wins:
granting plain access over the same path says "not secret here".

Ordinary malformed filesystem bytes use the separate, runtime-only
`VOpaque` value. It has one-byte identity but no durable codec or wire form;
an ordinary file observation may still retain the source bytes as a public
blob, while `blob(VOpaque)` is the explicit value-to-blob conversion.
`blob-get` returns `VOpaque` when a stored blob is not strict UTF-8 so that
the byte/hash round trip is exact. `blob(VSealed)` is rejected before any
blob repository operation with a `runtime.authority` error. The existing
`durable-value-p` contract rejects `VSealed`, `VOpaque`, and nested instances
before object, node-result, fenced-spec, publish, or generic lifecycle
publication.

**Status: holds**: implemented. `tests/044-sealed.sh` covers redacted print,
`unseal` round-trip, recursive store scans proving sealed reads never land
under `~/.pp/store`, the node-boundary ban both directions with stable stderr,
rotation invalidating exactly the observing node, a caller without the
`secret:` grant unable to hit a node whose cached closure read it, and the
both-grants case behaving as plain filesystem access.
`tests/127-sealed-blob-boundary.sh` covers the pre-CAS `blob` rejection,
recursive publication guards, opaque malformed-byte round trips, filesystem
precedence, and explicit unseal disclosure.

---

## Appendix A: Current status

The checked contract between stated semantics and implementation. The
law-linkage gate (`tests/072-law-pins.sh`) keeps it synchronized with the
suite.

| Law | Area | Status | Evidence |
|---|---|---|---|
| LAW 1 | mutual `let` scope | holds | `tests/007-phase0-laws.pp` |
| LAW 2 | dependency-derived order, cycle errors | holds | force paths report named cycles; `tests/095-scope-identity.sh` |
| LAW 3 | binding-order-free identity | holds | mutual `let` bindings are sorted before hashing; `tests/095-scope-identity.sh` |
| LAW 4 | one scope model | holds | top level, blocks, and modules prebind the same definitions while preserving value statement timing; `tests/025-def-value.sh`, `tests/039-global-scope.pp`, `tests/095-scope-identity.sh` |
| LAW 5 | `let*` sequential sugar | holds | reader emits `ELetStar`; sequential; `tests/007-phase0-laws.pp` |
| LAW 6 | node call-by-value plus memoization | holds | application is call-by-value; `node { e }` and applied `defnode` memoize persistently, keyed on code, free-variable values, and argument value hashes (`tests/011`, `tests/097`) |
| LAW 7 | demand-pruning at node granularity | holds | the desired object and forced node keys root the durable graph shared by cache validation, stabilization, transport, and GC (`tests/032`, `tests/050`, `tests/101`) |
| LAW 8 | `delay` ephemeral vs `node` persistent | holds | `delay` and local bindings are fresh, in-memory thunks; only `node` thunks use in-process deduplication, and nodes persist across runs |
| LAW 11 | stack-safe non-tail recursion | holds | heap continuation machine plus iterative builtin list traversal; regular deep regression (`tests/087-deep-recursion.pp`) and million-element acceptance fixture (`tests/fixtures/million-non-tail.pp`) |
| LAW 12 | total quotation, quasiquote | holds | `tests/007-phase0-laws.pp`; `defmacro` is built on this base; `Quotation.value_to_expr` completes the round trip, `tests/041-defmacro.pp` |
| LAW 15 | ordering never from capabilities | holds | authority and ordering are separate; filesystem and process domains use the generic domain pipeline (`tests/018`, `tests/033`) |
| LAW 16 | opt-in per-node caching | holds | persistent nodes cache across runs; ambient execution is scripting-only; an immutable foreign request runs in a node only after its trusted provider classifies it cacheable (`lifecycle_unit`, `tests/010`, `tests/017`, `tests/102`) |
| LAW 17 | hit is not effect replay | holds (node tier) | a `node { e }` hit does not replay in-node `log`/stdout (`tests/010`, `tests/014`) |
| LAW 18 | sandbox-scratch writes | holds | per-node scratch is real: relative node writes/reads are scratch-local, closed-action outputs are canonical verified trees, and absolute node writes error (`tests/017`, `tests/102`); domain writes use the reconciliation pipeline |
| LAW 19 | sound content hashing | holds | SHA-256 structural hashes cover referenced closure environments and handlers; store objects are content-addressed by result hash and shared across runs (`tests/009`) |
| LAW 20 | key = code plus argument values | holds | persistent node keys = expanded code plus free-variable value hashes plus applied argument value hashes; capabilities, the whole environment, config, and handlers are excluded (`tests/011`, `tests/015`, `tests/097`); authority cannot cross the node boundary (`tests/capability-adversarial.sh`); macro expansion precedes keying (`tests/042-defmacro-rekey.sh`) |
| LAW 21 | cutoff via traces | holds | trace sets, revert hits, glob invalidation, direct-reader invalidation with hash-gated child cutoff, push inline-node cutoff, and fresh-process child validation/reconstruction are real (`tests/010`, `tests/016`, `tests/032`, `tests/100`, `tests/101`) |
| LAW 22 | unforgeable root-minted capabilities | holds | constructors removed; `tests/capability-adversarial.sh` |
| LAW 22b | `with-caps` narrows a held value, never widens | holds | `current-capabilities`/`with-caps`/`cap-restrict`'s mode argument; the subset check runs against the current ambient; `effect` removed;  exception/tail-safe; `tests/capability-adversarial.sh` |
| LAW 23 | component/full-path plus transitive hit check | holds | component-aware, canonicalised paths at every cell/grant/loader-bound site (`tests/036`); hits require authority over the trace's transitive read closure; denials are not memoized (`tests/013`, `tests/014`, `tests/103`); `pp why` redacts unauthorized cells (`tests/019`) |
| LAW 24 | loader is runtime authority | holds | loader bounded to source roots plus `~/.pp`, reads traced as authority-exempt `runtime:file:` cells (`tests/020`); realpath-canonical (`tests/036`) |
| LAW 25 | no unenforced authority surface | holds | `CapTime`/`CapMemory` removed from types and surface |
| LAW 26 | two handler classes, synthetic trace cells | holds | semantic handler use is traced by effect and handler identity (`tests/015`); result-transparent scheduler handlers remain outside identity and traces (`tests/038`) |
| LAW 27 | exception/tail-safe dynamic extent | holds | save-stack restore on every exit |
| LAW 28 | failure traces, error memoization | holds | evaluative failures use the same durable trace lifecycle as successes and are re-served until a recorded read changes; authority denials and internal exceptions remain uncached (`tests/012`, `tests/014`, `tests/103`) |
| LAW 29 | source locations in errors | holds | every top-level form's location is appended to unlocated runtime errors; arity/capability errors name the callee/operation; `pp: error:` single-line reporting; a loaded file's own forms are individually located and decorated with that file's location before the error can unwind past the `load` (`tests/027`, including case (g)) |
| LAW 30 | desired-state plus single writer | holds | registered domains enforce plan, journal, atomic apply, verify, and stratification; `stdlib/domain-fs.pp` and `stdlib/domain-proc.pp` hold filesystem and process policy (`tests/018`, `tests/023`, `tests/033`, `tests/046`) |
| LAW 31 | fenced effects, intent journal | holds | scripting-tier `fenced(KIND, SPEC)`, `--fenced-policy retry|abort|ask`, intent/done journal, recovery without silent retry; `tests/034` |
| LAW 32 | gradual types, strict evaluator | holds | the evaluator enforces; tests 004/005 restored; `tests/007-phase0-laws.pp` |
| LAW 33 | config: computed keys, tail-safe scoping | holds | computed keys and tail-safe scoping; config reads inside nodes are `config:<key>` trace cells, ambient config out of the node key (`tests/015`) |
| LAW 34 | no location surface / scheduler exists | holds | the language has no location form; local process-pool scheduling, host-qualified domains, and explicit GC are implemented (`tests/038`, `tests/049`, `tests/050`) |
| LAW 35 | run-on-N-take-first as handler | holds | `race:N` process-pool fan-out lands (`tests/038`) |
| LAW 36 | evaluator correctness | holds | signed literals agree across readers and formatting (`tests/105`); macro expansion is shared ahead of evaluation |
| LAW 37 | declared nondeterminism | holds | `register-probe`/`probe` are the one sanctioned nondeterministic dependency, evaluated at most once per pass outside the reading node's trace stack, exposed only as a `probe:<name>` cell (`tests/043-probes.sh`) |
| LAW 38 | volatile-node containment | holds | `--check` double-run detection unchanged (`tests/019`); containment is the same probe mechanism as LAW 37; a volatile read wrapped as a probe is observed and pinned once per pass as its own cell, in-memory only, never written to `~/.pp/store` (`tests/043-probes.sh`) |
| LAW 39 | sealed cells | holds | `CapSecret`/`VSealed`: confidential reads redact on print, exclude from the content-addressed store, ban at the node boundary both directions, gate hits on a covering grant; `unseal(v)` is the explicit boundary (`tests/044-sealed.sh`) |

---

## Appendix B: The brace surface: token spec and lowering table (non-normative)

> Non-normative annex recording the current surface contract (see
> [SYNTAX.md](SYNTAX.md)): the grammar of the brace/infix surface and the
> exact s-expression form every brace construct reads to. It defines no new
> semantics: every row lowers to a form the laws above govern. The
> s-expression language is unchanged: it remains the AST's notation and the
> macro layer's data language (`quote` yields sexpr data in both surfaces).
>
> The elegance criterion (frozen): reading a brace file and reading its
> s-expression transpilation must yield the identical `Core_model.expr`, and
> therefore identical LAW 20 keys. No renames: kebab-case identifiers
> survive verbatim. Source ranges carry diagnostic extent and columns; the
> source name and one-based start line stay in `ELocated` identity for cache
> compatibility, so changing only range extent or columns does not change
> computation keys. Two consequences:
>
> 1. The brace reader attaches `ELocated` at exactly the sites the
>    s-expression reader does (see B.4).
> 2. Formatting preserves the source path and line number of every
>    location-carrying form nested inside hashed code: an `fn`/`def` inside a
>    node body carries its definition line into the node key. The formatter
>    owns this constraint.

### B.1 Tokens

Identifiers: a maximal run of name characters. Name characters are the
s-expression reader's symbol characters minus `:`; that is, everything
except whitespace, `, ( ) [ ] { } < ' `` ` `` " ; # ~` and `:`. So `-` `?`
`!` `.` `/` `*` `+` `=` `>` `|` `_` and similar characters are all name
characters: `string->number`, `nil?`, `proc-alive?`, `let*`, `run!`, `a-b`
are each one identifier. (`:` is reassigned in braces to keywords,
annotations, and cell literals; sexpr symbols may contain `:` (bare island
URIs like `file:./lib`), but no binding in the tree uses one, and braces
spell island URIs as strings; see row L55.)

The whitespace rule (frozen, non-negotiable): infix operators require
surrounding whitespace. `a - b` is subtraction; `a-b` is one identifier.
Token identity is maximal munch; whether a token acts as an infix operator
is decided by position, never inside a token. `a ->b` is the identifier
`->b`, a parse error in operand position. The sharpest case is `->`,
load-bearing for type-conversion names: glued, `string->number` is one
identifier; with whitespace on both sides, `k -> v` is the map/reconcile
arrow (L10). The glue rule alone distinguishes them: `string -> number` with
spaces would be the arrow between two operands. This one rule let the entire
standard library migrate with zero renames. The `<` family lexes specially
in braces (`<` is not a name character) but obeys the same whitespace
requirement for uniformity.

Reserved words: the following are grammar in head/statement positions, not
bindable names: `and` `assert` `config` `def` `defmacro` `delay` `do` `else`
`fn` `force` `if` `import` `island` `let` `let*` `load` `load-module` `mod`
`module` `needs` `node` `or` `perform` `quasiquote` `quote` `reconcile`
`splice` `unquote` `with-caps` `with-config` `with-handler`, plus the
literals `true` `false` `nil`. No existing binding in the standard library,
tests, or demos collides with these; this is verified, and a regression
gate re-verifies it mechanically. An operator word (`and`, `or`, `mod`) or
operator symbol (`+`, `-`, `<=`, …) in a non-infix position denotes its
symbol: `foldl(+, 0, xs)` becomes `(foldl + 0 xs)`, and `mod(a, b)` becomes
`(mod a b)`. Special-form heads applied in call position parse as their
special forms, exactly mirroring the sexpr reader's car-symbol dispatch.

Comments: `#` to end of line. `;` is not a comment; it is the inline
statement separator — the loudest lexical difference from sexprs, where `;`
comments and `#` introduces `#{`. A later formatter must transpose comment
markers; sets are spelled `hash-set(…)` (L12).

Strings: as in the sexpr reader, `"…"` with escapes `\n` `\t` `\\` `\"` (any
other backslashed character is itself); literal newlines are allowed.

Numbers: as in the sexpr reader, a token starting with a digit, or with `-`
immediately followed by a digit or `.`digit, is a number; `.` and exponents
work as today (`20.` is a float). `-5` is a literal when the sign is
attached; `a - 5` is subtraction; `a -5` is two adjacent operands, a parse
error, by design.

Keywords: `:name`, with `:` at the start of the token, becomes `VKeyword`,
as in sexprs.

Cell literals, removed: the fused `file:"P"`/`env:"N"`/`tree:"R"` token is no
longer part of the language. A single-string token cannot spell a default
(`$env("CC", "gcc")`) or a computed path, and an observation is an operation,
not a literal. World-reads are the `$` family exclusively (see B.8; rows L47
to L49 amended). An identifier followed immediately by `:` is only an
annotation colon (`x: ty`); `name:"…"` does not lex as a cell.

Annotations: `:` after a parameter or binding name (`x: int`) or after a
parameter list (`def f(x): int`); rows L24, L27 to L31.

Separators: inside `{ … }` blocks and at top level, statements are
separated by newline or `;`. The surface is not whitespace-sensitive: there
is no indentation semantics, since pp programs generate pp programs, so a
newline ends a statement only when it is syntactically complete. Inside an
open `(` `[` `{`, or after an infix operator, `=`, `->`, `|>`, a comma, or a
form head still awaiting its block, the statement continues across the
newline. Commas separate call arguments, vector/map elements, binding
groups, `needs` items, and handler pairs; a comma is never `unquote` (row
L58 is).

Blocks vs map literals: `{ … }` in expression position is always a map
literal (L10). A block `{ … }` appears only immediately after one of the
closed set of block-taking heads: `fn(…)` `def f(…)` `node` `do` `if`/`else`
`let(…)` `let*(…)` `module` `quote` `quasiquote` `defmacro name(…)`
`reconcile` `with-caps(…)` `with-config(…)` `with-handler(…)`. Sequencing in
expression position is spelled `do { … }`. In an `if` condition the
expression is parsed brace-free, Go-style: a top-level `{` terminates the
condition, so parenthesize a map literal used directly as a condition.

### B.2 Precedence and associativity

Every infix operator lowers to a binary application, or the `if` desugar.
The operator set is exactly what the s-expression language already has as
primitives or special forms; no new semantics, following this project's
rule against grammar creep.

| Level (tight → loose) | Operators | Associativity | Lowers to |
|---|---|---|---|
| 1 | call postfix `E(a, …)` | left (`f(x)(y)` → `((f x) y)`) | `(E a …)` |
| 2 | `*` `/` `mod` | left | `(* l r)` `(/ l r)` `(mod l r)` |
| 3 | `+` `-` | left | `(+ l r)` `(- l r)` |
| 4 | `<` `>` `<=` `>=` `=` | none; chaining is a parse error | `(< l r)` and so on |
| 5 | `and` | right | `(and l r)` becomes `(if l r false)` |
| 6 | `or` | right | `(or l r)` becomes `(if l true r)` |
| 7 | `\|>` | left | `x \|> f` → `(f x)`; `x \|> f(y, …)` → `(f x y …)` |
| — | `->` | n/a | not an expression operator: key/value separator inside map literals (and `reconcile`) only |

Notes, each load-bearing for hash preservation:

- there are no unary operators: negation is a signed literal or `0 - x`. The
  primitives' n-ary spellings (`(+ a b c)`, chained `(< a b c)`, variadic
  `=`) are reached by call syntax: `+(a, b, c)`, `<(a, b, c)`. An infix
  chain `a + b + c` lowers left-nested to `(+ (+ a b) c)`, which is a
  different AST, and hash, from `(+ a b c)`: a later printer must print
  n-ary applications in call form, never as infix chains.
- `and`/`or` are right-associative deliberately: the sexpr forms desugar
  right-nested (`(and a b c)` becomes `(if a (if b c false) false)`), so a
  right-associative infix chain `a and b and c` lowers to the identical
  `EIf` tree. Variadic `and`/`or` therefore do survive infix printing with
  hash equality; the desugar erases the arity, unlike `+`.
- `|>` is pure reader-level rewriting, at the lowest precedence, so
  `x + 1 |> f` is `(f (+ x 1))`: a pipeline and its spelled-out application
  are the same computation, hence the same key. The right-hand side must be
  an identifier or a call form; anything else is a parse error.

### B.3 Lowering table

Each row gives the s-expression text a brace form reads as; both readers
must then agree at the `pp.kernel` expression level. Where the frontend
reader applies a reader-level desugar (`and`/`or` → `if`, `assert`,
per-parameter type checks, the block rule), that desugar is a shared post-pass
run identically downstream of both parsers, never duplicated. ⟦stmts⟧ denotes
the frontend block-lowering rule: one statement becomes the statement itself;
several become `(do stmts…)`; zero become `(do)`, including the block's
duplicate-definition check (LAW 4).

#### Atoms and literals

| # | Brace form | Reads as |
|---|---|---|
| L1 | `42`, `-5` | `42`, `-5` |
| L2 | `2.5`, `20.`, `1e3` | same float literal |
| L3 | `"s\n"` | `"s\n"` (same escapes) |
| L4 | `true` `false` `nil` | `true` `false` `nil` |
| L5 | `:key` | `:key` |
| L6 | `string-index`, `nil?`, `run!` | the same symbol, verbatim |
| L7 | operator in non-infix position: `foldl(+, 0, xs)` | `(foldl + 0 xs)` |
| L8 | `( E )` | `E` (grouping only; no AST node) |

#### Composite literals

| # | Brace form | Reads as |
|---|---|---|
| L9 | `[e1, e2, …]` | `(list e1 e2 …)`; revised (see note) |
| L10 | `{ k1 -> v1, k2 -> v2, … }` | `(hash-map k1 v1 k2 v2 …)` |
| L10a | `{ …m, k -> v, … }` (spread) | fold: `(map-merge (hash-map) m)` for each `…spread`, `(map-insert acc k v)` for each pair, left to right; multiple spreads merge, rightmost wins. The spread-free literal keeps its `(hash-map …)` shape (hash-preserving). Replaces the removed `{ base \| k -> v }` update form. |
| L11 | `{}` (expression position) | `(hash-map)` |
| L12 | *(no set literal; `#` is the comment character)* `hash-set(e, …)` | `(hash-set e …)` |

> L9 is a revision, not sugar. `[…]` originally read as `(vector …)`; it now
> reads as `(list …)` — a semantic, hash-affecting change: a bracket literal
> is a `VPair` cons-chain, not a `VVector`, so its LAW 20 hash changed and the
> golden store was regenerated. Two consequences are checked mechanically:
> the quasiquote path builds the same cons-list value the equivalent code
> builds (`tests/060-qq-list-parity.sh`), and `pp check` flags
> `vector-get`/`vector-length` applied directly to a bracket literal
> (`tests/064-l9-vector-sweep.sh`).

#### Operators (see B.2 for nesting)

| # | Brace form | Reads as |
|---|---|---|
| L13 | `a + b`, `a - b`, `a * b` | `(+ a b)` `(- a b)` `(* a b)` |
| L14 | `a / b`, `a mod b` | `(/ a b)` `(mod a b)` |
| L15 | `a < b`, `a >= b`, `a = b`, … | `(< a b)` `(>= a b)` `(= a b)` … |
| L16 | `a and b` | `(and a b)`; the shared desugar yields `(if a b false)` |
| L17 | `a or b` | `(or a b)`; desugar `(if a true b)` |
| L18 | `x \|> f`; `x \|> f(y)` | `(f x)`; `(f x y)` |

#### Application

| # | Brace form | Reads as |
|---|---|---|
| L19 | `f(a, b)`; `f()` | `(f a b)`; `(f)` |
| L19a | `f(a, …rest, b)` (call spread) | `(apply f (list a) rest (list b))`; a `…` anywhere in a call's argument list groups consecutive plain args into `list(…)` segments, each spread its own segment; the `apply` primitive concatenates the segments and calls `f`. A spread-free call keeps the plain L19 shape (hash-preserving). A compound spread target uses the spaced `… E` form (as in list literals). |
| L20 | `(fn(x) { x })(3)`; `f(x)(y)` | `((fn (x) x) 3)`; `((f x) y)` |

#### Bindings and functions

| # | Brace form | Reads as |
|---|---|---|
| L21 | `let x = E` (statement) | `(def x E)`; value binding, LAW 4 (`EDefValue`) |
| L22 | *(a type annotation on `let x = E` is a parse error; sexpr value defs have no annotation slot; annotate via L24 or L30 instead)* | — |
| L23 | `let (x = e1, y = e2) { body… }` | `(let [x e1 y e2] body…)`; mutual scope, LAW 1 (`ELet`) |
| L24 | `let (x: int = e) { … }` | `(let [x : int e] …)` (`ETyped` binding) |
| L25 | `let* (x = e1, y = e2) { body… }` | `(let* [x e1 y e2] body…)` (`ELetStar`) |
| L26 | `fn(p, q) { body… }` | `(fn (p q) body…)` |
| L27 | `fn(p: int) { … }` | `(fn (p : int) …)`; shared LAW-32 desugar |
| L28 | `fn(p): int { … }` | `(fn (p) : int …)` |
| L29 | `def f(p, q) { body… }` | `(def (f p q) body…)` |
| L30 | `def f(p: int) { … }` | `(def (f p : int) …)`; shared LAW-32 desugar |
| L31 | `def f(p): int { … }` | `(def (f p) : int …)` |

#### Nodes

| # | Brace form | Reads as |
|---|---|---|
| L32 | `node { E… }` (expression) | `(node ⟦E…⟧)` |
| L33 | `node name { E… }` | `(defnode name ⟦E…⟧)`; ≡ `(def name (node ⟦E…⟧))`, LAW 4 |
| L34 | `node f(p…) { body… }` | `(defnode (f p…) body…)`; typed params/return as L30/L31 |
| L35 | `node f(p) needs I1, I2 { body… }` | `(defnode (f p) (with-caps C ⟦body…⟧))` where `C` is the single lowered item, or `(cap-compose I1′ I2′ …)` for several |

`needs` items (L35) lower via B.8's grant-descriptor sugar (`fs.read`/
`fs.write`/`fs.rw`, each a mode-scoped `cap-restrict` over
`(current-capabilities)`; that table is authoritative). The explicit
`needs current-capabilities()` spelling uses a private projection so it can
apply the node's captured authority without exposing an ambient capability
observation in ordinary node code. `needs` is value-open: any other item is
an ordinary expression that must evaluate to a capability; LAW 22b's subset
gate enforces it, so a named or composed grant is legal — e.g.
`node deploy() needs k8s-prod { … }` where `let k8s-prod =
cap-compose(net("k8s.prod.internal"), process)`. Capability kinds stay
closed (DESIGN.md's closed-kinds-open-instances principle); named grants are
open at the value level. The `fs.*` descriptors are recognised only inside a
`needs` clause; elsewhere `fs.read` is just an identifier. A bare `proc` item
is not frozen: no form projects a single capability kind out of the ambient
set (`cap-restrict` is path-scoped; a path-restricted `CapProcess` is
unusable), so freezing it would need a new core projection primitive — new
language, out of scope under the grammar-creep rule. Creation-time narrowing
stays expressible by composition:
`def f(x) { with-caps(E) { node { … } } }` becomes
`(def (f x) (with-caps E (node …)))`.

#### Control and sequencing

| # | Brace form | Reads as |
|---|---|---|
| L36 | `do { s… }` | `(do s…)` |
| L37 | `if C { T… }` | `(if C ⟦T…⟧)`; else defaults to `nil`, LAW 9 |
| L38 | `if C { T… } else { E… }` | `(if C ⟦T…⟧ ⟦E…⟧)` |
| L39 | `if C1 { … } else if C2 { … } else { … }` | nested `(if C1 … (if C2 … …))`; there is no `cond`; a flat `else if` chain, or `match` on the scrutinee with guards, is the spelling |
| L39a | `match E { p1 => b1; p2 if g => b2; … }` | `(match E (p1 b1) (p2 if g b2) …)` (`EMatch`). Patterns: literals, variables (bind), `_`, `[a, b, …rest]` (list, with spread), `(:tag p…)` (tagged). Guards: `p if g => b`; the arm fires only when `p` matches and `g`, evaluated under `p`'s bindings, where only `nil`/`false` are falsy, is truthy; otherwise control falls to the next arm. A guardless arm hashes identically to the pre-guard 2-tuple. First match wins; no match is a runtime error. The compiler's structural condition uses unshadowable primitives (LAW A5) and cons-guards every `car`/`cdr`, so a list/tagged pattern against a non-pair scalar falls through instead of erroring. On the sexpr surface, the reader/printer read and write this exact `(match …)` form (patterns `_`/literal/symbol/`(list …[. rest])`/`(tagged tag …)`, a guarded arm `(pat if guard body)`), so match files round-trip through `pp fmt`. |
| L39b | `f"…{E}…"` (f-string) | `(string-append lit0 (->string E1) lit1 …)`; the `f` prefix is glued to the quote; `{E}` holes take arbitrary expressions and lower through the generic `->string`; `{{`/`}}` are literal braces; a single part (`f"abc"` or `f"{x}"`) is emitted bare, so `f"abc"` is the same as `"abc"`. Ordinary `"…"` strings never interpolate. This is a one-way desugar with no AST node, hash-preserved through `pp fmt`. |
| L40 | `force(E)`; `delay(E)` | `(force E)`; `(delay E)` |

#### Effects, handlers, capabilities, config

| # | Brace form | Reads as |
|---|---|---|
| L41 | `perform name(a, …)` | `(perform name a …)`; for every effect: `read-file` `write-file` `run` `run-closed!` `http-get` `http-post` `log` `tree-observe` `materialize-file` `remove-file` `proc-spawn` `proc-alive?` `proc-stop` `proc-reap` `domain-state-get` `domain-state-put` (the `!` marks effect names that expose the suffix directly) |
| L42 | `with-handler(n1 = h1, n2 = h2) { body… }` | `(with-handler [n1 h1 n2 h2] body…)`; a handler name may also be a keyword literal, as in sexprs |
| L43 | `with-caps(E) { body… }` | `(with-caps E body…)` |
| L44 | `with-config(E) { body… }` | `(with-config E body…)`; `E` is any expression, typically a map literal `{:k -> v}` |
| L45 | `config(K)`; `config(K, D)` | `(config K)`; `(config K D)`; computed keys legal, LAW 33 |
| L46 | `assert(C)`; `assert(C, M)` | `(assert C)`; `(assert C M)`; the shared desugar to `if` plus `error`, with a structured source diagnostic attached at evaluation time (see B.4) |

Capability values need no rows of their own: `current-capabilities()`,
`cap-restrict(c, scope, :ro)`, `cap-compose(a, b)`, `cap-none()`,
`capability?(c)` are ordinary calls (L19), as are every other primitive
(`slurp`, `blob`, `blob-get`, `unseal`, `probe`, `register-probe`,
`register-domain`, `fenced`, `argv`, `env-get`, `file-exists?`, `dir?`,
`hash-string`, `hash-value`, `gensym`, …).

#### Cells

World-reads are the `$` family, the one observation surface. The
head set and lowerings are the generated table in B.8. An earlier revision
removed the fused cell-literal tokens `file:"P"`/`env:"N"`/`tree:"R"`, which
could not spell a default or a computed path.

| # | Brace form | Reads as |
|---|---|---|
| L47 | `$file(P)` | `(slurp P)`; a `file:` (or, under a `secret:` grant, `sealed:`) observation |
| L48 | `$env(N[, default])` | `(env-get N)`; an `env:` observation |
| L49 | `$glob(R)` | `(perform tree-observe R)`; a `tree:` observation |
| L50 | *(no `$` head for `stat:` cells)* `file-exists?("p")`, `dir?("p")` | predicate observations keep the call form; they observe predicates, not path contents |

An earlier design sketch's `glob:"src/*.c"` is not frozen here: no
glob-observing form exists in core (the manifest read that exists is
`tree-observe`, L49), and minting one is new semantics, out of scope for
this annex, by the same grammar-creep rule as `needs proc`.

#### Modules, loading, islands

| # | Brace form | Reads as |
|---|---|---|
| L51 | `module { forms… }` | `(module forms…)` |
| L52 | `import(E)` | `(import E)` |
| L53 | `load("P")` | `(load "P")`; literal string required, as in sexprs |
| L54 | `load-module("P")` | `(load-module "P")` |
| L55 | `island("URI")`; `island("URI", "PIN")` | `(island "URI" "PIN")`; braces spell URIs as strings; the sexpr reader's bare-symbol (`file:./lib`) and `<…>` island-literal lexes produce the same `EIsland`, so hashes agree. An unpinned island remains the LAW 24 hard error |

#### The quote bridge

Homoiconicity at the AST layer: these yield or
consume s-expression data, in both surfaces.

| # | Brace form | Reads as |
|---|---|---|
| L56 | `quote { F }` | `'F′` ≡ `(quote F′)`, where `F′` is `F`'s lowering; one form only |
| L57 | `quasiquote { F }` | `` `F′ ``; quasiquote-mode read of the lowered form |
| L58 | `unquote(E)`; legal only inside `quasiquote{}` | `,E` |
| L59 | `splice(E)`; legal only inside `quasiquote{}` | `,@E` |
| L60 | `defmacro name(p…) { s1; s2; … }` | `(defmacro (name p…) s1 s2 …)`; each body statement is a separate form, producing the application shape recognized by the shared macro expansion pass |

L56 and L57 are distinct on purpose: `'x` and `` `x `` read to different
ASTs (`EQuote` versus the quasiquote application building cons chains),
both occur in real code, and both must round-trip with hash equality. In
quasiquote mode a brace form denotes the s-expression data of its lowering
(atoms quoted, lists as `cons` chains, vectors/maps as `vector`/`hash-map`
builds), exactly as the sexpr reader's quasiquote mode denotes its literal
text.

#### Desired state

| # | Brace form | Reads as |
|---|---|---|
| L61 | `reconcile { k1 -> v1, … }` | `(hash-map k1 v1 …)`; identity sugar naming the final-value map (LAW 30); the reconciler consumes the program's final value, so `reconcile` adds no AST and no semantics |

Top level: a brace file is a newline/`;`-separated statement sequence; each
statement is one top-level form, `ELocated`-wrapped exactly as
`Reader.read_string` wraps sexpr forms today.

### B.4 Location threading (`ELocated` placement)

For AST identity, and therefore hash and LAW 29 error-text identity, the
brace reader attaches `ELocated` at exactly the sexpr reader's sites.

- every top-level form: `ELocated (range-of-first-token, form)`
- `def`/`defnode`/`fn`: the range of the token after the head locates the
  body (`ELocated (loc, body)`), the return annotation
  (`ELocated (loc, ETyped (body, ty))`), and each per-parameter check
  (`ELocated (loc, ETyped (ESymbol p, ty))`, LAW 32)
- value defs: `EDefValue (x, ELocated (loc, rhs))`; value `defnode`:
  `EDefValue (x, ELocated (loc, ENode rhs))`
- `assert`: a message-less `assert` renders its condition via
  `quote_to_value`/`string_of_value`; that is, in AST, s-expression notation
  in both surfaces. The runtime diagnostic carries the source range; the
  brace reader must reuse the same renderer verbatim; assert messages are not
  re-rendered in brace notation without re-keying every node containing one.

### B.5 Law audit

This section audits the laws against the brace project's requirement that
they hold across surfaces.

- LAW 4: "value defs" was defined by the sexpr shape ("`(def x v)` with a
  non-list head"); it is now defined as binding a bare name to an
  expression (AST `EDefValue`), with the sexpr spelling cited as the
  example, and the `defnode`-value equivalence stated at the AST
  (`EDefValue (x, ENode e)`).
- LAW 12: "every form the reader accepts" becomes every form a reader
  accepts, with quotation stated as defined against the AST so all surfaces
  share one quoted-data language.
- LAW 29 (status): emitting `ELocated`/definition-site wrapping is restated
  as an obligation on every reader, not a property of the one existing
  reader.
- LAW 32 (status): per-parameter annotation checking is attributed to the
  shared reader-level desugar pass downstream of any parser; sexpr
  spellings are kept as examples.
- LAW 34 (status and test): "no location surface exists in the reader" and
  "the reader rejects any placement form" become "any reader" and "no
  reader accepts one".

Verified surface-neutral, unchanged: laws 1 to 3, 5 to 11, 13 to 28, 30, 31,
33, and 35 to 39 — their statements quantify over AST forms, values, hashes,
traces, capabilities, cells, or process behaviour; sexpr text in them is
example programs. LAW 24's island clause was checked specifically: it
constrains `EIsland`'s inline pin and its identity in the code hash, not any
lexical spelling. LAW 22's "`(filesystem "/" :rw)` is an unbound symbol" is
the same error in either surface.

### B.7 Judgment calls frozen by this annex

These decisions are frozen semantics, not implementation details.

1. `;` separates, `#` comments. Sexpr `;` comments become `#`, and sexpr
   `#{…}` sets have no brace literal (L12).
2. Expression-position `{…}` is always a map; sequencing is `do { … }`.
3. `quasiquote { … }` exists alongside `quote { … }` (L56/L57): the two
   sexpr quote forms have different ASTs and hashes, so one brace spelling
   could not cover both.
4. `needs proc` is not frozen, since no per-kind capability projection
   exists in core. `needs` items are the three `fs.*` shorthands or
   ordinary capability expressions, and the clause lowers to `with-caps`
   around the node body (L35).
5. `glob:` is not frozen, since no core observing form exists; `tree:"R"`
   covers the manifest-read case via `tree-observe` (L49).
6. Island URIs are strings in braces (L55); the sexpr bare-symbol and
   `<…>` lexes remain sexpr-only spellings of the same `EIsland`.
7. `let x = E` takes no type annotation (L22), because the sexpr value-def
   form it lowers to has no annotation slot; adding one would be new AST
   surface.
8. `:` is not a name character in braces, though it is in sexprs; no
   existing binding uses one, and keywords, annotations, and cell literals
   need it.
9. n-ary operator applications print as calls (`+(a, b, c)`), because
   infix is strictly binary and `(+ a b c)` is not the same as
   `(+ (+ a b) c)` under LAW 20. `and`/`or` are the deliberate exception:
   right-associative infix reproduces the variadic desugar exactly (see
   B.2).
10. `reconcile { … }` is identity sugar (L61): the reconciler already
    consumes the program's final value, so the keyword names intent and
    lowers to nothing.
11. Line and path preservation is a formatter obligation (the annex
    preamble's second corollary): node keys can embed `ELocated (file,
    line)` of nested `fn`/`def` forms, so a later formatting stage must
    transpile line-stably and in place for the null-rebuild exit to be
    achievable.
12. Quasiquote-template name slots take `unquote(…)`. Inside
    `quasiquote { … }`, a `let`/`let*` binding name and a `def`'s function
    name may each be `unquote(E)` as well as a bare identifier — the two
    computed-name shapes real macro templates need: a gensym'd hygienic
    temporary (`let (unquote(g) = unquote(a)) { … }` lowers to the data
    `` `(let [,g ,a] …) ``) and a macro-generated definition
    (`def unquote(name)(x) { … }` becomes `` `(def (,name x) …) ``).
    Everything else stays a parse error inside `quasiquote{}`, deliberately:
    `defmacro` and `needs` templates, named node definitions (`node name {
    … }`; the bare `node { E }` is representable), computed parameter names,
    type annotations (`ETyped` is not quoted-symbol data; representing one
    would need a new data convention), and map spread (`{ …m, k -> v }`):
    quasiquote maps build eagerly (`quasiquote_walk` does not descend into a
    `VMap`), so a spread's `map-merge` would run before unquotes substitute.
    Plain `{ k -> v }` literals are representable; spread is not. Workaround:
    build the form as data with ordinary `list`/`cons`/`quote{}` calls, what
    macro bodies could always return. Block-versus-map ambiguity resolves as
    outside quasiquote (judgment call 2): expression-position `{…}` is map
    data; sequencing is spelled `do { … }`.

### B.8 Surface tables (generated from `lisp/frontend/frontend.lisp`)

The closed surface sets (the `$KIND` observation heads, the `with { }`
clause keywords, the `needs` grant-descriptor sugar) are one typed value each
in `lisp/frontend/frontend.lisp`. Every consumer (both readers, the `needs`
desugar, `lint`, error messages) derives from those tables; nothing
hand-copies the list. Generated block: do not edit between the markers.

<!-- BEGIN GENERATED surface-tables -->
#### Observation heads — `$KIND(args…)`

| head | arity | qq | lowering | meaning |
|---|---|---|---|---|
| `$file` | 1 | yes | `(slurp $1)` | $file(path) — read a file's contents (records a file: cell) |
| `$env` | 1..2 | yes | `(if (nil? (env-get $1)) $2 (env-get $1))` | $env(name[, default]) — read an environment variable (records an env: cell); the optional default is used when the variable is unset |
| `$glob` | 1 | yes | `(perform tree-observe $1)` | $glob(path) — observe a directory tree (records a tree: cell) |
| `$probe` | 1 | yes | `(probe $1)` | $probe(name) — read an observer-written volatile probe cell |
| `$secret` | 1 | yes | `(slurp $1)` | $secret(path) — read a sealed (confidential) file |
| `$config` | 1..2 | yes | `(config $1 $2)` | $config(key[, default]) — read a scoped config value (records a config: cell); the optional default is used when the key is unset |

#### `with { }` clauses

| keyword | wrapper | meaning |
|---|---|---|
| `caps:` | `with-caps` | caps: C — run the body with capability set C |
| `config:` | `with-config` | config: M — run the body with ambient config map M |
| `handlers:` | `with-handler` | handlers: { :name -> fn, ... } — install a map of effect handlers |

#### Grant-descriptor sugar (inside `needs`)

| descriptor | lowering | meaning |
|---|---|---|
| `fs.read` | `(cap-restrict (current-capabilities) $1 :ro)` | fs.read(p) — read-only fs grant for p |
| `fs.write` | `(cap-restrict (current-capabilities) $1 :wo)` | fs.write(p) — write-only fs grant for p |
| `fs.rw` | `(cap-restrict (current-capabilities) $1 :rw)` | fs.rw(p) — read-write fs grant for p |
<!-- END GENERATED surface-tables -->
