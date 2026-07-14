# pp SPEC — the semantic laws

> This is the **normative** document. It states what pp's forms *mean*, as
> testable laws. It is not a description of the current implementation — this
> project's docs have described aspirations as facts before, and this document
> exists partly to stop that. Every law carries an explicit **Status** marker:
>
> - **holds** — both backends already satisfy it (verified by tests or the
>   differential fuzzer).
> - **partial** — one backend satisfies it, or the mechanism exists but is
>   buggy/incomplete. The D# from [STATUS.md](STATUS.md) or the fuzzer signature
>   is cited.
> - **unimplemented** — a target only. Nothing in `src/` does this yet.
>
> The enforcement mechanism is the differential fuzzer (`tools/fuzz.ml`; see
> [TESTING.md](TESTING.md)) plus `tests/*.pp` run under both backends: every law
> is written so that a program could falsify it, and every law's test must pass
> identically in **both** backends (tree-walker and VM). Phase 0 (see
> [ROADMAP.md](ROADMAP.md)) does not exit until every **holds** claim below has
> a passing test and no law is silently violated.
>
> **Law-linkage gate (MASTER-PLAN A″3).** A **holds** claim is not self-certifying:
> `tests/072-law-pins.sh` cross-references every LAW id here against the
> `# pins: LAW-<n>` markers declared by the suite, and fails the build if a
> **holds** law has neither a pinned test nor an explicit entry on the PENDING
> backfill list. So a law cannot be *added* as **holds** without either a test
> that falsifies it or a recorded promise to write one — and a pin that names a
> renamed or deleted law is likewise a red build. Kernel laws (identity, the
> capability M3-bans, traces, handler restore, failure caching) are the first
> pinned tranche; the tail is paid down under the same gate.
>
> Cross-references: design rationale and the Q1–Q12 decisions live in
> [DESIGN.md](DESIGN.md); the D1–D21 ledger in [STATUS.md](STATUS.md); the
> phased plan in [ROADMAP.md](ROADMAP.md).

---

## 0. Preamble: what pp believes

**Order comes from data dependencies, not from source position.** The founding
observation is that build systems, package managers, init systems, and
orchestrators all manage the same thing — dependency graphs, execution order,
caching, side effects — and all of them re-derive it badly because the
languages underneath model computation as a *sequence of mutations*. Shell
scripts have no dependency model. Dockerfiles represent a build — actually a
DAG — as a linked list of snapshots, which is why invalidating one layer ruins
everything downstream. The systems that got it right — Excel, React, Haskell,
Jane Street's Incremental, Nix — all share one law: computation is a DAG with
explicit data flow; same inputs produce same outputs; caching is principled.
pp takes that law as its semantics, not as a convention.

**Identity is structure.** Every value has a content hash. Two computations
with the same code and the same input values *are the same computation*,
regardless of where or when they appear. Caching, deduplication, early cutoff,
and distribution are not features bolted onto pp; they are corollaries of
content-addressed identity.

**Pure by default; effects need capabilities.** A capability is authority — a
ceiling on what a computation *may* touch. It is unforgeable, minted only at
the root, and can only be narrowed. It is **not** an ordering mechanism and
not affine; ordering comes from data flow and the single-writer reconciler
(§9). This replaces Unix ambient authority the way Plan 9 and the capability
tradition intended.

**`force` is the only execution primitive.** Where a computation runs — this
core, another core, another machine — is a scheduler decision, never language
surface. Parallelism and distribution are one feature at different fan-out.
"Run this on three nodes and take the first result" is a handler swap, not an
infrastructure project. This is the rant's opening demand and the reason pp
exists.

**Static is a perspective, not a foundation.** Hardware is dynamic, topology
is dynamic, data is dynamic. pp is dynamically typed; type annotations are
optional gradual claims checked at force time. This is the explicit
differentiator from Unison, whose type system is too static for the top level
of a real system.

**The endgame is the OS-as-expressions** — users, services, and the
filesystem as expressions over a reactive, content-addressed substrate. Builds
are the beachhead that proves the substrate (DESIGN principle 6).

### 0.1 The two tiers

pp is two tiers, like every one of its models — Haskell's pure/IO split,
React's render/effects split, Excel's formulas/macros split:

- **The node tier** — pure, strict at node boundaries, content-addressed,
  cached, distributable. A *node* (`node` / `defnode`) is the unit of
  persistence and caching. To be cacheable it must be pure and analyzable.
  This tier is where the build/DevOps/distribution thesis lives.

- **The scripting tier** — dynamic, imperative, REPL glue. `write-file`
  wherever you like, full dynamism, no restrictions. Not cached, not
  distributed, not keyed.

The bargain that connects them: **purity is the price of a cache hit, and
caching is opt-in per node.** A cache hit means the node does *not* run — so
a cached node must not perform uncontrolled shared-state writes, or the hit
would silently drop them. Code that wants free effects simply isn't a
cacheable node; nothing bans it from the scripting tier. The restrictions in
this spec are the terms of a bargain the programmer opts into, not a
language-wide prohibition.

Status of the tier split itself: **partial** — the `node`/`defnode` reader
forms exist, and `node { e }` is a real persistence boundary: the tree-walker
routes it through `~/.pp/store` with verifying traces, so a node caches across
runs while a scripting-tier expression does not (D1). Both backends share the store (D7 closed). Still missing before the split is
fully realized: `node f(x) { body }` is only a named closure (node
*application* is not yet keyed on arg-value-hashes — LAW 6/20), though
`node x { e }` now binds the node thunk of `e` (LAW 4 value defs). The node
tier's write discipline now exists: node writes are sandbox-scratch only
(LAW 18, `tests/017`).

---

## 1. Binding and scope — the centerpiece

The `let` question is a referendum on the founding principle. If order comes
from dependencies and not position, then a binding form whose meaning depends
on the textual order of its bindings has imported the villain into the core of
the language. There are two **orthogonal axes**, and conflating them is how
languages get this wrong:

- **Scope** — which bindings can see which others?
- **Timing** — when does each binding's value get computed?

### [LAW 1] A scope is a local DAG: `let` bindings are mutually visible

In `let (a = e_a, b = e_b, …) { body }`, **every** binding name is in scope in
**every** right-hand side and in the body, regardless of textual order. A
`let` is a local Excel sheet: a set of named cells that may reference each
other freely, position-free.

*Grounding.* Excel formulas reference cells by name, never by "the cell above
me"; Haskell's `let` and `where` are recursive for the same reason. The two
rejected alternatives each betray a principle: **sequential** scope (Scheme
`let*`, shell) makes textual position semantically load-bearing — the exact
disease of Dockerfiles-as-linked-lists — and fights content-addressing,
because reordering bindings of the *same* computation would change its hash
(see LAW 3). **Parallel** scope (Scheme `let`) is the worst middle: it is
position-independent but cannot express a local dependency graph at all,
forcing nested `let`s that smuggle order right back in as tree depth. Mutual
scope is the only choice under which "order from dependencies, not position"
is true *inside* a binding form and not just between top-level nodes.

**Status: holds** — both backends now build a mutual environment for `ELet`
bindings; sibling references evaluate correctly and reordering independent
bindings does not change the result (`tests/007-phase0-laws.pp`, fuzzer `full`
grammar).

**Test:** `let (y = x + 1, x = 1) { y }` ⇒ `2` in both backends; reordering the
bindings must not change the result.

### [LAW 2] Evaluation order within a scope is derived from dependencies; genuine cycles are force-time errors

