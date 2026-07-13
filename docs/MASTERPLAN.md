# pp MASTERPLAN — solving devops in-language

The strategic layer above [ROADMAP.md](ROADMAP.md): how pp gets from "the
engine thesis is proven" (Phases 0–2 closed) to **devops solved in-language**
— not by shipping a devops product, but by making the primitives and model
complete enough that build, package, provision, deploy, and converge are all
realistically writable as pp libraries and islands. ROADMAP stays the phase
ledger where exit-criteria bookkeeping lives; DESIGN's frozen principles and
Q1–Q12 remain normative; this document sequences the remaining work and
states, falsifiably, what "done" means.

This plan was produced the way [DESIGN.md](DESIGN.md) was: drafted, then
hardened against an adversarial review pass. Three of that review's findings
were blocking (secrets leak into the CAS by design, the reconciler — not just
`force` — must distribute, and the end-state oracle was unfalsifiable as first
stated); all are folded in below.

---

## 0. Constraints this plan may never violate

1. **Abstractions, not features.** Anything expressible via existing
   abstractions — cells, traces, capabilities, scheduler handlers, the
   reconciler — MUST fall out of them. No tool-shaped surfaces: no `ssh`
   domain, no secret-manager API, no `remote-eval`. When a milestone below
   names a capability the core must grow (sealed cells, the domain protocol),
   the test is that it *completes an existing abstraction* (closes a partial
   LAW, resolves a documented residual) rather than adding a parallel one.
2. **DESIGN principle 1** — no local/remote distinction at the language
   surface; placement is a scheduler-handler decision. **Principle 6** —
   orchestration is a library, never core.
3. **Walls are information.** When a milestone's design breaks against
   reality, work stops and the design is re-derived from first principles.
   Divergence from this plan is presented to the owner; it is never patched
   around with a flag, a special case, or a second path.

---

## 1. The end-state claim (M6 — stated first; everything serves it)

One readable pp program that:

- **builds** a service from source (the Phase-1 engine),
- **provisions and deploys** it across ≥2 machines (containers acceptable),
- **converges** after drift and after `kill -9`,
- **rotates a secret** invalidating exactly its observers, with the secret's
  bytes never appearing under `~/.pp/store`,
- and is **auditable** via `pp why`,

with everything above the core written as libraries/islands.

**The diagonal oracle.** *Given identical pinned cell observations* — the
recorded cell→hash map from one run replayed into the others — the
desired-state root hash is byte-identical across
**backend** (tree-walker / VM) × **scheduler** (pull / push) ×
**placement** (serial / parallel / distributed). Probe and `proc:` cells are
pinned inputs; fenced actions are excluded — they sit outside the
desired-state law by construction (Q3, principle 5). The trace store already
records every observation needed to build the pin set, so this is a runnable
CI job, not prose.

---

## 2. Milestones

Dependencies: M2's canonicalization gates M1's exit; M3's attenuation gates
M4d; M2's cell grammar and M4 gate M5; everything gates M6. M1 and M2
otherwise proceed in parallel.

### M1 (= Phase 3) — Placement as a handler ✅ DONE (fork-at-dispatch)

The keystone for all distribution: once placement is a result-transparent
handler over worker *processes*, a remote worker is the same handler over a
different transport (Q9).

**Wall B (amendment — docs/PLAN-phase3-parallel.md, adversarial review):**
the `Runtime` global-mutable-state refactor named above as "the real
deliverable" is **not** on M1's critical path after all. `fork()` at the
dispatch point inherits ALL ambient state (handler closures, capabilities,
config, thunk_store) byte-identically via copy-on-write, for free — a
`Runtime.t` refactor is forced only by worker shapes that construct workers
independently of the dispatch point (a persistent pipe-fed pool, fresh `pp`
processes), which would need to MARSHAL that state across a channel
existing independently of any one dispatch, impossible for handler closures
under the store's own non-data law. M1 therefore ships fork workers and
DOCUMENTS the state inventory (DESIGN.md Q9) as what M5's remote transport
would need to marshal, instead of threading a `Runtime.t` now against a
fork-shaped M1 that could never validate it. The real M1 deliverable was the
missing batch fan-out point (Wall A: `EApply` forces every argument, so no
compound value could hold several unforced node thunks at once) — closed by
a new non-forcing `map` builtin — and the scheduler itself
(`src/scheduler.ml`).

