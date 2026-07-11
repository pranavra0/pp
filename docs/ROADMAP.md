# pp ROADMAP — the phased plan

Where pp is going, as falsifiable phases. For what works *today* see
[STATUS.md](STATUS.md); for *why* the design is shaped this way (principles,
the resolved open questions Q1–Q12, prior art, a worked example) see
[DESIGN.md](DESIGN.md).

The thesis: build systems, package managers, provisioners, and orchestrators
all manage one substrate — a dependency graph with caching and effects. pp
makes the language *be* that substrate. Phases nail it in order: hermetic +
incremental builds first, then reactive services, then parallelism, then
distribution.

---

## Phase 0 — A core that cannot lie ✅ DONE

Truth before features. Every rock moved and **verified by running the tests**,
not by trusting docs — which is how the D21 slot-reuse regression and the
D6/D17 content-key soundness holes (that the docs had implied were fine) got
caught and fixed. See the ledger in [STATUS.md](STATUS.md).

Highlights: stack-safe evaluator; mutual `let`; `node`/`defnode`/`delay` as
reader special forms; `def-fexpr` cut; total `quote`/quasiquote; SHA-256;
both-backend type enforcement; shared `Runtime`; `--grant` capability
bootstrap; path-component-aware capability checks; sound content-addressed key
(D6/D17); dune build + `dune runtest`.

**Exit criteria — all met:**
1. Fuzzer zero divergence — core exits clean; full grammar sampled ≥1500 cases,
   zero mismatches/crashes.
2. `dune runtest` (both backends diffed per file) — green.
3. Adversarial capability suite — green (constructor removal, path-component
   scope, gated `slurp`).
4. Stack-safe 10⁶ recursion — verified in both backends.
5. Every Phase-0-claimable SPEC law has a passing test (`tests/007`). (LAW 29
   still drops locations for arbitrary top-level expression errors — D12.)

---

## Phase 1 — The incremental hermetic build engine (the keystone) ✅ DONE

- Persistent CAS + **trace-set** store wired into `force` (Q8); failure
  caching; transitive hit-time capability check with the runtime/traced split
  (Q6); snapshot-as-CAS-ingest (Q11).
- Effect-interposed observed-read tracking with a **coarse-cell soundness floor
  + depfile/toolchain-closure refinement** (Q2); a `run` process effect with a
  per-node sandbox (D13); a C depfile adapter; the `toolchain:cc` closure cell.
- Desired-state output tree + filesystem-domain reconciler v1: atomic
  materialization, verify-after-write, journal (Q4); domain stratification;
  user `write-file` restricted to sandbox scratch.
- `pp why` (capability-filtered); `--no-cache`; `--check` (double-build
  determinism audit → flags volatile nodes).
- Rewrite `build.pp` for real.

**Exit (falsifiable), on a ≥100-file C project and on pp itself:**
1. Null rebuild executes **zero** external processes (journal proves it), <1s.
2. `touch shared.h` (no content change) → zero recompiles (cutoff).
3. Edit one `a.c` → exactly `a.o` + link re-run (trace logs prove it).
4. `rm -rf build/` → fully restored from the store, zero compiler invocations.
5. Comment-only header edit → dependents recompile, link cut off.
6. `pp` builds itself via `build.pp`.
7. A capability scoped to `src/` **cannot** get a cache hit on a node whose
   transitive trace closure touched a path outside `src/` under user authority.

**✅ EXIT CRITERIA MET** — verified by running, not prose:

- **1–5 and 7** on a generated **101-TU C project** built by a real
  `build.pp` (nodes + `run-dep` + blobs + reconcile), every claim proven by
  journal exec counts (`tests/024-phase1-exit.sh`, in `dune runtest`):
  null rebuild = 0 processes in ~130ms; mtime-only touch = 0 recompiles;
  one `f5.c` edit = exactly 1 compile + 1 link; `rm -rf build/` = restored
  byte-identical with 0 tool re-runs; comment-only header edit = 101
  recompiles, link cut off; no process grant = no hit served, no exec run.
  The VM shares the compile cache (data-keyed nodes) and null-rebuilds at
  zero processes too.