The runtime computes bindings in an order derived from their *actual*
references, not their positions. A dependency cycle among bindings is a
runtime error at force time, reporting the cycle — **unless** the cycle is
mediated by a function value (a lambda delays demand, so mutually recursive
functions are legal and ordinary, as in Haskell and at pp's own top level).

*Grounding.* This is the language-in-the-small mirror of the build engine:
the wanted-set is ordered by the discovered graph, and cycles are runtime
errors reporting the force path (DESIGN Q5). No solver, no declaration step —
demand discovers the order.

On the **timing axis**: local `let` bindings are *ephemeral* — never
persisted, never keyed, never in any store — so they are free to be lazy
on-demand thunks regardless of the node tier's strictness (LAW 6). Node-level
strictness (Q1) exists to protect *cached nodes*; a local binding is not one.
An unreferenced binding never runs.

**Status: partial** — mutually recursive functions work; direct cycles are
caught deterministically by the `Evaluating` marker in both backends, but the
reported error is the generic "infinite recursion detected" rather than a
named cycle.

**Test:** `let (even? = fn(n) { if n = 0 { true } else { odd?(n - 1) } }, odd? = fn(n) { if n = 0 { false } else { even?(n - 1) } }) { even?(10) }`
⇒ `true` in both backends. `let (a = b, b = a) { a }` ⇒ a deterministic cycle
error identically in both backends.

### [LAW 3] Binding order is not part of a computation's identity

Two `let` forms that differ only in the textual order of their bindings
denote the same computation and must have the same content hash (code-hash
canonicalizes binding sets).

*Grounding.* Content-addressing says identity is structure. If reordering
independent bindings changed the hash, the cache would treat one computation
as two — position would have leaked into identity, which is precisely the
failure content-addressing exists to kill.

**Status: unimplemented** — `hash_expr` hashes `let` bindings in source order
today, so reordering independent bindings still changes the hash; LAW 20's
value-hash keying is the fix.

**Test:** the node keys (once nodes exist: LAW 15) of
`let (a = 1, b = 2) { a + b }` and `let (b = 2, a = 1) { a + b }` are equal; a
cached result for one is a hit for the other.

### [LAW 4] One scope model everywhere: `let` = `do`-block `def`s = `module` = top level

A scope — local `let`, a `def` block, a module body, the top level of a
program — is one thing: **a set of mutually-visible DAG nodes ordered by
dependency.** Top-level `def`s already behave this way (later `def`s are
visible to earlier bodies); LAW 1 extends the same model downward so the
language has one scoping story, not three.

*Grounding.* Unification is the point: a module is just a bigger `let`; the
top level is just an implicit module. Excel does not have a different
reference model per worksheet region.

**Value defs.** A definition that binds a *bare name* to an expression (AST
`EDefValue`; the s-expression surface spells it `(def x v)` — a non-list
head, the brace surface `let x = v`) is a **value binding**: the RHS is
*evaluated when the definition executes* and `x` is bound to the result —
never a nullary closure (the
Phase-1 footgun, ROADMAP maturity §1). Evaluation does not force: a value
def whose RHS is a `delay` form binds the unforced thunk, and a name-binding
`defnode` is exactly a value def of the node thunk — `EDefValue (x, ENode e)`,
however a surface spells it. Scope follows LAW 4 with statement timing:

- **Blocks** (`do` bodies, multi-expression `fn`/`def` bodies, modules) are
  letrec*: every def in the block — function or value — is visible to the
  whole block. A reference that *runs* before the defining statement has
  executed raises `<name>: referenced before its definition`; defining the
  same name twice in one block is a read error (`duplicate definition in
  block`).
- **Top level** is processed form by form: a value def's RHS referencing a
  name only defined by a *later* top-level form is an unbound-symbol error
  (function defs still late-bind, so top-level mutual recursion between
  functions is unaffected).

**Exception — `try {}` `<-` bindings are sequential, and rebinding shadows.**
A `try {}` block is *not* a letrec* scope. Its `<-` bindings execute top to
bottom, each visible only to statements *after* it (a `<-` rhs sees earlier
binds, never later ones — there is no mutual visibility to poison), and
because the block lowers to nested `let`s, **binding the same name twice is
allowed**: the second `<-` shadows the first for the statements that follow,
exactly as re-`let`-ing a name in nested lets would. This is the one place
LAW 4's "duplicate definition in block is a read error" does not apply —
`try` statements are sequential lets, not a letrec* block of `def`s. Pinned
by a differential test that rebinds a `<-` name twice and observes the later
uses see the shadowing value on both backends
(`tests/065-try-rebind-shadow.sh`).

**Status: partial** — top-level and `do`-block `def`s are mutually recursive
in both backends (they share a mutable global scope), and value defs behave
identically in both backends including the letrec* poison error
(`tests/025-def-value.sh`, fuzzer `stmt_def_value`). The VM/tree-walker
module-body divergence is fixed (D22b closed: the VM now resolves
module-body sibling references — function defs, value defs, and bare
statements — through local slots in the module's own fresh frame, matching
the tree-walker's `env_acc` fold; `tests/039-vm-global-scope.pp`, fuzzer
`stmt_module_sibling`). A module is still its own fresh scope in both
backends (`Primitives.initial_env ()`/a fresh frame), not literally "a
bigger `let`" nested in the surrounding scope, so "one scope model
everywhere" doesn't yet hold in LAW 4's strong sense — only the
VM/tree-walker parity gap (D22) is closed, not the module-isolation-vs-`let`
unification itself.

**Test:** a module whose first `def` calls its second behaves identically to
the same two `def`s at top level, in both backends; `load-module` without
`import` leaves the caller's scope untouched in both; `let x = 5` followed by
`print(x)` prints `5` in both backends (`tests/025`).

### [LAW 5] `let*` survives only as explicit sequential sugar

`let* (a = e1, b = e2) { body }` is the scripting-tier form for "I really do mean a
sequence" — shadowing, staged reads, REPL work. Because mutual `let` makes
every RHS visible to every other RHS in the same binding set, `let*` is
implemented as a distinct sequential form: each RHS is compiled in an
environment that contains only the preceding bindings, and the body sees the
final binding. The primitive and the default remains mutual `let`.

*Grounding.* Sequence is sometimes the true structure (a REPL session *is* a
sequence). The law keeps that expressible while refusing to make it the
default meaning of binding.

**Status: holds** — the reader emits `ELetStar`; both backends evaluate it
sequentially and agree on shadowing (`tests/007-phase0-laws.pp`, fuzzer
`core` and `full` grammars).

**Test:** `let* (x = 1, x = x + 1) { x }` ⇒ `2` in both backends (shadowing,
strictly sequential visibility).

---

## 2. Evaluation: strict nodes, pruned demand

Honesty about a retired slogan first. The README's original claim — "every
expression is a thunk; the DAG emerges from laziness" — is **retired**
(DESIGN Q1). The DAG is the *demand-pruned wanted-set defined by the root
desired-state formula*, Bazel-shaped, not an emergent artifact of
per-expression call-by-need. Fine-grained laziness bought this codebase a
stack-overflow class (D4), an allocation storm, an unsound cache key (D6), and
effect-escape hazards (D9) — for zero build-relevant benefit. What survives as
"laziness" is demand-pruning and skip-on-hit, at node granularity.

### [LAW 6] Node application is call-by-value with memoization

A node's arguments are forced before the node's body runs, because the node's
key is `H(code-hash ‖ arg-value-hashes)` (LAW 15) — the key cannot exist
before the argument values do. Within the node tier, application is strict;
results are memoized by key.

*Grounding.* This is BSalC's constructive-trace rebuilder made into language
semantics: an aggregator (`link`) keyed on child result hashes forces its
children first, by construction. Haskell's laziness is not the model here;
Nix's "a derivation's inputs are realized before it builds" is.

**Status: partial** — `node { e }` exists and memoizes persistently under the
LAW 20 key in both backends, and `node x { e }` binds its node thunk; but
`node f(x) { body }` is still only a named closure, so node *application*
keyed on argument value hashes (the aggregator-forces-children construction)
does not yet arise.

**Test:** once applied `defnode` lands: a `defnode` whose argument expression
logs, called once, logs exactly once *before* the body's first effect, in
both backends.

### [LAW 7] Laziness is demand-pruning at node granularity

Only nodes reachable from the root's desired-state value are ever forced.
A single node may, when forced, *expand* into many nodes (a glob manifest
defining 50,000 compile nodes); unchanged ones hit the cache, undemanded ones
never run. The rant's "LLVM as one thunk that expands into 50k units on
force" story is preserved — at node granularity, not per-expression.

*Grounding.* Nix needs "dynamic derivations" and a socket mechanism for this;
a language whose graph expands under evaluation gets it natively. Demand
pruning is Excel not recalculating sheets nobody looks at.

**Status: partial** — `node { e }` and the store exist (D1), and the reverse-edge
dirty-propagation graph now exists for push `stabilize` (`pp --watch --stabilize`,
`tests/032`). What is still missing: a formal root desired-state formula and an
explicit wanted-set, so demand-pruning remains pull-mode "re-force from root"
rather than a declared target set (Q1/Q5).

**Test:** a root demanding 1 of a manifest's 3 children executes exactly 1
child (journal/trace proves it), in both backends.

### [LAW 8] `delay`/`force` is ephemeral, in-memory laziness — a different thing from `node`

`delay(e)` makes an ephemeral thunk: computed at most once per process,
never persisted, never keyed into any store. `force` is idempotent and is the
identity on non-thunks. Lazy sequences (`lazy-seq`, stdlib `cons` chains)
live here. `node` is persistence; `delay` is timing.

*Grounding.* Conflating the two is how the store fills with micro-entries
(DESIGN R4ii). Excel's distinction: a formula cell (recalculated, tracked)
vs. a spilled intermediate nobody addresses.

**Status: partial** — the persistent/ephemeral split now exists in both
backends: `node { e }` persists to `~/.pp/store` (tree-walker via `thunk_persist`,
VM via the `MAKE_NODE` opcode) while `delay(e)` never does. Remaining wart: the
tree-walker also routes ordinary `delay`/`let` thunks through its *in-memory*
content-addressed dedup table (not the persistent store), and the VM has no
in-memory dedup at all (D7) — neither affects the persistent node cache.

**Test:** `force(delay(42))` ⇒ `42`; `force(42)` ⇒ `42`; a delayed
computation's effect fires at most once across two forces — identical in both
backends.

### [LAW 9] `if` evaluates exactly one branch

The untaken branch of a conditional is never evaluated — no effects fire, no
errors raise, no nodes are demanded from it. `and`/`or` inherit this by
desugaring to `if`.

*Grounding.* Branch pruning is the atom of demand-pruning; a build system
that speculatively evaluates both arms of a conditional is Make, not Excel.

**Status: holds** — condition forced, branches in tail position in the
tree-walker; compile-to-jumps in the VM; exercised by the fuzzer's `core`
grammar.

**Test:** `if true { 1 } else { undefined-symbol }` ⇒ `1` in both backends;
the untaken branch's `perform log(…)` produces no stderr in either.

### [LAW 10] Tail calls run in constant stack

A tail-recursive computation runs at unbounded depth (≥ 10⁶) without stack
growth, in both backends.

*Grounding.* A language proposing to be the OS cannot have "your service loop
overflowed" as a semantic. Loops are recursion; recursion must be safe.

**Status: holds** — CPS `eval_tail`/`apply_tail` in the tree-walker,
`TAIL_CALL` frame-swap in the VM (ROADMAP §1.1). Caveat: a tail call *inside*
`effect`/`with-handler`/`with-config` currently skips the matching scope-exit
in the VM (D9) — that hazard is LAW 24's problem, not a TCO exception.

**Test:** a tail-recursive countdown from 10⁶ ⇒ `0` in both backends, no
overflow (ROADMAP Phase 0 exit 4).

### [LAW 11] Non-tail depth is a heap problem, not a crash

Non-tail recursion (stdlib `map` over a 10⁶-element list) completes without
native stack overflow: evaluation uses an explicit heap-allocated work stack.

*Grounding.* Same OS argument. "Rewrite your fold" is not an acceptable
answer from a substrate.

**Status: unimplemented** — this is D4 and the named Phase-0 "stack-safe
evaluator" workstream; the fuzzer's deep-recursion arm currently produces
`exitdiff:tw-err: Out_of_memory` and `crash:bc:timeout` signatures.

**Test:** `length(map(inc, range(0, 1000000)))` ⇒ `1000000` in both
backends (ROADMAP Phase 0 exit 4).

### [LAW 12] Quotation is total; the language is data

Every form a reader accepts — whichever surface it parses — `quote` can turn
into a value, and quasiquote/unquote work over that structure. Quotation is
defined against the AST (`Types.expr`), so every surface shares one
quoted-data language. A Lisp whose quoted conditional (`'(if a b c)`)
crashes is not homoiconic.

*Grounding.* Metaprogramming (and the `defmacro` that replaces the cut
fexprs — DESIGN Q1/R4iii) rests on code-as-data being *total*, not
best-effort.

**Status: holds** — `quote_to_value` handles all expr forms; the reader
parses quasiquote/unquote/unquote-splicing and a runtime walker expands them
(including splicing, nested quasiquote, vectors, and maps). `defmacro` (M3,
D10's promise, `macro.ml`) redeems the grounding: a macro receives its
argument forms already `quote_to_value`d, computes over them as data (via
`quote`/`quasiquote`/`list`/`cons`/`gensym`), and the result is converted
back to syntax by `Types.value_to_expr` — the total, exhaustive DUAL of
`quote_to_value`, so every case the reader can produce round-trips. This is
possible only because quotation was already total in both directions the
moment `value_to_expr` existed to complete it. `defmacro` is not itself a
reader special form (its shape — `(defmacro (name params...) body...)` in
the AST, `defmacro name(params…) { body… }` in braces — is recognized structurally, at the one expansion point both backends share,
never in `reader.ml`); a macro call is expanded, and gone, before either
backend's own machinery (LAW 20's `hash_expr`, the compiler) ever sees it.

**Test** (in the sexpr/AST notation, the natural one for a raw quoted-list
literal — braces have no bare list literal outside `list(…)`, only calls and
`[…]` vectors): `'(if a b c)` ⇒ the list `(if a b c)` in both backends;
`` `(1 ,(+ 1 1)) `` ⇒ `(1 2)` in both. Quoting the brace form of the same
`if`, `quote { if a { b } else { c } }`, yields the identical list
`(if a b c)` — one quoted-data language regardless of which reader produced
the form.

---

## 3. Effects and ordering

### [LAW 13] Effects are strict within `do` and fire in program order

Each step of `do { e1; e2; …; en }` is forced to completion, in order, before
the next begins; `en`'s value is the block's value. A `perform` fires eagerly
when its expression is evaluated. `do` is the sequencing form — the one place
program order *is* the semantics, by explicit request.

*Grounding.* This is Haskell's two-tier answer: pure values may be computed
whenever, `IO` actions happen in the order written. Effects are the boundary
where the world's arrow of time enters, so they get an explicit, tiny,
sequential sublanguage instead of leaking ordering into everything.

**Status: holds** — the tree-walker forces every `do` step; the compiler
emits `FORCE; POP` per step; the fuzzer compares stderr (the `log` effect
stream) between backends, so effect order is differentially checked.

**Test:** `do { perform log("a"); perform log("b"); 1 }` ⇒ stderr `a` then
`b`, identically in both backends.

### [LAW 14] Undemanded values fire no effects

Outside `do` and node boundaries there is no program-order guarantee: an
effect embedded in a value that is never demanded never fires; one embedded
in a demanded value fires when demand reaches it. If you need an effect to
happen, sequence it in `do` or make it a node input — do not rely on
evaluation order of pure positions.

*Grounding.* Excel doesn't run the formulas of cells nobody references. The
alternative — effects firing from speculative or positional evaluation — is
exactly the ambient, order-by-accident world pp exists to replace.

**Status: holds** for the current thunk semantics (an unforced binding's
`perform` does not fire, in both backends); its interaction with LAW 6
strictness is by construction (node arguments are demanded).

**Test:** `let (x = perform log("never")) { 1 }` ⇒ `1` with empty stderr in
both backends.

### [LAW 15] Ordering never comes from capabilities

Capabilities answer "may this computation touch X" — never "in what order do
writes happen." Ordering comes from data-flow (a consumer forces its
producer) and from the single-writer reconciler (§9). No law in this spec may
be enforced by making a capability linear, affine, or consumable.

*Grounding.* The design history explored affine write-capabilities and
rejected them (CONTEXT reframes 3–5): they import an imperative language's
mutation-policing into a model whose whole point is that there is exactly one
writer per domain, so there is no race to police. Clean factoring:
capabilities = authority/security; DAG + reconciler = determinism/ordering.

**Status: holds** as a constraint on current code (capabilities play no
ordering role anywhere in `src/`), **unimplemented** as a positive mechanism
(the reconciler does not exist — D13).

**Test:** structural — no spec test may require capability consumption for
its ordering claim; the D8/D18 rewrite (Q6) removes any `spent` machinery.

---

## 4. Purity and caching: the bargain

### [LAW 16] Purity is the price of a cache hit; caching is opt-in per node

Only nodes are cached. A node must be pure up to its declared effects: no
uncontrolled shared-state writes, no unrecorded reads. Code that refuses the
bargain lives in the scripting tier — uncached, unrestricted, unsurprising.

*Grounding.* This is the two-tier preamble made law. Nix's insight: a package
is a pure function of its inputs *because that's what makes the store
possible*, not because purity is a virtue. The restriction is the feature.

**Status: partial** — `node { e }` is opt-in and cached persistently in **both**
backends: the same node forced in two processes runs once, the store serves the
second, and a scripting-tier expression is never cached (D1, D7; `tests/010`,
`tests/014`). The "purity" half of the bargain is now partly enforced: node
writes are confined to per-node sandbox scratch and absolute node writes error
(LAW 18, `tests/017`); a tool run inside a node executes in the scratch dir.
A tool's own absolute-path writes are not fail-closed (Q2: traces, not the
sandbox, are the soundness mechanism).

**Test:** the same `node { e }` forced twice across two processes runs once
(store proves it — `tests/010`, `tests/014`); a scripting-tier expression forced
twice runs twice.

### [LAW 17] A cache hit does not replay ephemeral effects

A hit returns the stored result; `log`/stdout emitted during the original run
are **not** re-emitted. Hit and miss may differ *only* in ephemeral output
(and wall-clock). Any observable difference beyond that is a caching-soundness
bug.

*Grounding.* This is what "a hit means the node does not run" means,
committed to honestly (DESIGN R10vi). React does not re-run your logging
when it skips a re-render; pretending otherwise makes hits observable and
caching unsound in the other direction.

**Status: holds** (for the node tier, both backends) — a `node { e }` hit serves
the stored result and does **not** re-emit the `log`/stdout produced on the miss;
verified in the tree-walker (`tests/010`) and the VM (`tests/014`), where a
node's in-body `COMPUTE` log fires only on the miss.

**Test:** force a logging `node { e }` twice, second run in a fresh process:
result identical, log emitted exactly once (on the miss), in both backends.

### [LAW 18] A cached node's writes are sandbox-scratch only

Inside a node, `write-file` targets a sandbox-local scratch path; only output
blob hashes escape. Writes to any reconciled domain go exclusively through
the reconciler (LAW 28). In the scripting tier, `write-file` is free.

*Grounding.* Nix/Bazel sandboxing: the build writes wherever it likes inside
a throwaway directory, and only content-addressed outputs exist afterward.
Without this, "single writer" (LAW 28) is a slogan (DESIGN §1, write-fate).

**Status: partial** — the node/scripting split is enforced in both backends:
inside a node, a relative `write-file` targets the node's sandbox scratch (a
lazily-created temp dir, deleted when the node's frame pops; reads/writes
there are capability-free and unrecorded), and an **absolute** `write-file`
errors — even with an rw grant. The scripting tier is unchanged. `run`
executes with the scratch dir as cwd, so tool outputs land there and only
slurped values escape (`tests/017`). Remaining: reconciled domains do not
exist yet (Q4), so "writes to a reconciled domain go through the reconciler"
is vacuous, and the sandbox does not fail-close a tool's absolute-path writes
(Q2: the sandbox is hygiene; traces are the soundness mechanism).

**Test:** a node calling `perform write-file("/abs/x", …)` errors in both
backends and the file is not written; the same call in scripting tier
succeeds; a node's scratch write never appears outside its sandbox
(`tests/017`).

---

## 5. Content-addressing and cutoff

### [LAW 19] Value identity is a content hash, and equal hashes mean equal values

Every value has a deterministic content hash; identity is structure, not
position or time. The hash function must make collisions cryptographically
negligible (BLAKE3 per Q8 — not MD5) and must cover *everything semantically
part of the value* — in particular, a closure's hash covers its captured
free-variable values.

*Grounding.* Unison hashes definitions; pp hashes computations and world
observations. Everything downstream — dedup, cutoff, distribution, "same
inputs same outputs" — is only as sound as this law.

**Status: partial.** The tree-walker's in-memory dedup is now *sound*: the hash
is SHA-256 (D5 fixed), closure captures are folded into the key so two closures
over different captured values hash differently (D6 fixed), and the ambient
handler stack is folded in too (D17 fixed). A cross-run store now exists and its
value blobs are content-addressed by result hash (D1), shared by both backends
(D7). Remaining gap: the tree-walker's *in-memory* dedup table is not mirrored in
the VM, but that is separate from the persistent node hash, which both backends
compute identically (LAW 20).

**Test:** two closures over different captured values hash differently;
structurally equal values built by different routes hash equally — checked in
both backends.

### [LAW 20] Node key = H(code-hash ‖ arg-value-hashes); authority and handlers are not identity

A node's key covers exactly: its code (with free variables resolved to the
*hashes of their values*) and its argument value hashes. **Not** in the key:
the capability set (authority is checked at hit time — LAW 23), the handler
stack (LAW 26/27), the ambient environment beyond referenced free variables.
What a node *read* during execution is recorded in its trace and governs
validity, not identity.

*Grounding.* Identity vs. validity is BSalC's key/trace split and Nix's
CA-derivation realisations. The current key — `hash(expr, full-env, caps,
config)` — leaks catastrophically: touch one stdlib binding and every key in
the program changes; widen a capability and the world rebuilds (ROADMAP
Appendix A, "leaks found"). Authority may gate *access* to a result; it must
never *rename* the result.

**Status: partial** — the persistent `node { e }` key is now
`H(code-structure ‖ free-var value-hashes)` in **both** backends: the free
variables the node references are resolved (forced, call-by-value) to their value
hashes and folded in, **excluding** the whole-env hash and the capability set.
The tree-walker resolves them from its env (`node_key_of`); the VM resolves them
from the captured frames / globals via compiler-emitted descriptors
(`vm_node_key`), producing a byte-identical key for data-valued free vars so the
backends share store entries. The two catastrophic leaks this law names are
closed — rebinding an *unreferenced* global is a cache hit, and widening the
grant does not invalidate anything (`tests/011`, `tests/014`). Config and the
handler stack are now fully OUT of the key: a config read or a perform inside a
node records a `config:`/`handler:` trace cell instead (LAW 33/26,
`tests/015`). Residuals: binding-order canonicalization is not done (LAW 3);
applied `defnode` is a named closure (LAW 6); and closure-valued free vars key
per-backend (VM closures hash bytecode + captured frames, tree-walker closures
hash AST + env), so those do not share across backends.

**`defmacro` (M3, D10's promise) needed no change to this law, by
construction.** `hash_expr` (`node_key_of`) and the compiler both consume an
expr tree that has ALREADY been macro-expanded — expansion (`macro.ml`) is
the ONE shared step every top-level-form-shaped list passes through before
either backend's own machinery ever sees it (repl.ml's drivers, vm.ml's
`LOAD_FILE`/`eval_module_from`, evaluator.ml's `ELoad`/`eval_module_file`).
So "the code hash must hash the expanded form" is not a special case this
law had to grow — a node built from a macro call is keyed on exactly the
code the macro expanded into, and editing ONLY the macro's own definition
(the call site unchanged) changes that expanded code, hence the key, hence
forces a recompute (`tests/042-defmacro-rekey.sh`, M3 exit 3).

**M3 — the node boundary is symmetric: authority may not cross it in EITHER
direction.** Once capability *values* exist (M3's `current-capabilities` and
friends), a node's free variables and its result are both potential smuggling
routes, so both are hard-banned, independently of each other:
- **Import side (free-var ban):** if a node's free variable's forced value
  contains a `VCapability` anywhere in its structure — including inside a
  captured closure's environment/frames — `node_key_of`/`vm_node_key` raise
  `Capability_error` naming the variable, rather than silently keying on (and
  thereby encoding, in the store's key namespace) a piece of authority. A
  capability hidden behind an UNFORCED thunk is a documented gap (LAW 14
  forbids forcing it just to check); the use-time gates (LAW 22b, LAW 23b) are
  the actual floor for that residual case, not this hygiene check.
- **Export side (result ban):** if a node's result contains a `VCapability`,
  `run_node_body` raises `Capability_error ("a node may not return a
  capability")` before anything is stored. Without this, `node {
  current-capabilities() }` would be an ambient-dependent result invisible to
  both the key and the trace — a determinism hole — and a broad capability
  could ride a cached result out to a caller narrower than the node's own
  creator.

**Test:** rebinding an unreferenced global does not change the node key; widening
the root grant does not invalidate a cached result; changing a *referenced* free
variable does (`tests/011`). A node whose free variable is (or a captured
closure contains) a capability is `Capability_error`, directly and through a
closure, both backends; a node whose body returns (bare or embedded in a
compound value) a capability is rejected before it can be stored, both backends
(`tests/capability-adversarial.sh`).

### [LAW 21] Cutoff is hash equality; validity is the trace, not the key

If a recomputed node's result hash equals the prior result hash, dependents
are not dirtied — even though an input changed. A cached result is *valid*
iff some stored trace's every `(cell, hash)` observation still matches; one
key may hold many traces (different observed toolchains/platforms).

*Grounding.* Content-addressing makes Incremental's cutoff free and exact —
hash equality instead of user-supplied equality functions. The
comment-only-header-edit story (DESIGN Appendix A 2b): compiles must re-run,
link must not.

**Status: partial** — the *validity-is-the-trace* half is real in both backends:
each node key maps to a **SET** of traces, every trace records the
`(file-cell, content-hash)` observations the node made (plus `config:` and
`handler:` cells — LAW 33/26), and a hit is granted only if some trace's every
observation still matches the world — so editing a file invalidates the node,
reverting it re-matches an older trace in the set, an unchanged file hits, and a
touch (mtime-only change) is a non-event (`tests/010`, `tests/016`). The
*cutoff* half is real **at node granularity through LAW-20 keying**: a
downstream node whose free variable is an upstream node's *value* re-keys
identically when a recompute produces a byte-identical result — the
comment-only-header-edit story holds today when the build threads values
through free variables (compile re-runs, link hits; `tests/016`). Not
implemented: cutoff for a node *inline-nested* in its dependent's body (the
parent's trace subsumes the child's reads, so the parent re-runs). The
reverse-edge/dirty-propagation graph now exists and is used by push-mode
`stabilize` (`Store.build_reverse_index`, `Stabilize.reset_dirty`;
`pp --watch --stabilize`; `tests/032`); pull-mode re-verification still walks
from the root when `--stabilize` is not used. Glob and toolchain-closure cells
are not yet recorded.

**Test:** editing a file read by a node re-runs it; an unchanged read hits;
reverting the file hits the original trace in the set (`tests/010`); a
mtime-only touch rebuilds nothing, and a header edit that leaves the compile
result byte-identical re-runs the compile but NOT the value-keyed link
(`tests/016`).

---

## 6. Capabilities

### [LAW 22] Capabilities are unforgeable and enter only at the root

There is no expression that creates authority. `main` receives a powerbox
from the CLI (`--grant ...`); that is the sole mint. User code holds, passes,
`cap-restrict`s (narrows), and `cap-compose`s (unions what it already holds)
— it never constructs. `filesystem("/", :rw)` is an unbound symbol, not a
value.

*Grounding.* The capability tradition's first theorem: authority you can
fabricate is not authority, it's a comment. The rant demands capabilities
*replace* Unix ambient authority; a mintable capability is ambient authority
with extra steps.

**Status: holds** — `filesystem`/`network`/`process`/etc. are unbound symbols;
only `--grant` at process startup mints capabilities. `cap-restrict` and
`cap-compose` only narrow or union capabilities the code already holds.
**M4 amendment:** `CapNetwork` is now `{host; port option}` (a shape change
from the earlier bare `{protocol}` — `--grant net:<host>[:<port>]`; `host =
"*"` wildcards, an unspecified port is unrestricted); `CapSecret {path}` is a
new kind (`--grant secret:<path>`, canonicalized at mint like fs grants).
Both mint only via `--grant`, same as every other kind — the root-mint
invariant is unchanged by adding kinds to it.

**Test:** the adversarial suite (`tests/capability-adversarial.sh`): no
program, through any user-code surface, reads or writes a path it was not
granted; evaluating `filesystem("/", :rw)` is an unbound-symbol error in both
backends. `tests/045-network.sh`: no `net:` grant, or a `net:` grant for a
different host, denies `perform http-get(…)`/`perform http-post(…)`; a covering grant
(exact host, or `net:*`) allows it, host-and-port component-aware (a grant
for one host/port never authorizes another).

### [LAW 22b] `with-caps` narrows to a held value, never widens (M3)

`current-capabilities()` reifies the ambient set as of the call — an
observation of the ceiling the code already exercises on every `perform`, never
a mint. `with-caps(cap-expr) { body }` REPLACES the dynamic ambient with exactly
`cap-expr`'s value for `body`'s extent, gated by `cap_subseteq cap-expr
(current ambient)` — checked against the ambient live AT THE `with-caps` FORM,
not the process's root grant, so a narrowing composes even when some other
in-scope binding lexically retains a broader capability value.
`cap-restrict`'s optional mode argument is symmetric: requesting a mode WIDER
than what the underlying capability already grants at that scope is
`Capability_error`, never a silent widen. The `effect` form (the prior
capability-union block, rule `caps @ ambient`) is REMOVED — the instant
capability values exist, a union-with-ambient rule is a widening backdoor, so
it could not be kept alongside `with-caps`.

**Status: holds** — `current-capabilities`, `with-caps`, and `cap-restrict`'s
mode argument are implemented in both backends; `cap_subseteq` is evaluated
per-kind (SPEC LAW 25's per-kind check functions), with `CapRestrict`'s
authority computed as its effective `(path, mode)` grants (the scope/mode
intersection with the underlying capability, not a mint). `with-caps`
establishes dynamic extent restored on every exit — normal return, tail call,
and a raised exception alike (LAW 27; the VM's `WITH_CAPS` opcode runs the body
via a nested call wrapped in a real exception handler, rather than the flat
enter/exit opcode pair `with-config`/the removed `effect` used, specifically
so a raised error still restores the ambient).

**Test:** composing two capabilities each narrowed from the same broad root
grants only their union, never the root's full authority
(`compose-does-not-resurrect`); a capability value held from before a
`with-caps` narrowing fails the ⊆ check when reused INSIDE the narrowed extent
even though it is still lexically in scope (`with-caps-widen-rejected`);
requesting a wider `cap-restrict` mode than the underlying capability holds is
rejected (`cap-restrict-mode-widen-rejected`); a `with-caps` body that raises,
or ends in a tail call, still restores the prior ambient afterward
(`with-caps-exception-safe`, `with-caps-tail-safe`); `effect(…)` is an
unbound-symbol error (`effect-removed`) — all in `tests/capability-adversarial.sh`,
both backends.

### [LAW 23] Authority checks are component-wise, full-path, and transitive at hit time

(a) Path scope matching is by path component on the canonicalized full path —
a grant of `/tmp` covers `/tmp/x` and never `/tmpevil`. (b) A cache hit is
granted only if the caller's capability set covers the **transitive read
closure** of the stored trace — every cell read by the node *and,
recursively, by every child node* — so a narrow caller cannot launder a broad
read through an aggregating parent (`PUB = f(SECRET)`). (c) Introspection
surfaces (`pp why`, hit/miss observability) are capability-filtered, because
key existence is itself an oracle.

*Grounding.* The cache is a communication channel between past and future
executions; authority must gate the channel, not just live `perform`s.
DESIGN Q6/R3 derives the transitive requirement and its precomputed
`closure-cap-req` fast path.

**Status: holds (NFC residual)** — (a) path checks are component-aware and
full-path (`/tmp` does not grant `/tmpevil`), and the full path is now uniformly
CANONICALIZED first: `Runtime.canonical_path` (absolute realpath, symlinks
resolved, no trailing slash) runs at every `file:`/`tree:`/`stat:`/`tool:`/
`runtime:file:` construction site, at `--grant` parse time, and at the loader
bound (`Runtime.loader_authorized`) — and `Capabilities.path_grants` re-applies
it to both sides of every scope check, so a grant spelled one way authorizes a
cell observed another way (a symlinked source tree, macOS `/var` vs
`/private/var`, a trailing slash — `tests/036`). A path that does not yet exist
canonicalizes its longest existing prefix and appends the rest lexically, so a
write-target's cell-id is stable before and after the file is created
(`tests/036`). NFC Unicode normalization is **not** implemented — a documented
residual; it needs a new dependency (`uunf`, DESIGN E6) and is orthogonal to
the realpath fix. (b) **holds** in both backends: a hit is served only if the
caller's capabilities cover every cell in the stored trace's read closure
(`Store.hit ~authorized`), and because reads propagate to enclosing nodes the
closure is transitive — a narrow caller cannot launder a broad read through a
cached aggregator (`tests/013` tree-walker, `tests/014` VM). A capability denial
raises the distinct `Capability_error` and is deliberately **not** memoized
(authority is not identity/validity — LAW 15), so granting the capability later
still yields a hit. (c) `pp why` exists and is capability-filtered: it explains
each node's hit/miss (first build, stale cell, unauthorized, verified trace) to
stderr, and a cell the caller has no authority over is redacted rather than
named (`tests/019`).

**Test:** grant `fs:/tmp:ro`: reading `/tmpevil/x` errors in both backends.
A caller scoped to `src/` gets no hit on a node whose transitive closure
touched `/etc/passwd` (ROADMAP Phase 1 exit 7).

### [LAW 24] Loader reads are runtime authority, not user effects

`load` / `import` / `island` / stdlib and module resolution are the loader's
reads, bounded to the program's source roots and the store. They run under
the interpreter's runtime authority, are tagged `runtime` in traces, and are
**excluded** from user capability accounting — both at perform time and in
the hit-time closure check.

`island` is a real resolve (D2): the form's **inline 64-hex pin** names an
immutable, verified tree in the island cache, and the URI→pin mapping is
*identity* — it lives in the code hash (LAW 20), never in a trace cell. An
unpinned island form is a hard error; fetching new pins (`git:`/`github:`)
is opt-in runtime authority (`--fetch-islands`/`--update`, journaled — see
docs/THREAT-MODEL-islands.md), so with it disabled evaluation never touches
the network.

*Grounding.* Every program loads its own source; charging that to user
capabilities would make a caller scoped to `src/` unable to hit any node
whose closure touches the stdlib (DESIGN Q6). The runtime/user split is
load-bearing, not cosmetic.

**Status: holds** — every loader read in both backends goes through
`Runtime.loader_read`: bounded to the CLI-named programs' directories, the
working directory, and `~/.pp` (loading anything else errors, grants or no —
the D8c ambient hole is closed), and recorded as a `runtime:file:<path>`
trace cell that participates in cache validity (editing a loaded module
invalidates the nodes that loaded it) while being exempt from the hit-time
authority requirement (`tests/020`). The bound is now realpath-canonical
(LAW 23, `tests/036`): a symlinked source tree is authorized identically to
the real path.

**Test:** a program granted nothing can `load(…)` beside its own source
and hit a node cache whose trace contains that load; loading a path outside
every source root errors even with a broad fs grant; editing the loaded file
invalidates the node — both backends (`tests/020`).

### [LAW 25] Unenforced authority may not exist

A capability kind that nothing enforces (`CapTime`, `CapMemory` today) must
not appear in the surface language. Resource budgets return only when a
scheduler enforces them.

*Grounding.* This spec's honesty rule applied to the language itself: an
unenforced security surface is worse than none, because it teaches users to
trust a fiction (DESIGN Q6).

**Status: holds** — `CapTime`/`CapMemory` have been removed from the
capability type and surface language.

**Test:** evaluating the time/memory constructors is an unbound-symbol error
in both backends until Phase 3's scheduler enforces budgets.

---

## 7. Handlers

### [LAW 26] Two handler classes: result-transparent and semantic

**Result-transparent handlers** (scheduling, placement — Q7's schedulers) may
change only *where/when* work runs, never observable results. They cross node
boundaries freely and appear in no key and no trace. **Semantic handlers**
(mock `read-file`, fault injection, alternate `run`) change meaning: each
intercepted `perform` inside a node records a synthetic trace cell
`handler:<handler-code-hash>:<effect>:<arg-hash> → result-hash`.

*Grounding.* This is the D17 resolution at the trace layer: swapping mock ↔
real changes the handler code hash ⇒ different synthetic cell ⇒ sound
invalidation — strictly better than keying on the whole handler stack, which
would rebuild the world on any handler change, even for effects a node never
performed. It is also what makes "the scheduler is just a handler" (LAW 31)
compatible with caching at all.

**Status: partial** — the semantic half is implemented at node granularity in
**both backends**: every `perform` inside a node records a `handler:<effect>`
trace cell whose observed hash is the intercepting handler's value hash (or a
builtin marker when none intercepts), re-observed against the caller's handler
stack on a hit — so a node cached under a mock `read-file` and one cached under
the real builtin coexist as two traces under one key and never
cross-contaminate (`tests/015`). The recorded cell is coarser than the law's
`handler:<code>:<effect>:<arg-hash> → result-hash` form (no per-arg/result
refinement yet), and the handler stack is still folded conservatively into the
*in-memory* thunk key (the D17 fix). The result-transparent class does not
exist yet — there are no scheduler handlers to classify (Phase 2/3).
**M4 amendment:** `http-get`/`http-post` are new builtin (semantic-class)
effects, dispatched through the SAME `perform_effect`/`handler:<effect>`
machinery as `read-file`/`run` — no new handler category. They are banned
inside node bodies outright (a `trace_stack` guard, the same shape as
`fenced`/`write-file`'s node arm) rather than given a trace cell: a network
read is not the declared-nondeterminism mechanism (LAW 37/38's probes are)
and is not convergent, so it has no sound node-cached meaning at all — legal
only in probe observe-fns, domain observe/apply (stage 2), and the script
tier.

**Test:** force a node under a mock `read-file` handler, then under the real
one: two executions, two results, no cross-contamination (`tests/015`); a
result-transparent handler swap yields a hit with identical result hash
(`--check` audit) — both backends.

### [LAW 27] Effect, handler, and config scopes are dynamic extent — exception-safe and tail-safe

`effect`, `with-handler`, and `with-config` establish dynamic-extent state
that is restored on **every** exit: normal return, tail call, and raised
error alike. Scope state never leaks out of the form that established it.

*Grounding.* Fail-open dynamic scope is an ambient-authority generator: a
leaked handler or capability set is authority nobody granted. try/finally
semantics are the floor, not a nicety.

**Status: holds** — `effect`, `with-handler`, and `with-config` now restore
caps/handlers/config on normal return, exception, and tail call. VM handler
invocation saves and restores the operand stack.

**Test:** `do { with-handler(log = h) { tail-loop() } ; perform log("x") }` — the
final `log` uses the builtin, not `h`, in both backends; an error raised
inside `effect` leaves the capability set exactly as before entry.

---

## 8. Errors

### [LAW 28] A failure is a value with a trace: memoized, and re-forceable exactly when an input changes

A node that fails stores a *failing trace* (result = the error's hash,
outcome = failed). A later force with unchanged inputs re-serves the failure
without re-running; the node is re-executed exactly when a cell in its
failing trace changes. Forcing a failed thunk must report the original error,
never a fabricated one.

*Grounding.* Nix realisations + BSalC verifying traces applied to failure:
a clean build that re-runs every known-broken compile is not incremental.
Determinism means failures are as reproducible as successes (DESIGN R9,
D16's error-memoization law).

**Status: partial** — holds in both backends: a `node { e }` that raises a
`Failure` stores a *failing trace* (error value + the reads made up to the
failure), and a later force re-serves the same error without re-running the body,
re-running only when a recorded read changes (`tests/012` tree-walker,
`tests/014` VM). The D16 "raising thunk left `Evaluating` → fake infinite
recursion" bug is fixed for both persist and ephemeral thunks. Not yet covered:
only `Failure` exceptions are memoized (other exception kinds reset the status and
re-raise but are not cached); and the failure epoch is not yet reconciler-scoped
(Q3).

**Test:** force a failing node twice: same error text both times, body run once
(the in-node `log` fires only on the miss); touch its input, force again: it
re-runs (`tests/012`).

### [LAW 29] Errors carry source locations

A runtime error reports the file and line of the failing form (and, for type
errors, the definition site of the annotation — LAW 30).

*Grounding.* An error without a location is a riddle; the substrate for an OS
does not answer riddles with stack-free strings.

**Status: holds** — emitting `ELocated` for every top-level form and
wrapping `def`/`fn`/`defnode` bodies with their definition-site location is
an obligation on *every* reader, identical across surfaces (the current
s-expression reader satisfies it), and
the shared top-level driver (both backends) appends the enclosing form's
`file:line` to any runtime error whose message does not already carry a
location — so arbitrary top-level expression errors report where they
happened, never doubled (D12 closed; `tests/027-error-messages.sh`). Parse
errors include file and line. Arity errors name the function being called
(`arity mismatch calling f: …`), capability errors name the operation
(`read-file: capability error: …`), and unbound-symbol errors are
byte-identical across backends. Uncaught errors print as one clean
`pp: error: …` line with exit code 1.

A `load`ed file's forms are located against THAT file, not the loading
form: `Reader.read_string` reads a loaded file with its own path (previously
it silently fell back to the reader's `"<?>"` placeholder), and each of its
top-level forms is evaluated (tree-walker `eval_expressions`) or
compiled-and-run (VM `LOAD_FILE`) ONE AT A TIME under the same
never-doubled location decoration as the outer top-level driver
(`Runtime.with_form_location`/`message_has_location` — one implementation,
shared by both backends and both nesting levels). An error inside the
loaded file is decorated with its own `file:line` before it can unwind past
the `load`, so the `load(…)` call site's own decorator — seeing a
message that already carries a location — leaves it alone.

**Test:** `car(5)` at line 3 of `f.pp` reports `f.pp:3` in both backends,
with byte-identical stderr (`tests/027`); case (g) loads a file whose second
form is `car(5)` and asserts the reported location is the LOADED file's
line, not the loading form's.

---

## 9. Desired state and the single-writer reconciler

### [LAW 30] Program = pure function from input cells to a desired-state value; the runtime is the single writer

For observable, convergent domains (an output tree, a process set), a pp
program computes and *returns* a desired-state value — `{path → blob-hash}`,
`{proc-name → spec}` — a pure, hashable, diffable value. It performs no
domain writes. The reconciler — the one privileged writer per domain — diffs
desired against observed cells, applies the minimal change, and verifies
after write. Single writer ⇒ no write-write races ⇒ no ordering discipline
needed in user code (LAW 15). Nodes feeding a domain's desired state may not
read that domain's own cells (stratification — otherwise reconcile loops
forever).

*Grounding.* React verbatim: you never touch the DOM; you return desired DOM
and the reconciler applies the diff. Kubernetes controllers, Terraform's
plan/apply — done with a language that makes `desired` cheap to recompute
(cached) and with reality re-observed rather than a trusted state file.

**Status: holds** (full form, per-domain stratification — M4, Q13) — the
write-discipline law is now enforced GENERICALLY,
for any registered domain, not hardwired to the filesystem: a domain is an
`observe`/`diff`/`apply` triple of ordinary pp functions
(`register-domain`, script-tier), and core (`src/domains.ml`) wraps every
domain's `apply` in the same journal bracket, `observed_all` suspension,
plan cache, and verify-after-write, regardless of what the domain
converges. `src/reconciler.ml` and `src/supervisor.ml` (the pre-Q13 OCaml
modules) are **deleted**; the trusted mechanics they contained (atomic
materialize/remove, fork/exec/reap, per-domain state persistence) moved
into primitives (`tree-observe`, `materialize-file`, `remove-file`,
`proc-spawn`, `proc-alive?`, `proc-stop`, `proc-reap`, `domain-state-get/
put` — `src/domain_prims.ml`), and ALL the policy (the tree-walk diff, the
start/stop/restart decision) moved into `stdlib/domain-fs.pp` and
`stdlib/domain-proc.pp` as real pp source.

`pp --reconcile ROOT prog.pp` auto-loads `stdlib/domain-fs.pp` and
registers it with a write-cap `cap-restrict`'d to ROOT, taking the
program's final value — `{relative-path → content}` — as the fs domain's
desired state: diffs it against observed reality by content hash, applies
atomically, deletes unmanaged files (single writer), journals, requires an
fs write grant, and refuses stratification (`tests/018`, unchanged byte-
for-byte from the pre-Q13 implementation). Desired contents may be inline
strings or `blob:<sha256>` CAS references (`tests/023`). **Watch mode:**
`pp --watch --reconcile ROOT prog.pp` runs the program, reconciles, polls
cells for changes, and re-runs on change (`tests/031`); every registered
domain is now re-observed/re-diffed/re-applied on EVERY tick regardless of
which cells changed (generalized from the pre-Q13 proc-only recheck — a
killed service or an externally-drifted file is caught within one poll
interval either way; cheap when nothing changed, since the plan cache
turns a no-op pass into a cache hit). **Push stabilize:** `pp --watch
--stabilize prog.pp` uses the reverse-edge index from stored traces to
reset only dirty thunks, so clean nodes skip `Store.hit` entirely;
differential test `tests/032` confirms identical re-evaluation patterns to
pull mode on both backends. **The process domain:** `pp --supervise
prog.pp` auto-loads `stdlib/domain-proc.pp` and registers it; the
program's final value is a map of service-name → spec, kept in sync with
observed reality: starts missing services, stops removed ones, restarts on
spec change (compared structurally via `hash-value`, which canonicalizes
map-key order the same way the on-disk codec does — a spec round-tripped
through `domain-state-get/put` must not spuriously compare "different"),
reaps zombies, and restarts a `kill -9`'d service within one poll interval.
Requires `--grant process`, journals intent/done pairs (owned verbatim by
the `proc-spawn`/`proc-stop` primitives), and refuses stratification on
`proc:` observations (`tests/033`, unchanged byte-for-byte). **A
third-party domain unrelated to fs/proc** (`tests/046-domains.sh`'s toy
"kv" domain, registered from an ordinary pp program via `register-domain`
with neither `--reconcile` nor `--supervise`) proves the protocol is
genuinely generic: plan caching across separate process invocations
(proved via `pp why`), stratification, cap threading (`cap-restrict`
itself refuses before the domain ever runs), verify-after-write failure
surfaced for a deliberately under-converging `apply`, the generic journal
bracket, and fenced-after-domains ordering all hold for it too. **Fenced
effects (LAW 31) are live:** `fenced(KIND, SPEC)` registers a
scripting-tier action, drained once per pass after ALL domains'
convergent work; `--fenced-policy retry|abort|ask` resolves unknown-status
intents; a killed mid-apply action is recovered without silent
double-execution (`tests/034`). **Host-qualified domain distribution (M5
stage C):** the desired map generalizes ONE level, `{host -> {domain ->
desired}}` — `--member-name <n>` (explicit opt-in, never inferred) makes
main.ml index that one host's `{domain -> desired}` slice and hand it to
the UNCHANGED `Domains.run_all`/`run_domain` above, which never learn
host-keying exists; without the flag, the desired value passes through
untouched, so every pre-existing program/flags combination (this LAW's
own `tests/018`/`tests/033`/`tests/046`) is byte-identical to before. A
member's `kill -9` recovery is this LAW's existing per-machine story,
unchanged (`tests/049-host-domains.sh`).

**Test:** first reconcile creates the tree; a null reconcile writes nothing;
manual drift and foreign files converge away; a shrunk desired map deletes
the leavers; no write grant ⇒ capability error; a self-reading desired state
⇒ stratification error (`tests/018`); the process domain's equivalents hold
(`tests/033`); a from-scratch third-party domain holds all of the above PLUS
plan caching and verify-after-write failure (`tests/046`). ROADMAP Phase-1
exits 1–5 + 7 hold on a 101-TU C build (`tests/024`), exit 6 via
`scripts/build-self.sh`, and the lot replicate on Lua 5.4.7
(`scripts/build-lua.sh`) — all unaffected by the Q13 migration, since
`--reconcile`'s observable behavior is unchanged.

### [LAW 31] Fenced effects are reconciler-only, journaled, at-most-once per pass

Non-convergent actions (send email, charge card) may not appear in node
bodies at all — nodes are cache-replayable and must not contain irreversible
actions. The scripting-tier primitive `fenced(KIND, SPEC-MAP)` registers an
action for reconciler sequencing.  Under `--reconcile` or `--supervise`, the
reconciler executes fenced actions after all convergent work, journaling
`intent fenced KEY EPOCH KIND SPEC-HASH` → perform →
`done fenced KEY RESULT-HASH`.  Action identity within a pass is
`KEY = H("fenced", EPOCH, KIND, SPEC-HASH)`; the epoch is a fresh nonce per
reconcile pass, and on crash recovery the resumed pass reuses the epoch from
the unknown intent so a re-registered identical action deduplicates.  An
`intent` without a matching `done` after a crash is status **unknown** and
resolves by `--fenced-policy retry | abort | ask`, never by silent retry.

*Grounding.* The desired-state law covers convergent writes only; pretending
it tames non-idempotent actions is how systems double-charge cards. The
carve-out is named, not hidden (DESIGN Q3/E1).

**Status: holds** — both backends share the same primitive and journal
format; a `fenced(…)` inside a node body raises an error; an unknown-
status action is resolved by policy; a killed mid-apply action is retried
exactly once under `--fenced-policy retry` and marked done under `--fenced-
policy abort` (`tests/034`).

**Test:** kill `pp --watch --reconcile ROOT --fenced-policy retry` between
`intent fenced` and `done fenced`; on restart the action is retried exactly
once (crashed run + one recovery retry) and no silent double-execution
occurs (ROADMAP Phase 2 exit 5).

---

## 10. Types

### [LAW 32] Types are optional, gradual, and checked at force time — and the oracle is the strictest implementation

pp is dynamically typed. A type annotation is a checked claim: when an
annotated value is forced, a mismatch is a runtime error reporting the
annotation's definition site. No annotation, no check. The tree-walker (the
correctness oracle) must enforce at least everything the VM enforces —
an oracle weaker than the fast path is not an oracle.

*Grounding.* "Static is a perspective, not a foundation": the top level of a
real system is dynamic; static subsets live inside it as checked claims. This
is the differentiator from Unison. Force-time checking makes annotations
meaningful without a phase that must see the whole (dynamic) graph.

**Status: holds** — both backends enforce type annotations at force time;
the tree-walker `check_type` mirrors the VM (`tests/004-type-test.pp`).
`def`/`fn`/`defnode` bodies carry their definition-site location, so type
errors cite the annotation site. Per-parameter annotations — however a
surface spells them (s-expressions: `(def (f x : int) …)`, `(fn [x : int] …)`;
braces: `def f(x: int) { … }`, `fn(x: int) { … }`) — are checked too (they used to parse and then be discarded): a reader-level
desugar, downstream of any surface's parser, rewrites each into a located
type check (`ELocated`-wrapped `ETyped`) that runs ahead of the body, so
both backends enforce the shared AST identically
(`tests/026-param-types.sh`, fuzzer `stmt_param_typed_def`).

**Test:** `def f(x): int { "s" }` forced ⇒ the same type error, citing the
annotation site, in both backends; `f("oops")` against
`def f(x: int) { … }` ⇒ `type mismatch: expected int, got "oops"` citing the
definition site, byte-identical across backends; unannotated code never
type-errors.

---

## 11. Config

### [LAW 33] Config is ambient, dynamically scoped data; nested scopes shadow; keys may be computed

`with-config({..}) { body }` pushes a config frame for `body`'s dynamic extent;
`config(k, [default])` reads the nearest frame, falling through to the
default. Inner frames shadow outer. The key expression is an ordinary
expression — computed keys are legal. Config is *data* (what to build);
capabilities are *authority* (whether you may). A node that reads config has
observed an input: the read participates in the node's identity/validity like
any other observation, so the same code under different config is a different
computation.

*Grounding.* ReaderT / React context: parameters that flow by enclosure, not
by threading arguments through every call. Keeping config out of the
authority system keeps "what" and "may" from contaminating each other.

**Status: holds** — computed config keys work in both backends, nested scopes
shadow, and config frames are restored on every exit (normal, tail, and
exception) (`tests/006-config-test.pp`, `tests/007-phase0-laws.pp`). The
"config read = observed input" clause is now real at node granularity: a
`config(k)` inside a node records a `config:<k>` trace cell (absence is a
distinct observation), re-observed against the caller's config stack on a hit,
and ambient config is excluded from the node key (`tests/015`).

**Test:** `with-config({"k" -> 1}) { with-config({"k" -> 2}) { config(string-append("", "k")) } }`
⇒ `2` in both backends; outside both forms ⇒ the default.

---

## 12. Location transparency and distribution

### [LAW 34] `force` is the only execution primitive; location has no surface syntax

There is no `remote-eval`, no placement annotation, no node-pinning form —
and there never will be. Where a force runs is decided by the active
(result-transparent — LAW 26) schedule handler; cluster membership is ambient
config/capability. A program is byte-identical whether it runs on one core,
eight, or a cluster.

*Grounding.* The rant's core demand: microservices exist because no language
lets you say "evaluate this elsewhere and flow the result back." The moment
location is syntax, every caller hard-codes topology and you have rebuilt the
deployment-boundary blunt instrument inside the language.

**Status: holds** for the negative half (no location surface exists in any
reader — verified absence). **The positive half now lands for local
process-pool parallelism (M1 / Phase 3):** `--schedule
serial|parallel:N|race:N` selects a result-transparent handler
(`src/scheduler.ml`) that forks worker processes at the dispatch point — a
worker runs the exact `run_node_body` the serial miss arm calls (no second
force path) and communicates only through the store; a dead worker degrades
to an ordinary in-process recompute, never a wrong answer. `--schedule` is
read only by the miss arms and the scheduler — never by `node_key_of` /
`vm_node_key`, and it never enters a trace, so "a program is byte-identical
whether it runs on one core [or] eight" holds by construction, not merely by
intent. **M5 stage B extends this to a cluster:** `--schedule
remote:<member>` is the SAME `Scheduler.policy`/`dispatch_batch` seam,
gated to data-closed batches (every free var re-encodes under
`Codec.encode_value`, M5, "Remote placement");
membership is `~/.pp/cluster/members`/`$PP_CLUSTER_MEMBERS`, ambient
config, never `--grant` — an address is not an authority ceiling, the same
distinction LAW 34 already draws between location and syntax. A member is
an ordinary second `pp` invocation of the byte-identical program; a
non-data-closed node, an unreachable member, or a crashed member all
degrade to local compute, never a wrong answer (`src/remote.ml`). **M5
stage C (closing M5) adds cluster MEMBERSHIP's write-domain half:**
host-qualified domain distribution generalizes the desired map ONE level,
`{host -> {domain -> desired}}`, indexed by the SAME kind of ambient
identifier this LAW already uses for `remote:<member>` — an explicit
`--member-name <n>` CLI flag, never `--grant` (still no location surface;
LAW 34's negative half intact) — handing the UNCHANGED `Domains.run_all`
(LAW 30) only that host's slice; a member is simply `pp --watch
[--supervise] --member-name <n>` on its own slice, the local supervisor's
existing per-machine story, verbatim. Store GC (`pp gc`, explicit, never
automatic) is orthogonal to placement — it never runs during a scheduled
force, only via its own CLI command — and is documented under LAW 30 and
M5, "Store GC".

**Test:** no reader accepts a placement form (unchanged). Phase 3's exit:
the same 101-TU build under `--schedule parallel:N` produces a
byte-identical desired-state hash and materialized tree to the serial run,
with measured speedup (`tests/024`'s `p3-*` assertions); `--check` under a
non-serial policy re-runs forced-serial against the same store and fails on
any hash mismatch (schedule-transparency audit, same file). `tests/038`
stress-tests N concurrent workers against one store and a `race:N` fan-out.
M5 stage B's exit: the same build (scaled to 8 TU) under `--schedule
remote:<member>` over the stage-A local-dir transport, byte-identical
against serial, plus the cross-machine hit, Q11-bis differing-file, and
degrade-path assertions (`tests/048`'s `T6`/`Q11-bis`/`cross-machine-hit`
assertions). M5 stage C's exit: `--member-name` converges only its own
slice while another host's stays untouched, and a member's `kill -9`
recovery holds on that slice (`tests/049-host-domains.sh`); the by-hash
desired-value seam crosses two separate `$HOME`s including a `blob:`
ref's bytes, T1-rejects a tampered published object, and survives `pp gc`
on the receiving side (`tests/051-cluster-exit.sh`); store size stays
bounded across both repeated one-shot passes and a genuine `--watch`-loop/
`pp gc` race, with the kept root's closure surviving the sweep
(`tests/050-gc.sh`'s T7 assertions).

### [LAW 35] "Run on N, take the first" is a handler, not a feature

Redundant/parallel/distributed execution policies (fan-out, racing,
work-stealing, locality) are swappable schedule handlers — library code, zero
language-surface change. Parallelism and distribution are the same feature at
different fan-out.

*Grounding.* This sentence is the rant's opening demand, restated as an
acceptance test. If shipping it requires new syntax, LAW 34 has been
violated somewhere.

**Status: holds** for local process-pool fan-out (Q9, M1 / Phase 3):
`race:N` forks N redundant workers for one singleton node miss (homogeneous
redundancy only — LAW 37 nodes are deterministic, so racing identical
`(key, run)` jobs is sound; heterogeneous racing of different computations
stays out of scope until M4's declared-nondeterminism cells exist), the
first success wins, losers are killed (SIGTERM→SIGKILL), and the parent
re-enters `Store.hit` exactly as the batch path does. Cluster/distributed
racing is Phase 4, gated on a threat model.

**Test:** ROADMAP Phase 3 exit, `tests/038`'s race:3 case: swap
`serial` → `--schedule race:3`, byte-identical program text (only the CLI
flag differs): identical result hash, exactly one surviving trace line
(the store's own content dedup, not merely fork timing), wall-clock roughly
one run rather than N.

---

## 13. Backend parity

### [LAW 36] The two backends are one language

Every observable behavior — values printed, effect logs, error/exit status —
is identical between the tree-walker and the VM. The differential fuzzer is
the ratchet; its `core` grammar must be permanently green, and no *shipped*
feature may exist in one backend only (in-flight divergence during a
migration is allowed; a release with it is not — Q10).

*Grounding.* Two backends with one semantics is the cheapest correctness
asset this project owns — but only if divergence is treated as a broken
build, not a known quirk. A spec nobody can falsify differentially is prose.

**Status: partial** — the fuzzer exists and runs both backends
(`tools/fuzz.ml`; `dune exec ./tools/fuzz.exe`). The previously catalogued
divergences (D3/D15/D19 and the LAW 1 let divergence) are now closed; both
`--grammar core` and `--grammar full` runs exit zero. The persistent node cache
is no longer tree-walker-only — the VM shares the same store and key (D7,
`tests/014`), so `node { … }` caching is not a one-backend feature. Deep non-tail
recursion (D4) and the negative-literal reader bug (`-5` lexes as a symbol)
remain non-differential issues. Phase 0 exit 1 requires the `full` grammar to
stay green under extended CI runs. `defmacro` (M3) is a one-backend-only
FEATURE the moment it exists to violate this law — a macro table per backend,
or expansion happening inside one backend's own compile/eval path, would be
exactly the kind of divergence this law forbids. It does not, by
construction: expansion (`macro.ml`) runs once, ahead of both backends,
producing the SAME expanded AST regardless of which backend consumes it
next — `stmt_defmacro` (fuzzer, full grammar) and `tests/041-defmacro.pp`
exercise this the same way every other shared-AST feature is verified.

**Test:** `dune exec ./tools/fuzz.exe -- --grammar core` exits zero (the CI gate);
Phase 0 exit 1 extends this to the `full` grammar with zero value-or-effect
divergence within the time budget.

---

## 14. Reproducibility and volatility

### [LAW 37] Same inputs, same output — and nondeterminism must be declared

A node given the same input value hashes produces the same result hash. There
is no ambient entropy: `random`, wall-clock, and friends are either
capability-gated, trace-recorded *inputs* (a nondeterministic read is an
observation of the world — a cell) or unavailable inside nodes.

*Grounding.* This is the Excel/Nix law verbatim — same inputs, same outputs —
and it is what every other law's cache-soundness quietly depends on. Hidden
entropy is a hidden input, which is the one thing content-addressing cannot
forgive.

**Status: holds** (M4) — `random` remains removed (D8c unchanged); the
sanctioned nondeterministic dependency is now the **probe** (`register-probe(
name, observe-fn, read-cap)`, script-tier; `probe(name)`, inside or outside
nodes): observe-fn runs at most once per pass, OUTSIDE any node's trace stack
(so its own reads never contaminate the reading node's trace), under exactly
the registered `read-cap`; the reading node records only a `probe:<name>`
trace cell (hash of the observed value), capability-free at the read site —
the authority was already spent evaluating the probe. A node itself still
has no ambient entropy: nondeterminism enters ONLY through a declared probe
cell, never through an un-cell'd effect.

**Test:** a node reading `probe(name)` re-forces exactly when the probe's
underlying value changes across two separate runs, and hits (no recompute)
when it doesn't (`tests/043-probes.sh`, both backends); an unregistered
probe name is a hard error; a probe registered but never read never fires
(demand-pruned, mirroring LAW 7).

### [LAW 38] Volatile nodes are contained as cells and barred from shared caches

A node whose tool is irreducibly nondeterministic (`__DATE__`, timestamp
linkers, ASLR) is detected by `--check` (double-build, compare hashes) and
its result is treated as a *cell* — observed and pinned per pass — so its
instability stops at one edge instead of re-keying its whole ancestor cone
every build. Volatile results never enter a shared cache. Canonicalization
adapters (`-frandom-seed`, `ZERO_AR_DATE`) are preferred where they exist.

*Grounding.* The reproducibility hair Nix keeps finding, budgeted as
permanent gardening rather than wished away (ROADMAP E4). Cutoff above a
volatile node is otherwise dead, and the store grows without bound along the
cone.

**Status: holds** (M4) — the *detection* half already existed in both
backends (`pp --check` runs every missed node's body twice, compares result
hashes, flags a divergence as volatile, `tests/019`). The *containment* half
is now the probe mechanism (LAW 37): wrapping a volatile read as
`register-probe(name, observe-fn, read-cap)` / `probe(name)` moves it OUT of
the node body and into its own `probe:<name>` cell — observed and pinned
once per pass, exactly the "cell" treatment this law asked for — so a node
reading it re-forces only when the probe's value actually changes, and its
instability never re-keys or invalidates anything beyond that one cell edge.
Probe results are never written to `~/.pp/store` at all (Runtime.probe_values
is in-memory, cleared every pass) — stronger than "excluded from shared
caches," since there is no cache to exclude them from.

**Test:** a node whose tool emits a random value, wrapped as a probe, is
observed once per pass and re-forces the reading node only when the probe's
value changes across runs — never on an unrelated node, and never by
re-running the underlying volatile read more than once per pass
(`tests/043-probes.sh`, both backends). The pre-existing `--check`
double-build detection (`tests/019`) is unchanged.

### [LAW 39] Sealed cells: confidential reads are a distinct value kind, banned at the node boundary

`--grant secret:<path>` mints `CapSecret {path}`. A read covered by
`CapSecret` and NOT by `CapFilesystem` returns a new value kind, `VSealed`,
instead of `VString`: the cell records `sealed:<canonical-path>` (a hash of
the bytes — rotation invalidation needs it), the bytes pin in-memory only
(never `store_blob`/the CAS — a store-wide scan must never find secret
plaintext), and `string_of_value`/every printer redacts to `#<sealed>` (a
print that leaked the bytes would defeat the feature). `VSealed` joins the
M3 node-boundary ban exactly like `VCapability` — free-var ban and result ban,
both directions, both backends — and `cell_authorized_for` requires a
covering `CapSecret` grant to serve a hit on a `sealed:` cell (LAW 23b/23c
fall out unchanged: a narrow caller cannot launder a cached secret read
through an aggregator, and `pp why` redacts it). `unseal(v)` is the one
explicit, greppable way out to `VString` — derived data is ordinary data
afterward, by design (no dataflow tainting, the Vault/SOPS line); unsealing
INSIDE a node makes the result cacheable ordinary data, a documented residual
of the same shape as every other cache holding whatever a node chooses to
return. Covered by BOTH `secret:` and `fs:` grants: ordinary fs behavior
wins (the deployment that also granted plain fs access over the same path is
saying "not secret here").