- ✅ `parallel`/`race` schedule handler over local worker processes
  (`--schedule serial|parallel:N|race:N`); result-transparent handler
  discipline (LAW 26's first class) validated by `--check` (a non-serial
  policy re-runs forced-serial against the same store and fails on any
  desired-state hash mismatch).
- **Prerequisite: M2's cell-id canonicalization (LAW 23).** Satisfied —
  landed in M2.1, ahead of M1's exit.

**Exit (runnable) — checked against what `tests/024`/`tests/038` actually
prove, not aspiration:**
1. ✅ The Phase-1 101-TU build across N local workers: byte-identical
   desired-state hash and materialized tree bytes to the serial build,
   measured speedup (4-5x observed on the dev machine) — `tests/024`'s
   `p3-*` assertions.
2. ✅ "Run on 3, take first" is a handler swap with zero language-surface
   change (LAW 35 flips to holds for local process-pool fan-out; LAW 34's
   scheduler half lands) — `tests/038`'s race:3 case: identical result,
   exactly one surviving trace, wall-clock ≈ one run not 3x.
3. ✅ N-writer store stress test: workers hammering one store (64 nodes
   under `parallel:16`, repeated cold; `race:8` on one key with the
   internal `PP_TRACE_LOCK=0` escape hatch) produce no corrupt trace files
   and no wrong hits — the trace-SET's last-writer-wins drop is *shown*
   sound (a dropped trace recomputes; it never serves a wrong result), a
   per-key `lockf` makes the drop not happen in practice, and journal exec
   counts (one `Unix.write_substring` per line on an O_APPEND fd) still
   prove exact counts under concurrent writers — `tests/038`.

**Residual, out of M1's scope (documented, not silently dropped):**
Q11-bis (DESIGN.md Q11) — N forked workers agree only on cells pinned
*before* dispatch, not Q11's single-process "one run, one snapshot";
sound under R9, narrower than stated, fix is M5 design work. Cluster/remote
placement is unchanged Phase 4, gated on a threat-model doc.

### M2 — Portability floor (alongside M1; canonicalization first)

Devops targets Linux servers; a scheduler cannot place computation on
machines the runtime doesn't run on, and no store can be shared between two
hosts while it is OCaml `Marshal`.

- **Cell-id canonicalization** per DESIGN §2.1: absolute realpath, NFC, no
  trailing slash, done once in `Runtime`. The grammar is
  **host/namespace-qualified from day one** (`file:<host>:<canonical-path>`
  reserved) so M5's domain distribution does not re-break it.
- ✅ **Versioned portable store format** replacing `Marshal`, scoped
  explicitly: `objects/`, `traces/`, `procs/`, `fenced-specs/` now use the
  canonical byte-stable s-expr codec (`src/codec.ml`) under a
  `~/.pp/store/VERSION` stamp; `journal/` was already line text and islands
  already source trees. Golden byte fixtures + round-trip battery + version
  bump + non-data (closure) law + legacy-store wipe: `tests/037`.
- **Linux CI (M2.3): authored, awaiting first green run.**
  `.github/workflows/ci.yml` runs `dune build` + `dune runtest --force` +
  the fuzzer (`core`/`full`, both gating) + `scripts/build-lua.sh` on
  ubuntu-latest and macos-latest, on every push/PR to `master` — it has
  not yet run on GitHub, so Linux is not yet proven. Versioning is wired
  (`pp --version`/REPL banner via `dune-build-info`, verified from both a
  git checkout and a no-`.git` tarball) and [CHANGELOG.md](../CHANGELOG.md)
  / [RELEASING.md](RELEASING.md) exist; the first **tagged release**
  buildable from the tarball alone on a clean opam switch is still
  outstanding (ROADMAP maturity §4).

**Exit (runnable):**
1. A store written on macOS/arm64 is read on Linux/x86_64 with pure
   data-keyed nodes *hitting* (tool nodes legitimately miss — different
   `tool:` cells — and the test selects for that distinction).