- **6** — `pp` builds itself via a `build.pp` (`scripts/build-self.sh`):
  the dune invocation is one node keyed on the `tree:src` cell — cold run
  builds, null rebuild is a hit and never executes dune. Whole-project
  granularity (per-file OCaml compilation stays dune's job); run outside
  `dune runtest` (dune cannot nest).
- **Real-world replication** — Lua 5.4.7 (`scripts/build-lua.sh`): 33 TUs +
  link cold in ~2.2s, null rebuild 157ms/0 processes, comment-only `lua.h`
  edit recompiles all TUs with the link cut off (objects byte-identical at
  -O2), `rm -rf build/` restores a byte-identical working interpreter.

The machinery behind it, each pinned by a test: trace-set store + LAW-20
keying + failure caching + transitive hit gate + VM parity (`tests/010`–`014`),
config/handler trace cells (`tests/015`), value-keyed cutoff (`tests/016`),
`run` + per-node sandbox (`tests/017`), journaled reconciler (`tests/018`),
capability-filtered `pp why` / `--no-cache` / `--check` (`tests/019`), bounded
loader authority with runtime cells (`tests/020`), snapshot-as-CAS-ingest
(`tests/021`), the depfile adapter (`tests/022`), and blob-hash desired
values (`tests/023`).

**Residuals carried forward** (documented, none gating the exit):
the `closure-cap-req` fast path is *unnecessary by measurement* (101-node
null rebuild ~130ms, well under the 1s budget); the `toolchain:cc` closure
cell is *superseded* by per-file depfile `tool:` cells (DESIGN Q2);
node-captured caps are *vacuous* until in-language attenuation exists
(DESIGN Q11); uniform realpath canonicalization (LAW 23), LAW 26's per-arg
handler-cell refinement, LAW 38's containment half, and inline-nested cutoff
+ the reverse-edge graph move to Phase 2.

---

## Phase 2 — The reactive gear (push scheduler, same rebuilder) 🚧 IN PROGRESS

- ✅ Reverse-edge index over traces; fs watchers + process-supervision cells;
  push `stabilize`; `--once` vs `--watch` as the only build/service difference.
- ✅ Process-domain reconciler (start/stop/restart on spec-hash change); fenced
  effects + intent journal (Q3), reconciler-only.
- ✅ `pp graph` (now that the reverse index exists).

**Exit (falsifiable):**
1. ✅ A pp service killed with `kill -9` converges back within 1s.
2. ✅ Editing its config rewrites config and restarts exactly the affected process.
3. ✅ The same program file with `--once` provisions once and terminates.
4. ✅ Introspection shows `--watch` and `--once` hitting the **same node keys in
   the same store** — the store-level collapse, made auditable.
5. Kill the reconciler mid-apply of a fenced action → on restart it is not
   re-performed and the unknown-status policy fires.
6. ✅ Differential test: push `stabilize` result hashes equal the pull-scheduler
   reference (re-force-from-root) on a battery of cell-change sequences.

**Groundwork landed:** `pp --watch` (polling pull-in-loop, clears in-memory
state between iterations so the persistent store's trace-verification handles
incremental rebuild), `pp --once` (explicit one-shot), `pp graph` (lazy
cell→node dependency graph from stored traces), true push `stabilize`
(dirty-propagation via a reverse-edge index that resets only dirty thunks —
the optimization that avoids re-walking all traces from root) are live with
`tests/031` and `tests/032`. The process-domain reconciler is live with
`pp --supervise` / `pp --watch --supervise`, start/stop/restart on spec-hash
change, zombie reaping, and journal intent/done pairs (`tests/033`). Fenced
effects remain.
---

## Phase 3 — Parallelism (process pool)

- `parallel` schedule handler over local worker **processes**; the
  global-mutable-state refactor into `Runtime` this forces is the real
  deliverable. Result-transparent handler discipline validated by `--check`.

**Exit:** the Phase-1 build runs across N local workers with byte-identical
outputs to the serial build and a measured speedup; "run on 3, take first" is a
handler swap with zero language-surface change.

---

## Phase 4 / stretch — Distribution + ecosystem (gated)

Cluster forcing, by-hash object sync, signed capability tokens with remote
enforcement — **only after a written threat-model doc**. Islands that actually
fetch/pin (git; content-addressed by commit+tree; `--update` made real, D2).
LSP, cache GC. Self-hosting reconsidered. Exit criteria drafted
when Phase 3 closes.

---

## Maturity track — from research artifact to public project

Orthogonal to the phases (work here can proceed in parallel with Phase 2+);
this is what separates "the thesis is proven" from "strangers can use it" —
the threshold for a Lua-style public site. The engine phases prove claims;
this track removes the reasons a newcomer would bounce off. Nothing here is
speculative: every item below was hit in practice while building Phase 1.

### 1. Language ergonomics

- ✅ **The `(def x v)` footgun — FIXED.** `def` with a non-list head is now a
  *value binding*: the RHS is evaluated at definition time (unforced — a
  `delay`/`node` RHS binds the thunk) and `(defnode x e)` binds the node
  thunk of `e`. Blocks give defs letrec* scope with a
  `referenced before its definition` error for premature use and a read
  error for duplicate block defs; the top level stays sequential for value
  defs. Identical in both backends (SPEC LAW 4; `tests/025-def-value.sh`;
  fuzzer `stmt_def_value`). Two pre-existing VM scope holes surfaced while
  fixing it are documented as D22.
- ✅ **Error messages — FIXED.** Runtime errors escaping any top-level form
  now report that form's `file:line` in both backends (D12 closed, LAW 29
  holds); arity errors name the function being called, capability errors
  name the operation, unbound-symbol text is backend-identical, and
  uncaught errors print as a single `pp: error: …` line with exit 1
  (`tests/027-error-messages.sh`). Residual: errors inside a `load`ed file
  cite the loading form's line, not the inner file's.