*Grounding.* Q11's snapshot-as-CAS-ingest (every file read gets
content-addressed into `blobs/`) is sound for ordinary data and a
confidentiality bug for secrets; a security boundary needs a distinct VALUE
KIND for the existing node-boundary/authority machinery to pattern-match on,
not a new parallel authorization path.

**Status: holds** — implemented in both backends;
`tests/044-sealed.sh` covers: redacted print, `unseal` round-trip, a
recursive store scan proving the secret's bytes never land under
`~/.pp/store` (for a program that only reads, and separately one that
unseals at script tier only); the node-boundary ban both directions with
byte-identical stderr across backends; rotation invalidating exactly the
observing node (a sibling node is untouched); a caller without the
`secret:` grant unable to hit a node whose cached closure read it even
though the trace exists on disk; and the both-grants case behaving as plain
fs.

**Test:** `tests/044-sealed.sh`, both backends.

---

## Appendix A — Current gaps

Every non-**holds** law, with the discrepancy/fuzzer evidence it maps to.
This table is the honest inverse of the spec: what pp *says* it is versus
what `src/` does today. (Current-state claims cite ROADMAP §1 D#s and fuzzer
signatures, not line numbers — the source is under active migration.)

| Law | Area | Status | Evidence / D# |
|---|---|---|---|
| LAW 1 | mutual `let` scope | holds | `tests/007-phase0-laws.pp`; fuzzer `full` grammar |
| LAW 2 | dependency-derived order, cycle errors | partial | cycles caught via `Evaluating` marker; report is generic, not named |
| LAW 3 | binding-order-free identity | unimplemented | `hash_expr` order-sensitive (reordering changes the hash) |
| LAW 4 | one scope model | partial | value defs (`let x = v`) bind values with letrec* block scope, identical in both backends (`tests/025`); `do`-block and module-body scoping now matches the tree-walker in the VM too (D22 closed: `do` defs are block-local, never VM globals; module-body siblings resolve via local slots, not globals — `tests/039`); a module is still its own fresh, outer-scope-isolated environment rather than truly nested `let`-style, so full unification remains partial |
| LAW 5 | `let*` sequential sugar | holds | reader emits `ELetStar`; both backends sequential; `tests/007-phase0-laws.pp` |
| LAW 6 | node CBV + memoization | partial | application is CBV (Q1); `node { e }` memoizes persistently, keyed on code + free-var value hashes (LAW 20; `tests/011`); `node x { e }` binds the node thunk (`tests/025`), but applied `defnode` is still a named closure, so aggregator-keyed-on-child-result-hashes doesn't yet arise |
| LAW 7 | demand-pruning at node granularity | partial | reverse-edge dirty-propagation graph exists for push `stabilize` (`pp --watch --stabilize`, `tests/032`); root desired-state formula / explicit wanted-set still absent (Q1/Q5) |
| LAW 8 | `delay` ephemeral vs `node` persistent | partial | the split exists in both backends (`node` → `~/.pp/store`; `delay` never persists); residual: tree-walker's in-memory dedup table isn't mirrored in the VM (D7), separate from the node cache |
| LAW 11 | stack-safe non-tail recursion | unimplemented | D4; fuzz `exitdiff:tw-err: Out_of_memory`, `crash:bc:timeout` |
| LAW 12 | total quotation, quasiquote | holds | D11/D19 fixed; `tests/007-phase0-laws.pp`; `defmacro` (M3, D10's promise) built on this base — `Types.value_to_expr` completes the round trip, `tests/041-defmacro.pp` |
| LAW 15 | ordering never from capabilities | partial | negative half holds; fs-domain reconciler v1 exists (`tests/018`), process domain absent |
| LAW 16 | opt-in per-node caching | partial | `node { e }` cached persistently across runs in both backends (D1, D7); scripting-tier exprs uncached; node writes sandbox-scratch-only (LAW 18, `tests/017`); `tests/010`, `tests/014` |
| LAW 17 | hit ≠ effect replay | holds (node tier) | a `node { e }` hit does not replay in-node `log`/stdout, both backends (`tests/010`, `tests/014`) |
| LAW 18 | sandbox-scratch writes | partial | per-node scratch sandbox real: relative node writes/reads are scratch-local, absolute node writes error, `run` cwd = scratch (`tests/017`); reconciled domains absent (Q4) |
| LAW 19 | sound content hashing | partial | SHA-256 (D5 fixed); closure-env + handler holes closed → in-memory dedup sound (D6/D17 fixed); store objects content-addressed by result hash, shared by both backends (D1, D7); tree-walker's in-memory dedup table not mirrored in the VM |
| LAW 20 | key = code ‖ arg-values | partial | persistent `node { e }` key = code + free-var value hashes; caps, whole-env, config, and handlers all excluded (`tests/011`, `tests/015`); binding-order not canonicalized (LAW 3); node boundary now symmetric (M3): a capability-containing free var is `Capability_error` at the key, a capability-containing result is rejected before storage, both backends (`tests/capability-adversarial.sh`); `defmacro` (M3) expands before either backend's `hash_expr`/compiler ever sees a form, so the key is always over the EXPANDED code with no change to this law — a macro-only edit re-keys its call sites (`tests/042-defmacro-rekey.sh`) |
| LAW 21 | cutoff via traces | partial | validity-via-verifying-trace real (key→SET of traces, cells re-checked on hit; `tests/010`, `tests/015`); hash-equality cutoff proven at scale — comment-only header edit on a 101-TU C build and on Lua 5.4.7 recompiles dependents and cuts off the link (`tests/016`, `tests/024`, `scripts/build-lua.sh`); reverse-edge/dirty-propagation graph now used by push `stabilize` (`pp --watch --stabilize`, `tests/032`); inline-nested cutoff still absent |
| LAW 22 | unforgeable root-minted caps | holds | D18 fixed; constructors removed; `tests/capability-adversarial.sh` |
| LAW 22b | `with-caps` narrows a held value, never widens | holds | `current-capabilities`/`with-caps`/`cap-restrict`'s mode argument (M3); `cap_subseteq` checked against the CURRENT ambient; `effect` removed; both backends, exception/tail-safe; `tests/capability-adversarial.sh` |
| LAW 23 | component/full-path + transitive hit check | holds (NFC residual) | (a) component-aware, canonicalized (realpath, no trailing slash) paths at every cell/grant/loader-bound site (`tests/036`); (b) hits gated on the caller's caps covering the trace's transitive read closure in both backends, cap denials not memoized (`tests/013`, `tests/014`) — "the caller's caps" is now the forcing thunk's captured `node_caps` (M3 node capture), collapsing to the pre-M3 per-process grant when `with-caps` is unused; (c) capability-filtered `pp why` real (`tests/019`); NFC Unicode normalization not implemented |
| LAW 24 | loader = runtime authority | holds | loader bounded to source roots + ~/.pp, reads traced as authority-exempt `runtime:file:` cells (`tests/020`); realpath-canonical (`tests/036`) |
| LAW 25 | no unenforced authority surface | holds | `CapTime`/`CapMemory` removed from types and surface (D8d) |
| LAW 26 | two handler classes, synthetic trace cells | partial | semantic half real at node granularity: `handler:<effect>` trace cells in both backends, mock/real coexist without cross-contamination (`tests/015`); cells coarser than the law's per-arg form; result-transparent class awaits schedulers (Phase 2/3) |
| LAW 27 | exception/tail-safe dynamic extent | holds | D9/D16/D20 fixed; save-stack restore on every exit |
| LAW 28 | failure traces, error memoization | partial | both backends memoize `Failure` outcomes as failing traces, re-served until a recorded read changes; D16 `Evaluating`-leak fixed (`tests/012`, `tests/014`); non-`Failure` exceptions uncached |
| LAW 29 | source locations in errors | holds | D12 closed: every top-level form's location is appended to unlocated runtime errors in both backends; arity/capability errors name the callee/operation; `pp: error:` single-line reporting; a `load`ed file's own forms are individually located and decorated with THAT file's location before the error can unwind past the `load` (`tests/027`, including case (g)) |
| LAW 30 | desired-state + single writer | holds | Q13 full form: `register-domain` (a probe is the ⊥-write-authority case, one registry) + generic orchestration (`src/domains.ml`) enforce plan/journal/atomic-apply/verify/stratification for ANY registered domain, not hardwired to fs — `src/reconciler.ml`/`supervisor.ml` deleted; `stdlib/domain-fs.pp`/`domain-proc.pp` hold the fs/proc policy as pp source (`tests/018`, `tests/023`, `tests/033` unchanged byte-for-byte); a from-scratch third-party domain proves genericity (`tests/046`); drives a real 101-TU C build and Lua 5.4.7 end-to-end (`tests/024`); push `stabilize` live (`pp --watch --stabilize`, `tests/032`) |
| LAW 31 | fenced effects, intent journal | holds | scripting-tier `fenced(KIND, SPEC)`, `--fenced-policy retry|abort|ask`, intent/done journal, recovery without silent retry; `tests/034` |
| LAW 32 | gradual types, strictest oracle | holds | D3 fixed; both backends enforce; tests 004/005 restored; `tests/007-phase0-laws.pp` |
| LAW 33 | config: computed keys, tail-safe scoping | holds | D15 fixed; computed keys and tail-safe scoping in both backends; config reads inside nodes are `config:<key>` trace cells, ambient config out of the node key (`tests/015`) |
| LAW 34 | no location surface / scheduler exists | holds | negative half holds; scheduler half lands for local process-pool parallelism (M1, `tests/024`/`038`) AND remote cluster placement (M5 stage B, `--schedule remote:<member>`, `tests/048`); host-qualified domain distribution + GC remain M5 stage C |
| LAW 35 | run-on-N-take-first as handler | holds | `race:N` process-pool fan-out lands (M1, `tests/038`); `remote:<member>` cluster dispatch lands (M5 stage B, `tests/048`), gated to data-closed batches, over the stage-A threat-model-gated transport |
| LAW 36 | backend parity | partial | catalogued divergences closed; `core` and sampled `full` green; deep non-tail recursion and negative-literal lexing remain same-side issues; `defmacro` (M3) expands once, ahead of both backends (`macro.ml`), so it cannot itself become a one-backend feature — `stmt_defmacro` in `full` |
| LAW 37 | declared nondeterminism | holds | M4 probes: `register-probe`/`probe` are the one sanctioned nondeterministic dependency, evaluated at most once per pass outside the reading node's trace stack, exposed only as a `probe:<name>` cell (`tests/043-probes.sh`) |
| LAW 38 | volatile-node containment | holds | `--check` double-run detection unchanged (`tests/019`); containment is the same M4 probe mechanism as LAW 37 — a volatile read wrapped as a probe is observed/pinned once per pass as its own cell, in-memory only, never written to `~/.pp/store` (`tests/043-probes.sh`) |
| LAW 39 | sealed cells | holds | `CapSecret`/`VSealed`: confidential reads redact on print, exclude from the CAS, ban at the node boundary both directions, gate hits on a covering grant; `unseal(v)` is the explicit boundary (`tests/044-sealed.sh`) |

Laws that **hold** today, for the record: LAW 1 (mutual `let`),
LAW 5 (`let*` as sequential sugar), LAW 9 (branch pruning), LAW 10 (TCO),
LAW 12 (total quotation/quasiquote), LAW 13 (effect order in `do`),
LAW 14 (undemanded values fire no effects), LAW 22 (unforgeable caps),
LAW 25 (no unenforced authority), LAW 27 (exception/tail-safe dynamic
extent), LAW 32 (gradual types), LAW 33 (config), LAW 35 (run-on-N-take-first
as a handler, local process pool) — each exercised by `tests/*.pp` under
`--diff` and/or the fuzzer, and each must stay green through the Phase 1
build-engine work.

---

## Appendix B — The brace surface: token spec and lowering table (non-normative)

> **This annex is non-normative.** It freezes M7's S0 deliverable
> ([M7-SYNTAX.md](M7-SYNTAX.md)): the grammar of the brace/infix surface and
> the exact s-expression form every brace construct reads to. It defines **no
> new semantics** — every row lowers to a form the laws above already govern,
> and those laws are stated against the AST (`Types.expr`), never against a
> surface. The s-expression language is unchanged: it remains the AST's
> notation and the macro layer's data language (`quote` yields sexpr data in
> both surfaces).
>
> **The elegance criterion (frozen).** Reading a brace file and reading its
> s-expression transpilation must yield the **identical `Types.expr`** — and
> therefore identical LAW-20 keys. No renames: kebab-case identifiers
> (`string-index`, `nil?`, `proc-alive?`, `run!`) survive verbatim. Because
> `hash_expr` covers `ELocated (file, line)`, "identical `Types.expr`" has
> two load-bearing corollaries:
>
> 1. the brace reader must attach `ELocated` at exactly the sites the
>    s-expression reader does (§B.4), and
> 2. a *migration* transpile (S2/S3) must preserve the source path and the
>    line number of every location-carrying form nested inside hashed code —
>    any `fn`/`def` inside a node body carries its definition line into the
>    node key (e.g. the `link` node of `tests/024`, whose body contains
>    `(fn (o) …)`) — or node keys change and the null-rebuild exit fails.
>    The S2 formatter, not this grammar, owns that constraint; it is recorded
>    here because the grammar was shaped to make it satisfiable (every brace
>    form fits on the same line(s) as its sexpr spelling).

