# pp DESIGN — why it is shaped this way

The rationale behind the [ROADMAP](ROADMAP.md): frozen principles, the unified
runtime model, the twelve resolved open questions (Q1–Q12), the honest edges,
prior art, and a worked build example. For the *semantic laws* the language must
obey see [SPEC.md](SPEC.md); for *current reality* see [STATUS.md](STATUS.md);
for the *vocabulary* see [GLOSSARY.md](GLOSSARY.md).

This document was produced by an architect pass hardened against an adversarial
review; resolutions to that review are marked **[R#]** inline.

---

## 1. Frozen design principles

1. **`force` is the only execution primitive.** Where a computation runs is a
   scheduler decision, never language surface. No `remote-eval`. Parallelism
   and distribution are the same feature at different fan-out; scheduling is a
   swappable, **result-transparent** effect handler (see Q7); cluster
   membership is ambient config/capability, not per-expression.
2. **Laziness is demand-pruning at node granularity; node application is
   strict.** *(See Q1.)* The persistent, memoized, content-addressed property
   attaches to *graph nodes*; a node's body is call-by-value with memoization; a
   `perform` fires eagerly in program order within `do`. The DAG is not
   "emergent from per-expression laziness" — it is the demand-pruned subset of
   the wanted-set defined by the root desired-state formula (Bazel-shaped).
   `delay` remains for *ephemeral* in-memory laziness (lazy sequences); it is
   distinct from `node`.
3. **Capabilities are authority, not ordering, and are unforgeable.** A
   capability is a ceiling on what a computation *may* touch, minted only at the
   root (Q6); user code may `restrict`/`compose` but never `construct`. It is
   not linear/affine. Ordering/determinism come from principle 5.
4. **One rebuilder; two schedulers.** *(See Q7.)* A single rebuilder (verifying
   + constructive traces over one CA store, with hash cutoff) is driven by two
   schedulers: a suspending *pull* scheduler (builds, provisioning) and a
   dirty-propagating *push* scheduler (reconciliation, services). The collapse
   is at the store/rebuilder level, not the scheduler level.
5. **Program = pure function from input cells to a desired-state value for
   observable, convergent domains; runtime = single-writer reconciler.** Fenced,
   non-convergent actions are sequenced by the reconciler's intent journal and
   sit *outside* the desired-state law. User code never writes shared external
   state; domain writes go only through the reconciler. Single writer per domain
   ⟹ no write-write races, no ordering rule to enforce.
6. **Scope discipline.** Nail hermetic + incremental (then parallel, then
   distributed) *builds* first. Provisioning is a build. Reconciliation is the
   same rebuilder under the push scheduler. Orchestration is a library/island —
   never core surface.

**Fate of plain `write-file` in user code.** It dies as a domain-write path.
**Nodes may write only to sandbox-local scratch paths** (thrown away; only
output blob hashes escape); **writes to any reconciled domain go exclusively
through the reconciler.** pp remains a scripting Lisp for computation and
observation; it stops being one for uncontrolled side-effecting writes. This is
the price of principle 5 being true rather than fiction. A `--unsafe-scripting`
escape hatch may exist outside nodes for REPL ergonomics, explicitly outside
the caching/determinism guarantees.

---

## 2. The unified runtime model

### 2.1 Vocabulary

(Condensed; see [GLOSSARY.md](GLOSSARY.md) for standalone definitions.)

**Input cell (`Var`).** A stable identity naming a piece of the external world,
plus its current observed value as a content hash. Identities:
`file:<canonical-path>`, `glob:src/*.c` (a names→hashes manifest),
`tool:cc@<binary-hash>`, `toolchain:cc` (a *closure* cell — the tool binary
plus the set of system include/lib paths it reads; see Q2), `proc:web`
(an "is-running" observation). Cells are mutable only because reality is; the
observer (prober/watcher) is the only writer of a cell's value.

**Cell-id canonicalization.** A cell-id is canonicalized before hashing:
absolute real-path (symlinks resolved), NFC Unicode, no trailing slash. Done
once, in `Runtime`, so the D8 path-prefix bug class cannot reappear at the cell
layer. Two syntactically different paths naming the same inode are one cell.

**Node (the cacheable computation).** A suspended strict computation created
only at explicit boundaries: `(node e)`, `(defnode …)`, island imports. Not
`let`/argument thunks (those are strict, Q1). An island's boundary is its
*materialized content*, not its URI: the inline pin (the source tree's
canonical hash) is part of the code hash, so an island-importing node keys
on exactly the bytes it imported (D2).
- **Key** = `H(code-hash ‖ arg-value-hashes)` **[R4/Q5 unified]** — always
  argument *value* hashes. A path argument `"src/a.c"` contributes the hash of
  the *string*, not the file content. An aggregator argument (a child node's
  result) contributes that result's hash — which is why children are forced
  before the parent's key exists (call-by-value; Q1). `code-hash` resolves free
  variables to their *value* hashes. Capabilities and the handler stack are
  **not** in the key (Q6, Q7).
- **Validity** is separate from identity: a cached result is valid iff every
  entry in one of its stored traces still matches.

**Trace.** Recorded during evaluation: the `(cell-id, observed-hash)` pairs the
node read, the keys of child nodes it forced, its result hash, and a
`{ok|failed}` outcome. Constructive + verifying, in Build-Systems-à-la-Carte
terms.
- **Trace store keyed key → SET of traces** **[R9]**, not a single trace (the
  Nix CA-realisations model). One node can have been validly built under
  different observed toolchains/platforms; a hit succeeds if *any* stored trace
  verifies.
- **Failure caching** **[R9]**: a `failed` outcome is a stored trace (result =
  the error value's hash). A null rebuild with unchanged inputs re-serves the
  failure without re-running. Failures are re-forceable exactly when an input
  cell in their trace changes (the error-memoization law, fixing D16).

**Cutoff.** After recompute, if the result hash equals a prior result hash,
dependents are not dirtied. Content-addressing makes cutoff free and exact.

**Desired-state value.** An ordinary pp value the root returns: build →
`{output-path → blob-hash}`; services → `{proc-name → spec}`. Pure, hashable,
diffable.

**Reconciler.** The single privileged writer for a *domain* (an output subtree,
a process set, a DB schema). Observes the domain as cells, diffs desired vs
observed, applies the minimal change, verifies after write.

**Domain stratification [R10i].** Nodes that feed a domain's desired-state value
**may not read that domain's own cells** — otherwise
reconcile→cell-change→dirty→re-force→reconcile loops forever. Read/write strata
are declared per domain and checked.

**Two kinds of mutation, neither shared-mutable-state:** thunk-local scratch
(sandboxed per node, discarded, only output blob hash escapes — Nix/Bazel); and
shared/external (cells in, desired value out, reconciler applies — React/k8s).

### 2.2 The rebuilder (shared) and the two schedulers

```
force(key):                                    # THE REBUILDER (one impl)
  for trace in trace_store[key]:               # key → SET of traces
    if every (cell,hash) in trace matches current observation
       and caller's cap set permits the trace's TRANSITIVE read closure (Q6):
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

`build   = pull.force(root); reconcile(domain, desired=root.value)` — once.
`service = loop { watcher updates a cell; push.stabilize(dirty); reconcile(...) }` — forever.

### 2.3 The two axes

- **Authority ceiling (may touch):** the capability set — unforgeable, minted at
  root, checked at every `perform`, captured at node creation, checked again at
  hit time against the trace's transitive read closure (Q6).
- **Actual dependencies (did touch):** the trace set. Keys and cutoff live here,
  never on capability scope or handler identity.

---

## 3. Open questions Q1–Q12: decisions

### Q1 — Strictness. **Node application is call-by-value + memoization. Persistent `node` ≠ ephemeral `delay`. Fexprs are cut; `node`/`defnode` are reader special forms; quasiquote/`quote_to_value` are made total.** [R4]

Because an aggregator's key is `H(code, child-result-hashes)`, its children must
be forced before its key exists. Node application is therefore
**call-by-value with memoization**, not call-by-need. The old slogan "every
expression is a thunk; the DAG emerges from laziness" is **retired**. What
survives as "laziness" is (a) skip-on-hit (don't recompute cached nodes) and
(b) demand-pruning: only nodes reachable from the root desired-state formula are
built. The wanted-set is defined Bazel-style by the root.

*Why.* Fine-grained call-by-need gave this codebase a stack-overflow class (D4),
an argument-thunk allocation storm, an unsound cache key (D6), and effect-escape
hazards (D9) — for zero build-relevant benefit.

*Two distinct constructs.*
- **`node`/`defnode`** — persistent, cacheable graph node; keyed and stored.
  Reader special forms: `defnode` desugars like `def` but marks the binding a
  node constructor; `node` like `delay` but routed to the store.
- **`delay`/`force`** — ephemeral in-memory thunk, **never persisted**, for lazy
  sequences. Keeps micro-entries out of the store.

*Fexprs' fate: cut.* `def-fexpr` is removed. It was thin (thunks, not syntax;
D10) and its only mechanism (argument thunking) vanishes under CBV. The
metaprogramming need is served by making the reader's quote path total
(`quote_to_value` handles all forms; quasiquote; a future `defmacro`) — a
cleaner homoiconicity story than operatives-over-thunks.

### Q2 — Observed-read tracking. **Sound-but-coarse by default (whole mounted-cell tree hash); refined per-tool by depfile/toolchain-closure adapters.** [R6]

Sandbox v1 (temp dir + hardlinked read-only inputs) **cannot fail-close
absolute paths** — cc reads `/usr/include/*` regardless. So the sandbox is not
the soundness mechanism.

*The soundness rule.* A node's trace defaults to the **content hash of every
mounted cell boundary it was granted** — the whole `src/` tree hash and the
`toolchain:cc` closure cell. Sound (any change invalidates) but coarse
(non-incremental). Per-tool adapters then **refine**: `cc -MD` reports the exact
headers read; the adapter converts those into precise cells, shrinking the trace
below the coarse ceiling. No adapter ⇒ coarse-but-sound. Sound-but-coarse beats
precise-but-unsound.

*The `toolchain:cc` closure cell.* System headers/libs are staleness holes,
modeled as one closure cell whose hash covers the tool binary plus the resolved
system paths it reads. Different machines observe different toolchain cells →
different traces in the key's trace SET (R9).

*Resolution (implemented).* The floor and the refinement are live: plain
`run` records `tool:<binary>` + one `tree:<root>` per fs-read grant; `run-dep`
parses the tool's Makefile-style depfile and records precise `file:` cells for
granted deps and `tool:<path>` cells for out-of-grant (system) deps, with no
tree cells (`tests/022`). The aggregate `toolchain:cc` closure cell is
**superseded** where depfiles exist — per-file `tool:` cells cover exactly the
system paths the tool resolved, more precisely than one closure hash — and for
depfile-less tools the binary's `tool:` cell covers upgrades while system-path
reads beyond granted trees remain the documented hole a closure cell could not
have closed anyway (its "resolved system paths" are unknowable without the
tool's own report).

### Q3 — At-most-once effects. **Fenced effects live only in the reconciler, never in node bodies. Epoch = per-reconcile-pass, with a WAL and unknown-status policy.** [R10ii]

*Convergent* effects (write file, ensure process) are safely re-appliable —
these are what nodes may do (in sandbox) and what the reconciler applies.
*Fenced* effects (send email, charge card) are not convergent and **may not
appear in node bodies at all**; the `(fenced KIND SPEC-MAP)` primitive raises
an error if called inside a node.  The scripting tier registers fenced
actions in `Runtime.fenced_actions`; the reconciler/supervisor drains them
once per pass, after all convergent work.  The idempotency epoch is the
reconcile pass: at-most-once **per pass**.  WAL:
`intent fenced KEY EPOCH KIND SPEC-HASH` → perform →
`done fenced KEY RESULT-HASH`.  The spec value is persisted by content hash
at `~/.pp/store/fenced-specs/<spec-hash>` so recovery can re-run an unknown-
status action with the same inputs.  Replay: `done` ⇒ skip; `intent` without
`done` ⇒ status **unknown** → policy (`retry | abort | ask`), never silent
retry.  On recovery the epoch from the unknown intent is reused for the
resumed pass, so a re-registered identical action deduplicates and is not
silently doubled.

### Q4 — Reconciler crash-safety. **Journaled apply over the CAS; convergence driven by re-observed reality, not a trusted state file.**

Terraform's pain is a state file drifting from reality; pp sidesteps it because
desired is cheap to recompute (cache) and observed is re-derived from cells.
Steps: (1) diff plan is a pure value (hashable → plans cache); (2) append
`(desired-root-hash, plan)` to the journal; (3) apply — file materialization via
temp + `rename(2)`, process ops convergent, fenced via Q3; (4) verify-after-
write; (5) mark complete. Restart resolves fenced unknowns per policy and reruns
stabilize+reconcile.

### Q5 — Cutoff × generative graphs. **Dynamic deps native; key-vs-validity makes generators cheap; keying unified with Q8.** [R10iv]

Editing one file changes that file's cell, invalidating exactly the one
`compile` whose trace mentions it; the generator re-runs only when the
*manifest* (names) changes, and then emits the same child keys for unchanged
files — each an O(1) trace-check hit. Node key uses argument *value* hashes
uniformly (a path string's value happens to be a name). Cycles are runtime
errors reporting the force-path.

### Q6 — Capability model: **unforgeable, root-minted, pure ceiling; hit-time check is transitive.** [R1, R3]

*Authority bootstrap.* Capabilities enter **only at the root**. `main` receives
a *powerbox* from the CLI (`--grant fs:src:ro`, `--grant net:tcp`, …). This is
the sole mint. **User code cannot construct capabilities**:
`filesystem`/`network`/`process` are removed as constructor builtins (D18); what
remains is `cap-restrict`/`cap-compose`, which only narrow or union what the
code already holds. Capability values are sealed, unforgeable tokens.

*In-language attenuation (M3, docs/PLAN-m3-attenuation.md).*
`(current-capabilities)` observes the ambient ceiling as of the call (never a
mint — it reifies exactly what every `perform` already checks against);
`cap-restrict` gained an optional mode argument that only ever narrows
(requesting a mode wider than the underlying capability holds at that scope is
`Capability_error`); `(with-caps cap-expr body)` REPLACES the ambient with a
held, ⊆-checked value for `body`'s extent — checked against the CURRENT
ambient, so a narrowing composes even when some other binding lexically
retains a broader value. The prior `effect` capability-union form (rule `caps
@ ambient`) is REMOVED: the instant capability values exist, unioning with
ambient is a widening backdoor, so it could not be kept alongside `with-caps`.
This is the enabling dependency M4d needs (a domain's write capability must be
narrowable to exactly one function and ungrantable to node code) and is what
makes node-captured capabilities (Q11, below) a real, testable mechanism
instead of vacuously-true prose.

*Interpreter-level loads are runtime authority.* `load`/`import`/`island`/module
resolution run with the interpreter's own authority (bounded to source roots +
store), **outside** user capability accounting. They are the loader, not user
effects. Island *fetching* (`--fetch-islands`/`--update`) is the same runtime
authority extended to procurement — distinct from user `net`/`process` caps,
opt-in per invocation, never ambient (docs/THREAT-MODEL-islands.md).

*Hit-time check is TRANSITIVE [R3].* A node `PUB = f(SECRET)` where `SECRET`
reads `/etc/passwd` has, in `PUB`'s own trace, only the child key. A
direct-cell-only check would let a narrow-cap caller hit `PUB` and learn a broad
read happened. So the hit check must cover the **transitive read closure**: the
union of cells across `PUB`'s trace and, recursively, every child's. A hit is
granted only if the caller's caps permit every cell in that closure. **Now live**
in the tree-walker: reads propagate to enclosing nodes so `tr_reads` *is* the
transitive closure, and `Store.hit ~authorized` refuses to serve a trace the
caller cannot fully read (SPEC LAW 23b, `tests/013`). A capability denial raises
a distinct `Capability_error` and is not memoized (LAW 15). Not yet done: the
`closure-read-set-hash`/`closure-cap-req` fast path (the check is O(closure
size)), and capability-filtered `pp why`.
- **Cost:** O(closure size), not O(1). Mitigation: memoize a
  `closure-read-set-hash` and `closure-cap-requirement` per stored trace.
- **Runtime-vs-traced reads:** loader reads are tagged `runtime` and excluded
  from the caller's requirement; only user-capability reads count.
- **Store-existence oracle:** `pp why` and any hit/miss surface are
  capability-filtered from day one.

### Q7 — One rebuilder, two schedulers. **Drop "re-force from root."** [R7]

Root-re-force is O(reachable trace-checks) per tick — exactly the cost the
reactive gear exists to avoid. Resolution: **one rebuilder** (verifying +
constructive traces + CA cutoff over one store) driven by **two schedulers** — a
suspending pull scheduler (builds) and a dirty-propagating push scheduler
(services, using the reverse-edge index). The **store-level collapse is the
keepable claim**; the scheduler-level "same traversal" claim is dropped as
overclaim. Adapton's from-scratch-consistency is a *spec to test against*.

### Q8 — Phase-1 keystone: persistent store wired into force.

- **Store** `~/.pp/store/`: `objects/<hash>` (result values + file blobs);
  `traces/<node-key>` → **SET** of `{result-hash, [(cell-id,hash,origin)],
  [child-keys], outcome, closure-read-set-hash, closure-cap-req}` (R9);
  `journal` (Q4). Concurrency: exclusive temp + rename; hash-named objects
  immutable ⇒ races benign. **Now wired into the tree-walker's `force`** for
  `(node e)` thunks: objects are content-addressed by result hash and each key
  maps to a SET of verifying traces. The live traces are a subset of the target
  schema — `{outcome, result-hash, [(cell-id, observed-hash)]}` for file cells —
  with `child-keys`, `origin`, `closure-read-set-hash`, and `closure-cap-req`
  still to come. **Both backends are wired** (D7 closed): the VM compiles
  `(node e)` to a `MAKE_NODE` opcode carrying the body AST + free-var descriptors
  and forces it through the same store, computing a byte-identical key for
  data-valued free vars so the two backends share entries.
- **Keying** per §2.1: `H(code-hash ‖ arg-value-hashes)`; code-hash resolves
  free vars to value hashes. **Now live** for `(node e)`: the persistent key is
  `H(code-structure ‖ free-var value-hashes)` (`node_key_of` + `free_vars`),
  with the whole-env hash and the capability set excluded — closing the two
  leaks this keystone names (unrelated-global rebind, grant widening; SPEC
  LAW 20, `tests/011`). Residuals: config and the handler stack are still folded
  in conservatively (their trace-cell treatment is the D17/LAW 26 policy below
  and LAW 33); binding-order is not yet canonicalized (LAW 3).
- **Caps and handlers are NOT in the key.** Caps: hit-time transitive check
  (Q6). Handlers: the D17 policy below.
- **D17 policy (handlers × caching) [R2].** Two handler classes:
  1. **Result-transparent handlers** (schedule/placement): may not change
     observable results, only where/when work runs. Absent from keys/traces.
     Ships with a `--check` that runs a node under two schedule handlers and
     asserts identical result hashes.
  2. **Semantic handlers** (mock `read-file`, fault injection, alternate `run`):
     an intercepted `perform` records a **synthetic cell**
     `handler:<handler-code-hash>:<effect-name>:<arg-hash>` → `result-hash` into
     the trace. Swapping mock↔real changes the handler code hash → different
     synthetic cell → invalidation. Strictly better than putting the whole
     handler stack in the key (only intercepted effects that actually ran enter
     the trace).

  *(The in-memory D17 fix already shipped — the handler stack is folded into the
  thunk key today, see [STATUS.md](STATUS.md). The policy above is the Phase-1
  trace-layer refinement that supersedes it.)*
- **`.ppc` bytecode disk cache is CUT.** The value/trace store replaces it;
  bytecode stays purely in-memory as the VM's execution form. (The VM caches
  node *results* in the store, never its bytecode.)
- **Introspection:** `pp why <key>` (capability-filtered). `pp graph` deferred
  to Phase 2 (needs the reverse index).

### Q9 — Distribution. **Scheduler-as-handler over a process pool; cluster deferred.**

Phase 3 ships **process-pool parallelism only** — the `parallel`/`race`
schedule handler over local worker *processes* (not OCaml 5 domains: the
interpreter is saturated with global mutable state; processes give isolation
and match the sandbox model). Cluster forcing, by-hash object sync, and
signed capability tokens move to **Phase 4 / stretch**, gated behind a
written threat-model doc.

**Delivered (M1): fork-at-dispatch, not a persistent worker pool.** A
dispatch point (`Primitives.force_deep`'s collect pass over a batch built by
the new non-forcing `map` primitive, or a singleton `force_node`/`vm_force`
Miss under `Race n`) holds a batch of `(key, run)` jobs; `Scheduler
.dispatch_batch` (`src/scheduler.ml`) forks each up to the policy's
concurrency, the child runs `Evaluator.run_node_body` — the SAME function
the serial Miss arm calls, so there is no second "evaluate in a worker" code
path — and exits 0/1; the parent reaps and falls through to `Store.hit`,
never reading a value from a child. This resolves Wall B (below) in fork's
favor over a persistent pool: `fork()` inherits ALL ambient state (the
`handler_stack`'s live OCaml closures, `current_capabilities`,
`config_stack`, `thunk_store`) byte-identically via copy-on-write, for free,
at the one moment that state is already correct. A persistent pipe-fed pool
or a fresh `pp` process targeting one node key would both need to MARSHAL
that state across a channel that exists independently of any one
dispatch — impossible for handler closures under the store's own non-data
law, and buying nothing over a cheap `fork()` given that a node body never
reaches back into the parent's live state once it starts running. The
`Runtime` global-mutable-state refactor MASTERPLAN M1 originally named as
"the real deliverable" is consequently NOT required to reach M1's exit
(MASTERPLAN.md's M1 is amended accordingly) — but the state a REMOTE
transport (M5, named/registrable handlers replacing closures) would need to
marshal is the same inventory just enumerated, so M1 documents it instead of
threading a `Runtime.t` against a fork-shaped worker that could never
validate the refactor anyway.

### Q10 — Backend strategy. **Keep both; oracle is strictest; differential-test in CI; soften the parity rule.**

`--diff` is the cheapest correctness asset. The parity rule softens from "no
feature in one backend" to **"no *shipped* feature in one backend"** —
in-flight divergence during a migration is allowed; a release with it is not.
A cache hit does not replay ephemeral effects (log/stdout).

### Q11 — Effect ordering: **sufficient, with snapshot-as-CAS-ingest and node-captured caps.** [R8]

Residual races: (1) **torn reads** — the first observation of a cell ingests its
bytes into the CAS and pins `(cell → CAS-hash)`; nodes read only the CAS copy.
*Implemented* (`Store.read_file_cell`, `tests/021`), one step stronger than
specified: the pin serves EVERY tier, not just nodes — one run is one world
snapshot — because the in-memory CA dedup already memoizes identical read
exprs, so tier-split freshness was incoherent; pp's own `write-file` advances
the snapshot for that cell (unpin).
(2) **external writers to a reconciled domain** — verify-after-write +
converge-next-pass; single ownership. *Implemented* (`tests/018`).
(3) **hidden writes in user handlers** —
domain write caps are ungrantable to node code. (4) **laziness escape** — killed
by Q1 strictness plus capturing the capability set at node creation.
*Capture is now real (M3, docs/PLAN-m3-attenuation.md), not vacuous:* with
`(with-caps cap-expr body)` landed, the ambient CAN change mid-process, so
"captured at creation" and "ambient at force" are now genuinely distinct and
testable. `thunk.node_caps` is populated from `current_capabilities` at each
`(node e)` occurrence's creation (both backends' construction sites); `force_node`
uses the forcing thunk's `node_caps` — not live `current_capabilities` — for
both the hit gate and the miss recompute's ambient. The differential test this
makes possible for the first time: a node created under a narrowed `with-caps`
extent is still denied when forced later under the full grant, and a node
created under the full ambient still succeeds when forced inside a narrower
`with-caps` — capture wins in both directions, exactly mirroring how every
other value kind is captured by a closure at definition time, not read fresh
at call time (`tests/040-caps-attenuation.sh`). Absent `with-caps`, capture
still collapses to the pre-M3 per-process `--grant` set (nothing else can move
the ambient), so `tests/011`/`013`/`017` hold byte-for-byte. The node
boundary is symmetric (LAW 20): a node's free variable containing a
capability is banned at the key (`Hasher.contains_capability`, structural,
closure-env/frame-aware, never forcing an unforced thunk), and a node's
RESULT containing one is banned before it can be stored — both layers are
independent of the capture mechanism above them (they hold even where
`with-caps` is never used) and are the hygiene atop it; the use-time ⊆ checks
(`with-caps`'s gate, the hit gate) remain the actual security floor for the
one documented gap — a capability hidden behind an unforced thunk, invisible
to the free-var ban without violating LAW 14.

**Q11-bis (Phase 3 / M1 narrowing — Wall C, docs/PLAN-phase3-parallel.md).**
`Store.run_pins` is in-memory, per-process. A forked worker inherits the
pin table as of the fork instant via COW, but any cell it observes for the
FIRST time after that pins independently in its own copy — so N workers
racing or batch-computing under `parallel`/`race` are no longer
guaranteed to agree on a cell neither of them had pinned before dispatch.
One parallel run is therefore **"at most N world snapshots agreeing on
everything pinned before dispatch,"** not Q11's stronger single-process "one
run, one world snapshot." This is still sound under R9: a divergent
observed world across workers is a legitimate distinct trace (the store
already models "the same code validly built under different observed
worlds" as one key with a trace SET), so the worst case is a spurious
recompute somewhere, never a wrong hit served across two workers'
inconsistent worldviews. Closing the gap — a pre-dispatch snapshot barrier,
or moving pins into the store itself so workers share one table — is out of
M1's scope; it is M5 design work (the same milestone that would need the
`Runtime.t` refactor for a remote transport, and for the same underlying
reason: today's pin table, like the rest of ambient state, rides fork's COW
for free, which is exactly what a barrier or a shared table would need to
stop assuming).

### Q12 — Self-hosting: **cut now.** `pc.pp` is unrunnable on three independent counts (D14); deleted. The thesis-proving dogfood is Phase 1's exit: `pp` builds `pp` via a real `build.pp`. Self-hosting the compiler is a Phase 4+ curiosity.

---

## 4. Honest edges — each with mitigation

- **E1 Fenced effects don't converge.** Sequenced, not tamed. Mitigation: Q3
  (reconciler-only, per-pass epoch, WAL, unknown-status policy). Residual:
  `:ask` reintroduces a human — acceptable; silent double-send is not.
- **E2 The reconciler is a single privileged actor.** Holds the write authority
  the rest of the system eliminates. Mitigation: Q4 (journal, atomic
  materialization, verify-after-write, reality-driven convergence); its code is
  small, the only code with domain write caps.
- **E3 Dynamic discovery ⇒ no static "what will this touch."** Mitigation: the
  capability ceiling (static, sound) + last run's traces. Cycles are runtime
  errors with force-path reporting. Explicit trade vs Bazel's analyzability.
- **E4 Nondeterministic tools.** `__DATE__`, timestamp linkers, ASLR.
  Mitigation: per-tool canonicalization adapters; `--check` double-builds and
  flags **volatile** nodes. A volatile result is treated as a **cell** (observed
  per pass) rather than a node result, so its instability is contained at one
  edge instead of poisoning its whole ancestor cone.
- **E5 Strictness break.** Q1 changes observable semantics of lazy idioms.
  Mitigation: done at zero users (Phase 0); `delay`/`lazy-seq` retained;
  documented in SPEC.
- **E6 Zero-dependency story ends.** Hashing, sandboxing, watchers. Posture:
  dune/opam (done); accept first-party-quality opam deps; keep the *interpreter
  core* dep-light so the oracle stays auditable; isolate deps behind `Runtime`.
- **E7 Cache as authority/existence oracle.** Mitigation: transitive hit-time
  cap check (Q6) + capability-filtered `pp why`. Residual: hash-guessing side
  channels — out of scope until multi-tenant caches (Phase 4).
- **E8 High-churn cells thrash the push scheduler.** Mitigation: cell-design
  discipline, watcher debouncing, cutoff absorbing no-op observations.
- **E9 Coarse-cell fallback is non-incremental.** Until a tool has a depfile
  adapter, its nodes invalidate on any mounted-tree change. Mitigation: sound by
  default, precision added adapter-by-adapter; `pp why` shows coarse vs refined.

---

## 5. Prior art — pp against its neighbors

- **Unison** — content-addressed *definitions* + abilities + distributed
  runtime. Closest relative. pp hashes *computations and world observations*
  (the store holds traces of runs), which is why incremental builds and
  reconciliation fall out. pp is build-framed, dynamically typed, demand-pruned;
  Unison is general-app, statically typed, strict.
- **Build Systems à la Carte** (Mokhov/Mitchell/Peyton Jones) — **the
  load-bearing framing.** pp is one **rebuilder** (verifying + constructive
  traces, CA cutoff, one store) with **two schedulers** (suspending pull /
  dirty-propagating push). Exactly the vocabulary that resolves Q7.
- **Nix / CA-derivations** — shared CAS + hermeticity. pp has no
  eval/derivation phase split (the "derivation" *is* the node, discovered by
  running), native early cutoff, and dynamic dependencies where Nix's language
  is build-time-only. pp adopts Nix's realisations = key→trace-SET (R9).
- **Bazel (+ remote cache/exec)** — declared static action graph; strong
  analysis, weak dynamism. pp trades static analyzability for discovered
  dependencies and a general language, keeping Bazel's sandbox trick as a
  *precision* layer over a soundness floor.
- **Incremental / Bonsai** — reactive donor: `Var`s, discovered deps,
  stabilize, cutoff. pp is "a persistent Incremental whose cutoff is hash
  equality and whose Vars are the outside world," adding cross-process
  persistence.
- **Adapton / self-adjusting computation** — the theory behind Q7's push-
  scheduler correctness (from-scratch consistency), used as a spec to test
  against.
- **Salsa / Skyframe / Shake** — engineering proof points: red-green cutoff,
  graph-per-key invalidation at scale, monadic dynamic deps in production.
- **Terraform / Kubernetes** — the reconciler's lineage. pp differs by deriving
  desired state from a cached incremental computation and refusing to trust a
  state file (Q4).

---

## Appendix A — The two-file C build, traced through the model

`a.c`, `b.c`, both `#include "shared.h"`. Build, then rebuild after editing
`shared.h`, then after editing only `a.c`.

### Program (Phase-1 surface sketch, M3 attenuation notation)
```clojure
(defnode (compile src)                    ; key = H(compile-code, hash "src/a.c")
  (with-caps (cap-compose (cap-restrict (current-capabilities) "src" :ro)
                          (cap-restrict (current-capabilities) "toolchain" :ro))
    (perform run "cc" ["-c" src "-o" (scratch ".o")] :inputs [src])))
                                          ; sandbox + depfile refine the trace
(defnode (link objs)                      ; key = H(link-code, [child result hashes])
  (with-caps (cap-restrict (current-capabilities) "toolchain" :ro)
    (perform run "cc" (concat ["-o" (scratch "app")] objs) :inputs objs)))
(defnode (app)
  (let [srcs (perform list-dir "src" "*.c")]   ; observes glob:src/*.c
    (link (map compile srcs))))
{"build/a.o" (compile "src/a.c")
 "build/b.o" (compile "src/b.c")
 "build/app" (app)}                       ; desired-state root: {path → blob-hash}
```
The fs and toolchain grants arrive via `--grant` into the ambient set; user
code only OBSERVES it (`current-capabilities`) and NARROWS it
(`cap-restrict`/`with-caps`, M3) — it never constructs authority (Q6). Each
`with-caps` here replaces the ambient for exactly the node body's extent, so
`compile`'s narrowing to `src`+`toolchain` is what the node body actually runs
under — not just a comment — and (per node capture, Q11) is fixed at THIS
`(node e)` occurrence's creation, not re-derived from whatever is ambient
wherever the node is later forced. Children are forced before `link`'s key
exists — call-by-value (Q1).

### Cells & first (cold) build
Input cells: `file:.../src/a.c`=h_a, `file:.../src/b.c`=h_b,
`file:.../src/shared.h`=h_s, `glob:src/*.c`=h_m (header edits do **not** dirty
it), `toolchain:cc`=h_cc.

`pull.force(root)` → `app` → `list-dir` records `(glob:src/*.c, h_m)` →
`compile("src/a.c")`: first observation of each input **ingests bytes into the
CAS** (Q11); sandbox mounts the CAS copies read-only; cc runs; depfile refines
the trace below the coarse ceiling. Stored (into the key's trace SET):
```
K_ca = H(compile-code, H "src/a.c") →
  { result: h_ao,
    reads:  {file:src/a.c=h_a (user), file:src/shared.h=h_s (user),
             toolchain:cc=h_cc (toolchain-closure)},
    outcome: ok, closure-cap-req: {read src/, toolchain} }
```
Both axes are visible: the capability *ceiling* said "may read src/ + toolchain";
the trace says "did read a.c, shared.h, cc-closure." `K_link = H(link-code,
[h_ao, h_bo])` — arguments are child *result* hashes. Reconciler observes
`tree:build/`=∅ (a downstream observation, not a node input), materializes 3
blobs (temp+rename), verifies, journals complete. Null rebuild: every trace
verifies → zero processes.

### Rebuild 2 — edit `shared.h` (h_s→h_s′)
Pull (`--once`) or push (`--watch`) — same rebuilder (Q7). `K_ca`/`K_cb` traces
contain `file:src/shared.h=h_s` ⇒ stale ⇒ recompile → h_ao′, h_bo′. `K_link`
re-keys on `[h_ao′,h_bo′]` ⇒ link runs. The glob manifest is unchanged, so no
spurious graph re-expansion.

**2b — comment-only header edit.** h_s′≠h_s ⇒ both compiles re-run. cc emits
byte-identical objects ⇒ h_ao unchanged ⇒ **cutoff**: `K_link`'s argument hashes
unchanged ⇒ trace verifies ⇒ link never runs; desired-value hash unchanged ⇒
reconciler diff=∅. Cutoff at both graph and reconciler level.

### Rebuild 3 — edit only `a.c`
`K_ca` stale → recompile. `K_cb`'s trace verifies — **b.o not recompiled.**
`K_link` re-keys → runs. Reconciler writes exactly `build/a.o` and `build/app`.
If the edit adds `#include "extra.h"`, the depfile-refined trace simply gains
`file:src/extra.h` — dynamic discovery, no declaration step.

### Leaks found and fixed by the trace
1. **Identity vs validity.** The current keying `hash(expr, full-env, caps,
   config)` leaks: any stdlib/unrelated-binding change rebuilds the world; a
   widened cap rebuilds the world. Fix: key=(code, arg-value-hashes);
   validity=trace SET. The single most important divergence from current code.
2. **Caps out of the key, into a transitive hit-time check** (Q6/R3).
3. **Caps captured at node creation**, not read from the dynamic stack at force
   time — a watcher forces nodes far from any lexical `effect` block (Q11).
4. **Snapshot = CAS ingest** — makes torn reads impossible (Q11/R8).
5. **Cell boundaries are program API** — the glob had to be `*.c`-scoped for the
   header edit not to dirty the generator.
6. **Link keying implies strict child forcing** — forced the CBV admission (Q1).
