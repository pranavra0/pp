# pp SPEC — the semantic laws

> This is the normative document. It states what pp's forms mean, as testable
> laws. It does not describe the current implementation — this project's docs
> have described aspirations as facts before, and this document exists partly
> to stop that. Every law carries an explicit status marker:
>
> - holds: the tree-walker satisfies it, verified by tests or the
>   metamorphic fuzzer.
> - partial: the mechanism exists but is buggy or incomplete. The prose
>   cites the matching test, fuzzer signature, or status-table entry.
> - unimplemented: a target only. Nothing in `src/` does this yet.
>
> The enforcement mechanism is the metamorphic fuzzer (`tools/fuzz.ml`; see
> [TESTING.md](TESTING.md)) plus the expected-output test suite. Every law is
> written so a program could falsify it. The project did not declare its first
> build phase complete until every law marked holds below had a passing test
> and no law was silently violated.
>
> Law-linkage gate (`tests/072`). A holds claim is not self-certifying:
> `tests/072-law-pins.sh` cross-references every LAW id here against the
> `# pins: LAW-<n>` markers declared by the suite, and fails the build if a
> holds law has neither a pinned test nor an explicit entry on the pending
> backfill list. So a law cannot be added as holds without either a test that
> falsifies it or a recorded promise to write one, and a pin that names a
> renamed or deleted law is likewise a red build. Kernel laws (identity, the
> capability-value bans, traces, handler restore, failure caching) are the
> first pinned group; the rest are paid down under the same gate.
>
> Cross-references: design rationale and the numbered design decisions live in
> [DESIGN.md](DESIGN.md); current limits are summarized by the status table at
> the end of this document.

---

## 0. Preamble: what pp believes

Order comes from data dependencies, not from source position. Build systems,
package managers, init systems, and orchestrators all manage the same thing:
dependency graphs, execution order, caching, and side effects. All of them
re-derive this badly, because the languages underneath model computation as a
sequence of mutations. Shell scripts have no dependency model. Dockerfiles
represent a build as a linked list of snapshots, even though a build is
actually a DAG (a directed acyclic graph) — which is why invalidating one
layer ruins everything downstream. The systems that got this right — Excel,
React, Haskell, Jane Street's Incremental, Nix — all share one law:
computation is a DAG with explicit data flow, the same inputs produce the
same outputs, and caching is principled. pp takes that law as its semantics,
not as a convention.

Identity is structure. Every value has a content hash. Two computations with
the same code and the same input values are the same computation, regardless
of where or when they appear. Caching, deduplication, early cutoff, and
distribution are not features bolted onto pp — they follow directly from
content-addressed identity.

pp is pure by default; effects need capabilities. A capability is authority: a
ceiling on what a computation may touch. It is unforgeable, minted only at
the root, and can only be narrowed. It is not an ordering mechanism and is not
affine — ordering comes from data flow and the single-writer reconciler
(section 9). This replaces Unix ambient authority, in the way Plan 9 and the
capability tradition intended.

`force` is the only execution primitive. Where a computation runs — this
core, another core, another machine — is a scheduler decision, never part of
the language surface. Parallelism and distribution are the same feature at
different scales: running a computation on three nodes and taking the first
result is a handler swap, not an infrastructure project. This is pp's founding
argument for why it exists.

Static typing is a perspective, not a foundation. Hardware, topology, and data
are all dynamic. pp is dynamically typed: type annotations are optional,
gradual claims, checked when a value is forced. This sets pp apart from
Unison, whose type system is too static for the top level of a real system.

The endgame is the operating system expressed as expressions: users,
services, and the filesystem as expressions over a reactive, content-addressed
substrate. Builds are the beachhead that proves the substrate works (the
scope-discipline principle in DESIGN.md, which nails down builds before
provisioning and orchestration).

### 0.1 The two tiers

pp has two tiers, like every one of its models: Haskell's pure/IO split,
React's render/effects split, Excel's formulas/macros split.

- the node tier: pure, strict at node boundaries, content-addressed, cached,
  and distributable. A node (`node` / `defnode`) is the unit of persistence
  and caching. To be cacheable it must be pure and analyzable. This tier is
  where the build, DevOps, and distribution work happens.
- the scripting tier: dynamic, imperative, REPL glue. `write-file` wherever
  you like, with full dynamism and no restrictions. Not cached, not
  distributed, not keyed.

The bargain that connects them: purity is the price of a cache hit, and
caching is opt-in per node. A cache hit means the node does not run, so a
cached node must not perform uncontrolled shared-state writes, or the hit
would silently drop them. Code that wants free effects simply is not a
cacheable node — nothing bans it from the scripting tier. The restrictions in
this spec are the terms of a bargain the programmer opts into, not a
language-wide prohibition.

Status of the tier split itself: partial. The `node`/`defnode` reader forms
exist, and both inline and applied nodes are real persistence boundaries: the
tree-walker routes them through `~/.pp/store` with verifying traces, so a node
caches across runs while a scripting-tier expression does not. They share the
same store. The remaining gap is the broader tier specification, not applied
node identity. The node tier's write discipline now exists: node writes are
sandbox-scratch only (LAW 18, `tests/017`).

---

## 1. Binding and scope — the centrepiece

The `let` question is a test of the founding principle. If order comes from
dependencies and not position, a binding form whose meaning depends on the
textual order of its bindings has brought that problem back into the core of
the language. There are two independent axes here, and conflating them is how
languages get this wrong:

- scope: which bindings can see which others
- timing: when does each binding's value get computed

### [LAW 1] A scope is a local DAG: `let` bindings are mutually visible

In `let (a = e_a, b = e_b, …) { body }`, every binding name is in scope in
every right-hand side and in the body, regardless of textual order. A `let`
is a local Excel sheet: a set of named cells that may reference each other
freely, without regard to position.