### B.1 Tokens

**Identifiers.** A maximal run of *name characters*. Name characters are the
s-expression reader's symbol characters **minus `:`** — i.e. everything
except whitespace, `, ( ) [ ] { } < ' `` ` `` " ; # ~` and `:`. So `-` `?`
`!` `.` `/` `*` `+` `=` `>` `|` `_` and friends are all name characters:
`string->number`, `nil?`, `proc-alive?`, `let*`, `run!`, `a-b` are each ONE
identifier. (`:` is reassigned in braces to keywords, annotations, and cell
literals; sexpr symbols may contain `:` — bare island URIs like `file:./lib`
— but no *binding* in the tree uses one, and braces spell island URIs as
strings — row L55.)

**The whitespace rule (frozen, non-negotiable).** Infix operators require
surrounding whitespace: `a - b` is subtraction, `a-b` is one identifier.
Token identity is decided by maximal munch; whether a token *acts* as an
infix operator is decided by position, never inside a token. `a ->b` is the
identifier `->b` in operand position (a parse error), not an arrow. The `->`
token is the sharpest case of this rule, and it is load-bearing for the
type-conversion naming convention: glued, `string->number` is a single
identifier (a conversion primitive — likewise `number->string`); with
whitespace on both sides, `k -> v` is the map/reconcile arrow (L10). The two
never collide because the glue rule alone distinguishes them — `string ->
number` (spaces) would instead be the arrow between two operands. This one
rule is what lets the entire stdlib migrate with zero renames (M7
consequences 1–2). The `<`-family (`<`, `<=`) is lexed specially in braces
exactly as in sexprs (`<` is not a name character) but obeys the same
whitespace requirement for uniformity.

