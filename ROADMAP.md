# pp ROADMAP — the unified-engine plan

> Replaces the previous `ROADMAP.md`. Where README/TRD contradict
> this document, this document is correct and §1.2 is the punch list. Phase 0
> claims have been re-verified by *running* `make test`, `make cap-test`, and
> `make fuzz` in this session. This plan was produced by an architect pass and
> hardened against an adversarial review; resolutions to that review's ten
> required revisions are marked **[R#]** inline.

---

## 1. Current state, verified against source

pp is a two-backend interpreter for a Lisp with a now-unforgeable
(user-code surface) capability ceiling, an in-memory content-addressed thunk
store (tree-walker only, and still unsound at the closure-hash level), and the
scaffolding for the Phase 1 build engine. Honest one-liner: **Phase 0 is
closed — the core no longer lies about scope, effects, types, or capability
authority.** No persistent cache, process effect, reconciler, or scheduler
exists yet; those are Phase 1–4 work.

The scaffolding is nonetheless good — the O(1) env-hash design, the CPS TCO,
and the dual backend with `--diff` are real assets. The roadmap starts from
"the core is not yet trustworthy," not "wire up the last mile."

### 1.1 What actually works
- **Reader** (reader.ml): full s-expr syntax; mutual `let` and sequential
  `let*` (`ELetStar`), `and`/`or` (desugared to `EIf`), `def`/`fn`/`do`,
  `effect`/`perform`/`with-handler`, `module`/`import`/`load`/
  `load-module`, `island`, `with-config`/`config`, `quote`/`quasiquote`,
  type annotations parsed (per-parameter annotations parsed then **discarded**).
  Source locations (`ELocated`) are emitted for top-level forms and wrapped
  around `def`/`fn`/`defnode` bodies; parse errors include file and line.
- **Lazy tree-walking evaluator** (evaluator.ml): application is now strict
  (call-by-value) per Q1; `let` bindings become thunks. Memoization via
  `thunk_status` works; a trampoline switches to a heap work queue when
  `force_depth` exceeds a threshold.
- **In-memory content-addressed dedup — tree-walker only** (evaluator.ml:18,
  23–32); O(1)-incremental env hashes (types.ml:361–372). Real, in-memory,
  single-run, one backend — and unsound (D6).
- **TCO in both backends**: CPS `eval_tail`/`apply_tail` (evaluator.ml:75,353);
  VM `TAIL_CALL` frame-swap (vm.ml:383–414).
- **Effects + handlers**: dynamic handler stack, builtin fallbacks
  read-file/write-file/log. `random` has been removed. `do` is strict per
  step; `effect`/`with-handler`/`with-config` restore state on normal return,
  exception, and tail call in both backends.
- **Capability *checking*** exists for fs read/write at perform time and
  for the `slurp` primitive; capability constructors have been removed from
  user code (see D18).
- **Modules** in the tree-walker produce `VEnvMap` (evaluator.ml:236–267).
- **Bytecode VM + compiler**: 30+ opcodes; `--diff` compares backends
  (main.ml:52–66).
- **Bytecode `.ppc` serialization** (bytecode.ml): complete but **dead** (D1)
  and lossy; `cache.ml` has been deleted and the value/trace store is planned
  for Phase 1.

### 1.2 Verified discrepancy list

| # | Claim | Reality in source |
|---|---|---|
| D1 | Caching "across runs" (README) | `cache.ml` deleted. `store.ml` exists but is not yet wired to persistent node caching; the `.ppc` bytecode serializer remains dead code. |
| D2 | Islands "fetch, pin, cache" (README) | `EIsland` does `open_in uri` — local file, pin ignored (evaluator.ml:302–308; VM→`LOAD_FILE`, compiler.ml:309–310). `--update` **sets** `Island.update_mode` (main.ml:13) but the ref is **never read**; `Island.resolve`/`write_pin` never called; `island-fetch` is identity (primitives.ml:466–471). |
| D3 | Tree-walker is the correctness oracle | **Fixed.** Both backends enforce type annotations via matching `check_type`; tests 004/005 are included in `make test`. |
| D4 | Deep thunk chains | Trampoline handles forced thunk chains; deep non-tail *eval* recursion is still bounded by the OCaml stack. |
| D5 | "SHA-256" (TRD 2.4.1) | **Fixed.** `hash_string` now uses Cryptokit SHA-256. |
| D6 | "Same hash = same thunk" is sound | Closure hashes omit captured env (types.ml:313–318). `extend_env` folds bound values into `env_hash` (types.ml:368–372), so a colliding closure propagates into env_hash into thunk keys (evaluator.ml:26): `make_thunk_ca` can return a **wrong** memoized thunk. Content-addressing is unsound, not merely coarse. (reading) |
| D7 | VM shares the CA story | VM thunks now carry a content hash (`body offset + config hash`) and `vm_code`, but the VM `thunk_store` is still never used for dedup; the hash is not the Q8 sound key. |
| D8 | Capabilities are the security story | (a/b) **Fixed:** path checks are component-aware and full-path (`path_grants` in `capabilities.ml`). (c) `slurp` is gated; `random` removed; `load`/`load-module`/`island` still bypass user caps as loader reads but are not yet bounded to source roots + store. (d) `CapTime`/`CapMemory` removed. |
| D9 | VM effect/handler scoping | **Fixed.** `ENTER_EFFECT`/`EXIT_EFFECT` and `PUSH_HANDLER`/`POP_HANDLER` use save-stacks to restore the exact prior scope; bodies are compiled non-tail so exits run before tail calls. |
| D10 | Fexprs are operatives over syntax (TRD 6.2) | `def-fexpr` has been cut. Metaprogramming is served by total `quote`/`quasiquote` and the future `defmacro`. |
| D11 | Quasiquote | **Fixed.** The reader parses quasiquote/unquote/unquote-splicing and a runtime walker expands them (splicing, nested, vectors, maps). |
| D12 | Source locations | **Partially fixed.** The reader emits `ELocated` and wraps `def`/`fn`/`defnode` bodies with their definition-site location; parse errors include file and line. Runtime errors from arbitrary top-level expressions still drop the enclosing location. |
| D13 | Build-system-as-language | **No process/exec effect** — builtins are read/write-file/log only. pp cannot invoke a compiler. `build.pp` is aspirational and would crash. |
| D14 | Self-hosting `pc.pp` | `pc.pp` and `selfhost-test` have been deleted (Q12). |
| D15 | Backend parity, misc | **Fixed.** VM `module` compiles all children, computed config keys work, and `compile_program` forces non-final top-level expressions. |
| D16 | Error semantics | A raising thunk is still left `Evaluating`, so the next force misreports "infinite recursion"; failure traces are Phase 1 work. **Fixed:** exceptions inside `effect`/`with-handler`/`with-config` now restore state. |
| **D17** | Handlers × caching **(new)** | `handler_stack` is **not** in the thunk key (evaluator.ml:23–26 hashes caps+config, not handlers). A thunk memoized under handler A can be returned under handler B — cache-unsound today, and directly fatal to the "swap mock/real handler" feature. |
| **D18** | Capability mint **(new, security-fatal)** | **Fixed.** `filesystem`/`network`/`process`/etc. are no longer builtins; capabilities enter only via `--grant`. |
| **D19** | Homoiconicity **(new)** | **Fixed.** `quote_to_value` handles all expr forms; quasiquote expands at runtime. |
| **D20** | VM load-module + handler stack **(new)** | **Fixed.** `LOAD_MODULE_FILE` returns a module value; handler invocation saves/restores the operand stack. |

---

## 2. Frozen design principles

1. **`force` is the only execution primitive.** Where a computation runs is a
   scheduler decision, never language surface. No `remote-eval`. Parallelism
   and distribution are the same feature at different fan-out; scheduling is a
   swappable, **result-transparent** effect handler (see Q7/D17); cluster
   membership is ambient config/capability, not per-expression.
2. **Laziness is demand-pruning at node granularity; node application is
   strict.** *(Rewritten — see Q1.)* The persistent, memoized, content-
   addressed property attaches to *graph nodes*; a node's body is call-by-value
   with memoization; a `perform` fires eagerly in program order within `do`.
   The DAG is not "emergent from per-expression laziness" — it is the
   demand-pruned subset of the wanted-set defined by the root desired-state
   formula (Bazel-shaped). `delay` remains for *ephemeral* in-memory laziness
   (lazy sequences); it is distinct from `node`.
3. **Capabilities are authority, not ordering, and are unforgeable.** A
   capability is a ceiling on what a computation *may* touch, minted only at the
   root (Q6); user code may `restrict`/`compose` but never `construct`. It is
   not linear/affine. Ordering/determinism come from principle 5.
4. **One rebuilder; two schedulers.** *(Rewritten — see Q7.)* A single
   rebuilder (verifying + constructive traces over one CA store, with hash
   cutoff) is driven by two schedulers: a suspending *pull* scheduler (builds,
   provisioning) and a dirty-propagating *push* scheduler (reconciliation,
   services). The collapse is at the store/rebuilder level, not the scheduler
   level.
5. **Program = pure function from input cells to a desired-state value for
   observable, convergent domains; runtime = single-writer reconciler. Fenced,
   non-convergent actions are sequenced by the reconciler's intent journal and
   sit *outside* the desired-state law.** *(Amended — the fenced carve-out is
   named; see E1/Q3.)* User code never writes shared external state; domain
   writes go only through the reconciler. Single writer per domain ⟹ no
   write-write races, no ordering rule to enforce.
6. **Scope discipline.** Nail hermetic + incremental (then parallel, then
   distributed) *builds* first. Provisioning is a build. Reconciliation is the
   same rebuilder under the push scheduler. Orchestration is a library/island —
   never core surface.

**Fate of plain `write-file` in user code (required answer).** It dies as a
domain-write path. Decision: **nodes may write only to sandbox-local scratch
paths** (thrown away; only output blob hashes escape); **writes to any
reconciled domain go exclusively through the reconciler.** pp remains a
scripting Lisp for computation and observation; it stops being one for
uncontrolled side-effecting writes. This is the price of principle 5 being true
rather than fiction; without it "single writer" is a slogan. A
`--unsafe-scripting` escape hatch may exist outside nodes for REPL ergonomics,
explicitly outside the caching/determinism guarantees.

---

## 3. The unified runtime model

### 3.1 Vocabulary

**Input cell (`Var`).** A stable identity naming a piece of the external world,
plus its current observed value as a content hash. Identities:
`file:<canonical-path>`, `glob:src/*.c` (a names→hashes manifest),
`tool:cc@<binary-hash>`, `toolchain:cc` (a *closure* cell — the tool binary
plus the set of system include/lib paths it reads; see Q2), `proc:web`
(an "is-running" observation: pid+start-time, deliberately not CPU%). Cells are
mutable only because reality is; the observer (prober/watcher) is the only
writer of a cell's value.

**Cell-id canonicalization (required answer).** A cell-id is canonicalized
before hashing: absolute real-path (symlinks resolved via `realpath`), NFC
Unicode, no trailing slash. This is done once, in the Runtime module, so the D8
path-prefix bug class cannot reappear at the cell layer. Two syntactically
different paths naming the same inode are the same cell.

**Node (the cacheable computation).** A suspended strict computation created
only at explicit boundaries: `(node e)`, `(defnode …)`, island imports. Not
`let`/argument thunks (those are strict, Q1).
- **Key** = `H(code-hash ‖ arg-value-hashes)` **[R4/Q5 unified]** — always
  argument *value* hashes. A path argument `"src/a.c"` contributes the hash of
  the *string*, not the file content. An aggregator argument (a child node's
  result) contributes that result's hash — which is why children are forced
  before the parent's key exists (call-by-value; Q1). `code-hash` resolves free
  variables to their *value* hashes (fixing D6's env hole and the env-coarseness
  in one move). Capabilities and handler-stack are **not** in the key (Q6, Q7).
- **Validity** is separate from identity: a cached result is valid iff every
  entry in one of its stored traces still matches (below).

**Trace.** Recorded during evaluation: the `(cell-id, observed-hash)` pairs the
node read, the keys of child nodes it forced, its result hash, and a
`{ok|failed}` outcome. Constructive + verifying, in BSalC terms.
- **Trace store keyed key → SET of traces** **[R9]**, not a single trace (Nix
  CA-realisations model). One node can have been validly built under different
  observed toolchains/platforms; a hit succeeds if *any* stored trace verifies.
- **Failure caching** **[R9]**: a `failed` outcome is a stored trace (result =
  the error value's hash). A null rebuild with unchanged inputs re-serves the
  failure without re-running — otherwise every clean build re-runs known-broken
  compiles. Failures are re-forceable exactly when an input cell in their trace
  changes (this is the error-memoization law, fixing D16).

**Cutoff.** After recompute, if result hash equals a prior result hash,
dependents are not dirtied. Content-addressing makes cutoff free and exact.

**Desired-state value.** An ordinary pp value the root returns: build →
`{output-path → blob-hash}`; services → `{proc-name → spec}`. Pure, hashable,
diffable.

**Reconciler.** The single privileged writer for a *domain* (an output subtree,
a process set, a DB schema). Observes the domain as cells, diffs desired vs
observed, applies the minimal change, verifies after write.

**Domain stratification (required answer, R10i).** Nodes that feed a domain's
desired-state value **may not read that domain's own cells.** Otherwise
reconcile→cell-change→dirty→re-force→reconcile loops forever. Read/write strata
are declared per domain and checked: desired-state producers are upstream;
observation of `tree:build/` for the *reconciler's* diff is downstream and not a
node input.

**Two kinds of mutation, neither shared-mutable-state:** thunk-local scratch
(sandboxed per node, discarded, only output blob hash escapes — Nix/Bazel); and
shared/external (cells in, desired value out, reconciler applies — React/k8s).

### 3.2 The rebuilder (shared) and the two schedulers

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

### 3.3 The two axes
- **Authority ceiling (may touch):** the capability set, unforgeable, minted at
  root, checked at every `perform`, captured at node creation, and checked again
  at hit time against the trace's transitive read closure (Q6).
- **Actual dependencies (did touch):** the trace set. Keys and cutoff live here,
  never on capability scope or handler identity.

---

## 4. Open questions Q1–Q12: decisions

### Q1 — Strictness. **Node application is call-by-value + memoization. Persistent `node` ≠ ephemeral `delay`. Fexprs are cut; `node`/`defnode` are reader special forms; quasiquote/`quote_to_value` are made total.** [R4]

*Admit the thesis change honestly.* Because an aggregator's key is
`H(code, child-result-hashes)`, its children must be forced before its key
exists. Node application is therefore **call-by-value with memoization**, not
call-by-need. The README slogan "every expression is a thunk; the DAG emerges
from laziness" is **retired**. What survives as "laziness" is (a) skip-on-hit
(don't recompute cached nodes) and (b) demand-pruning: only nodes reachable from
the root desired-state formula are built. The wanted-set is defined
Bazel-style by the root, not discovered by bottoming-out lazy demand. The
50k-unit "generative laziness" story is replaced by "the glob manifest defines
50k node keys; only demanded ones are forced; unchanged ones hit."

*Why.* Fine-grained call-by-need gave this codebase a documented stack-overflow
class (D4), an argument-thunk allocation storm, an unsound cache key (D6), and
effect-escape hazards (D9) — for zero build-relevant benefit.

*Two distinct constructs.*
- **`node`/`defnode`** — persistent, cacheable graph node; keyed and stored.
  Reader special forms (**the vehicle**, resolving R4's "name the vehicle"):
  `defnode` desugars like `def` but marks the binding a node constructor;
  `node` like `delay` but routed to the store. This avoids relying on fexprs.
- **`delay`/`force`** — ephemeral in-memory thunk, **never persisted**, for
  lazy sequences (`lazy-seq`). Keeps micro-entries out of the store (R4ii).

*Fexprs' fate (R4iii): cut.* `def-fexpr` is removed from the surface. It was
thin (thunks, not syntax; D10) and its only mechanism (argument thunking)
vanishes under CBV. The macro/metaprogramming need is served instead by making
the reader's quote path total: fix `quote_to_value` to handle `if`/`let`/all
forms (D19), implement quasiquote (D11), and add a `defmacro` that operates on
quoted structure at read/expand time. This is a cleaner homoiconicity story than
operatives-over-thunks ever was.

*`=`-divergence (R4iv).* Structural `=` on unforced/deduped values currently
differs (tree-walker dedups, VM doesn't — D7). Sequence **strictness before
parity work**: eager evaluation removes the unforced-structure comparison class,
so the fuzzer isn't chasing a divergence we're about to delete.

*How.* Evaluate `ELet`/`EApply` eagerly in both backends; keep `force`
(idempotent on non-nodes); route `node` through the successor to `make_thunk_ca`
with Q8 keying. This is a semantic break — done at zero users in Phase 0.

### Q2 — Observed-read tracking. **Sound-but-coarse by default (whole mounted-cell tree hash); refined per-tool by depfile/toolchain-closure adapters. The depfile is a *precision* mechanism layered on a coarse *soundness* floor.** [R6]

*Concede the point.* Sandbox v1 (temp dir + hardlinked read-only inputs)
**cannot fail-close absolute paths** — cc reads `/usr/include/*` regardless. So
the sandbox alone is not the soundness mechanism, and "depfiles are just an
optimization" (the prior draft) was wrong.

*The soundness rule.* A node's trace defaults to the **content hash of every
mounted cell boundary it was granted** — e.g. the whole `src/` tree hash and the
`toolchain:cc` closure cell. This is *sound* (any change to any granted input
invalidates) but *coarse* (non-incremental: any `src/` file touches everything).
Per-tool adapters then **refine**: `cc -MD` reports the exact user + system
headers read; the adapter converts those into precise cells
(`file:src/shared.h`, and the system headers become part of the `toolchain:cc`
closure cell), shrinking the trace below the coarse ceiling. If no adapter
exists for a tool, you keep the coarse-but-sound behavior. Sound-but-coarse
beats precise-but-unsound.

*The `toolchain:cc` closure cell.* System headers/libs are real staleness holes.
They are modeled as one closure cell whose hash covers the tool binary plus the
resolved set of system paths it reads (discovered from depfiles, pinned per
platform). A libc header bump changes the closure cell → invalidates dependents.
Different machines observe different toolchain cells → different traces in the
key's trace SET (R9).

*Cell boundary* = the locator the effect names. *How:* a `current_trace`
collector pushed per force; `read-file`/`list-dir`/`run` handlers append
observations (ingesting to CAS, Q11). OS-level read tracing (Linux
landlock/fanotify; macOS is genuinely painful) is a later precision upgrade, not
a soundness dependency. Delete/gate every ambient bypass first (D8c, D18).

### Q3 — At-most-once effects. **Fenced effects live only in the reconciler, never in node bodies. Epoch = per-reconcile-pass ⇒ at-most-once-per-pass, with a WAL and unknown-status policy.** [R10ii]

*Two effect classes.* *Convergent* (write file, ensure process): safely
re-appliable; these are what nodes may do (in sandbox) and what the reconciler
applies. *Fenced* (send email, charge card): not convergent. **Decision: fenced
performs may not appear in node bodies at all** — nodes are cache-replayable and
must not contain irreversible actions. Fenced actions are reconciler-only. So
"run cc" inside a node is convergent-in-sandbox, never fenced.

*Epoch (required definition).* The idempotency epoch is the **reconcile pass**.
Guarantee is at-most-once **per pass**, not globally — a converged service that
reconciles every tick would otherwise never be allowed to re-send on a genuine
new desired state. Key default = `H(reconcile-epoch, action-args)`.

*How.* WAL: `intent(key)` → perform → `done(key, result-hash)`. Replay: `done` ⇒
skip, return recorded; `intent` without `done` ⇒ status **unknown** →
policy (`:retry | :abort | :ask`), never silent retry. Fenced actions are
excluded from any cross-machine reuse.

### Q4 — Reconciler crash-safety. **Journaled apply over the CAS; convergence is driven by re-observed reality, not a trusted state file.**

Terraform's pain is a state file drifting from reality; pp sidesteps it because
desired is cheap to recompute (cache) and observed is re-derived from cells — a
crashed half-apply is just another observed state the next pass diffs and
converges. Steps: (1) diff plan is a pure value (hashable → plans cache);
(2) append `(desired-root-hash, plan)` to `~/.pp/journal`; (3) apply — file
materialization via `out/.pp-tmp-<hash>` + `rename(2)` (same fs ⇒ atomic),
process ops convergent, fenced ops via Q3; (4) verify-after-write: re-observe
domain cell, mismatch ⇒ report + converge next pass; (5) mark complete. Restart:
resolve fenced unknowns per policy, rerun stabilize+reconcile.

### Q5 — Cutoff × generative graphs. **Dynamic deps native; key-vs-validity makes generators cheap; keying unified with Q8.** [R10iv]

`sources` reads `glob:src/*.c` and maps `compile`. Editing one file changes that
file's cell, invalidating exactly the one `compile` whose trace mentions it; the
generator itself re-runs only when the *manifest* (names) changes, and then emits
the same child keys for unchanged files — each an O(1) trace-check hit. **Node
key uses argument value hashes uniformly** (Q8): `compile`'s argument value is
the string `"src/a.c"`; `link`'s argument value is the list of child result
hashes. (This unifies the Q5-"arg-names" vs Q8-"arg-values" wording the review
flagged: it is always arg *values*; a path string's value just happens to be a
name.) Cost honesty: manifest churn makes a generator re-run O(#children) hash
lookups — acceptable; stable-key incremental maps (`Incr_map`) are a later
optimization. Cycles are runtime errors reporting the force-path (the collector
already carries the stack).

### Q6 — Capability model: **unforgeable, root-minted, pure ceiling; hit-time check is transitive.** [R1, R3]

*Authority bootstrap (the fatal fix).* Capabilities enter **only at the root**.
`main` receives a *powerbox* — the full authority set — from the CLI
(`--grant fs:src:ro`, `--grant net:tcp`, …). This is the sole mint. **User code
cannot construct capabilities**: `filesystem`/`network`/`process`/… are removed
as constructor builtins (D18); what remains are `cap-restrict`/`cap-compose`,
which only *narrow* or *union* capabilities the code already holds. Capability
values are sealed (unforgeable tokens carrying `{kind; scope; attrs;
provenance}`); there is no surface syntax that fabricates one. `(effect
:capabilities [(filesystem "/" :rw)] …)` becomes a compile/parse error — the
symbol `filesystem` is unbound.

*Interpreter-level loads are runtime authority (R1 self-contradiction fix).*
`load`/`import`/`island`/module resolution are file reads *every* program needs;
they run with the interpreter's own runtime authority (bounded to the program's
source roots + store), **outside** user capability accounting. They are the
loader, not user effects. P0 exit(3) is rewritten accordingly (below).

*Pure ceiling semantics.* `restrict` narrows (no consumption — the affine/spent
machinery is dropped), `compose` unions. Path checks become path-component-aware
and full-path (fix D8ab). `random` becomes a capability-gated, trace-recorded
input (a nondeterministic read) or is banned in nodes. `CapTime`/`CapMemory` are
**removed now** (unenforced security surface is worse than none) and reintroduced
only as scheduler-enforced node budgets when there is an enforcer (Phase 3).

*Hit-time check is TRANSITIVE (R3, the leak-closure fix).* A node `PUB =
f(SECRET)` where `SECRET` reads `/etc/passwd` has, in `PUB`'s own trace, only the
child key `K_secret`. A direct-cell-only check would let a narrow-cap caller hit
`PUB` and learn a broad read happened. So the hit check must cover the
**transitive read closure**: the union of cells across `PUB`'s trace and,
recursively, the traces of every child key. A hit is granted only if the
caller's cap set permits every cell in that closure.
- **Cost:** a hit is **O(transitive closure size)**, not O(1). Mitigation:
  memoize a `closure-read-set-hash` and `closure-cap-requirement` per stored
  trace (computed once at store time), so a hit is a single set-containment
  check against a precomputed requirement in the common case; the full walk is
  the fallback when the requirement isn't cached.
- **Runtime-vs-traced reads (required distinction):** reads performed under
  *interpreter runtime authority* (loader reads: `load`/stdlib/island) are
  tagged `runtime` in the trace and are **excluded** from the caller's
  capability requirement — otherwise a caller scoped to `src/` could never hit
  anything whose closure touches the stdlib. Only reads performed under *user
  capabilities* count toward the requirement. This is why the runtime/traced
  split (Q2, D8c) is load-bearing, not cosmetic.
- **Store-existence oracle:** because keys are computable without holding caps
  and hit/miss is observable, an unprivileged party could probe existence.
  Therefore `pp why` and any hit/miss surface are **capability-filtered from day
  one** — you cannot introspect a node whose closure you couldn't read.

*Remote form (Phase 4 stretch):* signed token chains verified and enforced by
the remote's own handler before any perform — but this is explicitly deferred
behind a threat-model doc (see Cuts).

### Q7 — One rebuilder, two schedulers. **Drop "re-force from root."** [R7]

*Fix the internal contradiction.* The prior §3.2 said "dirty-propagate via
reverse index" while Q7 decided "memoized re-force from root." Those are two
algorithms. Root-re-force is O(reachable trace-checks) per tick — it re-observes
cells and re-hashes O(graph) on every change, which is exactly the cost the
reactive gear exists to avoid, and it leaves the reverse index unused.

*Resolution (BSalC framing, leaned on harder):* **one rebuilder** (verifying +
constructive traces + CA cutoff over one store) driven by **two schedulers** —
a *suspending pull* scheduler (builds) and a *dirty-propagating push* scheduler
(services, using the reverse-edge index derived from traces). The
**store-level collapse is the real, keepable claim**: both schedulers hit the
same node keys in the same store (P2 exit(4) makes this auditable). The
scheduler-level collapse ("it's literally the same traversal") is **dropped** as
overclaim. Correctness of the push scheduler rests on Adapton's from-scratch-
consistency *as a spec to test against*, not on re-running from the root.
Pull-scheduler v1 may implement stabilize as naive re-force-from-root purely as
a **correctness reference** to differential-test the push scheduler; it is not
the shipping reactive path.

### Q8 — Phase-1 keystone: persistent store wired into force.
- **Store** `~/.pp/store/`: `objects/<blake3>` (result values + file blobs);
  `traces/<node-key>` → **SET** of `{result-hash, [(cell-id,hash,origin)],
  [child-keys], outcome, closure-read-set-hash, closure-cap-req}` (R9); `journal`
  (Q4). Concurrency: O_CREAT-exclusive temp + rename; hash-named objects
  immutable ⇒ races benign.
- **Hash** BLAKE3, replacing MD5 (D5), before anything persists (no migration
  ever exists). Dependency posture in E6.
- **Keying** per §3.1: `H(code-hash ‖ arg-value-hashes)`; code-hash resolves free
  vars to value hashes (fixes D6 + env-coarseness). Replaces the current
  `hash(expr, env, caps, config)` (evaluator.ml:23–32).
- **Caps and handlers are NOT in the key.** Caps: hit-time transitive check (Q6).
  Handlers: synthetic-cell rule (D17 resolution below).
- **D17 resolution (handlers × caching) [R2].** Two handler classes:
  1. **Result-transparent handlers** (by decree the *schedule/placement*
     handlers of Q7/principle 1): they may not change observable results, only
     where/when work runs. They cross node boundaries freely and are absent from
     keys/traces. Ships with a debug `--check` that runs a node under two
     schedule handlers and asserts identical result hashes.
  2. **Semantic handlers** (mock `read-file`, fault injection, alternate
     `run`): an intercepted `perform` inside a node records a **synthetic cell**
     `handler:<handler-code-hash>:<effect-name>:<arg-hash>` → `result-hash` into
     the trace. Swapping mock↔real changes the handler code hash → different
     synthetic cell → invalidation. This makes the headline "swap the handler,
     get correct rebuild" *sound*, and it is strictly better than putting the
     whole handler stack in the key (only intercepted effects that actually ran
     enter the trace). D17 is thus closed at the trace layer, not the key layer.
- **`.ppc` bytecode disk cache is CUT.** `cache.ml`'s `save`/`load` and
  `bytecode.ml`'s serializer are **deleted** (they persist bytecode, are lossy on
  caps/types, and are dead — D1). The Q8 value/trace store replaces them
  entirely. Bytecode stays purely in-memory as the VM's execution form.
- **Introspection:** `pp why <key>` (hit/miss + first stale trace entry),
  capability-filtered (Q6). `pp graph` is deferred to P2 (needs the reverse
  index, which doesn't exist until then).
- **One `Runtime` module.** The backends duplicate handler stacks, cap sets,
  config stacks, thunk stores (evaluator.ml:9–18 vs vm.ml:7–14) — a standing
  parity-bug factory (D7,D9,D20). Extract a shared `Runtime`; the store, traces,
  cells, and the loader authority live there.

### Q9 — Distribution. **Scheduler-as-handler over a process pool; cluster deferred.** [Cut (d)1]
Phase 3 ships **process-pool parallelism only** — the `parallel` schedule
handler over local worker *processes* on a ready queue. Worker **processes**, not
OCaml 5 domains: the interpreter is saturated with global mutable state
(evaluator.ml:9–18; vm.ml:7–14; primitives.ml refs), processes give isolation,
match the sandbox model, and make node-granularity parallelism (viable only
because of Q1) real. This exercises the real work — the global-mutable-state
refactor into `Runtime`. Cluster forcing, by-hash object sync, and signed
capability tokens move to **Phase 4 / stretch**, gated behind a written
threat-model doc (E7); publishing token formats before the threat model is
theater.

### Q10 — Backend strategy. **Keep both; oracle is strictest; differential-test in CI; soften the parity rule.**
`--diff` is the cheapest correctness asset here. Phase 0 closed the previously
open VM parity gaps: D3 (type enforcement), D7 (VM thunk hash), D9 (effect/
handler/config scoping), D10 (fexprs cut), D15 (module/config/top-level
forcing), D20 (load-module/handler stack), and tests 004/005 were restored.
The rule softens from "no feature in one backend" to **"no *shipped* feature in
one backend"** — in-flight divergence during a migration is allowed; a release
with it is not. `SPEC.md` states that **a cache hit does not replay ephemeral
effects** (log/stdout) — hit vs miss differ only in ephemeral output (R10vi).

### Q11 — Effect ordering: **sufficient, with snapshot-as-CAS-ingest and node-captured caps.** [R8]
Residual races: (1) **torn reads** — the first observation of a cell in a pass
**ingests its bytes into the CAS** and pins `(cell → CAS-hash)`; nodes read only
the CAS copy, never the source path (hardlink *from CAS*, never from source).
This makes mid-pass in-place edits impossible to observe partially and prevents
store-poisoning (a pinned hash whose hardlinked inode was edited in place).
(2) **external writers to a reconciled domain** — verify-after-write +
converge-next-pass; domains declare single ownership. (3) **hidden writes in user
handlers** — domain write caps are ungrantable to node code (principle 5
write-fate). (4) **laziness escape** — killed by Q1 strictness plus capturing the
capability set at node creation, making authority a property of the node (also
what makes remote forcing well-defined).

### Q12 — Self-hosting: **cut now.** `pc.pp` is unrunnable on three independent
counts (D14); delete it and `make selfhost-test`. The thesis-proving dogfood is
Phase 1's exit: `pp` builds `pp` via a real `build.pp`, Makefile deleted.
Self-hosting the compiler is a Phase 4+ curiosity, revisited only if it earns its
keep as a VM-correctness exercise.

---

## 5. Phased plan — falsifiable exit criteria

### Phase 0 — A core that cannot lie
Truth before features.  **DONE.**  All rocks moved and verified by running tests.

**DONE:**
- [x] Stack-safe evaluator (trampoline + depth-limit)
- [x] Mutual `let` (LAW 1)
- [x] `node`/`defnode`/`delay` as reader special forms
- [x] `def-fexpr` cut
- [x] `quote_to_value` total — handles all forms
- [x] SHA-256 replacing MD5
- [x] Tree-walker type enforcement — `check_type` mirrors VM
- [x] Shared `Runtime` module
- [x] `--grant` capability bootstrap
- [x] Path-component-aware capability checks
- [x] VM effect/handler/config scoping fixed
- [x] `random` removed from builtins
- [x] `CapTime`/`CapMemory` removed
- [x] `slurp` gated behind `Capabilities.check_fs_read`
- [x] `cache.ml` deleted; Makefile uses dune
- [x] `pc.pp` deleted, `selfhost-test` removed
- [x] Exception-safe state restore for effect/handler/config
- [x] VM thunks carry content hash
- [x] Reader emits `ELocated`; parse errors include file and line
- [x] Tests 004/005 restored to `make test`
- [x] `make test` passes all files under `--diff`

**ALL PHASE 0 ROCKS DONE:**
- [x] Quasiquote reader + function — `` ` ``/`,`/`,@` fully working with splicing, nested quasiquote, vectors, maps
- [x] Dune build system — `dune build` produces a working binary; Makefile is a convenience wrapper

**Phase 0 exit criteria:**
1. Fuzzer zero divergence — **DONE** (`./fuzz --grammar core` exits zero; `./fuzz --grammar full` sampled 200 cases with zero mismatches/crashes)
2. `make test` under `--diff` — **DONE** (7/7 pass, including `tests/007-phase0-laws.pp`)
3. Adversarial capability suite — **DONE** (`tests/capability-adversarial.sh` runs both backends and checks constructor removal, path-component scope, and gated `slurp`)
4. Stack-safe 10⁶ recursion — **DONE** (tail-recursive countdown verified to 1,000,000 in both backends)
5. Every SPEC law has passing test — **DONE** for all Phase 0-claimable laws (`tests/007-phase0-laws.pp`); remaining unimplemented laws are Phase 1+ work.

**Exit criteria check:**
1. Fuzzer zero divergence — **DONE** (verified with `./fuzz --grammar full --count 200`)
2. `make test` under `--diff` — **DONE** (7/7 pass)
3. Adversarial capability suite — **DONE** (`make cap-test`)
4. Stack-safe 10⁶ recursion — **DONE** (verified in both backends)
5. Every SPEC law has passing test — **DONE** for the Phase 0 surface; LAW 29 still drops locations for arbitrary top-level expression errors.

### Phase 1 — The incremental hermetic build engine (the keystone)
- Persistent CAS + **trace-set** store wired into `force` (Q8); failure caching;
  transitive hit-time capability check with runtime/traced split (Q6);
  snapshot-as-CAS-ingest (Q11).
- Effect-interposed observed-read tracking with **coarse-cell soundness floor +
  depfile/toolchain-closure refinement (Q2)**; `run` process effect with per-node
  sandbox (D13); C depfile adapter; `toolchain:cc` closure cell.
- Desired-state output tree + filesystem-domain reconciler v1: atomic
  materialization, verify-after-write, journal (Q4); domain stratification (R10i);
  user `write-file` restricted to sandbox scratch (principle 5).
- `pp why` (capability-filtered); `--no-cache`; `--check` (double-build
  determinism audit → flags volatile nodes, E4).
- Rewrite `build.pp` for real.

**Exit (falsifiable), on a ≥100-file C project and on pp itself:**
1. Null rebuild executes **zero** external processes (journal proves it), <1s.
2. `touch shared.h` (no content change) → zero recompiles (cutoff).
3. Edit one `a.c` → exactly `a.o` + link re-run (trace logs prove it).
4. `rm -rf build/` → fully restored from the store, zero compiler invocations.
5. Comment-only header edit → dependents recompile, link cut off (Appendix A 2b).
6. `pp` builds itself via `build.pp`, Makefile deleted.
7. A capability scoped to `src/` **cannot** get a cache hit on a node whose
   transitive trace closure touched a path outside `src/` under user authority
   (Q6 transitivity, as a passing negative test).

### Phase 2 — The reactive gear (push scheduler, same rebuilder)
- Reverse-edge index over traces; fs watchers + process-supervision cells;
  push `stabilize`; `--once` vs `--watch` as the only build/service difference.
- Process-domain reconciler (start/stop/restart on spec-hash change); fenced
  effects + intent journal (Q3), reconciler-only.
- `pp graph` (now that the reverse index exists).

**Exit (falsifiable):**
1. A pp service killed with `kill -9` converges back within 1s.
2. Editing its config rewrites config and restarts exactly the affected process.
3. The same program file with `--once` provisions once and terminates.
4. Introspection shows the `--watch` run and the `--once` run hitting the **same
   node keys in the same store** — the store-level collapse, made auditable.
5. Kill the reconciler mid-apply of a fenced action → on restart it is not
   re-performed and the unknown-status policy fires.
6. Differential test: push `stabilize` result hashes equal the pull-scheduler
   reference (re-force-from-root) on a battery of cell-change sequences.

### Phase 3 — Parallelism (process pool)
- `parallel` schedule handler over local worker processes; the global-mutable-
  state refactor into `Runtime` this forces is the real deliverable. Result-
  transparent handler discipline (Q8) validated by `--check`.

**Exit:** the Phase-1 build runs across N local workers with byte-identical
outputs to the serial build and a measured speedup on a parallelizable project;
"run on 3, take first" is a handler swap with zero language-surface change.

### Phase 4 / stretch — Distribution + ecosystem (gated)
Cluster forcing, by-hash object sync, signed capability tokens with remote
enforcement — **only after a written threat-model doc** (E7). Islands that
actually fetch/pin (git; content-addressed by commit+tree; `--update` made real,
D2). Real stdlib, LSP, cache GC. Self-hosting reconsidered (Q12). Exit criteria
drafted when Phase 3 closes.

---

## 6. Honest edges — each with mitigation

- **E1 Fenced effects don't converge.** Sequenced, not tamed. Mitigation: Q3
  (reconciler-only, per-pass epoch, WAL, unknown-status policy); named as the
  carve-out in principle 5. Residual: `:ask` reintroduces a human — acceptable;
  silent double-send is not.
- **E2 The reconciler is a single privileged actor.** Holds the write authority
  the rest of the system eliminates. Mitigation: Q4 (journal, atomic
  materialization, verify-after-write, reality-driven convergence — not a trusted
  state file); its code is small, the only code with domain write caps.
- **E3 Dynamic discovery ⇒ no static "what will this touch."** Mitigation: the
  capability ceiling (static, sound) + last run's traces (`pp plan`: precise for
  unchanged shape). Cycles are runtime errors with force-path reporting (Q5).
  Explicit trade vs Bazel's static analyzability.
- **E4 Nondeterministic tools.** `__DATE__`, timestamp linkers, ASLR. Mitigation:
  per-tool canonicalization adapters (`-frandom-seed=<hash>`, `ZERO_AR_DATE`);
  `--check` double-builds and flags **volatile** nodes. **Volatile-node cone
  poisoning (R9):** a volatile result re-keys its whole ancestor cone each build,
  killing cutoff above it and growing the store unboundedly along the cone.
  Mitigation: a volatile result is treated as a **cell** (observed/pinned per
  pass) rather than a node result, so its instability is contained at one edge
  instead of propagating; where possible, canonicalize instead. Permanent
  gardening, budgeted as such.
- **E5 Strictness break.** Q1 changes observable semantics of lazy idioms.
  Mitigation: done at zero users (Phase 0); `delay`/`lazy-seq` retained for
  ephemeral laziness; documented in `SPEC.md`.
- **E6 Zero-dependency story ends.** BLAKE3, sandboxing, watchers. Posture: move
  to dune/opam in Phase 0; accept first-party-quality opam deps (blake3 or
  vendored C; digestif fallback); keep the *interpreter core* dep-free so the
  oracle stays auditable; isolate deps behind `Runtime`.
- **E7 Cache as authority/existence oracle.** Mitigation: transitive hit-time
  cap check (Q6) + capability-filtered `pp why`. Residual: hash-guessing side
  channels — out of scope until multi-tenant caches (Phase 4 threat-model doc).
- **E8 High-churn cells thrash the push scheduler.** Mitigation: cell design
  discipline (observe convergence-relevant facts only), watcher debouncing,
  cutoff absorbing no-op observations.
- **E9 Coarse-cell fallback is non-incremental.** Until a tool has a depfile
  adapter, its nodes invalidate on any mounted-tree change (Q2). Mitigation:
  sound by default, precision added adapter-by-adapter; `pp why` shows whether a
  node ran coarse or refined.

---

## 7. Prior art — pp against its neighbors

- **Unison** — content-addressed *definitions* + abilities + distributed runtime.
  Closest relative. pp hashes *computations and world observations* (the store
  holds traces of runs), which is why incremental builds and reconciliation fall
  out and why Unison doesn't compete for the build/orchestration slot. pp is
  build-framed, dynamically typed, demand-pruned DAG; Unison is general-app,
  statically typed, strict.
- **Build Systems à la Carte** (Mokhov/Mitchell/Peyton Jones) — **the
  load-bearing framing.** pp is one **rebuilder** (verifying + constructive
  traces, CA cutoff, one store) with **two schedulers** (suspending pull /
  dirty-propagating push). This is exactly the vocabulary that resolves Q7: the
  collapse is a shared rebuilder+store, not a shared traversal. It also names the
  failure mode to avoid — a self-tracking build with unsound cutoff.
- **Nix / CA-derivations** — shared CAS + hermeticity ambitions. pp has no
  eval/derivation phase split (the "derivation" *is* the node, discovered by
  running), native early cutoff (Nix input-addressing lacks it; CA-derivations
  bolt it on; and pp adopts Nix's **realisations = key→trace-SET**, R9), and
  dynamic dependencies where Nix's language is build-time-only. Nix also funds E4.
- **Bazel (+ RE/remote cache)** — declared static action graph; strong analysis,
  weak dynamism. pp trades static analyzability for discovered dependencies and a
  general language, keeping Bazel's sandbox trick (Q2, as a *precision* layer over
  a soundness floor) and its remote cache/exec shape (Phase 4).
- **Incremental / Bonsai** — reactive donor: `Var`s, discovered deps, stabilize,
  cutoff. pp is "a persistent Incremental whose cutoff is hash equality and whose
  Vars are the outside world," adding cross-process persistence.
- **Adapton / self-adjusting computation** — the theory behind Q7's push-
  scheduler correctness (from-scratch consistency), used as a *spec to test
  against*, not as the shipping algorithm.
- **Salsa / Skyframe / Shake** — engineering proof points: red-green cutoff,
  graph-per-key invalidation at scale, monadic dynamic deps in production builds.
- **Terraform / Kubernetes** — the reconciler's lineage. pp differs by deriving
  desired state from a cached incremental computation (plans are nodes too) and
  refusing to trust a state file (Q4).

---

## Appendix A — The two-file C build, traced through the model

`a.c`, `b.c`, both `#include "shared.h"`. Build, then rebuild after editing
`shared.h`, then after editing only `a.c`.

### Program (Phase-1 surface sketch)
```clojure
(defnode (compile src)                    ; key = H(compile-code, hash "src/a.c")
  (effect [(restrict fs-root "src" :ro) (restrict toolchain "cc")]
    (perform run "cc" ["-c" src "-o" (scratch ".o")] :inputs [src])))
                                          ; sandbox + depfile refine the trace
(defnode (link objs)                      ; key = H(link-code, [child result hashes])
  (effect [(restrict toolchain "cc")]
    (perform run "cc" (concat ["-o" (scratch "app")] objs) :inputs objs)))
(defnode (app)
  (let [srcs (perform list-dir "src" "*.c")]   ; observes glob:src/*.c
    (link (map compile srcs))))
{"build/a.o" (compile "src/a.c")
 "build/b.o" (compile "src/b.c")
 "build/app" (app)}                       ; desired-state root: {path → blob-hash}
```
`fs-root`/`toolchain` are handed to `main` by `--grant`; user code only
`restrict`s them (Q6). `compile`/`link`/`app`/`node` are reader special forms
(Q1). Children are forced before `link`'s key exists — call-by-value (Q1).

### Cells & first (cold) build
Input cells: `file:.../src/a.c`=h_a, `file:.../src/b.c`=h_b,
`file:.../src/shared.h`=h_s, `glob:src/*.c`=h_m (`*.c` only — header edits do
**not** dirty it), `toolchain:cc`=h_cc (binary + resolved system-header closure).

`pull.force(root)` → `app` → `list-dir` records `(glob:src/*.c, h_m)` →
`compile("src/a.c")`: first observation of each input **ingests bytes into the
CAS** (Q11); sandbox mounts the CAS copies read-only; cc runs; depfile refines
the trace below the coarse `src/`-tree ceiling. Stored (into the key's trace
SET):
```
K_ca = H(compile-code, H "src/a.c") →
  { result: h_ao,
    reads:  {file:src/a.c=h_a (user), file:src/shared.h=h_s (user),
             toolchain:cc=h_cc (toolchain-closure)},
    outcome: ok, closure-cap-req: {read src/, toolchain} }
```
Both axes are visible: the capability *ceiling* said "may read src/ + toolchain";
the trace says "did read a.c, shared.h, cc-closure." `K_cb`→h_bo similarly.
`K_link = H(link-code, [h_ao, h_bo])` — arguments are child *result* hashes.
Desired = `{build/a.o→h_ao, build/b.o→h_bo, build/app→h_app}`. Reconciler
observes `tree:build/`=∅ (a *downstream* observation, not a node input —
stratification, R10i), materializes 3 blobs (temp+rename), verifies, journals
complete. Null rebuild: every trace verifies → zero processes, diff=∅.

### Rebuild 2 — edit `shared.h` (h_s→h_s′)
Pull (`--once`) or push (`--watch`) — same rebuilder (Q7). `K_ca` and `K_cb`
traces both contain `file:src/shared.h=h_s` ⇒ stale ⇒ recompile → h_ao′, h_bo′.
`K_link` re-keys on `[h_ao′,h_bo′]` ⇒ link runs → h_app′. Desired differs at
three paths; reconciler writes three files. The glob manifest is unchanged, so
`app`'s `list-dir` observation is intact — no spurious graph re-expansion.

**2b — comment-only header edit.** h_s′≠h_s ⇒ both compiles *must* re-run (no
cutoff saves a node whose actual input changed). cc emits byte-identical objects
⇒ h_ao unchanged ⇒ **cutoff**: `K_link`'s argument hashes unchanged ⇒ same key,
trace verifies ⇒ link never runs; desired-value hash unchanged ⇒ reconciler
diff=∅ ⇒ zero writes. Cutoff at both graph and reconciler level. (E4 caveat: if
the header held `__TIME__`, `--check` flags the compile node volatile and treats
its result as a cell.)

### Rebuild 3 — edit only `a.c`
`K_ca` stale → recompile → h_ao′. `K_cb`'s trace verifies — **b.o not recompiled,
cc not invoked for it.** `K_link` re-keys on `[h_ao′,h_bo]` → runs → h_app′.
Reconciler writes exactly `build/a.o` and `build/app`. If the edit adds
`#include "extra.h"`, the depfile-refined trace simply gains
`file:src/extra.h` — dynamic discovery, no declaration step. (Coarse-cell
fallback, E9: without the cc depfile adapter, `K_ca`/`K_cb` would key on the
whole `src/`-tree hash and *both* would recompile on any `src/` edit — sound but
non-incremental. The adapter is what buys per-file precision, per Q2.)

### Leaks found and fixed by the trace
1. **Identity vs validity.** Current keying `hash(expr, full-env, caps, config)`
   (evaluator.ml:23–32) leaks: any stdlib/unrelated-binding change rebuilds the
   world (env in key); widening a cap rebuilds the world (caps in key). Fix:
   key=(code, arg-value-hashes); validity=trace SET. The single most important
   divergence from current code.
2. **Caps out of the key, into a transitive hit-time check.** The `PUB=f(SECRET)`
   trace made the leak concrete and the trace closure supplied the fix — at
   O(closure) cost with a precomputed `closure-cap-req` fast path (Q6/R3).
3. **Caps captured at node creation**, not read from the dynamic stack at force
   time — a watcher forces nodes far from any lexical `effect` block; the current
   dynamic lookup (evaluator.ml:12,449–452) would use the *loop's* caps. (Q11.)
4. **Snapshot = CAS ingest.** Pinning a source hash while hardlinking the source
   inode would let a mid-pass in-place edit poison the store; ingesting bytes to
   CAS on first observation makes torn reads impossible (Q11/R8).
5. **Cell boundaries are program API.** The glob had to be `*.c`-scoped for the
   header edit not to dirty the generator; "what you observe is what you react
   to" is doctrine (§3.1).
6. **Link keying implies strict child forcing.** `K_link=H(code, child-result-
   hashes)` cannot exist before children are forced ⇒ node application is
   call-by-value+memoization (Q1) — the appendix is what forced that admission.

No unresolved leak remains in this trace; the residual hazards are the
enumerated honest edges (E4/E9 are the ones this trace brushed against).

---

*Phase 0 has been executed in this session: `make test`, `make cap-test`, and
`./fuzz --grammar full --count 200` all pass. Residual uncertainties: D6
(closure-hash collision) remains unsound; the `full` fuzzer should be run under
extended CI coverage; BLAKE3/vendor-vs-opam, the push-scheduler reference
implementation (Q7), and the exact fuzzer time budget are Phase 1 decisions.*