Grounding: Excel formulas reference cells by name, never by "the cell above
me", and Haskell's `let` and `where` are recursive for the same reason. The
two rejected alternatives each betray a principle. Sequential scope (Scheme's
`let*`, shell) makes textual position semantically load-bearing — the exact
disease of representing a build as a linked list of snapshots — and it fights
content-addressing, because reordering bindings of the same computation would
change its hash (see LAW 3). Parallel scope (Scheme's `let`) is the worst
middle ground: it is position-independent but cannot express a local
dependency graph at all, forcing nested `let`s that smuggle order back in as
tree depth. Mutual scope is the only choice under which "order from
dependencies, not position" is true inside a binding form, not just between
top-level nodes.

**Status: holds** — the engine builds a mutual environment for `ELet`
bindings; sibling references evaluate correctly and reordering independent
bindings does not change the result (`tests/007-phase0-laws.pp`, fuzzer `full`
grammar).

Test: `let (y = x + 1, x = 1) { y }` gives `2` ; reordering
the bindings must not change the result.

### [LAW 2] Evaluation order within a scope is derived from dependencies; genuine cycles are force-time errors

The runtime computes bindings in an order derived from their actual
references, not their positions. A dependency cycle among bindings is a
runtime error at force time, reporting the cycle, unless the cycle is
mediated by a function value: a lambda delays demand, so mutually recursive
functions are legal and ordinary, as in Haskell and at pp's own top level.

Grounding: this is the language-in-the-small mirror of the build engine. The
wanted-set is ordered by the discovered graph, and cycles are runtime errors
reporting the force path, the same principle DESIGN.md records for cutoff
over dynamic dependency graphs. There is no solver and no declaration step —
demand discovers the order.

On the timing axis: local `let` bindings are ephemeral. They are never
persisted, never keyed, and never stored, so they are free to be lazy
on-demand thunks regardless of the node tier's strictness (LAW 6). Node-level
strictness exists to protect cached nodes; a local binding is not one. An
unreferenced binding never runs.

**Status: holds** — force-time cycles are reported from the active force path,
including the binding names (for example `a -> b -> a`). Function values still
delay demand, so mutually recursive functions remain valid.

Test: `let (even? = fn(n) { if n = 0 { true } else { odd?(n - 1) } }, odd? = fn(n) { if n = 0 { false } else { even?(n - 1) } }) { even?(10) }`
evaluates to `true` . `let (a = b, b = a) { a }` gives a
deterministic cycle error identically .

### [LAW 3] Binding order is not part of a computation's identity

Two `let` forms that differ only in the textual order of their bindings
denote the same computation and must have the same content hash: the code
hash canonicalises binding sets.

Grounding: content-addressing says identity is structure. If reordering
independent bindings changed the hash, the cache would treat one computation
as two. Position would have leaked into identity, which is precisely the
failure content-addressing exists to prevent.

**Status: holds** — the expression hasher sorts the named bindings of a
mutually visible `let`; `let*` and statement-bearing scopes retain source
order.

Test: the node keys (once nodes exist: LAW 15) of
`let (a = 1, b = 2) { a + b }` and `let (b = 2, a = 1) { a + b }` are equal; a
cached result for one is a hit for the other.

### [LAW 4] One scope model everywhere: `let` = `do`-block `def`s = `module` = top level

A scope — local `let`, a `def` block, a module body, the top level of a
program — is one thing: a set of mutually visible DAG nodes ordered by
dependency. Top-level `def`s already behave this way, since later `def`s are
visible to earlier bodies. LAW 1 extends the same model downward so the
language has one scoping story, not three.

Grounding: the point is unification. A module is just a bigger `let`; the top
level is just an implicit module. Excel does not have a different reference
model per worksheet region.

Value defs. A definition that binds a bare name to an expression (AST
`EDefValue`; the s-expression surface spells it `(def x v)`, a non-list head;
the brace surface spells it `let x = v`) is a value binding: the right-hand
side is evaluated when the definition executes, and `x` is bound to the
result — never to a nullary closure (an early footgun this project has since
closed; `tests/025`). Evaluation does not force: a value def whose right-hand
side is a `delay` form binds the unforced thunk, and a name-binding
`defnode` is exactly a value def of the node thunk — `EDefValue (x, ENode e)`,
however a surface spells it. Scope follows LAW 4, with statement timing as
follows.

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
`try {}` block is not a letrec* scope. Its `<-` bindings execute top to
bottom, each visible only to statements after it — a `<-` right-hand side
sees earlier binds, never later ones, so there is no mutual visibility to
poison. Because the block lowers to nested `let`s, binding the same name
twice is allowed: the second `<-` shadows the first for the statements that
follow, exactly as re-`let`-ing a name in nested lets would. This is the one
place LAW 4's rule that a duplicate definition in a block is a read error
does not apply — `try` statements are sequential lets, not a letrec* block of
`def`s. This is pinned by a behavior test that rebinds a `<-` name twice
and checks that later uses see the shadowing value 
(`tests/065-try-rebind-shadow.sh`).

**Status: holds** — top level, `do` blocks, and modules predeclare the same
binding set before executing statements. Function bindings are available
throughout that scope; value bindings retain statement timing and report a
named "referenced before its definition" error when demanded early. Modules
remain fresh scopes, while `let*` remains explicitly sequential.

Test: a module whose first `def` calls its second behaves identically to
the same two `def`s at top level, ; `load-module` without
`import` leaves the caller's scope untouched in both; `let x = 5` followed by
`print(x)` prints `5` (`tests/025`).

### [LAW 5] `let*` survives only as explicit sequential sugar

`let* (a = e1, b = e2) { body }` is the scripting-tier form for "I really do
mean a sequence": shadowing, staged reads, REPL work. Because mutual `let`
makes every right-hand side visible to every other right-hand side in the
same binding set, `let*` is implemented as a distinct sequential form: each
right-hand side is compiled in an environment that contains only the
preceding bindings, and the body sees the final binding. The default, and the
primitive form, remains mutual `let`.

Grounding: sequence is sometimes the true structure — a REPL session is a
sequence. The law keeps that expressible while refusing to make it the
default meaning of binding.

**Status: holds** — the reader emits `ELetStar`; the engine evaluates it
sequentially and agree on shadowing (`tests/007-phase0-laws.pp`, fuzzer
`core` and `full` grammars).

Test: `let* (x = 1, x = x + 1) { x }` evaluates to `2` 
(shadowing, strictly sequential visibility).

---

## 2. Evaluation: strict nodes, pruned demand

This section retires a claim from the project's earlier documentation. The
README once claimed "every expression is a thunk; the DAG emerges from
laziness". That claim is retired: the DAG is the demand-pruned wanted-set
defined by the root desired-state formula, shaped like Bazel's, not an
emergent artefact of per-expression call-by-need. Fine-grained laziness
bought this codebase a class of stack overflows, an allocation storm, an
unsound cache key, and effect-escape hazards — for no build-relevant benefit.
What survives as "laziness" is demand-pruning and skip-on-hit, at node
granularity.

### [LAW 6] Node application is call-by-value with memoization

A node's arguments are forced before the node's body runs, because the node's
key is `H(code-hash ‖ arg-value-hashes)` (LAW 15): the key cannot exist before
the argument values do. Within the node tier, application is strict, and
results are memoized by key.

Grounding: this turns the constructive-trace rebuilder from "Build systems à
la carte" into language semantics — an aggregator (`link`) keyed on child
result hashes forces its children first, by construction. Haskell's laziness
is not the model here; Nix's rule that a derivation's inputs are realised
before it builds is.

**Status: holds** — `node { e }` and applied `defnode` computations memoize
persistently under the LAW 20 key. Node arguments are forced before the body,
and equal applications share one computation across processes.

Test: `tests/097-node-application.sh` proves argument forcing, equal-argument
reuse, distinct argument keys, free-variable invalidation, and scheduler use.

### [LAW 7] Laziness is demand-pruning at node granularity

Only nodes reachable from the root's desired-state value are ever forced. A
single node may, when forced, expand into many nodes — for example, a glob
manifest defining 50,000 compile nodes. Unchanged ones hit the cache;
undemanded ones never run. pp's founding argument that a build such as LLVM's
can be one thunk that expands into 50,000 units on force is preserved — at
node granularity, not per expression.

Grounding: Nix needs "dynamic derivations" and a socket mechanism for this;
a language whose graph expands under evaluation gets it natively. Demand
pruning is Excel not recalculating sheets nobody looks at.

**Status: partial** — `node { e }` and the store exist, and the reverse-edge
dirty-propagation graph now exists for push `stabilize` (`pp --watch --stabilize`,
`tests/032`). Still missing: a formal root desired-state formula and an
explicit wanted-set, so demand-pruning remains pull-mode "re-force from root"
rather than a declared target set.

Test: a root demanding 1 of a manifest's 3 children executes exactly 1
child (journal/trace proves it), .

### [LAW 8] `delay`/`force` is ephemeral, in-memory laziness — a different thing from `node`

`delay(e)` makes an ephemeral thunk: computed at most once per process, never
persisted, never keyed into any store. `force` is idempotent and is the
identity on non-thunks. Lazy sequences (`lazy-seq`, stdlib `cons` chains)
live here. `node` is persistence; `delay` is timing.

Grounding: conflating the two is how the store fills with micro-entries.
Excel draws the same distinction: a formula cell is recalculated and tracked,
but a spilled intermediate value that nobody addresses is not.

**Status: partial** — the persistent/ephemeral split exists in the evaluator:
`node { e }` persists to `~/.pp/store` while `delay(e)` never does. Remaining wart: the
tree-walker also routes ordinary `delay`/`let` thunks through its in-memory
content-addressed dedup table rather than the persistent store, which does not affect the persistent node cache.

Test: `force(delay(42))` evaluates to `42`; `force(42)` evaluates to `42`;
a delayed computation's effect fires at most once across two forces —
identical .

### [LAW 9] `if` evaluates exactly one branch

The untaken branch of a conditional is never evaluated: no effects fire, no
errors raise, and no nodes are demanded from it. `and`/`or` inherit this by
desugaring to `if`.

Grounding: branch pruning is the smallest unit of demand-pruning. A build
system that speculatively evaluates both arms of a conditional is Make, not
Excel.

**Status: holds** — condition forced, branches in tail position in the
tree-walker; eval in the tree-walker; exercised by the fuzzer's `core`
grammar.

Test: `if true { 1 } else { undefined-symbol }` evaluates to `1`; the untaken
branch's `perform log(…)` produces no stderr.

### [LAW 10] Tail calls run in constant stack

A tail-recursive computation runs at unbounded depth (at least a million
calls deep) without stack growth, .

Grounding: a language proposing to be the operating system cannot have "your
service loop overflowed" as part of its semantics. Loops are recursion, and
recursion must be safe.

**Status: holds** — CPS `eval_tail`/`apply_tail` in the tree-walker,
CPS continuations in the tree-walker. Caveat: a tail call inside
`effect`/`with-handler`/`with-config` currently skips the matching scope-exit
guarantee.

Test: a tail-recursive countdown from a million evaluates to `0` with no
overflow.

### [LAW 11] Non-tail depth is a heap problem, not a crash

Non-tail recursion, such as the standard library's `map` over a
million-element list, completes without native stack overflow: evaluation
uses an explicit heap-allocated work stack.

Grounding: the same operating-system argument applies. "Rewrite your fold" is
not an acceptable answer from a substrate.

**Status: holds** — shallow evaluation keeps the direct tree-walker path;
deep evaluation transfers to the same evaluator's heap-allocated continuation
machine. Builtin list traversal is iterative, so evaluator and primitive
frames both remain bounded.

Test: `length(map(inc, range(0, 1000000)))` evaluates to `1000000`  (the same stack-safety requirement as LAW 10).

### [LAW 12] Quotation is total; the language is data

Every form a reader accepts, whichever surface it parses, `quote` can turn
into a value, and quasiquote/unquote work over that structure. Quotation is
defined against the AST (`Core_model.expr`), so every surface shares one
quoted-data language. A Lisp whose quoted conditional (`'(if a b c)`) crashes
is not homoiconic.

Grounding: metaprogramming, including the `defmacro` form that replaced this
project's earlier, abandoned fexpr design, depends on code-as-data being
total, not best-effort.

**Status: holds** — `quote_to_value` handles all expr forms; the reader
parses quasiquote/unquote/unquote-splicing and a runtime walker expands them,
including splicing, nested quasiquote, vectors, and maps. `defmacro`
(`macro.ml`) redeems the grounding: a macro receives its argument forms
already converted by `quote_to_value`, computes over them as data (via
`quote`/`quasiquote`/`list`/`cons`/`gensym`), and the result is converted
back to syntax by `Quotation.value_to_expr` — the total, exhaustive counterpart
of `quote_to_value`, so every case the reader can produce round-trips. This
is possible only because quotation was already total in both directions the
moment `value_to_expr` existed to complete it. `defmacro` is not itself a
reader special form. Its shape — `(defmacro (name params...) body...)` in
the AST, `defmacro name(params…) { body… }` in braces — is recognised
structurally, at the one expansion point the engine uses, never in
`reader.ml`; a macro call is expanded, and gone, before the evaluator's own
machinery (including LAW 20's `hash_expr`) ever sees it.

Test (in the sexpr/AST notation, the natural one for a raw quoted-list
literal — braces have no bare list literal outside `list(…)`, only calls and
`[…]` vectors): `'(if a b c)` evaluates to the list `(if a b c)` in both
backends; `` `(1 ,(+ 1 1)) `` evaluates to `(1 2)` in both. Quoting the brace
form of the same `if`, `quote { if a { b } else { c } }`, yields the
identical list `(if a b c)` — one quoted-data language regardless of which
reader produced the form.

---

## 3. Effects and ordering

### [LAW 13] Effects are strict within `do` and fire in program order

Each step of `do { e1; e2; …; en }` is forced to completion, in order, before
the next begins; `en`'s value is the block's value. A `perform` fires eagerly
when its expression is evaluated. `do` is the sequencing form — the one place
where program order is the semantics, by explicit request.

Grounding: this is Haskell's two-tier answer. Pure values may be computed
whenever; `IO` actions happen in the order written. Effects are the boundary
where the world's arrow of time enters, so they get an explicit, small,
sequential sublanguage instead of leaking ordering into everything.

**Status: holds** — the evaluator forces every `do` step; the fuzzer's
metamorphic oracle compares stderr (the `log` effect stream) for each
program and its semantics-preserving twin.

Test: `do { perform log("a"); perform log("b"); 1 }` writes `a` then `b`
to stderr, identically .

### [LAW 14] Undemanded values fire no effects

Outside `do` and node boundaries there is no program-order guarantee: an
effect embedded in a value that is never demanded never fires. One embedded
in a demanded value fires when demand reaches it. If you need an effect to
happen, sequence it in `do` or make it a node input — do not rely on the
evaluation order of pure positions.

Grounding: Excel does not run the formulas of cells nobody references. The
alternative, effects firing from speculative or positional evaluation, is
exactly the ambient, order-by-accident world pp exists to replace.

**Status: holds** for the current thunk semantics — an unforced binding's
`perform` does not fire, . Its interaction with LAW 6's
strictness follows by construction, since node arguments are demanded.

Test: `let (x = perform log("never")) { 1 }` evaluates to `1` with empty
stderr .

### [LAW 15] Ordering never comes from capabilities

Capabilities answer "may this computation touch X", never "in what order do
writes happen". Ordering comes from data flow — a consumer forces its
producer — and from the single-writer reconciler (section 9). No law in this
spec may be enforced by making a capability linear, affine, or consumable.

Grounding: the design history explored affine write-capabilities and rejected
them: they import an imperative language's mutation-policing into a model
whose whole point is that there is exactly one writer per domain, so there is
no race to police. The factoring stays clean this way — capabilities are
authority and security; the DAG plus the reconciler are determinism and
ordering.

**Status: holds** as a constraint on current code — capabilities play no
ordering role anywhere in `src/`, and the single-writer reconciler enforces
ordering through data flow rather than capability consumption (`tests/018`,
`tests/023`, `tests/033`). Capabilities remain authority and security only.

Test: structural — no spec test may require capability consumption for
its ordering claim, and the capability rewrite that removed the project's
earlier affine "spent" machinery keeps it that way.

---

## 4. Purity and caching: the bargain

### [LAW 16] Purity is the price of a cache hit; caching is opt-in per node

Only nodes are cached. A node must be pure up to its declared effects: no
uncontrolled shared-state writes, no unrecorded reads. Code that refuses the
bargain lives in the scripting tier — uncached, unrestricted, unsurprising.

Grounding: this turns the two-tier preamble into law. Nix's insight is that a
package is a pure function of its inputs because that is what makes the store
possible, not because purity is a virtue in itself. The restriction is the
feature.

**Status: partial** — `node { e }` is opt-in and cached persistently: the same
node forced in two processes runs once, the store serves
the second, and a scripting-tier expression is never cached (`tests/010`,
`tests/014`). The purity half of the bargain is now partly enforced: node
writes are confined to per-node sandbox scratch and absolute node writes error
(LAW 18, `tests/017`), and a tool run inside a node executes in the scratch
dir. A tool's own absolute-path writes are not fail-closed — traces, not the
sandbox, are the soundness mechanism for that case.

Test: the same `node { e }` forced twice across two processes runs once,
which the store proves (`tests/010`, `tests/014`); a scripting-tier expression
forced twice runs twice.

### [LAW 17] A cache hit does not replay ephemeral effects

A hit returns the stored result; `log`/stdout emitted during the original run
are not re-emitted. A hit and a miss may differ only in ephemeral output and
wall-clock time. Any observable difference beyond that is a caching-soundness
bug.

Grounding: this is what "a hit means the node does not run" means, taken
seriously. React does not re-run your logging when it skips a re-render;
pretending otherwise would make hits observable and caching unsound in the
other direction.

**Status: holds** (for the node tier) — a `node { e }` hit
serves the stored result and does not re-emit the `log`/stdout produced on
the miss. This is verified in the tree-walker (`tests/010`) and the tree-walker
(`tests/014`), where a node's in-body `COMPUTE` log fires only on the miss.

Test: force a logging `node { e }` twice, the second run in a fresh
process: the result is identical, and the log is emitted exactly once, on
the miss, .

### [LAW 18] A cached node's writes are sandbox-scratch only

Inside a node, `write-file` targets a sandbox-local scratch path; only output
blob hashes escape. Writes to any reconciled domain go exclusively through
the reconciler (LAW 28). In the scripting tier, `write-file` is free.

Grounding: this is Nix and Bazel-style sandboxing — the build writes wherever
it likes inside a throwaway directory, and only content-addressed outputs
exist afterward. Without this, "single writer" (LAW 28) is only a slogan.

**Status: partial** — the node/scripting split is enforced .
Inside a node, a relative `write-file` targets the node's sandbox scratch, a
lazily created temp directory deleted when the node's frame pops; reads and
writes there are capability-free and unrecorded. An absolute `write-file`
errors, even with a read-write grant. The scripting tier is unchanged. `run`
(`tests/017`). The reconciled-domain write path is now generic: filesystem and
process domains apply desired state through the single writer
(`stdlib/domain-fs.pp`, `stdlib/domain-proc.pp`), while a tool's own absolute-
path writes remain outside the sandbox's control and traces provide the
soundness boundary.

Test: a node calling `perform write-file("/abs/x", …)` errors and the file is
not written; the same call in scripting tier
succeeds; a node's scratch write never appears outside its sandbox
(`tests/017`).

---

## 5. Content-addressing and cutoff

### [LAW 19] Value identity is a content hash, and equal hashes mean equal values

Every value has a deterministic content hash; identity is structure, not
position or time. The hash function must make collisions cryptographically
negligible (this project uses BLAKE3, not MD5) and must cover everything
semantically part of the value — in particular, a closure's hash covers its
captured free-variable values.

Grounding: Unison hashes definitions; pp hashes computations and world
observations. Everything downstream — dedup, cutoff, distribution, "same
inputs same outputs" — is only as sound as this law.

**Status: partial.** The tree-walker's in-memory dedup is now sound: the hash
is SHA-256, closure captures are folded into the key so two closures over
different referenced captures hash differently while unrelated environment
bindings are ignored, and the ambient handler stack is
folded in too. A cross-run store now exists and its value blobs are
content-addressed by result hash, shared across runs. Remaining gap: the
tree-walker's in-memory dedup table is not mirrored across runs, but that is
separate from the persistent node hash, which the engine computes
identically (LAW 20).

Test: two closures over different captured values hash differently;
structurally equal values built by different routes hash equally — checked in
the engine.

### [LAW 20] Node key = H(code-hash ‖ arg-value-hashes); authority and handlers are not identity

A node's key covers exactly its code, with free variables resolved to the
hashes of their values, and its argument value hashes. Not in the key: the
capability set (authority is checked at hit time — LAW 23), the handler stack
(LAW 26/27), or the ambient environment beyond referenced free variables.
What a node reads during execution is recorded in its trace, and that governs
validity, not identity.

Grounding: this is the key/trace split for identity versus validity from
"Build systems à la carte", and Nix's content-addressed derivation
realisations. A key built from `hash(expr, full-env, caps, config)` leaks
catastrophically: touch one standard-library binding and every key in the
program changes, or widen a capability and the whole world rebuilds.
Authority may gate access to a result; it must never rename the result.

**Status: partial** — the persistent node key is
`H(code-structure ‖ free-var value-hashes ‖ argument-value-hashes)`. The free
variables the node references are resolved, forced, call-by-value, to their
value hashes and folded in, excluding the whole-environment hash and the
capability set. The tree-walker resolves them from its environment
(`Identity.node_key`); the evaluator resolves them from the captured frames and globals
producing a stable key for data-valued free variables so store entries are
shared across runs. The
two catastrophic leaks this law names are closed: rebinding an unreferenced
global is a cache hit, and widening the grant does not invalidate anything
(`tests/011`, `tests/014`, `tests/097`). Config and the handler stack are now fully out of
the key: a config read or a perform inside a node records a `config:`/
`handler:` trace cell instead (LAW 33/26, `tests/015`). Residual:
binding-order canonicalisation is not done (LAW 3).

`defmacro` needed no change to this law, by construction. `hash_expr`
(`node_key_of`) consumes an expression tree that has
already been macro-expanded — expansion (`macro.ml`) is the one shared step
every top-level-form-shaped list passes through before the evaluator's own
machinery ever sees it (the REPL drivers, the REPL drivers and `ELoad`/`eval_module_file`). So "the
code hash must hash the expanded form" is not a special case this law had to
grow: a node built from a macro call is keyed on exactly the code the macro
expanded into, and editing only the macro's own definition, with the call
site unchanged, changes that expanded code, hence the key, hence forces a
recompute (`tests/042-defmacro-rekey.sh`).

The node boundary is symmetric: authority may not cross it in either
direction. Once capability values exist (`current-capabilities` and related
forms), a node's free variables and its result are both potential smuggling
routes, so both are banned outright, independently of each other.

- import side (the free-variable ban): if a node's free variable's forced
  value contains a `VCapability` anywhere in its structure, including inside
  a captured closure's environment or frames, `node_key_of`
  raise `Capability_error` naming the variable, rather than silently keying
  on — and thereby encoding, in the store's key namespace — a piece of
  authority. A capability hidden behind an unforced thunk is a documented
  gap, since LAW 14 forbids forcing it just to check; the use-time gates in
  LAW 22b and LAW 23b are the actual floor for that residual case, not this
  hygiene check.
- export side (the result ban): if a node's result contains a `VCapability`,
  `run_node_body` raises `Capability_error ("a node may not return a
  capability")` before anything is stored. Without this, `node {
  current-capabilities() }` would be an ambient-dependent result invisible to
  both the key and the trace — a determinism hole — and a broad capability
  could ride a cached result out to a caller narrower than the node's own
  creator.

Test: rebinding an unreferenced global does not change the node key;
widening the root grant does not invalidate a cached result; changing a
referenced free variable does (`tests/011`). A node whose free variable is,
or whose captured closure contains, a capability gives `Capability_error`,
directly and through a closure, . A node whose body returns
a capability, bare or embedded in a compound value, is rejected before it
can be stored, (`tests/capability-adversarial.sh`).

### [LAW 21] Cutoff is hash equality; validity is the trace, not the key

If a recomputed node's result hash equals the prior result hash, dependents
are not dirtied, even though an input changed. A cached result is valid only
if some stored trace's every `(cell, hash)` observation still matches; one
key may hold many traces, for example from different observed toolchains or
platforms.

Grounding: content-addressing makes the cutoff in Jane Street's Incremental
free and exact — hash equality instead of user-supplied equality functions.
This is the comment-only-header-edit story from DESIGN.md: a compile must
re-run, but a link must not.

**Status: partial** — the validity-is-the-trace half is real: each node key
maps to a set of traces, every trace records the
`(file-cell, content-hash)` observations the node made, plus `config:` and
`handler:` cells (LAW 33/26), and a hit is granted only if some trace's every
observation still matches the world. So editing a file invalidates the node,
reverting it re-matches an older trace in the set, an unchanged file hits,
and a touch (a change to modification time only) is a non-event (`tests/010`,
`tests/016`). The cutoff half is real at node granularity through LAW 20's
keying: a downstream node whose free variable is an upstream node's value
re-keys identically when a recompute produces a byte-identical result — the
comment-only-header-edit story holds today when the build threads values
through free variables, so the compile re-runs but the link hits
(`tests/016`). Not implemented: cutoff for a node inline-nested in its
dependent's body, where the parent's trace subsumes the child's reads, so the
parent re-runs regardless. The reverse-edge dirty-propagation graph now
exists and is used by push-mode `stabilize` (`Store_index.reverse`,
`Stabilize.reset_dirty`; `pp --watch --stabilize`; `tests/032`); pull-mode
re-verification still walks from the root when `--stabilize` is not used.
Glob and toolchain-closure cells are not yet recorded.

Test: editing a file read by a node re-runs it; an unchanged read hits;
reverting the file hits the original trace in the set (`tests/010`); a
touch that only changes the modification time rebuilds nothing, and a
header edit that leaves the compile result byte-identical re-runs the
compile but not the value-keyed link (`tests/016`).

---

## 6. Capabilities

### [LAW 22] Capabilities are unforgeable and enter only at the root

There is no expression that creates authority. `main` receives a powerbox
from the command line (`--grant ...`), and that is the sole mint. User code
holds capabilities, passes them, narrows them with `cap-restrict`, and unions
what it already holds with `cap-compose` — it never constructs one.
`filesystem("/", :rw)` is an unbound symbol, not a value.

Grounding: the capability tradition's first theorem is that authority you can
fabricate is not authority, it is a comment. pp's founding argument demands
that capabilities replace Unix ambient authority; a mintable capability is
ambient authority with extra steps.

**Status: holds** — `filesystem`/`network`/`process` and similar names are
unbound symbols; only `--grant` at process startup mints capabilities.
`cap-restrict` and `cap-compose` only narrow or union capabilities the code
already holds. `CapNetwork` is now `{host; port option}`, a shape change from
the earlier bare `{protocol}` (`--grant net:<host>[:<port>]`; `host = "*"`
wildcards, and an unspecified port is unrestricted). `CapSecret {path}` is a
newer kind (`--grant secret:<path>`, canonicalised at mint like filesystem
grants). Both mint only via `--grant`, the same as every other kind — adding
kinds does not change the root-mint invariant.

Test: the adversarial suite (`tests/capability-adversarial.sh`) checks
that no program, through any user-code surface, reads or writes a path it was
not granted, and that evaluating `filesystem("/", :rw)` is an unbound-symbol
error . `tests/045-network.sh` checks that no `net:` grant,
or a `net:` grant for a different host, denies `perform http-get(…)`/
`perform http-post(…)`, while a covering grant (an exact host, or `net:*`)
allows it, aware of both host and port — a grant for one host or port never
authorises another.

### [LAW 22b] `with-caps` narrows to a held value, never widens

`current-capabilities()` reifies the ambient set as of the call: an
observation of the ceiling the code already exercises on every `perform`,
never a mint. `with-caps(cap-expr) { body }` replaces the dynamic ambient
with exactly `cap-expr`'s value for `body`'s extent, gated by checking that
`cap-expr` is a subset of the current ambient. That check runs against the
ambient live at the `with-caps` form, not the process's root grant, so a
narrowing composes even when some other in-scope binding lexically retains a
broader capability value. `cap-restrict`'s optional mode argument is
symmetric: requesting a mode wider than what the underlying capability
already grants at that scope is `Capability_error`, never a silent widen.
The `effect` form — the prior capability-union block, with the rule
"capabilities union with the ambient" — is removed: the instant capability
values exist, a union-with-ambient rule is a widening backdoor, so it could
not be kept alongside `with-caps`.

**Status: holds** — `current-capabilities`, `with-caps`, and `cap-restrict`'s
mode argument are implemented . The subset check is
evaluated per capability kind, using the per-kind check functions LAW 25
describes, with `CapRestrict`'s authority computed as its effective `(path,
mode)` grants — the scope/mode intersection with the underlying capability,
not a mint. `with-caps` establishes a dynamic extent that is restored on
every exit: normal return, tail call, and a raised exception alike (LAW 27;
`with-caps` runs the body via a nested call wrapped in a real
exception handler, rather than the flat enter/exit opcode pair
`with-config`/the removed `effect` used, specifically so a raised error still
restores the ambient).

Test: composing two capabilities each narrowed from the same broad root
grants only their union, never the root's full authority
(`compose-does-not-resurrect`); a capability value held from before a
`with-caps` narrowing fails the subset check when reused inside the narrowed
extent even though it is still lexically in scope
(`with-caps-widen-rejected`); requesting a wider `cap-restrict` mode than the
underlying capability holds is rejected
(`cap-restrict-mode-widen-rejected`); a `with-caps` body that raises, or ends
in a tail call, still restores the prior ambient afterward
(`with-caps-exception-safe`, `with-caps-tail-safe`); `effect(…)` is an
unbound-symbol error (`effect-removed`) — all in
`tests/capability-adversarial.sh`.

### [LAW 23] Authority checks are component-wise, full-path, and transitive at hit time

Three requirements apply. Path scope matching is by path component on the
canonicalised full path, so a grant of `/tmp` covers `/tmp/x` and never
`/tmpevil`. A cache hit is granted only if the caller's capability set covers
the transitive read closure of the stored trace — every cell read by the
node, and recursively by every child node — so a narrow caller cannot
launder a broad read through an aggregating parent, for example
`PUB = f(SECRET)`. Introspection surfaces, such as `pp why` and other
hit/miss observability, are capability-filtered, because the mere existence
of a key is itself an oracle.

Grounding: the cache is a communication channel between past and future
executions, so authority must gate the channel, not just live `perform`s.
DESIGN.md derives the transitive requirement and its precomputed
`closure-cap-req` fast path from this.

**Status: holds** (with one residual gap) — path checks are component-aware
and full-path (`/tmp` does not grant `/tmpevil`), and the full path is now
uniformly canonicalised first: `World_path.canonical` — absolute realpath,
symlinks resolved, no trailing slash — runs at every `file:`/`tree:`/`stat:`/
`tool:`/`runtime:file:` construction site, at `--grant` parse time, and at
the loader bound (`Loader.authorized`). `Capabilities.path_grants`
re-applies it to both sides of every scope check, so a grant spelled one way
authorises a cell observed another way — a symlinked source tree, macOS
`/var` versus `/private/var`, a trailing slash (`tests/036`). A path that
does not yet exist canonicalises its longest existing prefix and appends the
rest lexically, so a write-target's cell id is stable before and after the
file is created (`tests/036`). Unicode normalisation (NFC) is not
implemented — a documented residual gap that needs a new dependency and is
orthogonal to the realpath fix. The transitive-closure requirement holds : a hit is served only if the caller's capabilities cover every
cell in the stored trace's read closure (`Cache_policy.lookup ~authorized`), and
because reads propagate to enclosing nodes the closure is transitive — a
narrow caller cannot launder a broad read through a cached aggregator
(`tests/013` tree-walker, `tests/014`). A capability denial raises the
distinct `Capability_error` and is deliberately not memoized, since authority
is not identity or validity (LAW 15), so granting the capability later still
yields a hit. `pp why` exists and is capability-filtered: it explains each
node's hit or miss (first build, stale cell, unauthorized, verified trace) to
stderr, and redacts rather than names a cell the caller has no authority over
(`tests/019`).

Test: grant `fs:/tmp:ro`: reading `/tmpevil/x` errors . A
caller scoped to `src/` gets no hit on a node whose transitive closure
touched `/etc/passwd` (one of the acceptance checks for the capability-hit
milestone).

### [LAW 24] Loader reads are runtime authority, not user effects

`load`, `import`, `island`, and standard-library and module resolution are
the loader's own reads, bounded to the program's source roots and the store.
They run under the interpreter's runtime authority, are tagged `runtime` in
traces, and are excluded from user capability accounting, both at perform
time and in the hit-time closure check.

`island` is a genuine resolve: the form's inline 64-character hex pin names
an immutable, verified tree in the island cache, and the mapping from URI to
pin is identity — it lives in the code hash (LAW 20), never in a trace cell.
An unpinned island form is a hard error. Fetching new pins (`git:`/`github:`)
is opt-in runtime authority (`--fetch-islands`/`--update`, journaled — see
docs/THREAT-MODEL-islands.md), so with it disabled, evaluation never touches
the network.

Grounding: every program loads its own source, so charging that to user
capabilities would make a caller scoped to `src/` unable to hit any node
whose closure touches the standard library. The runtime/user split is
load-bearing, not cosmetic.

**Status: holds** — every loader read  goes through
`Loader.read`: bounded to the directories of the programs named on
the command line, the working directory, and `~/.pp`. Loading anything else
errors, with or without a grant. Each read is recorded as a
`runtime:file:<path>` trace cell that participates in cache validity —
editing a loaded module invalidates the nodes that loaded it — while being
exempt from the hit-time authority requirement (`tests/020`). The bound is
now realpath-canonical (LAW 23, `tests/036`): a symlinked source tree is
authorised identically to the real path.

Test: a program granted nothing can `load(…)` beside its own source and
hit a node cache whose trace contains that load; loading a path outside
every source root errors even with a broad filesystem grant; editing the
loaded file invalidates the node — (`tests/020`).

### [LAW 25] Unenforced authority may not exist

A capability kind that nothing enforces — `CapTime` and `CapMemory` today —
must not appear in the surface language. Resource budgets return only when a
scheduler enforces them.

Grounding: this is this spec's honesty rule applied to the language itself.
An unenforced security surface is worse than none, because it teaches users
to trust a fiction.

**Status: holds** — `CapTime`/`CapMemory` have been removed from the
capability type and surface language.

Test: evaluating the time/memory constructors is an unbound-symbol error
 until a later scheduler milestone enforces budgets.

---

## 7. Handlers

### [LAW 26] Two handler classes: result-transparent and semantic

Result-transparent handlers, such as the schedulers covering placement, may
change only where or when work runs, never observable results. They cross
node boundaries freely and appear in no key and no trace. Semantic handlers —
a mock `read-file`, fault injection, an alternate `run` — change meaning:
each intercepted `perform` inside a node records a synthetic trace cell
`handler:<handler-code-hash>:<effect>:<arg-hash> → result-hash`.

Grounding: this resolves an old trace-layer problem where swapping a mock for
the real implementation changed the handler code hash, hence the synthetic
cell, hence gave sound invalidation — strictly better than keying on the
whole handler stack, which would rebuild the world on any handler change,
even for effects a node never performed. It is also what makes "the
scheduler is just a handler" (LAW 31) compatible with caching at all.

**Status: partial** — the semantic half is implemented at node granularity : every `perform` inside a node records a `handler:<effect>`
trace cell whose observed hash is the intercepting handler's value hash, or a
builtin marker when none intercepts, re-observed against the caller's handler
stack on a hit. So a node cached under a mock `read-file` and one cached
under the real builtin coexist as two traces under one key and never
cross-contaminate (`tests/015`). The recorded cell is coarser than the law's
`handler:<code>:<effect>:<arg-hash> → result-hash` form, with no per-argument
or per-result refinement yet, and the handler stack is still folded
conservatively into the in-memory thunk key. The result-transparent class is
implemented by the serial/parallel/race/remote scheduler handlers, which are
excluded from node identity and traces; differential scheduling tests cover
their result transparency (`tests/024`, `tests/038`, `tests/048`).
`http-get`/`http-post` are newer builtin, semantic-class effects, dispatched
through the same `perform_effect`/`handler:<effect>` machinery as
`read-file`/`run` — no new handler category. They are banned inside node
bodies outright, by a trace-stack guard shaped like `fenced`/`write-file`'s
node-body ban, rather than given a trace cell: a network read is not the
declared-nondeterminism mechanism (LAW 37/38's probes are that mechanism) and
is not convergent, so it has no sound node-cached meaning at all. It is legal
only in probe observe functions, in domain observe/apply functions (a later
stage of this feature), and in the scripting tier.

Test: force a node under a mock `read-file` handler, then under the real
one: two executions, two results, no cross-contamination (`tests/015`); a
result-transparent handler swap yields a hit with identical result hash
(the `--check` audit) — the engine.

### [LAW 27] Effect, handler, and config scopes are dynamic extent — exception-safe and tail-safe

`effect`, `with-handler`, and `with-config` establish dynamic-extent state
that is restored on every exit: normal return, tail call, and raised error
alike. Scope state never leaks out of the form that established it.

Grounding: fail-open dynamic scope is an ambient-authority generator — a
leaked handler or capability set is authority nobody granted. The semantics
of try/finally are the floor here, not a nicety.

**Status: holds** — `effect`, `with-handler`, and `with-config` now restore
capabilities, handlers, and config on normal return, exception, and tail
call. Handler invocation saves and restores the operand stack.

Test: `do { with-handler(log = h) { tail-loop() } ; perform log("x") }` —
the final `log` uses the builtin, not `h`, ; an error raised
inside `effect` leaves the capability set exactly as it was before entry.

---

## 8. Errors

### [LAW 28] A failure is a value with a trace: memoized, and re-forceable exactly when an input changes

A node that fails stores a failing trace: the result is the error's hash,
and the outcome is marked failed. A later force with unchanged inputs
re-serves the failure without re-running; the node is re-executed exactly
when a cell in its failing trace changes. Forcing a failed thunk must report
the original error, never a fabricated one.

Grounding: this applies Nix's realisations and the verifying traces from
"Build systems à la carte" to failure. A clean build that re-runs every
known-broken compile is not incremental. Determinism means failures are as
reproducible as successes.

**Status: partial** — holds : a `node { e }` that raises a
`Failure` stores a failing trace (the error value plus the reads made up to
the failure), and a later force re-serves the same error without re-running
the body, re-running only when a recorded read changes (`tests/012`
tree-walker, `tests/014`). An earlier bug, where a raising thunk left its
`Evaluating` marker set and so looked like a fake infinite recursion, is
fixed for both persistent and ephemeral thunks. Not yet covered: only
`Failure` exceptions are memoized (other exception kinds reset the status and
re-raise but are not cached), and the failure epoch is not yet scoped to the
reconciler.

Test: force a failing node twice: same error text both times, body run
once, since the in-node `log` fires only on the miss; touch its input, force
again, and it re-runs (`tests/012`).

### [LAW 29] Errors carry source locations

A runtime error reports the file and line of the failing form, and, for type
errors, the definition site of the annotation (LAW 30).

Grounding: an error without a location is a riddle, and the substrate for an
operating system should not answer riddles with stack-free strings.

**Status: holds** — emitting `ELocated` for every top-level form, and
wrapping `def`/`fn`/`defnode` bodies with their definition-site location, is
an obligation on every reader, identical across surfaces (the current
s-expression reader satisfies it). The shared top-level driver appends the
enclosing form's `file:line` to any runtime error
whose message does not already carry a location, so arbitrary top-level
expression errors report where they happened, never doubled
(`tests/027-error-messages.sh`). Parse errors include file and line. Arity
errors name the function being called (`arity mismatch calling f: …`),
capability errors name the operation (`read-file: capability error: …`), and
unbound-symbol errors use one stable format. Uncaught errors
print as one clean `pp: error: …` line with exit code 1.

A loaded file's forms are located against that file, not the loading form:
`Reader.read_string` reads a loaded file with its own path (it used to fall
back silently to the reader's `"<?>"` placeholder), and each of its
top-level forms is evaluated (the tree-walker's `eval_expressions`) or
evaluated one at a time, under the same
never-doubled location decoration as the outer top-level driver
(`Error_context.with_form_location`/`message_has_location` — one implementation,
shared across runs and both nesting levels). An error inside the loaded
file is decorated with its own `file:line` before it can unwind past the
`load`, so the `load(…)` call site's own decorator, seeing a message that
already carries a location, leaves it alone.

Test: `car(5)` at line 3 of `f.pp` reports `f.pp:3` in 
with byte-identical stderr (`tests/027`); case (g) loads a file whose second
form is `car(5)` and checks that the reported location is the loaded file's
line, not the loading form's.

---

## 9. Desired state and the single-writer reconciler

### [LAW 30] Program = pure function from input cells to a desired-state value; the runtime is the single writer

For observable, convergent domains, such as an output tree or a process set,
a pp program computes and returns a desired-state value — `{path →
blob-hash}`, `{proc-name → spec}` — a pure, hashable, diffable value. It
performs no domain writes. The reconciler, the one privileged writer per
domain, diffs desired against observed cells, applies the minimal change,
and verifies after the write. A single writer means no write-write races,
which means no ordering discipline is needed in user code (LAW 15). Nodes
feeding a domain's desired state may not read that domain's own cells —
stratification — because otherwise reconciling would loop forever.

Grounding: this is React, verbatim. You never touch the DOM; you return the
desired DOM and the reconciler applies the diff. It is the same idea behind
Kubernetes controllers and Terraform's plan/apply cycle, done with a language
that makes the desired value cheap to recompute (because it is cached) and
with reality re-observed rather than trusted from a state file.

**Status: holds** (the full form, with per-domain stratification) — the
write-discipline law is now enforced generically, for any registered domain,
not hardwired to the filesystem. A domain is an `observe`/`diff`/`apply`
triple of ordinary pp functions (`register-domain`, scripting tier), and
core (`src/runtime/domains.ml`) wraps every domain's `apply` in the same journal
bracket, `observed_all` suspension, plan cache, and verify-after-write,
regardless of what the domain converges. The trusted mechanics —
atomic materialize/remove, fork/exec/reap, and
per-domain state persistence — live in primitives
(`tree-observe`, `materialize-file`, `remove-file`, `proc-spawn`,
`proc-alive?`, `proc-stop`, `proc-reap`, `domain-state-get`/`put` in
`src/runtime/domain_prims.ml`), and all the policy — the tree-walk diff, the
start/stop/restart decision — moved into `stdlib/domain-fs.pp` and
`stdlib/domain-proc.pp` as ordinary pp source.

`pp --reconcile ROOT prog.pp` auto-loads `stdlib/domain-fs.pp` and registers
it with a write capability restricted to ROOT, taking the program's final
value — `{relative-path → content}` — as the filesystem domain's desired
state. It diffs that against observed reality by content hash, applies
atomically, deletes unmanaged files (single writer), journals, requires a
filesystem write grant, and refuses stratification (`tests/018`, unchanged
byte for byte from the earlier implementation). Desired contents may be
inline strings or `blob:<sha256>` content-addressed-store references
(`tests/023`).

Watch mode: `pp --watch --reconcile ROOT prog.pp` runs the program,
reconciles, polls cells for changes, and re-runs on change (`tests/031`).
Every registered domain is now re-observed, re-diffed, and re-applied on
every tick regardless of which cells changed — generalised from an earlier
process-only recheck — so a killed service or an externally drifted file is
caught within one poll interval either way; this stays cheap when nothing
changed, since the plan cache turns a no-op pass into a cache hit.

Push stabilize: `pp --watch --stabilize prog.pp` uses the reverse-edge index
from stored traces to reset only dirty thunks, so clean nodes skip
repository lookup entirely; the test `tests/032` confirms the same
re-evaluation patterns to pull mode on the engine.

The process domain: `pp --supervise prog.pp` auto-loads
`stdlib/domain-proc.pp` and registers it. The program's final value is a map
of service name to spec, kept in sync with observed reality: it starts
missing services, stops removed ones, and restarts on a spec change,
compared structurally via `hash-value`, which canonicalises map-key order
the same way the on-disk codec does, so a spec round-tripped through
`domain-state-get`/`put` must not spuriously compare as different. It reaps
zombies and restarts a service killed with `kill -9` within one poll
interval. This requires `--grant process`, journals intent/done pairs owned
verbatim by the `proc-spawn`/`proc-stop` primitives, and refuses
stratification on `proc:` observations (`tests/033`, unchanged byte for
byte).

A third-party domain unrelated to the filesystem or process domains — the
toy "kv" domain in `tests/046-domains.sh`, registered from an ordinary pp
program via `register-domain` with neither `--reconcile` nor `--supervise`
— proves the protocol is genuinely generic: plan caching across separate
process invocations (proved via `pp why`), stratification, capability
threading (`cap-restrict` itself refuses before the domain ever runs),
verify-after-write failure surfaced for a deliberately under-converging
`apply`, the generic journal bracket, and fenced-after-domains ordering all
hold for it too.

Fenced effects (LAW 31) are live: `fenced(KIND, SPEC)` registers a
scripting-tier action, drained once per pass after all domains' convergent
work; `--fenced-policy retry|abort|ask` resolves unknown-status intents; a
killed mid-apply action is recovered without silent double-execution
(`tests/034`).

Host-qualified domain distribution: the desired map generalises one level,
to `{host -> {domain -> desired}}`. An explicit `--member-name <n>` flag,
never inferred, makes `main.ml` index that one host's `{domain -> desired}`
slice and hand it to the unchanged `Domains.run_all`/`run_domain` above,
which never learn host-keying exists. Without the flag, the desired value
passes through untouched, so every pre-existing program and flag combination
(this law's own `tests/018`/`tests/033`/`tests/046`) is byte-identical to
before. A member's recovery from `kill -9` is this law's existing
per-machine story, unchanged (`tests/049-host-domains.sh`).

Test: first reconcile creates the tree; a null reconcile writes nothing;
manual drift and foreign files converge away; a shrunk desired map deletes
the leavers; no write grant gives a capability error; a self-reading desired
state gives a stratification error (`tests/018`); the process domain's
equivalents hold (`tests/033`); a from-scratch third-party domain holds all
of the above plus plan caching and verify-after-write failure (`tests/046`).
Most of the build-engine milestone's acceptance checks hold on a 101
translation-unit C build (`tests/024`), the self-hosting build check passes
via `scripts/build-self.sh`, and the same checks replicate on Lua 5.4.7
(`scripts/build-lua.sh`) — all unaffected by the domain-generalisation work,
since `--reconcile`'s observable behaviour is unchanged.

### [LAW 31] Fenced effects are reconciler-only, journaled, at-most-once per pass

Non-convergent actions, such as sending an email or charging a card, may not
appear in node bodies at all — nodes are cache-replayable and must not
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

Grounding: the desired-state law covers convergent writes only. Pretending
it tames non-idempotent actions is how systems double-charge cards. This
carve-out is named, not hidden.

**Status: holds** — the engine uses the same primitive and journal
format; a `fenced(…)` inside a node body raises an error; an unknown-status
action is resolved by policy; a killed mid-apply action is retried exactly
once under `--fenced-policy retry` and marked done under `--fenced-policy
abort` (`tests/034`).

Test: kill `pp --watch --reconcile ROOT --fenced-policy retry` between
`intent fenced` and `done fenced`. On restart, the action is retried exactly
once — the crashed run plus one recovery retry — and no silent
double-execution occurs (the crash-recovery requirement for fenced effects).

---

## 10. Types

### [LAW 32] Types are optional, gradual, and checked at force time — and the oracle is the strictest implementation

pp is dynamically typed. A type annotation is a checked claim: when an
annotated value is forced, a mismatch is a runtime error reporting the
annotation's definition site. No annotation, no check. The tree-walker, the
project's correctness oracle, must enforce at least everything the engine
enforces — an oracle weaker than the fast path is not an oracle.

Grounding: this project holds that static typing is a perspective, not a
foundation. The top level of a real system is dynamic; static subsets live
inside it as checked claims. This is the differentiator from Unison.
Force-time checking makes annotations meaningful without a phase that must
see the whole, dynamic, graph.

**Status: holds** — the engine enforces type annotations at force time;
the tree-walker's `check_type` mirrors the tree-walker (`tests/004-type-test.pp`).
`def`/`fn`/`defnode` bodies carry their definition-site location, so type
errors cite the annotation site. Per-parameter annotations are checked too,
however a surface spells them (s-expressions: `(def (f x : int) …)`,
`(fn [x : int] …)`; braces: `def f(x: int) { … }`, `fn(x: int) { … }`) —
they used to parse and then be discarded. A reader-level desugar, downstream
of any surface's parser, rewrites each into a located type check
(`ELocated`-wrapped `ETyped`) that runs ahead of the body, so the engine enforces the shared AST identically (`tests/026-param-types.sh`, fuzzer
`stmt_param_typed_def`).

Test: `def f(x): int { "s" }` forced gives the same type error, citing
the annotation site, ; `f("oops")` against
`def f(x: int) { … }` gives `type mismatch: expected int, got "oops"`,
citing the definition site; unannotated
code never type-errors.

---

## 11. Config

### [LAW 33] Config is ambient, dynamically scoped data; nested scopes shadow; keys may be computed

`with-config({..}) { body }` pushes a config frame for `body`'s dynamic
extent; `config(k, [default])` reads the nearest frame, falling through to
the default. Inner frames shadow outer ones. The key expression is an
ordinary expression, so computed keys are legal. Config is data — what to
build; capabilities are authority — whether you may. A node that reads
config has observed an input: the read participates in the node's identity
and validity like any other observation, so the same code under different
config is a different computation.

Grounding: this is the ReaderT/React-context pattern — parameters that flow
by enclosure, not by threading arguments through every call. Keeping config
out of the authority system keeps "what" and "may" from contaminating each
other.

**Status: holds** — computed config keys work in  nested
scopes shadow, and config frames are restored on every exit: normal, tail,
and exception (`tests/006-config-test.pp`, `tests/007-phase0-laws.pp`). The
"config read is an observed input" clause is now real at node granularity: a
`config(k)` inside a node records a `config:<k>` trace cell, where absence is
itself a distinct observation, re-observed against the caller's config stack
on a hit, and ambient config is excluded from the node key (`tests/015`).

Test:
`with-config({"k" -> 1}) { with-config({"k" -> 2}) { config(string-append("", "k")) } }`
evaluates to `2` ; outside both forms it evaluates to the
default.

---

## 12. Location transparency and distribution

### [LAW 34] `force` is the only execution primitive; location has no surface syntax

There is no `remote-eval`, no placement annotation, no node-pinning form —
and there never will be. Where a force runs is decided by the active,
result-transparent (LAW 26) schedule handler; cluster membership is ambient
config or capability. A program is byte-identical whether it runs on one
core, eight, or a cluster.

Grounding: this is pp's core founding demand. Microservices exist because no
language lets you say "evaluate this elsewhere and flow the result back."
The moment location is syntax, every caller hard-codes topology, and you have
rebuilt the deployment-boundary blunt instrument inside the language.

**Status: holds** for the negative half: no location surface exists in any
reader, and this absence is verified. The positive half now lands for local
process-pool parallelism: `--schedule serial|parallel:N|race:N` selects a
result-transparent handler (`src/runtime/scheduler.ml`) that forks worker processes
at the dispatch point. A worker runs the exact `run_node_body` the serial
miss arm calls, with no second force path, and communicates only through the
store; a dead worker degrades to an ordinary in-process recompute, never a
wrong answer. `--schedule` is read only by the miss arms and the
scheduler, never by `node_key_of`, and it never enters a
trace, so "a program is byte-identical whether it runs on one core or eight"
holds by construction, not merely by intent.

This extends to a cluster: `--schedule remote:<member>` is the same
`Scheduler.policy`/`dispatch_batch` seam, gated to data-closed batches, since
every free variable re-encodes under `Codec.encode_value`. Membership comes
from `~/.pp/cluster/members`/`$PP_CLUSTER_MEMBERS`, ambient config, never
`--grant` — an address is not an authority ceiling, the same distinction
this law already draws between location and syntax. A member is an ordinary
second `pp` invocation of the byte-identical program; a non-data-closed
node, an unreachable member, or a crashed member all degrade to local
compute, never a wrong answer (`src/runtime/remote.ml`).

A later stage of this same cluster work adds cluster membership's
write-domain half: host-qualified domain distribution generalises the
desired map one level, to `{host -> {domain -> desired}}`, indexed by the
same kind of ambient identifier this law already uses for
`remote:<member>` — an explicit `--member-name <n>` command-line flag, never
`--grant`, so the negative half of this law stays intact. It hands the
unchanged `Domains.run_all` (LAW 30) only that host's slice; a member is
simply `pp --watch [--supervise] --member-name <n>` on its own slice, the
local supervisor's existing per-machine story, verbatim. Explicit store garbage
collection (`pp gc`, explicit, never automatic) is orthogonal to placement:
it never runs during a scheduled force, only via its own command, and is
documented alongside LAW 30.

Test: no reader accepts a placement form (unchanged). The same 101
translation-unit build under `--schedule parallel:N` produces a
byte-identical desired-state hash and materialized tree to the serial run,
with measured speedup (`tests/024`'s `p3-*` assertions); `--check` under a
non-serial policy re-runs forced-serial against the same store and fails on
any hash mismatch (the schedule-transparency audit, same file). `tests/038`
stress-tests N concurrent workers against one store and a `race:N` fan-out.
For cluster placement: the same build, scaled to 8 translation units, under
`--schedule remote:<member>` over the local-directory transport, is
byte-identical against serial, plus the cross-machine hit, differing-file,
and degrade-path assertions (`tests/048`'s `T6`/`Q11-bis`/`cross-machine-hit`
assertions). For host-qualified domain distribution: `--member-name`
converges only its own slice while another host's stays untouched, and a
member's recovery from `kill -9` holds on that slice
(`tests/049-host-domains.sh`); the by-hash desired-value seam crosses two
separate home directories including a `blob:` reference's bytes, rejects a
tampered published object, and survives `pp gc` on the receiving side
(`tests/051-cluster-exit.sh`); store size stays bounded across both repeated
one-shot passes and a genuine `--watch`-loop/`pp gc` race, with the kept
root's closure surviving the sweep (`tests/050-gc.sh`'s T7 assertions).

### [LAW 35] "Run on N, take the first" is a handler, not a feature

Redundant, parallel, or distributed execution policies — fan-out, racing,
work-stealing, locality — are swappable schedule handlers: library code, with
zero change to the language surface. Parallelism and distribution are the
same feature at different scales.

Grounding: this sentence is pp's founding demand, restated as an acceptance
test. If shipping it requires new syntax, LAW 34 has been violated
somewhere.

**Status: holds** for local process-pool fan-out: `race:N` forks N
redundant workers for one singleton node miss. This is homogeneous
redundancy only — LAW 37 nodes are deterministic, so racing identical
`(key, run)` jobs is sound, while heterogeneous racing of different
computations stays out of scope until the declared-nondeterminism cells of
LAW 37/38 exist. The first success wins, losers are killed
(`SIGTERM` then `SIGKILL`), and the parent re-enters `Cache_policy.lookup` exactly as
the batch path does. Cluster and distributed racing is a later milestone,
gated on a threat model.

Test: `tests/038`'s race:3 case, one of the acceptance checks for this
milestone: swap `serial` for `--schedule race:3`, with byte-identical
program text — only the command-line flag differs — and check for an
identical result hash, exactly one surviving trace line
(the store's own content dedup, not merely fork timing), wall-clock roughly
one run rather than N.

---

## 13. Evaluator correctness

### [LAW 36] The tree-walker is the single reference engine

The tree-walker is the executable specification. The metamorphic fuzzer is
the ratchet that enforces this: semantics-preserving twins must produce
identical output, and the reader round-trip gate catches serialization
divergence. No shipped feature may exist outside the evaluator's verified
surface.

Grounding: one engine with a metamorphic oracle is a strong correctness asset.
The fuzzer turns "should agree" into "does agree, now and forever", by
running tens of thousands of random programs every CI run.

**Status: partial** — the fuzzer exists and runs the engine
(`tools/fuzz.ml`; `dune exec ./tools/fuzz.exe`). Previously catalogued
divergences are now closed; both `--grammar core` and `--grammar full` runs
exit zero. The persistent node cache is verified across runs (`tests/014`).
The negative-literal reader bug (`-5` lexes as a symbol) remains open. The build-engine milestone requires the `full`
grammar to stay green under extended CI runs. `defmacro` would be an
evaluator-only feature the moment it exists to violate this law — expansion
happening outside the shared `macro.ml` path would be exactly the kind of
divergence this law forbids. It does not, by construction: expansion
(`macro.ml`) runs once, ahead of the evaluator, producing the expanded AST
before the evaluator consumes it — `stmt_defmacro` (fuzzer, full grammar) and
`tests/041-defmacro.pp` exercise this the same way every other shared-AST
feature is verified.

Test: `dune exec ./tools/fuzz.exe -- --grammar core` exits zero (the CI
gate); the build-engine milestone's exit criterion extends this to the
`full` grammar with zero twin divergence within the time budget.
---

## 14. Reproducibility and volatility

### [LAW 37] Same inputs, same output — and nondeterminism must be declared

A node given the same input value hashes produces the same result hash.
There is no ambient entropy: `random`, wall-clock, and similar sources are
either capability-gated, trace-recorded inputs — a nondeterministic read is
an observation of the world, so it is a cell — or unavailable inside nodes.

Grounding: this is the Excel/Nix law, verbatim: same inputs, same outputs.
Every other law's cache-soundness quietly depends on it. Hidden entropy is a
hidden input, which is the one thing content-addressing cannot forgive.

**Status: holds** — `random` remains removed; the sanctioned nondeterministic
dependency is now the probe (`register-probe(name, observe-fn, read-cap)`,
scripting tier; `probe(name)`, inside or outside nodes). The observe function
runs at most once per pass, outside any node's trace stack, so its own reads
never contaminate the reading node's trace, under exactly the registered
`read-cap`. The reading node records only a `probe:<name>` trace cell, a
hash of the observed value, capability-free at the read site, since the
authority was already spent evaluating the probe. A node itself still has no
ambient entropy: nondeterminism enters only through a declared probe cell,
never through an effect with no cell.

Test: a node reading `probe(name)` re-forces exactly when the probe's
underlying value changes across two separate runs, and hits, with no
recompute, when it does not (`tests/043-probes.sh`); an
unregistered probe name is a hard error; a probe registered but never read
never fires, demand-pruned, mirroring LAW 7.

### [LAW 38] Volatile nodes are contained as cells and barred from shared caches

A node whose tool is irreducibly nondeterministic — `__DATE__`, timestamp
linkers, address-space layout randomisation — is detected by `--check`,
which double-builds and compares hashes, and its result is treated as a
cell, observed and pinned per pass, so its instability stops at one edge
instead of re-keying its whole ancestor cone on every build. Volatile
results never enter a shared cache. Canonicalisation adapters
(`-frandom-seed`, `ZERO_AR_DATE`) are preferred where they exist.

Grounding: this budgets the reproducibility problem Nix keeps finding as
permanent gardening, rather than wishing it away. Cutoff above a volatile
node is otherwise dead, and the store grows without bound along that cone.

**Status: holds** — the detection half already existed :
`pp --check` runs every missed node's body twice, compares result hashes,
and flags a divergence as volatile (`tests/019`). The containment half is
now the same probe mechanism as LAW 37: wrapping a volatile read as
`register-probe(name, observe-fn, read-cap)`/`probe(name)` moves it out of
the node body and into its own `probe:<name>` cell, observed and pinned once
per pass, exactly the cell treatment this law asked for. So a node reading
it re-forces only when the probe's value actually changes, and its
instability never re-keys or invalidates anything beyond that one cell edge.
Probe results are never written to `~/.pp/store` at all — the session's probe cache
is in-memory and cleared every pass — which is stronger than merely being
excluded from shared caches, since there is no cache to exclude them from.

Test: a node whose tool emits a random value, wrapped as a probe, is
observed once per pass and re-forces the reading node only when the probe's
value changes across runs, never on an unrelated node, and never by
re-running the underlying volatile read more than once per pass
(`tests/043-probes.sh`). The pre-existing `--check`
double-build detection (`tests/019`) is unchanged.

### [LAW 39] Sealed cells: confidential reads are a distinct value kind, banned at the node boundary

`--grant secret:<path>` mints `CapSecret {path}`. A read covered by
`CapSecret` and not by `CapFilesystem` returns a new value kind, `VSealed`,
instead of `VString`. The cell records `sealed:<canonical-path>`, a hash of
the bytes needed for rotation invalidation; the bytes pin in-memory only,
never via `store_blob` or the content-addressed store, so a store-wide scan
must never find secret plaintext; and `string_of_value` and every printer
redact to `#<sealed>`, since a print that leaked the bytes would defeat the
feature. `VSealed` joins the node-boundary ban exactly like `VCapability` —
the free-variable ban and the result ban, both directions —
and `Observation.authorized` requires a covering `CapSecret` grant to serve a
hit on a `sealed:` cell. LAW 23's transitive-closure and
introspection-filtering clauses fall out unchanged: a narrow caller cannot
launder a cached secret read through an aggregator, and `pp why` redacts it.
`unseal(v)` is the one explicit, greppable way out to `VString` — derived
data is ordinary data afterward, by design, with no dataflow tainting, the
same line Vault and SOPS draw. Unsealing inside a node makes the result
cacheable ordinary data, a documented residual of the same shape as every
other cache holding whatever a node chooses to return. When a path is
covered by both a `secret:` and an `fs:` grant, ordinary filesystem behaviour
wins: a deployment that also granted plain filesystem access over the same
path is saying "not secret here".

Grounding: this project's approach of content-addressing every file read
into the store as a snapshot is sound for ordinary data, but a
confidentiality bug for secrets. A security boundary needs a distinct value
kind for the existing node-boundary and authority machinery to pattern-match
on, not a new parallel authorisation path.

**Status: holds** — implemented . `tests/044-sealed.sh`
covers: redacted print, `unseal` round-trip, a recursive store scan proving
the secret's bytes never land under `~/.pp/store` (for a program that only
reads, and separately one that unseals at script tier only); the
node-boundary ban both directions with stable stderr; rotation invalidating
exactly the observing node, leaving a
sibling node untouched; a caller without the `secret:` grant unable to hit a
node whose cached closure read it even though the trace exists on disk; and
the both-grants case behaving as plain filesystem access.

Test: `tests/044-sealed.sh`.

---

## Appendix A — Current gaps

Every law not marked holds, with the discrepancy or fuzzer evidence it maps
to. This table is the honest inverse of the spec: what pp says it is, versus
what `src/` does today. Current-state claims cite the change ledger and
fuzzer signatures, not line numbers, since the source is under active
migration.

| Law | Area | Status | Evidence |
|---|---|---|---|
| LAW 1 | mutual `let` scope | holds | `tests/007-phase0-laws.pp`; fuzzer `full` grammar |
| LAW 2 | dependency-derived order, cycle errors | holds | force paths report named cycles; `tests/095-scope-identity.sh` |
| LAW 3 | binding-order-free identity | holds | mutual `let` bindings are sorted before hashing; `tests/095-scope-identity.sh` |
| LAW 4 | one scope model | holds | top level, blocks, and modules prebind the same definitions while preserving value statement timing; `tests/025-def-value.sh`, `tests/039-global-scope.pp`, `tests/095-scope-identity.sh` |
| LAW 5 | `let*` sequential sugar | holds | reader emits `ELetStar`; sequential; `tests/007-phase0-laws.pp` |
| LAW 6 | node call-by-value plus memoization | holds | application is call-by-value; `node { e }` and applied `defnode` memoize persistently, keyed on code, free-variable values, and argument value hashes (`tests/011`, `tests/097`) |
| LAW 7 | demand-pruning at node granularity | partial | reverse-edge dirty-propagation graph exists for push `stabilize` (`pp --watch --stabilize`, `tests/032`); a root desired-state formula and an explicit wanted-set are still absent |
| LAW 8 | `delay` ephemeral vs `node` persistent | partial | the split exists (`node` persists to `~/.pp/store`; `delay` never persists); residual: the in-memory dedup table is not mirrored across runs, separate from the persistent node cache |
| LAW 11 | stack-safe non-tail recursion | holds | heap continuation machine plus iterative builtin list traversal; regular deep regression (`tests/087-deep-recursion.pp`) and million-element acceptance fixture (`tests/fixtures/million-non-tail.pp`) |
| LAW 12 | total quotation, quasiquote | holds | `tests/007-phase0-laws.pp`; `defmacro` is built on this base — `Quotation.value_to_expr` completes the round trip, `tests/041-defmacro.pp` |
| LAW 15 | ordering never from capabilities | partial | authority and ordering are separate; filesystem and process domains use the generic domain pipeline (`tests/018`, `tests/033`); the remaining gap is the broader law definition |
| LAW 16 | opt-in per-node caching | partial | `node { e }` cached persistently across runs ; scripting-tier expressions uncached; node writes sandbox-scratch-only (LAW 18, `tests/017`); `tests/010`, `tests/014` |
| LAW 17 | hit is not effect replay | holds (node tier) | a `node { e }` hit does not replay in-node `log`/stdout (`tests/010`, `tests/014`) |
| LAW 18 | sandbox-scratch writes | partial | per-node scratch sandbox is real: relative node writes/reads are scratch-local, absolute node writes error, and `run` uses the scratch directory (`tests/017`); domain writes use the reconciliation pipeline |
| LAW 19 | sound content hashing | partial | hash is SHA-256; closure-environment and handler gaps closed, so in-memory dedup is sound; store objects are content-addressed by result hash, shared across runs; the tree-walker's in-memory dedup table is not mirrored across runs |
| LAW 20 | key = code plus argument values | partial | persistent node keys = expanded code plus free-variable value hashes plus applied argument value hashes; capabilities, the whole environment, config, and handlers are all excluded (`tests/011`, `tests/015`, `tests/097`); the node boundary is symmetric: a capability-containing free variable is `Capability_error` at the key, a capability-containing result is rejected before storage (`tests/capability-adversarial.sh`); `defmacro` expands before `Identity.node_key` sees a form, so a macro-only edit re-keys its call sites (`tests/042-defmacro-rekey.sh`) |
| LAW 21 | cutoff via traces | partial | validity via verifying trace is real (key maps to a set of traces, cells re-checked on hit; `tests/010`, `tests/015`); hash-equality cutoff proven at scale — a comment-only header edit on a 101 translation-unit C build, and on Lua 5.4.7, recompiles dependents and cuts off the link (`tests/016`, `tests/024`, `scripts/build-lua.sh`); the reverse-edge dirty-propagation graph is now used by push `stabilize` (`pp --watch --stabilize`, `tests/032`); inline-nested cutoff is still absent |
| LAW 22 | unforgeable root-minted capabilities | holds | constructors removed; `tests/capability-adversarial.sh` |
| LAW 22b | `with-caps` narrows a held value, never widens | holds | `current-capabilities`/`with-caps`/`cap-restrict`'s mode argument; the subset check runs against the current ambient; `effect` removed;  exception/tail-safe; `tests/capability-adversarial.sh` |
| LAW 23 | component/full-path plus transitive hit check | holds (one residual gap) | component-aware, canonicalised (realpath, no trailing slash) paths at every cell/grant/loader-bound site (`tests/036`); hits gated on the caller's capabilities covering the trace's transitive read closure; capability denials not memoized (`tests/013`, `tests/014`) — the check uses the forcing thunk's captured capabilities, collapsing to the earlier per-process grant when `with-caps` is unused; capability-filtered `pp why` real (`tests/019`); Unicode normalisation (NFC) not implemented |
| LAW 24 | loader is runtime authority | holds | loader bounded to source roots plus `~/.pp`, reads traced as authority-exempt `runtime:file:` cells (`tests/020`); realpath-canonical (`tests/036`) |
| LAW 25 | no unenforced authority surface | holds | `CapTime`/`CapMemory` removed from types and surface |
| LAW 26 | two handler classes, synthetic trace cells | partial | semantic handler cells work at node granularity (`tests/015`); cells are coarser than the law's per-argument form, and result-transparent handler cells are not implemented |
| LAW 27 | exception/tail-safe dynamic extent | holds | save-stack restore on every exit |
| LAW 28 | failure traces, error memoization | partial | the engine memoizes `Failure` outcomes as failing traces, re-served until a recorded read changes; the earlier `Evaluating`-leak bug is fixed (`tests/012`, `tests/014`); non-`Failure` exceptions uncached |
| LAW 29 | source locations in errors | holds | every top-level form's location is appended to unlocated runtime errors ; arity/capability errors name the callee/operation; `pp: error:` single-line reporting; a loaded file's own forms are individually located and decorated with that file's location before the error can unwind past the `load` (`tests/027`, including case (g)) |
| LAW 30 | desired-state plus single writer | holds | `register-domain` and `src/runtime/domains.ml` enforce plan, journal, atomic apply, verify, and stratification for any registered domain; `stdlib/domain-fs.pp` and `stdlib/domain-proc.pp` hold filesystem and process policy (`tests/018`, `tests/023`, `tests/033`, `tests/046`) |
| LAW 31 | fenced effects, intent journal | holds | scripting-tier `fenced(KIND, SPEC)`, `--fenced-policy retry|abort|ask`, intent/done journal, recovery without silent retry; `tests/034` |
| LAW 32 | gradual types, strictest oracle | holds | the engine enforces; tests 004/005 restored; `tests/007-phase0-laws.pp` |
| LAW 33 | config: computed keys, tail-safe scoping | holds | computed keys and tail-safe scoping ; config reads inside nodes are `config:<key>` trace cells, ambient config out of the node key (`tests/015`) |
| LAW 34 | no location surface / scheduler exists | holds | the language has no location form; local process-pool scheduling, remote placement, host-qualified domains, and explicit GC are implemented (`tests/024`, `tests/038`, `tests/048`, `tests/049`, `tests/050`) |
| LAW 35 | run-on-N-take-first as handler | holds | `race:N` process-pool fan-out lands (`tests/038`); `remote:<member>` cluster dispatch lands (`tests/048`), gated to data-closed batches, over the threat-model-gated transport |
| LAW 36 | evaluator correctness | partial | catalogued divergences and evaluator crash classes closed; `core` and sampled `full` green; negative-literal lexing remains a same-side issue; `defmacro` expands once, ahead of the evaluator (`macro.ml`), so it cannot itself become an evaluator-only feature — `stmt_defmacro` in `full` |
| LAW 37 | declared nondeterminism | holds | `register-probe`/`probe` are the one sanctioned nondeterministic dependency, evaluated at most once per pass outside the reading node's trace stack, exposed only as a `probe:<name>` cell (`tests/043-probes.sh`) |
| LAW 38 | volatile-node containment | holds | `--check` double-run detection unchanged (`tests/019`); containment is the same probe mechanism as LAW 37 — a volatile read wrapped as a probe is observed and pinned once per pass as its own cell, in-memory only, never written to `~/.pp/store` (`tests/043-probes.sh`) |
| LAW 39 | sealed cells | holds | `CapSecret`/`VSealed`: confidential reads redact on print, exclude from the content-addressed store, ban at the node boundary both directions, gate hits on a covering grant; `unseal(v)` is the explicit boundary (`tests/044-sealed.sh`) |

Laws that hold today, for the record: LAW 1 (mutual `let`), LAW 5 (`let*` as
sequential sugar), LAW 9 (branch pruning), LAW 10 (tail-call optimisation),
LAW 12 (total quotation/quasiquote), LAW 13 (effect order in `do`),
LAW 14 (undemanded values fire no effects), LAW 22 (unforgeable
capabilities), LAW 25 (no unenforced authority), LAW 27 (exception/tail-safe
dynamic extent), LAW 32 (gradual types), LAW 33 (config), and LAW 35
(run-on-N-take-first as a handler, local process pool). Each is exercised by
`tests/*.pp` under the fuzzer, and each must stay green
through the build-engine milestone's remaining work.

---

## Appendix B — The brace surface: token spec and lowering table (non-normative)

> This annex is non-normative. It freezes the first-stage deliverable of the
> brace-syntax project (see [SYNTAX.md](SYNTAX.md)): the grammar of the
> brace/infix surface and the exact s-expression form every brace construct
> reads to. It defines no new semantics — every row lowers to a form the laws
> above already govern, and those laws are stated against the AST
> (`Core_model.expr`), never against a surface. The s-expression language is
> unchanged: it remains the AST's notation and the macro layer's data
> language (`quote` yields sexpr data in both surfaces).
>
> The elegance criterion (frozen). Reading a brace file and reading its
> s-expression transpilation must yield the identical `Core_model.expr`, and
> therefore identical LAW 20 keys. No renames: kebab-case identifiers
> (`string-index`, `nil?`, `proc-alive?`, `run!`) survive verbatim. Because
> `hash_expr` covers `ELocated (file, line)`, "identical `Core_model.expr`" has
> two load-bearing corollaries.
>
> 1. The brace reader must attach `ELocated` at exactly the sites the
>    s-expression reader does (see B.4).
> 2. A later migration transpile must preserve the source path and the line
>    number of every location-carrying form nested inside hashed code — any
>    `fn`/`def` inside a node body carries its definition line into the node
>    key, for example the `link` node of `tests/024`, whose body contains
>    `(fn (o) …)` — or node keys change and the null-rebuild exit fails. The
>    formatter that performs that later transpile, not this grammar, owns
>    that constraint; it is recorded here because the grammar was shaped to
>    make it satisfiable, since every brace form fits on the same line(s) as
>    its sexpr spelling.

### B.1 Tokens

Identifiers: a maximal run of name characters. Name characters are the
s-expression reader's symbol characters minus `:` — that is, everything
except whitespace, `, ( ) [ ] { } < ' `` ` `` " ; # ~` and `:`. So `-` `?`
`!` `.` `/` `*` `+` `=` `>` `|` `_` and similar characters are all name
characters: `string->number`, `nil?`, `proc-alive?`, `let*`, `run!`, `a-b`
are each one identifier. (`:` is reassigned in braces to keywords,
annotations, and cell literals; sexpr symbols may contain `:` — bare island
URIs like `file:./lib` — but no binding in the tree uses one, and braces
spell island URIs as strings; see row L55.)

The whitespace rule (frozen, non-negotiable): infix operators require
surrounding whitespace. `a - b` is subtraction; `a-b` is one identifier.
Token identity is decided by maximal munch; whether a token acts as an
infix operator is decided by position, never inside a token. `a ->b` is the
identifier `->b` in operand position, which is a parse error, not an arrow.
The `->` token is the sharpest case of this rule, and it is load-bearing for
the type-conversion naming convention: glued, `string->number` is a single
identifier, a conversion primitive, and likewise `number->string`; with
whitespace on both sides, `k -> v` is the map/reconcile arrow (L10). The two
never collide, because the glue rule alone distinguishes them — `string ->
number` with spaces would instead be the arrow between two operands. This
one rule is what lets the entire standard library migrate with zero
renames. The `<` family (`<`, `<=`) is lexed specially in braces exactly as
in sexprs, since `<` is not a name character, but obeys the same whitespace
requirement for uniformity.

Reserved words: the following are grammar in head/statement positions, not
bindable names: `and` `assert` `config` `def` `defmacro` `delay` `do` `else`
`fn` `force` `if` `import` `island` `let` `let*` `load` `load-module` `mod`
`module` `needs` `node` `or` `perform` `quasiquote` `quote` `reconcile`
`splice` `unquote` `with-caps` `with-config` `with-handler`, plus the
literals `true` `false` `nil`. No existing binding in the standard library,
tests, or demos collides with these — this is verified, and a regression
gate re-verifies it mechanically. An operator word (`and`, `or`, `mod`) or
operator symbol (`+`, `-`, `<=`, …) in a non-infix position denotes its
symbol: `foldl(+, 0, xs)` becomes `(foldl + 0 xs)`, and `mod(a, b)` becomes
`(mod a b)`. Special-form heads applied in call position parse as their
special forms, exactly mirroring the sexpr reader's car-symbol dispatch.

Comments: `#` to end of line. `;` is not a comment — it is the inline
statement separator. This is the loudest single lexical difference from the
s-expression surface, where `;` comments and `#` introduces `#{`: a later
formatter must transpose comment markers, and `#` never opens a set literal
in braces — sets are spelled with the call form `hash-set(…)` (L12).

Strings: as in the sexpr reader, `"…"` with escapes `\n` `\t` `\\` `\"` (any
other backslashed character is itself); literal newlines are allowed.

Numbers: as in the sexpr reader, a token starting with a digit, or with `-`
immediately followed by a digit or `.`digit, is a number; `.` and exponents
work as today (`20.` is a float). `-5` is a literal when the sign is
attached; `a - 5` is subtraction; `a -5` is two adjacent operands, a parse
error, by design.

Keywords: `:name`, with `:` at the start of the token, becomes `VKeyword`,
as in sexprs.

Cell literals, now removed: the fused `file:"P"`/`env:"N"`/`tree:"R"` token
is no longer part of the language. A single-string token cannot spell a
default (`$env("CC", "gcc")`) or a computed path, and an observation is an
operation, not a literal. World-reads are the `$` family exclusively (see
B.8; rows L47 to L49 amended). An identifier followed immediately by `:` is
now only an annotation colon (`x: ty`); `name:"…"` does not lex as a cell.

Annotations: `:` after a parameter or binding name (`x: int`) or after a
parameter list (`def f(x): int`) — rows L24, L27 to L31.

Separators: inside `{ … }` blocks and at top level, statements are
separated by newline or `;`. The surface is not whitespace-sensitive — there
is no indentation semantics, since pp programs generate pp programs — so a
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
primitives or special forms — no new semantics, following this project's
rule against grammar creep.

| Level (tight → loose) | Operators | Associativity | Lowers to |
|---|---|---|---|
| 1 | call postfix `E(a, …)` | left (`f(x)(y)` → `((f x) y)`) | `(E a …)` |
| 2 | `*` `/` `mod` | left | `(* l r)` `(/ l r)` `(mod l r)` |
| 3 | `+` `-` | left | `(+ l r)` `(- l r)` |
| 4 | `<` `>` `<=` `>=` `=` | none — chaining is a parse error | `(< l r)` and so on |
| 5 | `and` | right | `(and l r)` becomes `(if l r false)` |
| 6 | `or` | right | `(or l r)` becomes `(if l true r)` |
| 7 | `\|>` | left | `x \|> f` → `(f x)`; `x \|> f(y, …)` → `(f x y …)` |
| — | `->` | n/a | not an expression operator: key/value separator inside map literals (and `reconcile`) only |

Notes, each load-bearing for hash preservation:

- there are no unary operators: negation is a signed literal or `0 - x`. The
  primitives' n-ary spellings (`(+ a b c)`, chained `(< a b c)`, variadic
  `=`) are reached by call syntax — `+(a, b, c)`, `<(a, b, c)`. An infix
  chain `a + b + c` lowers left-nested to `(+ (+ a b) c)`, which is a
  different AST, and hash, from `(+ a b c)`: a later printer must print
  n-ary applications in call form, never as infix chains.