**Reserved words.** The following are grammar in head/statement positions,
not bindable names: `and` `assert` `config` `def` `defmacro` `delay` `do`
`else` `fn` `force` `if` `import` `island` `let` `let*` `load` `load-module`
`mod` `module` `needs` `node` `or` `perform` `quasiquote` `quote` `reconcile`
`splice` `unquote` `with-caps` `with-config` `with-handler`, plus the
literals `true` `false` `nil`. (No existing binding in stdlib/tests/demo
collides — verified; S1's differential gate re-verifies mechanically.) An
operator word (`and`, `or`, `mod`) or operator symbol (`+`, `-`, `<=`, …) in
a **non-infix** position denotes its symbol: `foldl(+, 0, xs)` →
`(foldl + 0 xs)`, `mod(a, b)` → `(mod a b)`. Special-form heads applied in
call position parse as their special forms, exactly mirroring the sexpr
reader's car-symbol dispatch.

**Comments.** `#` to end of line. **`;` is NOT a comment** — it is the
inline statement separator. This is the loudest single lexical difference
from the s-expression surface (where `;` comments and `#` introduces `#{`):
the S2 formatter must transpose comment markers, and `#` never opens a set
literal in braces — sets are spelled with the call form `hash-set(…)` (L12).

**Strings.** As in the sexpr reader: `"…"` with escapes `\n` `\t` `\\` `\"`
(any other backslashed character is itself); literal newlines allowed.

**Numbers.** As in the sexpr reader: a token starting with a digit — or with
`-` *immediately* followed by a digit or `.`digit — is a number; `.` and
exponents as today (`20.` is a float). `-5` is a literal when the sign is
attached; `a - 5` is subtraction; `a -5` is two adjacent operands — a parse
error, by design.

**Keywords.** `:name` (`:` at token start) → `VKeyword`, as in sexprs.

**Cell literals.** An identifier immediately followed by `:` immediately
followed by a string literal — no whitespace anywhere: `file:"src/main.c"`,
`env:"CC"`, `tree:"src"`. Exactly these three heads exist (rows L47–L49);
any other `name:"…"` is a parse error (the space is reserved). World-reads
get visual identity; the literal is authority-neutral — whether `file:"p"`
returns plain bytes or a sealed value stays the grant's decision (LAW 39),
because the lowering is the same read form either way.

**Annotations.** `:` after a parameter or binding name (`x: int`) or after a
parameter list (`def f(x): int`) — rows L24, L27–L31.

**Separators.** Inside `{ … }` blocks and at top level, statements are
separated by newline or `;`. The surface is **not** whitespace-sensitive (no
indentation semantics — pp programs generate pp programs): a newline ends a
statement only when it is syntactically complete. Inside an open `(` `[`
`{`, or after an infix operator, `=`, `->`, `|>`, a comma, or a form head
still awaiting its block, the statement continues across the newline. Commas
separate call arguments, vector/map elements, binding groups, `needs` items,
and handler pairs; a comma is never `unquote` (row L58 is).

**Blocks vs map literals.** `{ … }` in *expression position* is always a map
literal (L10). A block `{ … }` appears only immediately after one of the
closed set of block-taking heads: `fn(…)` `def f(…)` `node` `do` `if`/`else`
`let(…)` `let*(…)` `module` `quote` `quasiquote` `defmacro name(…)`
`reconcile` `with-caps(…)` `with-config(…)` `with-handler(…)`. Sequencing in
expression position is spelled `do { … }`. In an `if` condition the
expression is parsed brace-free, Go-style: a top-level `{` terminates the
condition (parenthesize a map literal used directly as a condition).

### B.2 Precedence and associativity

Every infix operator lowers to a **binary** application (or the `if`
desugar). The operator set is exactly what the s-expression language already
has as primitives/special forms — no new semantics, per M7's grammar-creep
rule.

| Level (tight → loose) | Operators | Associativity | Lowers to |
|---|---|---|---|
| 1 | call postfix `E(a, …)` | left (`f(x)(y)` → `((f x) y)`) | `(E a …)` |
| 2 | `*` `/` `mod` | left | `(* l r)` `(/ l r)` `(mod l r)` |
| 3 | `+` `-` | left | `(+ l r)` `(- l r)` |
| 4 | `<` `>` `<=` `>=` `=` | none — chaining is a parse error | `(< l r)` etc. |
| 5 | `and` | **right** | `(and l r)` ⇒ `(if l r false)` |
| 6 | `or` | **right** | `(or l r)` ⇒ `(if l true r)` |
| 7 | `\|>` | left | `x \|> f` → `(f x)`; `x \|> f(y, …)` → `(f x y …)` |
| — | `->` | n/a | not an expression operator: key/value separator inside map literals (and `reconcile`) only |

Notes, each load-bearing for hash preservation:

- **There are no unary operators.** Negation is a signed literal or `0 - x`;
  the primitives' n-ary spellings (`(+ a b c)`, chained `(< a b c)`,
  variadic `=`) are reached by call syntax — `+(a, b, c)`, `<(a, b, c)`.
  An infix chain `a + b + c` lowers left-nested to `(+ (+ a b) c)`, which is
  a **different AST (and hash)** from `(+ a b c)`: the S2 printer must print
  n-ary applications in call form, never as infix chains.
