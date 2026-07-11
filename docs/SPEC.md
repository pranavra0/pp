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
forms exist, and `(node e)` is a real persistence boundary: the tree-walker
routes it through `~/.pp/store` with verifying traces, so a node caches across
runs while a scripting-tier expression does not (D1). Both backends share the store (D7 closed). Still missing before the split is
fully realized: `(defnode (f x) body)` is only a named closure (node
*application* is not yet keyed on arg-value-hashes — LAW 6/20), though
`(defnode x e)` now binds the node thunk of `e` (LAW 4 value defs). The node
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

In `(let [a e_a  b e_b ...] body)`, **every** binding name is in scope in
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

**Test:** `(let [y (+ x 1)  x 1] y)` ⇒ `2` in both backends; reordering the
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

**Test:** `(let [even? (fn (n) (if (= n 0) true (odd? (- n 1))))  odd? (fn (n) (if (= n 0) false (even? (- n 1))))] (even? 10))`
⇒ `true` in both backends. `(let [a b  b a] a)` ⇒ a deterministic cycle error
identically in both backends.

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
`(let [a 1 b 2] (+ a b))` and `(let [b 2 a 1] (+ a b))` are equal; a cached
result for one is a hit for the other.

### [LAW 4] One scope model everywhere: `let` = `do`-block `def`s = `module` = top level

A scope — local `let`, a `def` block, a module body, the top level of a
program — is one thing: **a set of mutually-visible DAG nodes ordered by
dependency.** Top-level `def`s already behave this way (later `def`s are
visible to earlier bodies); LAW 1 extends the same model downward so the
language has one scoping story, not three.

*Grounding.* Unification is the point: a module is just a bigger `let`; the
top level is just an implicit module. Excel does not have a different
reference model per worksheet region.

**Value defs.** `(def x v)` with a non-list head is a **value binding**: the
RHS is *evaluated when the definition executes* and `x` is bound to the
result — never a nullary closure (the Phase-1 footgun, ROADMAP maturity §1).
Evaluation does not force: `(def d (delay e))` binds the unforced thunk, and
`(defnode x e)` is exactly `(def x (node e))` — the unforced node thunk.
Scope follows LAW 4 with statement timing:

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

**Status: partial** — top-level and `do`-block `def`s are mutually recursive
in both backends (they share a mutable global scope), and value defs behave
identically in both backends including the letrec* poison error
(`tests/025-def-value.sh`, fuzzer `stmt_def_value`). Module scope is not
unified: the tree-walker's module `def`s capture the environment at
definition time (value defs do participate in the letrec* prebinding), while
the VM resolves module-body sibling references globally (D22) — the D15/D20
residue.

**Test:** a module whose first `def` calls its second behaves identically to
the same two `def`s at top level, in both backends; `load-module` without
`import` leaves the caller's scope untouched in both; `(def x 5) (print x)`
prints `5` in both backends (`tests/025`).

### [LAW 5] `let*` survives only as explicit sequential sugar

`(let* [a e1 b e2] body)` is the scripting-tier form for "I really do mean a
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