- `and`/`or` are right-associative deliberately: the sexpr forms desugar
  right-nested (`(and a b c)` becomes `(if a (if b c false) false)`), so a
  right-associative infix chain `a and b and c` lowers to the identical
  `EIf` tree. Variadic `and`/`or` therefore do survive infix printing with
  hash equality — the desugar erases the arity, unlike `+`.
- `|>` is pure reader-level rewriting, at the lowest precedence, so
  `x + 1 |> f` is `(f (+ x 1))`: a pipeline and its spelled-out application
  are the same computation, hence the same key. The right-hand side must be
  an identifier or a call form; anything else is a parse error.

### B.3 Lowering table

Each row gives the s-expression text a brace form reads as; both readers
must then agree at the `Core_model.expr` level. Where the sexpr reader applies a
reader-level desugar (`and`/`or` → `if`, `assert`, per-parameter type
checks, the block rule), that desugar is a shared post-pass run identically
downstream of both parsers, never duplicated. ⟦stmts⟧ denotes the block
rule (`reader.ml block_body`): one statement becomes the statement itself;
several become `(do stmts…)`; zero become `(do)` — including the block's
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
| L9 | `[e1, e2, …]` | `(list e1 e2 …)` — revised (see note) |
| L10 | `{ k1 -> v1, k2 -> v2, … }` | `(hash-map k1 v1 k2 v2 …)` |
| L10a | `{ …m, k -> v, … }` (spread) | fold: `(map-merge (hash-map) m)` for each `…spread`, `(map-insert acc k v)` for each pair, left to right — multiple spreads merge, rightmost wins. The spread-free literal keeps its `(hash-map …)` shape (hash-preserving). Replaces the removed `{ base \| k -> v }` update form. |
| L11 | `{}` (expression position) | `(hash-map)` |
| L12 | *(no set literal — `#` is the comment character)* `hash-set(e, …)` | `(hash-set e …)` |