- **`and`/`or` are right-associative deliberately**: the sexpr forms desugar
  right-nested (`(and a b c)` ⇒ `(if a (if b c false) false)`), so a
  right-associative infix chain `a and b and c` lowers to the *identical*
  `EIf` tree. Variadic `and`/`or` therefore DO survive infix printing with
  hash equality — the desugar erases the arity, unlike `+`.
- **`|>` is pure reader-level rewriting** (lowest precedence, so
  `x + 1 |> f` is `(f (+ x 1))`): a pipeline and its spelled-out application
  are the same computation, hence the same key. The right-hand side must be
  an identifier or a call form; anything else is a parse error.

### B.3 Lowering table

Each row gives the s-expression text a brace form reads as; both readers
must then agree at the `Types.expr` level. Where the sexpr reader applies a
reader-level desugar (`and`/`or` → `if`, `assert`, per-parameter type
checks, the block rule), that desugar is a **shared post-pass** run
identically downstream of both parsers (M7 consequence 3) — never
duplicated. ⟦stmts⟧ denotes the block rule (`reader.ml block_body`): one
statement → the statement itself; several → `(do stmts…)`; zero → `(do)` —
including the block's duplicate-definition check (LAW 4).

**Atoms and literals**

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

**Composite literals**

| # | Brace form | Reads as |
|---|---|---|
| L9 | `[e1, e2, …]` | `(list e1 e2 …)` — **revised** (see note) |
| L10 | `{ k1 -> v1, k2 -> v2, … }` | `(hash-map k1 v1 k2 v2 …)` |
| L11 | `{}` (expression position) | `(hash-map)` |
| L12 | *(no set literal — `#` is the comment character)* `hash-set(e, …)` | `(hash-set e …)` |