**Test:** `(let* [x 1  x (+ x 1)] x)` ⇒ `2` in both backends (shadowing,
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

**Status: partial** — `(node e)` exists and memoizes persistently under the
LAW 20 key in both backends, and `(defnode x e)` binds its node thunk; but
`(defnode (f x) body)` is still only a named closure, so node *application*
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

**Status: partial** — `(node e)` and the store exist (D1), and the reverse-edge
dirty-propagation graph now exists for push `stabilize` (`pp --watch --stabilize`,
`tests/032`). What is still missing: a formal root desired-state formula and an
explicit wanted-set, so demand-pruning remains pull-mode "re-force from root"
rather than a declared target set (Q1/Q5).

**Test:** a root demanding 1 of a manifest's 3 children executes exactly 1
child (journal/trace proves it), in both backends.

### [LAW 8] `delay`/`force` is ephemeral, in-memory laziness — a different thing from `node`

`(delay e)` makes an ephemeral thunk: computed at most once per process,
never persisted, never keyed into any store. `force` is idempotent and is the
identity on non-thunks. Lazy sequences (`lazy-seq`, stdlib `cons` chains)
live here. `node` is persistence; `delay` is timing.

*Grounding.* Conflating the two is how the store fills with micro-entries
(DESIGN R4ii). Excel's distinction: a formula cell (recalculated, tracked)
vs. a spilled intermediate nobody addresses.

**Status: partial** — the persistent/ephemeral split now exists in both
backends: `(node e)` persists to `~/.pp/store` (tree-walker via `thunk_persist`,
VM via the `MAKE_NODE` opcode) while `(delay e)` never does. Remaining wart: the
tree-walker also routes ordinary `delay`/`let` thunks through its *in-memory*
content-addressed dedup table (not the persistent store), and the VM has no
in-memory dedup at all (D7) — neither affects the persistent node cache.

**Test:** `(force (delay 42))` ⇒ `42`; `(force 42)` ⇒ `42`; a delayed
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

**Test:** `(if true 1 (undefined-symbol))` ⇒ `1` in both backends; the
untaken branch's `(perform log ...)` produces no stderr in either.

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

**Test:** `(length (map inc (range 0 1000000)))` ⇒ `1000000` in both
backends (ROADMAP Phase 0 exit 4).

### [LAW 12] Quotation is total; the language is data

Every form the reader accepts, `quote` can turn into a value, and
quasiquote/unquote work over that structure. A Lisp whose `'(if a b c)`
crashes is not homoiconic.

*Grounding.* Metaprogramming (and the `defmacro` that replaces the cut
fexprs — DESIGN Q1/R4iii) rests on code-as-data being *total*, not
best-effort.

**Status: holds** — `quote_to_value` handles all expr forms; the reader
parses quasiquote/unquote/unquote-splicing and a runtime walker expands them
(including splicing, nested quasiquote, vectors, and maps).

**Test:** `'(if a b c)` ⇒ the list `(if a b c)` in both backends;
`` `(1 ,(+ 1 1)) `` ⇒ `(1 2)` in both.

---

## 3. Effects and ordering

### [LAW 13] Effects are strict within `do` and fire in program order

Each step of `(do e1 e2 ... en)` is forced to completion, in order, before
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

**Test:** `(do (perform log "a") (perform log "b") 1)` ⇒ stderr `a` then
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

**Test:** `(let [x (perform log "never")] 1)` ⇒ `1` with empty stderr in
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

**Status: partial** — `(node e)` is opt-in and cached persistently in **both**
backends: the same node forced in two processes runs once, the store serves the
second, and a scripting-tier expression is never cached (D1, D7; `tests/010`,
`tests/014`). The "purity" half of the bargain is now partly enforced: node
writes are confined to per-node sandbox scratch and absolute node writes error
(LAW 18, `tests/017`); a tool run inside a node executes in the scratch dir.
A tool's own absolute-path writes are not fail-closed (Q2: traces, not the
sandbox, are the soundness mechanism).

**Test:** the same `(node e)` forced twice across two processes runs once
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

**Status: holds** (for the node tier, both backends) — a `(node e)` hit serves
the stored result and does **not** re-emit the `log`/stdout produced on the miss;
verified in the tree-walker (`tests/010`) and the VM (`tests/014`), where a
node's in-body `COMPUTE` log fires only on the miss.

**Test:** force a logging `(node e)` twice, second run in a fresh process:
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

**Test:** a node calling `(perform write-file "/abs/x" ...)` errors in both
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

**Status: partial** — the persistent `(node e)` key is now
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

**Test:** rebinding an unreferenced global does not change the node key; widening
the root grant does not invalidate a cached result; changing a *referenced* free
variable does (`tests/011`).

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
— it never constructs. `(filesystem "/" :rw)` is an unbound symbol, not a
value.

*Grounding.* The capability tradition's first theorem: authority you can
fabricate is not authority, it's a comment. The rant demands capabilities
*replace* Unix ambient authority; a mintable capability is ambient authority
with extra steps.

**Status: holds** — `filesystem`/`network`/`process`/etc. are unbound symbols;
only `--grant` at process startup mints capabilities. `cap-restrict` and
`cap-compose` only narrow or union capabilities the code already holds.

**Test:** the adversarial suite (`tests/capability-adversarial.sh`): no
program, through any user-code surface, reads or writes a path it was not
granted; evaluating `(filesystem "/" :rw)` is an unbound-symbol error in both
backends.

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

**Status: partial** — (a) path checks are component-aware and full-path (`/tmp`
does not grant `/tmpevil`). (b) **holds** in both backends: a hit is served only
if the caller's capabilities cover every cell in the stored trace's read closure
(`Store.hit ~authorized`), and because reads propagate to enclosing nodes the
closure is transitive — a narrow caller cannot launder a broad read through a
cached aggregator (`tests/013` tree-walker, `tests/014` VM). A capability denial
raises the distinct `Capability_error` and is deliberately **not** memoized
(authority is not identity/validity — LAW 15), so granting the capability later
still yields a hit. (c) `pp why` exists and is capability-filtered: it explains
each node's hit/miss (first build, stale cell, unauthorized, verified trace) to
stderr, and a cell the caller has no authority over is redacted rather than
named (`tests/019`). Still open: uniform realpath canonicalization of grants
and cells.

**Test:** grant `fs:/tmp:ro`: reading `/tmpevil/x` errors in both backends.
A caller scoped to `src/` gets no hit on a node whose transitive closure
touched `/etc/passwd` (ROADMAP Phase 1 exit 7).

### [LAW 24] Loader reads are runtime authority, not user effects

`load` / `import` / `island` / stdlib and module resolution are the loader's
reads, bounded to the program's source roots and the store. They run under
the interpreter's runtime authority, are tagged `runtime` in traces, and are
**excluded** from user capability accounting — both at perform time and in
the hit-time closure check.

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
authority requirement (`tests/020`). Residual: the bound is a lexical-path
policy fence, not a symlink-proof boundary (uniform realpath canonicalization
is still open, LAW 23).

**Test:** a program granted nothing can `(load ...)` beside its own source
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

**Test:** `(do (with-handler [(log h)] (tail-loop)) (perform log "x"))` — the
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

**Status: partial** — holds in both backends: a `(node e)` that raises a
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

**Status: holds** — the reader emits `ELocated` for top-level forms and
wraps `def`/`fn`/`defnode` bodies with their definition-site location, and
the shared top-level driver (both backends) appends the enclosing form's
`file:line` to any runtime error whose message does not already carry a
location — so arbitrary top-level expression errors report where they
happened, never doubled (D12 closed; `tests/027-error-messages.sh`). Parse
errors include file and line. Arity errors name the function being called
(`arity mismatch calling f: …`), capability errors name the operation
(`read-file: capability error: …`), and unbound-symbol errors are
byte-identical across backends. Uncaught errors print as one clean
`pp: error: …` line with exit code 1. Residual: an error inside a `load`ed
file reports the loading form's location, not the inner file's line.

**Test:** `(car 5)` at line 3 of `f.pp` reports `f.pp:3` in both backends,
with byte-identical stderr (`tests/027`).

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

**Status: partial** — the filesystem domain has a v1 reconciler in both
backends: `pp --reconcile ROOT prog.pp` takes the program's final value —
`{relative-path → content}` — as the domain's desired state, diffs it against
observed reality, applies atomically, deletes unmanaged files, journals,
requires an fs write grant, and refuses stratification (`tests/018`). Desired
contents may be inline strings or `blob:<sha256>` CAS references (`tests/023`).
**Watch mode is now live:** `pp --watch --reconcile ROOT prog.pp` runs the
program, reconciles, polls cells for changes, and re-runs on change
(`tests/031`). **Push stabilize is now live:** `pp --watch --stabilize
prog.pp` uses the reverse-edge index from stored traces to reset only dirty
thunks, so clean nodes skip `Store.hit` entirely; differential test
`tests/032` confirms identical re-evaluation patterns to pull mode on both
backends. Not yet: the process domain and fenced effects (LAW 31).

**Test:** first reconcile creates the tree; a null reconcile writes nothing;
manual drift and foreign files converge away; a shrunk desired map deletes
the leavers; no write grant ⇒ capability error; a self-reading desired state
⇒ stratification error (`tests/018`). ROADMAP Phase-1 exits 1–5 + 7 hold on
a 101-TU C build (`tests/024`), exit 6 via `scripts/build-self.sh`, and the
lot replicate on Lua 5.4.7 (`scripts/build-lua.sh`).

### [LAW 31] Fenced effects are reconciler-only, journaled, at-most-once per pass

Non-convergent actions (send email, charge card) may not appear in node
bodies at all — nodes are cache-replayable and must not contain irreversible
actions. The reconciler sequences fenced actions through an intent journal
(`intent(key)` → perform → `done(key, result)`), keyed
`H(reconcile-epoch, action-args)`; an `intent` without `done` after a crash
is status **unknown** and resolves by policy (`:retry | :abort | :ask`),
never by silent retry.

*Grounding.* The desired-state law covers convergent writes only; pretending
it tames non-idempotent actions is how systems double-charge cards. The
carve-out is named, not hidden (DESIGN Q3/E1).

**Status: unimplemented** (Q3/Phase 2).

**Test:** kill the reconciler between `intent` and `done`: on restart the
action is not re-performed and the unknown-status policy fires (ROADMAP
Phase 2 exit 5).

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
errors cite the annotation site. Per-parameter annotations —
`(def (f x : int) …)`, `(fn [x : int] …)` — are checked too (they used to
parse and then be discarded): the reader desugars each into a located type
check that runs ahead of the body, so both backends enforce the shared AST
identically (`tests/026-param-types.sh`, fuzzer `stmt_param_typed_def`).

**Test:** `(def (f x) : int "s")` forced ⇒ the same type error, citing the
annotation site, in both backends; `(f "oops")` against
`(def (f x : int) …)` ⇒ `type mismatch: expected int, got "oops"` citing the
definition site, byte-identical across backends; unannotated code never
type-errors.

---

## 11. Config

### [LAW 33] Config is ambient, dynamically scoped data; nested scopes shadow; keys may be computed

`(with-config {..} body)` pushes a config frame for `body`'s dynamic extent;
`(config k [default])` reads the nearest frame, falling through to the
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
`(config k)` inside a node records a `config:<k>` trace cell (absence is a
distinct observation), re-observed against the caller's config stack on a hit,
and ambient config is excluded from the node key (`tests/015`).

**Test:** `(with-config {"k" 1} (with-config {"k" 2} (config (string-append "" "k"))))`
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

**Status: holds** for the negative half (no location surface exists in the
reader — verified absence), **unimplemented** for the positive half (there is
no scheduler at all; everything runs in-process, serially).

**Test:** the reader rejects any placement form; Phase 3's exit — the same
program under the `parallel` handler produces byte-identical outputs to the
serial run.

### [LAW 35] "Run on N, take the first" is a handler, not a feature

Redundant/parallel/distributed execution policies (fan-out, racing,
work-stealing, locality) are swappable schedule handlers — library code, zero
language-surface change. Parallelism and distribution are the same feature at
different fan-out.

*Grounding.* This sentence is the rant's opening demand, restated as an
acceptance test. If shipping it requires new syntax, LAW 34 has been
violated somewhere.

**Status: unimplemented** (Q9: process-pool parallelism is Phase 3; cluster
forcing is Phase 4, gated on a threat model).

**Test:** ROADMAP Phase 3 exit: swap serial → `parallel` handler: identical
result hashes, measured speedup, no program text change.

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
`tests/014`), so `(node …)` caching is not a one-backend feature. Deep non-tail
recursion (D4) and the negative-literal reader bug (`-5` lexes as a symbol)
remain non-differential issues. Phase 0 exit 1 requires the `full` grammar to
stay green under extended CI runs.

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

**Status: unimplemented** — `random` is an ambient, uncapped builtin effect
today (D8c); the fuzzer must ban it from generation precisely because effect
logs would be incomparable.

**Test:** any node forced twice from a cold store yields the same result
hash; a program using ungated `random` inside a node is an error — both
backends.

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

**Status: partial** — the *detection* half exists in both backends:
`pp --check` runs every missed node's body twice, compares result hashes, and
flags a divergence as a volatile node, failing the run (`tests/019`). The
*containment* half (volatile result pinned as a per-pass cell so instability
stops at one edge; exclusion from shared caches) is not built.

**Test:** a node whose tool emits a random value is flagged volatile by
`--check` and the run exits nonzero; a deterministic node is not flagged
(`tests/019`). Containment (parent key stable across builds via the cell
edge) awaits the cell treatment — both backends.

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
| LAW 4 | one scope model | partial | value defs (`(def x v)`) bind values with letrec* block scope, identical in both backends (`tests/025`); modules sequential in tree-walker; VM resolves module-body sibling refs globally and leaks bare-top-level-`do` defs to globals (D22) |
| LAW 5 | `let*` sequential sugar | holds | reader emits `ELetStar`; both backends sequential; `tests/007-phase0-laws.pp` |
| LAW 6 | node CBV + memoization | partial | application is CBV (Q1); `(node e)` memoizes persistently, keyed on code + free-var value hashes (LAW 20; `tests/011`); `(defnode x e)` binds the node thunk (`tests/025`), but applied `defnode` is still a named closure, so aggregator-keyed-on-child-result-hashes doesn't yet arise |
| LAW 7 | demand-pruning at node granularity | partial | reverse-edge dirty-propagation graph exists for push `stabilize` (`pp --watch --stabilize`, `tests/032`); root desired-state formula / explicit wanted-set still absent (Q1/Q5) |
| LAW 8 | `delay` ephemeral vs `node` persistent | partial | the split exists in both backends (`node` → `~/.pp/store`; `delay` never persists); residual: tree-walker's in-memory dedup table isn't mirrored in the VM (D7), separate from the node cache |
| LAW 11 | stack-safe non-tail recursion | unimplemented | D4; fuzz `exitdiff:tw-err: Out_of_memory`, `crash:bc:timeout` |
| LAW 12 | total quotation, quasiquote | holds | D11/D19 fixed; `tests/007-phase0-laws.pp` |
| LAW 15 | ordering never from capabilities | partial | negative half holds; fs-domain reconciler v1 exists (`tests/018`), process domain absent |
| LAW 16 | opt-in per-node caching | partial | `(node e)` cached persistently across runs in both backends (D1, D7); scripting-tier exprs uncached; node writes sandbox-scratch-only (LAW 18, `tests/017`); `tests/010`, `tests/014` |
| LAW 17 | hit ≠ effect replay | holds (node tier) | a `(node e)` hit does not replay in-node `log`/stdout, both backends (`tests/010`, `tests/014`) |
| LAW 18 | sandbox-scratch writes | partial | per-node scratch sandbox real: relative node writes/reads are scratch-local, absolute node writes error, `run` cwd = scratch (`tests/017`); reconciled domains absent (Q4) |
| LAW 19 | sound content hashing | partial | SHA-256 (D5 fixed); closure-env + handler holes closed → in-memory dedup sound (D6/D17 fixed); store objects content-addressed by result hash, shared by both backends (D1, D7); tree-walker's in-memory dedup table not mirrored in the VM |
| LAW 20 | key = code ‖ arg-values | partial | persistent `(node e)` key = code + free-var value hashes; caps, whole-env, config, and handlers all excluded (`tests/011`, `tests/015`); binding-order not canonicalized (LAW 3) |
| LAW 21 | cutoff via traces | partial | validity-via-verifying-trace real (key→SET of traces, cells re-checked on hit; `tests/010`, `tests/015`); hash-equality cutoff proven at scale — comment-only header edit on a 101-TU C build and on Lua 5.4.7 recompiles dependents and cuts off the link (`tests/016`, `tests/024`, `scripts/build-lua.sh`); reverse-edge/dirty-propagation graph now used by push `stabilize` (`pp --watch --stabilize`, `tests/032`); inline-nested cutoff still absent |
| LAW 22 | unforgeable root-minted caps | holds | D18 fixed; constructors removed; `tests/capability-adversarial.sh` |
| LAW 23 | component/full-path + transitive hit check | partial | (a) component-aware paths; (b) hits gated on the caller's caps covering the trace's transitive read closure in both backends, cap denials not memoized (`tests/013`, `tests/014`); (c) capability-filtered `pp why` real (`tests/019`); uniform realpath canonicalization still open |
| LAW 24 | loader = runtime authority | holds | loader bounded to source roots + ~/.pp, reads traced as authority-exempt `runtime:file:` cells (`tests/020`); realpath canonicalization still open |
| LAW 25 | no unenforced authority surface | holds | `CapTime`/`CapMemory` removed from types and surface (D8d) |
| LAW 26 | two handler classes, synthetic trace cells | partial | semantic half real at node granularity: `handler:<effect>` trace cells in both backends, mock/real coexist without cross-contamination (`tests/015`); cells coarser than the law's per-arg form; result-transparent class awaits schedulers (Phase 2/3) |
| LAW 27 | exception/tail-safe dynamic extent | holds | D9/D16/D20 fixed; save-stack restore on every exit |
| LAW 28 | failure traces, error memoization | partial | both backends memoize `Failure` outcomes as failing traces, re-served until a recorded read changes; D16 `Evaluating`-leak fixed (`tests/012`, `tests/014`); non-`Failure` exceptions uncached |
| LAW 29 | source locations in errors | holds | D12 closed: every top-level form's location is appended to unlocated runtime errors in both backends; arity/capability errors name the callee/operation; `pp: error:` single-line reporting (`tests/027`); residual: `load`ed-file errors cite the loading form |
| LAW 30 | desired-state + single writer | partial | fs-domain reconciler v1: plan/journal/atomic-apply/verify, single-writer deletes, stratification check, blob-hash desired values (Q4, `tests/018`, `tests/023`); drives a real 101-TU C build and Lua 5.4.7 end-to-end (`tests/024`); push `stabilize` live (`pp --watch --stabilize`, `tests/032`); process domain absent |
| LAW 31 | fenced effects, intent journal | unimplemented | Q3/Phase 2 |
| LAW 32 | gradual types, strictest oracle | holds | D3 fixed; both backends enforce; tests 004/005 restored; `tests/007-phase0-laws.pp` |
| LAW 33 | config: computed keys, tail-safe scoping | holds | D15 fixed; computed keys and tail-safe scoping in both backends; config reads inside nodes are `config:<key>` trace cells, ambient config out of the node key (`tests/015`) |
| LAW 34 | no location surface / scheduler exists | partial | negative half holds; no scheduler at all |
| LAW 35 | run-on-N-take-first as handler | unimplemented | Q9 (Phase 3 process pool; Phase 4 cluster, threat-model-gated) |
| LAW 36 | backend parity | partial | catalogued divergences closed; `core` and sampled `full` green; deep non-tail recursion and negative-literal lexing remain same-side issues |
| LAW 37 | declared nondeterminism | partial | `random` builtin effect removed; no declared-nondeterminism mechanism yet |
| LAW 38 | volatile-node containment | partial | `--check` double-run audit flags volatile nodes and fails the run, both backends (`tests/019`); per-pass cell containment absent |

Laws that **hold** today, for the record: LAW 1 (mutual `let`),
LAW 5 (`let*` as sequential sugar), LAW 9 (branch pruning), LAW 10 (TCO),
LAW 12 (total quotation/quasiquote), LAW 13 (effect order in `do`),
LAW 14 (undemanded values fire no effects), LAW 22 (unforgeable caps),
LAW 25 (no unenforced authority), LAW 27 (exception/tail-safe dynamic
extent), LAW 32 (gradual types), LAW 33 (config) — each exercised by
`tests/*.pp` under `--diff` and/or the fuzzer, and each must stay green
through the Phase 1 build-engine work.