> L9 is a revision, not sugar. `[…]` originally read as `(vector …)`; it now
> reads as `(list …)` — the default collection is a cons-list. This is a
> semantic, hash-affecting change, not a surface convenience: a bracket
> literal now evaluates to a different runtime value, a `VPair` cons-chain
> rather than a `VVector`, so its LAW 20 content hash changed and the golden
> store had to be regenerated. That regeneration commit is the receipt that
> the change is real, not cosmetic. Two consequences follow and are checked
> mechanically. First, the quasiquote path was realigned so a `[…]` template
> builds the same cons-list value the equivalent code builds
> (`tests/060-qq-list-parity.sh`). Second, `pp check` sweeps for
> `vector-get`/`vector-length` applied directly to a bracket literal — a
> leftover from the vector era that is now a type error — and flags it
> (`tests/064-l9-vector-sweep.sh`).

#### Operators (see B.2 for nesting)

| # | Brace form | Reads as |
|---|---|---|
| L13 | `a + b`, `a - b`, `a * b` | `(+ a b)` `(- a b)` `(* a b)` |
| L14 | `a / b`, `a mod b` | `(/ a b)` `(mod a b)` |
| L15 | `a < b`, `a >= b`, `a = b`, … | `(< a b)` `(>= a b)` `(= a b)` … |
| L16 | `a and b` | `(and a b)` — the shared desugar yields `(if a b false)` |
| L17 | `a or b` | `(or a b)` — desugar `(if a true b)` |
| L18 | `x \|> f`; `x \|> f(y)` | `(f x)`; `(f x y)` |