> **L9 is a revision, not sugar.** `[…]` originally read as `(vector …)`; it
> now reads as `(list …)` — the default collection is a cons-list. This is a
> **semantic, hash-affecting** change, *not* a surface convenience: a bracket
> literal now evaluates to a different runtime value (a `VPair` cons-chain, not
> a `VVector`), so its LAW-20 content hash changed and the golden store had to
> be regenerated — that regeneration commit is the receipt that the change is
> real, not cosmetic. Two consequences follow and are checked mechanically:
> (1) the quasiquote path was realigned so a `[…]` template builds the same
> cons-list value the equivalent code builds (A2, `tests/060-qq-list-parity.sh`);
> (2) `pp check` sweeps for `vector-get`/`vector-length` applied directly to a
> bracket literal — a leftover from the vector era that is now a type error —
> and flags it (`tests/064-l9-vector-sweep.sh`).

**Operators** (see §B.2 for nesting)

| # | Brace form | Reads as |
|---|---|---|
| L13 | `a + b`, `a - b`, `a * b` | `(+ a b)` `(- a b)` `(* a b)` |
| L14 | `a / b`, `a mod b` | `(/ a b)` `(mod a b)` |
| L15 | `a < b`, `a >= b`, `a = b`, … | `(< a b)` `(>= a b)` `(= a b)` … |
| L16 | `a and b` | `(and a b)` — the shared desugar yields `(if a b false)` |
| L17 | `a or b` | `(or a b)` — desugar `(if a true b)` |
| L18 | `x \|> f`; `x \|> f(y)` | `(f x)`; `(f x y)` |

**Application**

| # | Brace form | Reads as |
|---|---|---|
| L19 | `f(a, b)`; `f()` | `(f a b)`; `(f)` |
| L20 | `(fn(x) { x })(3)`; `f(x)(y)` | `((fn (x) x) 3)`; `((f x) y)` |

**Bindings and functions**

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

**Nodes**

| # | Brace form | Reads as |
|---|---|---|
| L32 | `node { E… }` (expression) | `(node ⟦E…⟧)` |
| L33 | `node name { E… }` | `(defnode name ⟦E…⟧)` — ≡ `(def name (node ⟦E…⟧))`, LAW 4 |
| L34 | `node f(p…) { body… }` | `(defnode (f p…) body…)` — typed params/return as L30/L31 |
| L35 | `node f(p) needs I1, I2 { body… }` | `(defnode (f p) (with-caps C ⟦body…⟧))` where `C` is the single lowered item, or `(cap-compose I1′ I2′ …)` for several |