2. A store-version bump invalidates cleanly; it never crashes or misreads.
3. The Lua build from a **symlinked source tree** behaves identically to the
   real path — "symlinked trees are undefined behavior" ends here (LAW 23
   flips to holds).
4. CI green on both OSes; `v0.2.0` tagged and stranger-buildable.

### M3 — Language self-growth ✅ DONE

The pieces a userland devops library stands on.

- ✅ **In-language capability attenuation/threading**
  (docs/PLAN-m3-attenuation.md). The enabling dependency for M4d: a userland
  domain's `apply` needs a write capability threaded to exactly that function
  and ungrantable to node code (Q11 race 3, principle 5). Landed *together
  with* node-captured-cap capture and the differential test distinguishing
  capture-at-creation from ambient-at-force — per DESIGN Q11, capture without
  attenuation was dead, unfalsifiable code, and attenuation makes it testable.
  `(current-capabilities)` reifies the ambient (never a mint); `cap-restrict`
  gained an optional mode argument that only narrows (a wider request is
  `Capability_error`); `(with-caps cap-expr body)` replaces the ambient for
  `body`'s extent, ⊆-gated against the CURRENT ambient, exception- and
  tail-safe in both backends. The `effect` capability-union form (the
  widening-backdoor rule `caps @ ambient`) is REMOVED — vacuous and untested
  before this landed, unsound the instant capability values exist. The node
  boundary is enforced symmetrically: a node's free variable that is/contains
  a capability is `Capability_error` at the key (structural,
  closure-env-aware); a node's RESULT containing one is rejected before
  storage. **Anti-mint constraint (principle 3, D18) holds**:
  `cap-restrict`/`cap-compose`/`with-caps` only narrow/union/replace-within
  what is already held; domain write caps remain root-powerbox-only
  (`--grant domain:…` is M4d surface, not implemented here). The D18
  adversarial suite extends (`tests/capability-adversarial.sh`) to prove
  composing narrowed views never resurrects the root's authority and a
  printed capability is inert text.
- ✅ **Fix D22** (the two VM global-scope holes). Module/global correctness
  stops being a curiosity the moment libraries are real. `EDo` now binds its
  defs as local slots unconditionally (never VM globals, even at
  `st.cenv = []`); `EModule` compiles its body as a fresh 0-param closure so
  sibling defs/value-defs resolve through local slots in their own runtime
  frame, isolated from the enclosing scope. `tests/039-vm-global-scope.pp`;
  fuzzer `stmt_do_scoped_def`/`stmt_module_sibling`.