#### Application

| # | Brace form | Reads as |
|---|---|---|
| L19 | `f(a, b)`; `f()` | `(f a b)`; `(f)` |
| L19a | `f(a, …rest, b)` (call spread) | `(apply f (list a) rest (list b))` — a `…` anywhere in a call's argument list groups consecutive plain args into `list(…)` segments, each spread its own segment; the `apply` primitive concatenates the segments and calls `f`. A spread-free call keeps the plain L19 shape (hash-preserving). A compound spread target uses the spaced `… E` form (as in list literals). |
| L20 | `(fn(x) { x })(3)`; `f(x)(y)` | `((fn (x) x) 3)`; `((f x) y)` |

#### Bindings and functions

| # | Brace form | Reads as |
|---|---|---|
| L21 | `let x = E` (statement) | `(def x E)` — value binding, LAW 4 (`EDefValue`) |
| L22 | *(a type annotation on `let x = E` is a parse error — sexpr value defs have no annotation slot; annotate via L24 or L30 instead)* | — |
| L23 | `let (x = e1, y = e2) { body… }` | `(let [x e1 y e2] body…)` — mutual scope, LAW 1 (`ELet`) |
| L24 | `let (x: int = e) { … }` | `(let [x : int e] …)` (`ETyped` binding) |
| L25 | `let* (x = e1, y = e2) { body… }` | `(let* [x e1 y e2] body…)` (`ELetStar`) |
| L26 | `fn(p, q) { body… }` | `(fn (p q) body…)` |
| L27 | `fn(p: int) { … }` | `(fn (p : int) …)` — shared LAW-32 desugar |
| L28 | `fn(p): int { … }` | `(fn (p) : int …)` |
| L29 | `def f(p, q) { body… }` | `(def (f p q) body…)` |
| L30 | `def f(p: int) { … }` | `(def (f p : int) …)` — shared LAW-32 desugar |
| L31 | `def f(p): int { … }` | `(def (f p) : int …)` |