`needs` items (L35) lower via the grant-descriptor sugar of §B.8
(`fs.read`/`fs.write`/`fs.rw`, each a mode-scoped `cap-restrict` over
`(current-capabilities)` — that table is the one authoritative listing, not
this paragraph). **`needs` is value-open:** the descriptors are only sugar;
any other item is an ordinary expression passed through unchanged (it must
evaluate to a capability — LAW 22b's ⊆ gate does the enforcing; the reader
adds nothing), so a named or composed grant is a legal item —
`node deploy() needs k8s-prod { … }` where `let k8s-prod =
cap-compose(net("k8s.prod.internal"), process)`. The capability *kind* set
stays closed (DESIGN §1 principle 7); the *vocabulary* of named grants is open
at the value level. The `fs.*` descriptors are recognized only inside a
`needs` clause (elsewhere `fs.read` is just an identifier). The M7 sketch's bare `proc` item is **not frozen**: no existing
form projects a single capability kind out of the ambient set
(`cap-restrict` is path-scoped, and a path-restricted `CapProcess` is
unusable — `demo/agent.pp`'s own comment), so freezing it would require a
new core projection primitive — a language change, out of M7's scope by the
grammar-creep rule. Creation-time narrowing (M3 node capture) stays
expressible by composition: `def f(x) { with-caps(E) { node { … } } }`
→ `(def (f x) (with-caps E (node …)))`.

**Control and sequencing**

| # | Brace form | Reads as |
|---|---|---|
| L36 | `do { s… }` | `(do s…)` |
| L37 | `if C { T… }` | `(if C ⟦T…⟧)` — else defaults to `nil`, LAW 9 |
| L38 | `if C { T… } else { E… }` | `(if C ⟦T…⟧ ⟦E…⟧)` |
| L39 | `if C1 { … } else if C2 { … } else { … }` | nested `(if C1 … (if C2 … …))` — there is no `cond`/`match` in the language; the chain **is** the spelling |
| L40 | `force(E)`; `delay(E)` | `(force E)`; `(delay E)` |

**Effects, handlers, capabilities, config**

| # | Brace form | Reads as |
|---|---|---|
| L41 | `perform name(a, …)` | `(perform name a …)` — for every effect: `read-file` `write-file` `run` `run-dep` `http-get` `http-post` `log` `tree-observe` `materialize-file` `remove-file` `proc-spawn` `proc-alive?` `proc-stop` `proc-reap` `domain-state-get` `domain-state-put` |
| L42 | `with-handler(n1 = h1, n2 = h2) { body… }` | `(with-handler [n1 h1 n2 h2] body…)` — a handler name may also be a keyword literal, as in sexprs |
| L43 | `with-caps(E) { body… }` | `(with-caps E body…)` |
| L44 | `with-config(E) { body… }` | `(with-config E body…)` — `E` is any expression, typically a map literal `{:k -> v}` |
| L45 | `config(K)`; `config(K, D)` | `(config K)`; `(config K D)` — computed keys legal, LAW 33 |
| L46 | `assert(C)`; `assert(C, M)` | `(assert C)`; `(assert C M)` — the shared desugar to `if`+`error`, with `at file:line` baked into the message (§B.4) |

Capability values need no rows of their own: `current-capabilities()`,
`cap-restrict(c, scope, :ro)`, `cap-compose(a, b)`, `cap-none()`,
`capability?(c)` are ordinary calls (L19), as are every other primitive
(`slurp`, `blob`, `blob-get`, `unseal`, `probe`, `register-probe`,
`register-domain`, `fenced`, `argv`, `env-get`, `file-exists?`, `dir?`,
`hash-string`, `hash-value`, `gensym`, …).

**Cells** (world-reads get visual identity; string-literal argument only —
a computed path uses the call form, e.g. `slurp(path(f))`)

| # | Brace form | Reads as |
|---|---|---|
| L47 | `file:"P"` | `(slurp "P")` — a `file:` (or, under a `secret:` grant, `sealed:`) observation |
| L48 | `env:"N"` | `(env-get "N")` — an `env:` observation |
| L49 | `tree:"R"` | `(perform tree-observe "R")` — a `tree:` observation |
| L50 | *(no literal for `stat:`/`probe:`/`argv:` cells)* `file-exists?("p")`, `dir?("p")`, `probe("n")`, `argv()` | the same calls — they observe predicates/registered probes, not path contents, so call form is the honest spelling |

The M7 sketch's `glob:"src/*.c"` is **not frozen**: no glob-observing form
exists in core (the manifest read that exists is `tree-observe`, L49), and
minting one is new semantics — out of S0's scope by the same grammar-creep
rule as `needs proc`.

**Modules, loading, islands**

| # | Brace form | Reads as |
|---|---|---|
| L51 | `module { forms… }` | `(module forms…)` |
| L52 | `import(E)` | `(import E)` |
| L53 | `load("P")` | `(load "P")` — literal string required, as in sexprs |
| L54 | `load-module("P")` | `(load-module "P")` |
| L55 | `island("URI")`; `island("URI", "PIN")` | `(island "URI" "PIN")` — braces spell URIs as strings; the sexpr reader's bare-symbol (`file:./lib`) and `<…>` island-literal lexes produce the same `EIsland`, so hashes agree. An unpinned island remains the LAW-24 hard error |

**The quote bridge** (homoiconicity at the AST layer: these yield/consume
s-expression *data*, in both surfaces)

| # | Brace form | Reads as |
|---|---|---|
| L56 | `quote { F }` | `'F′` ≡ `(quote F′)`, where `F′` is `F`'s lowering — one form only |
| L57 | `quasiquote { F }` | `` `F′ `` — quasiquote-mode read of the lowered form |
| L58 | `unquote(E)` — legal only inside `quasiquote{}` | `,E` |
| L59 | `splice(E)` — legal only inside `quasiquote{}` | `,@E` |
| L60 | `defmacro name(p…) { s1; s2; … }` | `(defmacro (name p…) s1 s2 …)` — each body statement a separate form, producing exactly the application shape `macro.ml match_defmacro` recognizes (never an `EDo`-wrapped body) |

L56/L57 are distinct on purpose: `'x` and `` `x `` read to different ASTs
(an `EQuote` vs the quasiquote application that builds cons chains), both
occur in real code, and both must round-trip with hash equality — so the
brace surface names them separately. In quasiquote mode a brace form denotes
the s-expression *data* of its lowering (atoms quoted, lists as `cons`
chains, vectors/maps as `vector`/`hash-map` builds), exactly as the sexpr
reader's quasiquote mode denotes its literal text.

**Desired state**

| # | Brace form | Reads as |
|---|---|---|
| L61 | `reconcile { k1 -> v1, … }` | `(hash-map k1 v1 …)` — identity sugar naming the final-value map (LAW 30); the reconciler consumes the program's *final value*, so `reconcile` adds no AST and no semantics |

**Top level.** A brace file is a newline/`;`-separated statement sequence;
each statement is one top-level form, `ELocated`-wrapped exactly as
`Reader.read_string` wraps sexpr forms today.

### B.4 Location threading (`ELocated` placement)

For AST — hence hash and LAW-29 error-text — identity, the brace reader
attaches `ELocated` at exactly the sexpr reader's sites:

- every **top-level form**: `ELocated ((source, line-of-first-token), form)`;
- **`def`/`defnode`/`fn`**: the line of the token after the head locates the
  body (`ELocated (loc, body)`), the return annotation
  (`ELocated (loc, ETyped (body, ty))`), and each per-parameter check
  (`ELocated (loc, ETyped (ESymbol p, ty))` — LAW 32);
- **value defs**: `EDefValue (x, ELocated (loc, rhs))`; value `defnode`:
  `EDefValue (x, ELocated (loc, ENode rhs))`;
- **`assert`**: the location is baked into the generated *message string*
  (`… at file:line`), and a message-less `assert` renders its condition via
  `quote_to_value`/`string_of_value` — i.e. in AST (s-expression) notation
  in **both** surfaces. That string is part of the desugared expression and
  therefore of every enclosing hash: the brace reader must reuse the same
  renderer verbatim, and no later stage may re-render assert messages in
  brace notation without re-keying every node containing one.

### B.5 Law audit (M7 S0)

**Touched — reworded to be surface-neutral; zero semantic change:**

- **LAW 4** — "value defs" was defined by the sexpr shape ("`(def x v)` with
  a non-list head"); now defined as binding a bare name to an expression
  (AST `EDefValue`), with the sexpr spelling cited as the example, and the
  `defnode`-value equivalence stated at the AST (`EDefValue (x, ENode e)`).
- **LAW 12** — "every form the reader accepts" → every form *a* reader
  accepts, with quotation stated as defined against the AST so all surfaces
  share one quoted-data language.
- **LAW 29** (status) — emitting `ELocated`/definition-site wrapping
  restated as an obligation on every reader, not a property of the one
  existing reader.
- **LAW 32** (status) — per-parameter annotation checking attributed to the
  shared reader-level desugar pass downstream of any parser; sexpr
  spellings kept as examples.
- **LAW 34** (status + test) — "no location surface exists in the reader" /
  "the reader rejects any placement form" → *any* reader / *no* reader
  accepts one.

**Verified surface-neutral — unchanged:** LAWs 1–3, 5–11, 13–28, 30, 31,
33, 35–39. Their statements quantify over AST forms, values, hashes,
traces, capabilities, cells, or process behavior; s-expression text
appearing in them is example programs (which remain valid — the sexpr
surface is not deprecated by M7), not definitional dependence. LAW 24's
island clause was checked specifically: it constrains `EIsland`'s inline
pin (identity in the code hash), not any lexical spelling. LAW 22's
"`(filesystem "/" :rw)` is an unbound symbol" is the application of an
unbound name — the same error in either surface.

### B.6 Fuzzer-coverage checklist (S0 exit criterion)

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
`fenced`/domains/probes, sealed reads — are covered by rows L32–L35,
L43, L46–L50, L55, and the L19 call rule, so S1's sexpr→brace printer has a
defined spelling for every form both grammars and the real tree can
produce.

### B.7 Judgment calls frozen by this annex

Decisions the M7 sketch left open (or sketched un-implementably), recorded
because later stages implement exactly what S0 froze:

1. **`;` separates, `#` comments** — plan-mandated; flagged as the top
   migration hazard (sexpr `;` comments become `#`; sexpr `#{…}` sets have
   no brace literal, L12).
2. **Expression-position `{…}` is always a map**; sequencing is `do { … }`.
3. **`quasiquote { … }` exists alongside `quote { … }`** (L56/L57): the two
   sexpr quote forms have different ASTs and hashes, so one brace spelling
   could not cover both.
4. **`needs proc` is not frozen** (no per-kind capability projection exists
   in core); `needs` items are the three `fs.*` shorthands or ordinary
   capability expressions, and the clause lowers to `with-caps` around the
   node body (L35).
5. **`glob:` is not frozen** (no core observing form); `tree:"R"` covers the
   manifest-read case via `tree-observe` (L49).
6. **Island URIs are strings in braces** (L55); the sexpr bare-symbol and
   `<…>` lexes remain sexpr-only spellings of the same `EIsland`.
7. **`let x = E` takes no type annotation** (L22) — the sexpr value-def form
   it lowers to has no annotation slot; adding one would be new AST surface.
8. **`:` is not a name character in braces** (it is in sexprs); no existing
   binding uses one, and keywords/annotations/cell literals need it.
9. **n-ary operator applications print as calls** (`+(a, b, c)`), because
   infix is strictly binary and `(+ a b c)` ≠ `(+ (+ a b) c)` under LAW 20;
   `and`/`or` are the deliberate exception (right-associative infix
   reproduces the variadic desugar exactly — §B.2).
10. **`reconcile { … }` is identity sugar** (L61): the reconciler already
    consumes the program's final value, so the keyword names intent and
    lowers to nothing.
11. **Line/path preservation is a formatter obligation** (the annex
    preamble's corollary 2):
    node keys can embed `ELocated (file, line)` of nested `fn`/`def` forms,
    so S2/S3 must transpile line-stably and in place for the null-rebuild
    exit to be achievable.
12. **Quasiquote-template name slots take `unquote(…)`** (M7 S5). Inside
    `quasiquote { … }`, a `let`/`let*` *binding name* and a `def`'s
    *function name* may each be `unquote(E)` as well as a bare identifier —
    the two computed-name shapes real macro templates need: a gensym'd
    hygienic temporary (`let (unquote(g) = unquote(a)) { … }` lowers to the
    data `` `(let [,g ,a] …) ``) and a macro-generated definition
    (`def unquote(name)(x) { … }` → `` `(def (,name x) …) ``). Everything
    else deviation-listed at S1 stays a parse error inside `quasiquote{}`,
    deliberately: `defmacro` and `needs` templates, *named* node
    definitions (`node name { … }` / `node f(p) { … }`; the bare node
    *expression* `node { E }` is representable), computed *parameter*
    names, and type annotations (an `ETyped` is not plain quoted-symbol
    data, so representing one would need a new data convention, not a
    parser rule). **Workaround for all of these:** build the form as data
    with ordinary `list`/`cons`/`quote{}` calls — `list(quote { defnode },
    …)` etc. — exactly what macro bodies could always return; and a
    block-vs-map ambiguity inside a template is resolved the same way as
    outside quasiquote (B.7 #2): expression-position `{…}` is map data,
    sequencing must be spelled `do { … }`.

### B.8 Surface tables (generated from `src/surface_tables.ml`)

The closed surface sets — the `$KIND` observation heads, the `with { }`
clause keywords, and the `needs` grant-descriptor sugar — are one typed value
each in `src/surface_tables.ml` (MASTER-PLAN A′1). Every consumer (both
readers, the `needs` desugar, `lint`, error messages) derives from those
tables; nothing hand-copies the list. **This block is generated, not authored:**
`tests/067-surface-tables-drift.sh` regenerates it (`pp --dump-surface-tables`)
and diffs, so a table edit that isn't mirrored here is a red build (closing the
D10 doc-drift class), and no closed set is ever hand-listed in SPEC again. Do
not edit between the markers by hand.

<!-- BEGIN GENERATED surface-tables -->
#### Observation heads — `$KIND(args…)`

| head | arity | qq | lowering | meaning |
|---|---|---|---|---|
| `$file` | 1 | yes | `(slurp $1)` | $file(path) — read a file's contents (records a file: cell) |
| `$env` | 1..2 | yes | `(if (nil? (env-get $1)) $2 (env-get $1))` | $env(name[, default]) — read an environment variable (records an env: cell); the optional default is used when the variable is unset |
| `$glob` | 1 | yes | `(perform tree-observe $1)` | $glob(path) — observe a directory tree (records a tree: cell) |
| `$probe` | 1 | yes | `(probe $1)` | $probe(name) — read an observer-written volatile probe cell |
| `$secret` | 1 | yes | `(slurp $1)` | $secret(path) — read a sealed (confidential) file |

#### `with { }` clauses

| keyword | wrapper | meaning |
|---|---|---|
| `caps:` | `with-caps` | caps: C — run the body with capability set C |
| `config:` | `with-config` | config: M — run the body with ambient config map M |
| `handler NAME:` | `with-handler` | handler NAME: fn — install one effect handler (B9 will move to handlers: { :name -> fn, ... }) |

#### Grant-descriptor sugar (inside `needs`)

| descriptor | lowering | meaning |
|---|---|---|
| `fs.read` | `(cap-restrict (current-capabilities) $1 :ro)` | fs.read(p) — read-only fs grant for p |
| `fs.write` | `(cap-restrict (current-capabilities) $1 :wo)` | fs.write(p) — write-only fs grant for p |
| `fs.rw` | `(cap-restrict (current-capabilities) $1 :rw)` | fs.rw(p) — read-write fs grant for p |
<!-- END GENERATED surface-tables -->