- ✅ **`defmacro`** on the total quote/quasiquote base (D10's promise).
  Landed the way the design decision forces: expansion (`macro.ml`) is ONE
  shared step both backends pass through BEFORE their own machinery — the
  tree-walker's `hash_expr`/`node_key_of` and the compiler — ever sees a
  form, so LAW 20's code-hash needs no change to hash the **expanded**
  form; it already does, by construction. `(defmacro (name params...)
  body...)` parses as an ordinary application (no reader special form); a
  macro runs its body through the tree-walker (LAW 36: the oracle) over
  `quote_to_value`d argument forms and converts the result back via the new
  `Types.value_to_expr` (`quote_to_value`'s inverse — the exhaustive dual of
  every case it handles, plus the merged `(name params...)` shape a
  quasiquoted `` `(def (,name ,@params) ,body) `` naturally produces).
  `gensym` (primitives.ml) mints a fresh, genuinely-unwritable symbol (`~`
  — excluded from `is_symbol_char` and unclaimed by any lexer rule, so a
  bare `~` is a lex error) for manual hygiene; full hygiene is NOT required
  (unhygienic capture is documented behavior). Scope, decided: macros are
  recognized ONLY at the true top level of a file/REPL input, sequentially
  like a value def (`load` shares the loader's macro table — load is
  sequential evaluation); NOT inside `do`/`module`/`fn`/`node`/etc. bodies,
  which answers "and in modules?" NO and means a `defmacro` inside a node
  body is simply an ordinary unbound-symbol error in both backends, with no
  special-cased detection code. `tests/041-defmacro.pp` (differential:
  control flow, gensym hygiene, a macro building a node form, nested macro
  use, a macro-generated def, redefinition) and
  `tests/042-defmacro-rekey.sh` (the LAW 20 exit criterion, isolated HOME,
  both backends, plus the node-body error pin); fuzzer `stmt_defmacro`
  (full grammar).
- ✅ **LAW 29 residual**: errors inside a `load`ed file cite the inner file.
  `Reader.read_string` now reads a loaded file under its own path, and each
  of its top-level forms is located/decorated individually
  (`Runtime.with_form_location`, shared by both backends), so an error
  inside it cites that file's line, not the loading form's.
  `tests/027-error-messages.sh` case (g).

**Exit (runnable):**
1. ✅ The two deliberate D22 fuzzer generator exclusions
   ([TESTING.md](TESTING.md)) are **deleted** and the fuzzer stays green on
   `full`.
2. ✅ Attenuation adversarial suite green, including capture-vs-ambient
   (`tests/040-caps-attenuation.sh`'s two-direction differential) and
   anti-mint cases (`tests/capability-adversarial.sh`).
3. ✅ `defmacro` has a fuzzer grammar arm and a differential test proving a
   macro-definition edit re-keys dependent nodes
   (`tests/042-defmacro-rekey.sh`).

### M4 — The world as cells ✅ DONE

External state — remote services, endpoints, secrets, cloud resources —
enters pp the way files already do: as observed cells with capability-gated
authority. Nothing here is a new ontology; each item completes a documented
partial.

- **(a) ✅ Probes as observer-written volatile cells.** A probe is a
  *registration* the watcher/prober machinery evaluates once per pass,
  feeding a cell that nodes then **read** — never a `perform` inside a node
  body ("the observer is the only writer of a cell's value," DESIGN §2.1).
  One feature closes two partial laws at once: LAW 38's containment half
  (volatile results contained at one edge) and LAW 37's missing
  declared-nondeterminism mechanism. That coincidence is the
  abstractions-first test passing.
- **(b) ✅ Sealed cells (secrets).** A cell whose observed **hash** participates
  in traces — so rotation invalidates exactly its observers for free, LAW 23b
  blocks laundering, LAW 23c already redacts — but whose **bytes are excluded
  from CAS ingest and from store sync**, with reads capability-gated at the
  use site. Without this, Q11's snapshot-as-CAS-ingest puts secret plaintext
  in `blobs/<sha256>`, falsifying the M6 claim.
- **(c) ✅ Network capability + effect**, decomposed into the categories that
  already exist: content-addressed fetch = **convergent** (island-shaped);
  health check / API read = **probe cell** (via a); convergent network
  mutation = **a domain write through (d) — the only write path** (the fate
  of `write-file`, DESIGN §1); `fenced` stays reserved for genuinely
  non-convergent actions, reconciler-only (Q3/LAW 31). A "mutating API call =
  fenced" default is explicitly rejected: it would rebuild imperative
  Terraform inside pp — a principle-5 violation wearing principle-5's
  clothes. Stage 1 ships the primitive (`http-get`/`http-post` via curl,
  `CapNetwork {host; port}`, `tests/045-network.sh`) — the domain-write half
  (mutating network state as a converged desired-state map) waits on (d).
- **(d) ✅ Q13 — the in-language reconciler-domain protocol.** A domain is an
  observe/diff/apply triple of pp functions running under **core-enforced**
  journal, fencing, stratification, and single-writer discipline. Each domain
  declares its cell namespace so `Runtime.observe_all` can enforce LAW 30
  stratification mechanically. Q13 is written into DESIGN.md through the same
  architect-pass + adversarial-review discipline that produced Q1–Q12, and
  includes the honest-edge E2 revision it forces: core-enforced discipline
  replaces "the reconciler's code is small" as the trust argument. Landed:
  `register-domain` (a probe is now sugar for the ⊥-write-authority case,
  ONE registry, `Runtime.domain_registry`); the trusted primitives
  (`tree-observe`, `materialize-file`, `remove-file`, `proc-spawn`,
  `proc-alive?`, `proc-stop`, `proc-reap`, `domain-state-get/put`,
  `src/domain_prims.ml`); the generic orchestrator (`src/domains.ml`:
  journal bracket, `observed_all` suspension, plan caching via a direct
  Store key — no synthetic node needed, verify-after-write); `Cell.Domain`
  for third-party domains; and `stdlib/domain-fs.pp` /
  `stdlib/domain-proc.pp`, which now hold ALL the policy `reconciler.ml`/
  `supervisor.ml` used to — those two OCaml modules are **deleted**.

**Exit (runnable):**
1. ✅ The existing fs and process reconcilers are **re-implemented as pp
   libraries over the Q13 protocol and pass `tests/018` and `tests/033`
   unchanged** (byte-for-byte assertions; `src/reconciler.ml`/
   `src/supervisor.ml` deleted, `src/domains.ml` + `src/domain_prims.ml` +
   `stdlib/domain-fs.pp` + `stdlib/domain-proc.pp` in their place). A
   third-party toy domain unrelated to fs/proc (`tests/046-domains.sh`,
   "kv": a directory of one-file-per-key values) proves the protocol is
   genuinely generic, not fs/proc-shaped: plan caching, stratification,
   cap threading, verify-after-write failure, the generic journal bracket,
   and fenced-after-domains ordering all hold for it too. The protocol
   expresses the two domains the core already shipped AND a domain neither
   stdlib module defines — principle 6 is proven executable.
2. ✅ Secret rotation invalidates exactly the observing nodes, and a
   store-wide scan proves sealed bytes never landed under `~/.pp/store`
   (`tests/044-sealed.sh`).
3. ✅ A probe-driven convergence test, both as two separate `pp` invocations
   (a node reading `(probe name)` re-forces exactly when the probe's
   underlying value changed, hits otherwise — `tests/043-probes.sh`) AND
   live under one long-running `pp --watch` process on a timer (the same
   test's final section): probe reads are ordinary cell observations
   (`Runtime.observed_all` when `--watch`/`--reconcile`/`--supervise` sets
   `observe_all`; `Store.observe_cell`'s `probe:` arm re-evaluates via the
   `Runtime.probe_observer` hook), so the EXISTING generic watch-loop
   polling picks up a changed probe cell with no probe-specific wiring at
   all — verified empirically before writing this down, not assumed. LAW
   37/38 hold on this evidence (SPEC.md).

### M5 (= Phase 4) — Distribution

**Gated on a written threat-model doc**, which must *name* multi-tenant
stores and E7's hash-guessing exfiltration as out of scope: M6 is ≥2 machines
under one owner; multi-tenancy is cache-service product work, not language
completeness. Sealed cells (M4b) already cover the one tenant-adjacent risk
M6 actually has. ✅ **Gate cleared** — docs/THREAT-MODEL-cluster.md, naming
both exactly.

**Stage A** (docs/PLAN-m5-distribution.md; transport + tokens + sync — DONE):

- ✅ **Signed capability tokens.** Minted by `pp cluster-init` +
  `--mint-token`; verified (MAC -> cluster id -> expiry -> caps) at the
  serving member. Remote *enforcement* (this stage) means the wire path
  feeds the unchanged `Store.hit`/`cell_authorized_for` gate via
  `serve-hit`; remote *evaluation* (running a node ON a remote member) is
  stage B, not this.
- ✅ **By-hash object sync plus trace-set merge semantics** — R9's key→SET
  is the merge mechanism — with capability-filtered `pp why` / LAW 23c
  redaction surviving sync: a synced trace naming cells the local caller
  cannot read stays redacted (proven byte-identical to a local run).
  `src/transport.ml`'s local-dir implementation; ssh stubbed (a clear
  "not yet", drops in behind the same signature later).

**Stage B** (docs/PLAN-m5-distribution.md "Remote placement" / "Q11-bis" —
DONE):

- ✅ **Remote placement**: the M1 handler (`Scheduler.dispatch_batch`) gains
  `Remote of string` and, over the stage-A transport, ships a data-closed
  batch to a named cluster member — an ORDINARY second `pp` invocation of
  the byte-identical program (own $HOME, `--schedule serial`), never a
  second "evaluate on a member" code path. Membership is ambient config
  (`~/.pp/cluster/members`/`$PP_CLUSTER_MEMBERS`), never `--grant` (LAW
  34's negative half preserved — still no location surface). Q11-bis
  (sandbox-inputs-by-hash) makes the member's own disk structurally
  unobservable for a pre-seeded cell (`Store.run_pins` consulted first,
  unconditionally, before any disk read); every failure mode (unreachable
  member, non-data-closed free var, a crashed member) degrades to local
  compute, never a wrong answer. `src/remote.ml`;
  `tests/048-remote-placement.sh`.

**Stage C (later, NOT this work):**

- **Domain distribution — the piece that makes M6's deploy claim real.**
  Placement handlers distribute `force`; the reconciler is runtime, not a
  node, and a process domain on host B can only be applied and re-observed on
  host B. The mechanism falls out of existing pieces: **host-qualified cell
  identity** (a process on host B is a *different cell* than on host A —
  naming world state, not a location surface) + a per-machine supervisor
  (`pp --watch --supervise`) pulling its desired-state value **by hash** from
  the synced store. M2's cell grammar + Phase-2 machinery + object sync; no
  new core surface.
- **Minimal, executable store GC**: root set = current desired-state roots +
  pinned islands; sweep unreachable objects/traces. A substrate for
  long-running services that can never delete anything is a prose asterisk on
  "devops-complete."

**Exit (runnable):**
1. ✅ The Phase-1 build across 2 machines (an 8-TU real-cc build, scaled down
   from 101 for a two-process-per-node test; local-dir transport, the same
   CI-loopback shape stage A's exit test uses), byte-identical materialized
   tree + desired-state hash vs serial. (`tests/048-remote-placement.sh`.)
2. ✅ A node built on machine A hits on machine B; `pp why` on B explains the
   hit with correct redaction. (`tests/047-cluster-sync.sh`, two `pp`
   process invocations differing only in `$HOME` standing in for two
   machines — see transport.ml's header for why.)
3. ✅ A tampered capability token is rejected (adversarial-suite lineage), and
   LAW 23b holds across the wire: B without authority over a cell in the
   transitive closure is not served the hit. (`tests/047-cluster-sync.sh`
   T2/T3.)
4. Store size stays bounded across N `--watch` iterations under GC.
   *Stage C — not started.*

### M6 — The devops-complete demonstration

All-library: a deploy island written in pp, zero new core surface. The §1
claim runs end-to-end, and the pinned-observation diagonal oracle runs in CI.
Convergence-time criteria budget the polling interval explicitly (fs-event
watchers are a non-goal; see §3).

**Exit (runnable):** every clause of §1, each proven by journal/exec counts
or store scans in the `tests/024` style, plus the diagonal oracle green
across all 2×2×3 combinations.

---

## 3. Explicit non-goals (do not gate M6; listed so they cannot pad milestones)

- LAW 3 binding-order canonicalization — spurious misses only; sound.
- D16 residual (non-`Failure` exception caching) — uncached = re-run; sound.
- Inline-nested cutoff — proven unnecessary at 101-TU scale.
- LAW 26 per-arg handler-cell refinement — coarser invalidation; sound.
- fs-event watchers vs polling — polling suffices at demo scale.
- Multi-tenant store hardening (E7) — deferred past M6 by the threat model.

Noted without fixing: D7's closure-free-var keying residual means the two
backends do not *share* store entries for closure-capturing nodes. This is
fine for the diagonal oracle — it compares result hashes, not keys — and must
not be "fixed" under deadline pressure.

---

## 4. Method — how this gets executed

- **Design before code.** Every milestone opens with a design pass (Q13+
  continuing DESIGN.md's numbering), hardened by adversarial review before
  implementation — as this plan itself was.
- **Verified by running.** Every claim lands with a falsifiable test
  (`dune runtest` + scripts), differential across both backends. The fuzzer
  grammar grows with every new surface, and deliberate generator exclusions
  are deleted when their bug is fixed (the D22 pattern).
- **Ledger discipline.** STATUS.md's D-ledger and SPEC.md's law table update
  in the same commit as the behavior. Laws this plan must flip to *holds*:
  23, 34, 35, 37, 38, and LAW 30's full form.
- **Walls protocol.** A wall stops work and triggers first-principles
  re-derivation; divergence from this plan is presented, never patched
  around. No flags, shims, special cases, or parallel paths to dodge a
  broken rule — a patched-around wall is treated as a failed deliverable
  regardless of sunk cost.