#### Nodes

| # | Brace form | Reads as |
|---|---|---|
| L32 | `node { E… }` (expression) | `(node ⟦E…⟧)` |
| L33 | `node name { E… }` | `(defnode name ⟦E…⟧)` — ≡ `(def name (node ⟦E…⟧))`, LAW 4 |
| L34 | `node f(p…) { body… }` | `(defnode (f p…) body…)` — typed params/return as L30/L31 |
| L35 | `node f(p) needs I1, I2 { body… }` | `(defnode (f p) (with-caps C ⟦body…⟧))` where `C` is the single lowered item, or `(cap-compose I1′ I2′ …)` for several |

`needs` items (L35) lower via the grant-descriptor sugar of B.8
(`fs.read`/`fs.write`/`fs.rw`, each a mode-scoped `cap-restrict` over
`(current-capabilities)` — that table is the one authoritative listing, not
this paragraph). `needs` is value-open: the descriptors are only sugar. Any
other item is an ordinary expression passed through unchanged — it must
evaluate to a capability, and LAW 22b's subset gate does the enforcing, so
the reader adds nothing — so a named or composed grant is a legal item, for
example `node deploy() needs k8s-prod { … }` where `let k8s-prod =
cap-compose(net("k8s.prod.internal"), process)`. The set of capability kinds
stays closed (DESIGN.md's closed-kinds-open-instances principle); the
vocabulary of named grants is open at the value level. The `fs.*`
descriptors are recognised only inside a `needs` clause; elsewhere `fs.read`
is just an identifier. An earlier design sketch's bare `proc` item is not
frozen here: no existing form projects a single capability kind out of the
ambient set (`cap-restrict` is path-scoped, and a path-restricted
`CapProcess` is unusable, as `demo/agent.pp`'s own comment notes), so
freezing it would require a new core projection primitive — a language
change, out of scope for this annex under the grammar-creep rule.
Creation-time narrowing stays expressible by composition:
`def f(x) { with-caps(E) { node { … } } }` becomes
`(def (f x) (with-caps E (node …)))`.

#### Control and sequencing

| # | Brace form | Reads as |
|---|---|---|
| L36 | `do { s… }` | `(do s…)` |
| L37 | `if C { T… }` | `(if C ⟦T…⟧)` — else defaults to `nil`, LAW 9 |
| L38 | `if C { T… } else { E… }` | `(if C ⟦T…⟧ ⟦E…⟧)` |
| L39 | `if C1 { … } else if C2 { … } else { … }` | nested `(if C1 … (if C2 … …))` — there is no `cond`; a flat `else if` chain, or `match` on the scrutinee with guards, is the spelling |
| L39a | `match E { p1 => b1; p2 if g => b2; … }` | `(match E (p1 b1) (p2 if g b2) …)` (`EMatch`). Patterns: literals, variables (bind), `_`, `[a, b, …rest]` (list, with spread), `(:tag p…)` (tagged). Guards: `p if g => b` — the arm fires only when `p` matches and `g`, evaluated under `p`'s bindings, where only `nil`/`false` are falsy, is truthy; otherwise control falls to the next arm. A guardless arm hashes identically to the pre-guard 2-tuple. First match wins; no match is a runtime error. The compiler's structural condition uses unshadowable primitives (LAW A5) and cons-guards every `car`/`cdr`, so a list/tagged pattern against a non-pair scalar falls through instead of erroring. On the sexpr surface, the reader/printer read and write this exact `(match …)` form (patterns `_`/literal/symbol/`(list …[. rest])`/`(tagged tag …)`, a guarded arm `(pat if guard body)`), so match files round-trip through `pp fmt`. |
| L39b | `f"…{E}…"` (f-string) | `(string-append lit0 (->string E1) lit1 …)` — the `f` prefix is glued to the quote; `{E}` holes take arbitrary expressions and lower through the generic `->string`; `{{`/`}}` are literal braces; a single part (`f"abc"` or `f"{x}"`) is emitted bare, so `f"abc"` is the same as `"abc"`. Ordinary `"…"` strings never interpolate. This is a one-way desugar with no AST node, hash-preserved through `pp fmt`. |
| L40 | `force(E)`; `delay(E)` | `(force E)`; `(delay E)` |

#### Effects, handlers, capabilities, config

| # | Brace form | Reads as |
|---|---|---|
| L41 | `perform name(a, …)` | `(perform name a …)` — for every effect: `read-file` `write-file` `run` `run-dep!` `http-get` `http-post` `log` `tree-observe` `materialize-file` `remove-file` `proc-spawn` `proc-alive?` `proc-stop` `proc-reap` `domain-state-get` `domain-state-put` (an earlier revision renamed the depfile effect `run-dep` to `run-dep!`; the `!` marks the effect) |
| L42 | `with-handler(n1 = h1, n2 = h2) { body… }` | `(with-handler [n1 h1 n2 h2] body…)` — a handler name may also be a keyword literal, as in sexprs |
| L43 | `with-caps(E) { body… }` | `(with-caps E body…)` |
| L44 | `with-config(E) { body… }` | `(with-config E body…)` — `E` is any expression, typically a map literal `{:k -> v}` |
| L45 | `config(K)`; `config(K, D)` | `(config K)`; `(config K D)` — computed keys legal, LAW 33 |
| L46 | `assert(C)`; `assert(C, M)` | `(assert C)`; `(assert C M)` — the shared desugar to `if` plus `error`, with `at file:line` baked into the message (see B.4) |

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
| L47 | `$file(P)` | `(slurp P)` — a `file:` (or, under a `secret:` grant, `sealed:`) observation |
| L48 | `$env(N[, default])` | `(env-get N)` — an `env:` observation |
| L49 | `$glob(R)` | `(perform tree-observe R)` — a `tree:` observation |
| L50 | *(no `$` head for `stat:` cells)* `file-exists?("p")`, `dir?("p")` | predicate observations keep the call form — they observe predicates, not path contents |

An earlier design sketch's `glob:"src/*.c"` is not frozen here: no
glob-observing form exists in core (the manifest read that exists is
`tree-observe`, L49), and minting one is new semantics — out of scope for
this annex, by the same grammar-creep rule as `needs proc`.

#### Modules, loading, islands

| # | Brace form | Reads as |
|---|---|---|
| L51 | `module { forms… }` | `(module forms…)` |
| L52 | `import(E)` | `(import E)` |
| L53 | `load("P")` | `(load "P")` — literal string required, as in sexprs |
| L54 | `load-module("P")` | `(load-module "P")` |
| L55 | `island("URI")`; `island("URI", "PIN")` | `(island "URI" "PIN")` — braces spell URIs as strings; the sexpr reader's bare-symbol (`file:./lib`) and `<…>` island-literal lexes produce the same `EIsland`, so hashes agree. An unpinned island remains the LAW 24 hard error |

#### The quote bridge

Homoiconicity at the AST layer: these yield or
consume s-expression data, in both surfaces.

| # | Brace form | Reads as |
|---|---|---|
| L56 | `quote { F }` | `'F′` ≡ `(quote F′)`, where `F′` is `F`'s lowering — one form only |
| L57 | `quasiquote { F }` | `` `F′ `` — quasiquote-mode read of the lowered form |
| L58 | `unquote(E)` — legal only inside `quasiquote{}` | `,E` |
| L59 | `splice(E)` — legal only inside `quasiquote{}` | `,@E` |
| L60 | `defmacro name(p…) { s1; s2; … }` | `(defmacro (name p…) s1 s2 …)` — each body statement a separate form, producing exactly the application shape `macro.ml match_defmacro` recognises, never an `EDo`-wrapped body |

L56 and L57 are distinct on purpose: `'x` and `` `x `` read to different
ASTs — an `EQuote` versus the quasiquote application that builds cons
chains — both occur in real code, and both must round-trip with hash
equality, so the brace surface names them separately. In quasiquote mode a
brace form denotes the s-expression data of its lowering (atoms quoted,
lists as `cons` chains, vectors/maps as `vector`/`hash-map` builds), exactly
as the sexpr reader's quasiquote mode denotes its literal text.

#### Desired state

| # | Brace form | Reads as |
|---|---|---|
| L61 | `reconcile { k1 -> v1, … }` | `(hash-map k1 v1 …)` — identity sugar naming the final-value map (LAW 30); the reconciler consumes the program's final value, so `reconcile` adds no AST and no semantics |

Top level: a brace file is a newline/`;`-separated statement sequence; each
statement is one top-level form, `ELocated`-wrapped exactly as
`Reader.read_string` wraps sexpr forms today.

### B.4 Location threading (`ELocated` placement)

For AST identity, and therefore hash and LAW 29 error-text identity, the
brace reader attaches `ELocated` at exactly the sexpr reader's sites.

- every top-level form: `ELocated ((source, line-of-first-token), form)`
- `def`/`defnode`/`fn`: the line of the token after the head locates the
  body (`ELocated (loc, body)`), the return annotation
  (`ELocated (loc, ETyped (body, ty))`), and each per-parameter check
  (`ELocated (loc, ETyped (ESymbol p, ty))` — LAW 32)
- value defs: `EDefValue (x, ELocated (loc, rhs))`; value `defnode`:
  `EDefValue (x, ELocated (loc, ENode rhs))`
- `assert`: the location is baked into the generated message string (`… at
  file:line`), and a message-less `assert` renders its condition via
  `quote_to_value`/`string_of_value` — that is, in AST, s-expression,
  notation in both surfaces. That string is part of the desugared
  expression and therefore of every enclosing hash: the brace reader must
  reuse the same renderer verbatim, and no later stage may re-render assert
  messages in brace notation without re-keying every node containing one.

### B.5 Law audit

This section audits the laws above against the brace-syntax project's
requirement that they hold across surfaces.

Touched — reworded to be surface-neutral, with zero semantic change:

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
33, and 35 to 39. Their statements quantify over AST forms, values, hashes,
traces, capabilities, cells, or process behaviour; s-expression text
appearing in them is example programs, which remain valid, since the sexpr
surface is not deprecated by this brace-syntax project, not a definitional
dependence. LAW 24's island clause was checked specifically: it constrains
`EIsland`'s inline pin, its identity in the code hash, not any lexical
spelling. LAW 22's "`(filesystem "/" :rw)` is an unbound symbol" is the
application of an unbound name, the same error in either surface.

### B.6 Fuzzer-coverage checklist

Every construct the fuzzer's `full` grammar (`tools/fuzz.ml`) can emit, with
its covering row(s):

| Generator | Emits | Row(s) |
|---|---|---|
| `gen_int_lit` / `gen_float_lit` / `gen_str_lit` | int (incl. negative), float (incl. `20.`), string literals | L1–L3 |
| `gen_int` | `+ - *` (2-ary and 3-ary), `mod`, `/`, `if`, `let`, user-fn calls, `string-length`, `string->number`∘`number->string`, `string-index` under `nil?`+`if`, `length`, `foldl` with `+` as a value, `car`, `vector-get` on `[…]`, `hash-map-get` on `{:k …}`, immediate `fn` application, `do` | L13–L14 (binary), L7 (n-ary `+`/`*` and operator-as-value in call form), L37–L38, L23, L19, L9–L10, L5, L20, L36 |
| `gen_bool` | `true`/`false`, `< > <= >= =`, string `=`, `not`, `and`/`or`, `nil?`, `if` | L4, L15, L19, L16–L17, L37–L38 |
| `gen_string` | `string-append`/`string-trim`/`number->string`/`string-sub`, `if` | L19, L37–L38 |
| `gen_float` | float arithmetic, `if` | L13, L37–L38 |
| `gen_list`/`gen_list_ne` | `nil`, `list`, `cons`, `range`, `map`/`filter` with `fn`, `take`, `cdr` | L4, L19, L26 |
| `stmt_print` / `stmt_do_print` | `print`, `do` | L19, L36 |
| `stmt_let_print` | multi-binding `let` | L23 |
| `stmt_letstar_print` | `let*` | L25 |
| `stmt_seq_let` | sibling-referencing `let` (divergence probe) | L23 |
| `stmt_def_value` / `stmt_do_scoped_def` | `(def x e)` at top level and inside `do` | L21, L36 |
| `stmt_def` / `stmt_def_rec` / `stmt_deep_rec` | function defs, arity 1–3, recursion | L29 |
| `stmt_typed_let` | `(let [x : ty e] …)` | L24 |
| `stmt_typed_def` | `(def (f p) : ty body)` | L31 |
| `stmt_param_typed_def` | `(def (f p : ty) body)` | L30 |
| `stmt_with_config` / `stmt_config_computed` | `with-config` with map literal + keyword keys, `config` with computed key and default | L44, L45, L10, L5 |
| `stmt_module` / `stmt_module_sibling` | `(import (module …))` incl. non-def children and sibling refs | L51, L52 |
| `stmt_load_module` / `stmt_big_map` / `load_stdlib_form` | `load-module`, `load` | L54, L53 |
| `stmt_island` | `(import (island file:DIR "PIN"))` | L55 (string-URI spelling), L52 |
| `stmt_perform` | `perform log` bare and in value position | L41 |
| `stmt_with_handler` / `stmt_handler_leak` | `with-handler` with `fn` handler, tail-position bodies | L42, L26 |
| `stmt_eq_list` | `(= E E)` on lists | L15 |
| `stmt_quote_special` | `'(if 1 2 3)`, `'(let [x 1] x)` | L56 (+ L37, L23 inside the quote) |
| `stmt_defmacro` | `defmacro` + macro call with `list`/`quote` body | L60, L19, L56 |

Every generator maps to at least one row; no row was needed that this table
could not name. Constructs in the tree but outside the fuzzer's grammar —
`node`/`defnode`, `with-caps`, cells, `assert`, `island` bare-URI lexes,
`fenced`/domains/probes, sealed reads — are covered by rows L32 to L35,
L43, L46 to L50, L55, and the L19 call rule, so a later sexpr-to-brace
printer has a defined spelling for every form both grammars and the real
tree can produce.

### B.7 Judgment calls frozen by this annex

Decisions an earlier design sketch left open, or sketched un-implementably,
recorded here because later stages implement exactly what this annex froze.

1. `;` separates, `#` comments. This was mandated by the plan, and flagged
   as the top migration hazard: sexpr `;` comments become `#`, and sexpr
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
12. Quasiquote-template name slots take `unquote(…)`, a later addition to
    this annex. Inside `quasiquote { … }`, a `let`/`let*` binding name and a
    `def`'s function name may each be `unquote(E)` as well as a bare
    identifier — the two computed-name shapes real macro templates need: a
    gensym'd hygienic temporary (`let (unquote(g) = unquote(a)) { … }`
    lowers to the data `` `(let [,g ,a] …) ``) and a macro-generated
    definition (`def unquote(name)(x) { … }` becomes
    `` `(def (,name x) …) ``). Everything else on the list of known
    deviations stays a parse error inside `quasiquote{}`, deliberately:
    `defmacro` and `needs` templates, named node definitions (`node name {
    … }`/`node f(p) { … }`; the bare node expression `node { E }` is
    representable), computed parameter names, type annotations (an
    `ETyped` is not plain quoted-symbol data, so representing one would
    need a new data convention, not a parser rule), and map spread
    (`{ …m, k -> v }`): a quasiquote map is built eagerly
    (`quasiquote_walk` does not descend into a `VMap`), so a spread's
    `map-merge` would run before unquotes are substituted — plain
    `{ k -> v }` literals are representable, spread is not. The workaround
    for all of these is to build the form as data with ordinary
    `list`/`cons`/`quote{}` calls — `list(quote { defnode }, …)` and
    similar — exactly what macro bodies could always return. A
    block-versus-map ambiguity inside a template is resolved the same way
    as outside quasiquote (judgment call 2 above): expression-position
    `{…}` is map data, and sequencing must be spelled `do { … }`.

### B.8 Surface tables (generated from `src/frontend/surface_tables.ml`)

The closed surface sets — the `$KIND` observation heads, the `with { }`
clause keywords, and the `needs` grant-descriptor sugar — are one typed
value each in `src/frontend/surface_tables.ml`. Every consumer (both readers, the
`needs` desugar, `lint`, error messages) derives from those tables; nothing
hand-copies the list. This block is generated, not authored:
`tests/067-surface-tables-drift.sh` regenerates it (`pp --dump-surface-tables`)
and diffs, so a table edit that is not mirrored here is a red build, and no
closed set is ever hand-listed in SPEC again. Do not edit between the
markers by hand.

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