- ✅ **REPL quality — DONE.** Multi-line input (paren-balanced, string- and
  comment-aware, `..>` continuation prompt); history persisted to
  `~/.pp/history` with Up/Down recall; a raw-mode line editor (arrows,
  Home/End, Ctrl-A/E/K/U/W) on a tty; results print deep-forced; `:why
  on|off` toggles the node-cache explainer; `:help`/`:quit`. Piped sessions
  print no prompts or banner (`echo '(+ 1 2)' | pp` emits exactly `3`), and
  the VM REPL keeps its globals across lines (it used to reset per line).
  Scriptable parts pinned by `tests/029-repl.sh`; editing verified by hand.
- ✅ **Type annotations — CHECKED.** Per-parameter annotations
  (`(def (f x : int) …)`, `(fn [x : int] …)`) now desugar in the reader into
  located force-time checks ahead of the body, so both backends enforce them
  identically and errors cite the definition site (SPEC LAW 32;
  `tests/026-param-types.sh`; fuzzer `stmt_param_typed_def`).

### 2. Standard library

~40 primitives and one list file was not a stdlib. Phase-1's `build.pp` had
to inline `map`/`each`/`foldl` and grew `string-split`/`map-insert`/`blob-get`
mid-build. Landed since (all differential-tested, `tests/028`):

- ✅ **String ops** — `string-index`, `string-trim`, `string-sub`,
  `number->string`, `string->number` primitives; `string-join`,
  `starts-with?`, `ends-with?`, `lines` in `stdlib/string.pp`.
- ✅ **File predicates** — `file-exists?`, `dir?`: capability-gated (fs read)
  and recorded as precise `stat:` trace cells (presence/kind, not contents),
  so a node that probed a path recomputes exactly when it appears/vanishes —
  including re-hitting an absence trace when the path is deleted again.
- ✅ **argv/env access** — `(argv)` returns everything after `--` on the pp
  command line (an `argv:` cell); `(env-get "NAME")` returns the variable or
  nil (an `env:NAME` cell, absence included).
- ✅ **Exit-code control** — `(exit N)` terminates with status N via a
  dedicated exception: never memoized as a failing trace, never decorated.
- ✅ **Assoc/map utilities** — `map-keys`/`map-vals`/`map-remove` primitives;
  `map-has?`/`map-merge` in `stdlib/map.pp`; `each`/`append`/`reverse`/
  `nth`/`drop`/`member?` added to `stdlib/list.pp`.
- ✅ **`assert`** — a reader form: `(assert cond [msg])` raises
  `assertion failed: <form> at file:line` (custom messages get the location
  appended), desugared to if+error so both backends enforce identically.

✅ **Milestone met**: the Phase-1 proof's fixture generator and both
drift-mutation steps ARE pp programs — `tests/gen-cproject.pp` emits the
101-TU C project and `tests/mutate-cproject.pp` performs the one-TU edit
(criterion 3) and the comment-only header append (criterion 5), invoked by
`tests/024-phase1-exit.sh`, which passes unchanged. The top-level pass/fail
oracle deliberately stays external (a test written in pp inherits the bugs
it hunts; this repo's history is the argument), and the mtime-only `touch`
stays shell (writing content would defeat it).

### 3. Portability

- The store serializes with OCaml `Marshal`: same-compiler-version,
  same-architecture only. Fine for a local cache, wrong for shared or
  long-lived stores — needs a versioned, portable object format (or at
  minimum a store-format version stamp that invalidates cleanly).
- Grants, cells, and loader bounds compare lexical paths; no realpath
  canonicalization (macOS `/var` vs `/private/var` already bites — LAW 23
  residual). Symlinked source trees are undefined behavior today.
- Linux CI. Everything to date is verified on macOS/arm64 only; `tree_hash`,
  sandbox dirs, `/usr/bin/cc` resolution, and the store all need a second OS
  proving them.

### 4. Releases

Versioning (the binary says `v0.1.0` unconditionally), a changelog, tagged
releases with tarballs, reproducible build instructions from a clean opam
switch, and CI that runs `dune runtest` + the fuzzer + `scripts/build-lua.sh`
on every commit. "Mature project website" mostly advertises that this
mundane layer exists and holds.

### 5. Documentation site

A Lua-style site is the *last* step, and its content should be executable:
the Phase-1 exit criteria, the Lua build, and (post-Phase-2) a
`--watch` demo are the pitch — runnable, not prose. SPEC/DESIGN/STATUS
already carry the substance; the site is a rendering of them plus a
tutorial that survives a beginner (§1's footguns are fixed).

**Threshold.** A public site stops being aspirational when: Phase 2 is
closed, ~~§1's footgun and error-message items are done~~ ✅, ~~§2's
milestone holds (pp-written fixture tooling)~~ ✅, CI is green on Linux, and
there is at least one tagged release a stranger can build from the tarball
alone. §1 and §2 are complete; portability (§3) and releases (§4) are the
remaining maturity blockers.
