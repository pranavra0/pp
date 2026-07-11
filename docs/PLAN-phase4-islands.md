# Handoff: Islands — fetch, pin, cache, content-address (D2 / Phase 4)

**Goal:** implement D2 — Islands as a real content-addressed module system
(fetch a remote/local source tree, pin it by a verified content hash, cache
it under `~/.pp/islands`, and make island imports become node boundaries whose
cache key depends on the pinned content) — and close D2.

**Why this shape:** D2 is the last discrepancy in the ledger that is named but
does nothing (`island` does a local `open_in`, the pin is ignored,
`--update` sets a flag that is never read, `island-fetch` is identity).
Unlike fenced (Phase 2) and parallel (Phase 3), Islands live in Phase 4, which
is "gated on a written threat-model doc." This plan splits Islands into the
deterministic, threat-model-light half (local `file:` islands + a real,
content-verified pin store + node keying) and the network half
(`git:`/`github:` fetch) that requires a *narrow* threat-model note about what
running pp grants to a remote git host. The two halves can ship
independently; the first half is fully testable offline today.

---

## 1. What islands are

An **island** is a module that lives elsewhere — a git repo, a URL, a local
directory — referenced by URI and materialized into the store before
evaluation, so that the program's identity depends on the *content* of the
dependency, not on a mutable ref that can move under you. From
[DESIGN.md](DESIGN.md) §1 and the node definition:

> a suspended strict computation created only at explicit boundaries:
> `(node e)`, `(defnode …)`, **island imports**.

and from [SPEC.md](SPEC.md) LAW 24:

> `load` / `import` / `island` / stdlib and module resolution are the
> loader's reads, bounded to the program's source roots and the store. They
> run under the interpreter's runtime authority, are tagged `runtime` in
> traces, and are **excluded** from user capability accounting.

The contract (GLOSSARY, STATUS D2, ROADMAP Phase 4):

- An island URI names an *external* source; pp resolves it to a local path
  **before** evaluation.
- The resolved tree is **content-addressed**: its identity is `H(tree-contents)`,
  not `H(uri)`. Moving the ref changes the content → cache invalidation.
- The pin is recorded under `~/.pp/islands`; reads of pinned source go through
  `Runtime.loader_read` and become `runtime:file:` trace cells (validity yes,
  hit-time authority no — LAW 24, Q6/D8c).
- An island import is a **node boundary**: a node that imports an island is
  keyed on the pinned content (via the loader-read cells), so bumping the pin
  recomputes; a stable pin gives a stable cache hit.
- Fetching is a real effect (network/process) and is **opt-in by a CLI flag**,
  not ambient. It runs under runtime (loader) authority, not a user
  `--grant net`/`--grant process` capability — the loader is not a user
  effect (LAW 24). The narrow threat model for the network half governs this.

---

## 2. Current state

`src/island.ml` exists but is inert:

```ocaml
let update_mode = ref false                  (* set by --update; NEVER read *)
let pin_path uri = Filename.concat (pin_dir ()) (Digest.string uri ^ ".pin")
let resolve uri = … read one line from pin_path …
let write_pin uri pin / clear_pin uri …
```

The evaluator and compiler both handle `EIsland (uri, _)` *as a local file
load through `Runtime.loader_read uri`*:

- `src/evaluator.ml` (`EIsland`): `let source = Runtime.n uri in … eval_expressions`.
- `src/compiler.ml` (`EIsland`): `emit st (LOAD_FILE (intern_name st uri))`,
  and the VM's `LOAD_FILE` calls the same `Runtime.n`.

So today `(island github:foo/bar v1)` is exactly `(load "github:foo/bar v1")`
against the filesystem and fails (`No such file or directory`) unless the URI
string happens to name a real local path under a source root. Both backends
fail identically, which is why `tests/005-island-test.pp` "passes" the
differential suite today *by erroring the same way on both sides* — it pins
nothing about islands actually working.

Other facts grounding this plan:

- `primitives.ml` registers `island-fetch` as **identity** (`VString uri → VString uri`).
- `main.ml` parses `--update` and sets `Island.update_mode := true` and never reads it.
- The fuzzer (`tools/fuzz.ml`) and `docs/TESTING.md` explicitly **never
  generate** `island` (line 198 / fuzz.ml line 26) because the form is
  non-deterministic today.
- `Runtime.loader_read` bounds reads to source roots + cwd + `~/.pp` and
  records `runtime:file:<path>` cells; `~/.pp/store/blobs/<sha256>` is the
  existing CAS ingest for raw bytes (Q11). The pin store lives at
  `~/.pp/islands` (sibling of `store`), currently keyed by `Digest.string uri`
  — not content-addressed, not verified.

---

## 3. Recommended design

### 3.1 URI surface

Keep the reader form unchanged — `(island <uri> [pin])` already parses a
symbol/string URI plus an optional version/pin (reader.ml `parse_island`).
Give the URI a scheme and make `island.ml` dispatch on it:

```
(island file:relative-or-abs-path)            ; local, no network
(island git:<url>#<ref>)                      ; remote git
(island github:<owner>/<repo>#<ref>)          ; remote github sugar
(island github:<owner>/<repo>#<ref> <pin>)    ; explicit pin overrides ref
```

- `file:` resolves to a local path through `loader_read`; it is loader-
  authorized (source roots + cwd + `~/.pp`), same as `load`. **No network.**
- `git:`/`github:` require opt-in fetching (§3.5).
- The optional `<pin>` is the content hash to demand (the verified tree hash).
  If absent, pp resolves the ref to a pin on first fetch and freezes it.

Rejected alternative: make the second argument a symbolic version like
`v1.0` (as the current reader test writes `v1.0` today). Keep accepting it as
a free-form pin string, but normalize: a 64-hex SHA is a *pin*; anything else
is a *ref hint* used only at fetch time.

### 3.2 Pin store, content-addressed

Replace `~/.pp/islands/<Digest(uri)>.pin` with a two-file layout under
`~/.pp/islands`:

```
~/.pp/islands/
  index                 ; append-only: <uri>\t<pin>\t<ref-resolved>\t<ts>
  src/<pin>/            ; the materialized source tree, content-addressed by pin
    entry.pp
    …
```

- **`pin`** = `H(canonical-tree-hash)`, where canonical-tree-hash digests a
  deterministic serialization of the tree (sorted file list, each file's
  `hash_string` of its bytes — reuse `Types.hash_string`/Cryptokit SHA-256,
  the same hasher used for `~/.pp/store/blobs`). This is the identity.
- `src/<pin>/` is immutable; two trees with the same pin are the same dir.
- `index` records the latest *resolved* ref per URI (so `--update` can move
  it; without `--update`, the index is the frozen source of truth — hermetic
  and offline-reproducible). This index is the **lockfile** analogue.

Pin verification (anti-tamper): on every resolve, re-hash the on-disk
`src/<pin>/` and assert it equals `pin`. A mismatch is a hard error, never a
silent re-fetch — that's the content-addressing invariant.

### 3.3 Import as a node boundary

Per DESIGN, island imports are explicit node boundaries. Concretely:

- `(island …)`, when standalone, evaluates the materialized `entry.pp` and
  returns its exports as a `VEnvMap` (mirror `ELoadModule`, not `ELoad`):
  `(import (island file:./lib))` merges the island's bindings into scope.
- Reads of the pinned source go via `Runtime.loader_read` (existing path),
  producing `runtime:file:~/.pp/islands/src/<pin>/entry.pp` cells.
- Additionally record one synthetic cell per island resolve —
  `island:<uri>` with observed-hash = `pin` — so that the *URI → pin* mapping
  is itself a validity input. A node that imported
  `github:foo/bar@main` invalidates exactly when the index's pin for that URI
  changes, independent of whether the on-disk path moved.
  - This cell is `runtime:`-tagged (authority-exempt) like the file cells.
- Because the resolved path encodes the pin and the synthetic cell carries
  it, a node key (`H(code ‖ free-var value-hashes)`, LAW 20) already varies
  with the pin via the env-hash (the imported module value's hash), and the
  trace varies via the synthetic cell. Both halves of validity are covered
  without adding the pin into the node *key* (keeping key = identity, not
  observations — consistent with LAW 21/33].

### 3.4 Backend parity

The fetch/resolve/path-computation must run **before** the per-backend
mechanism, identically, so both backends see the same resolved path and pin:

- Move URI parsing + resolution into `Island.resolve : uri:string -> pin:string option -> resolved_path * pin` (shared).
- The evaluator's `EIsland` branch and the VM's `LOAD_FILE`/new `ISLAND` op
  *both* call `Island.resolve` first, then `Runtime.loader_read` the resolved
  path. The compiler may emit a dedicated `ISLAND <uri-cp-idx>` opcode so the
  VM records the synthetic `island:` cell before the `LOAD_FILE`-equivalent
  read — keeping op inventories in sync (VM must mirror `runtime:island:` cell
  recording the tree-walker does).
- Node keys stay shared: both backends key a node importing an island on the
  same free-var value hash (the `VEnvMap` produced from the same pinned bytes)
  and the same store entry. `tests/014` parity discipline carries over
  unchanged.

### 3.5 Fetch authority and the network half

Fetching touches network + runs `git` — a real effect. It is **not** ambient:

- New CLI flag `--fetch-islands` (and `--update` continues to imply it):
  - **off (default):** island resolution may only consult `~/.pp/islands`
    (the existing index + `src/<pin>/`). A URI whose pin is absent is a
    **hard error**: *(island: missing pin for <uri>; run `pp --fetch-islands`)*.
    This is the hermetic default — a build is reproducible exactly because pp
    refuses to phone home.
  - **on:** pp may spawn `git` to obtain the ref, hash the tree, write
    `src/<pin>/` and append to `index`. The flag is a runtime authority, **not**
    a `--grant net`/`--grant process` user capability — fetching is the
    loader's job (LAW 24), so it is not counted against user caps and not
    memoized into node traces as a user observation.
- `--update` is made real: it means "re-resolve every URI's ref to the latest
  pin and re-pin," implying `--fetch-islands`. Without `--update`, the index
  is frozen even if the remote moved.
- Threat model (network half): a *short* note in `docs/THREAT-MODEL-islands.md`
  covering: what a malicious git host can do (run during clone via hooks/fsmon
  — mitigate by `git clone --no-local --filter=blob:none` into a temp dir,
  never executing any hook), DNS/TLS trust, and the assertion that the pinned
  content (not the ref) is pp's identity. This is intentionally narrower than
  the Phase 4 *cluster-forcing* threat model (LAW 34/35); it is package-
  procurement trust, like Bazel/Nix fetchers.

### 3.6 `file:` islands: the first, fully-offline half

`file:` needs no `--fetch-islands`: a `file:./path` (or absolute) URI is
resolved through `loader_read` against the existing loader authority (source
roots + cwd + `~/.pp`). Pinning a `file:` island = hash the directory tree,
write `index` + symlink/copy into `src/<pin>/` (or, for a true local read,
record the pin but keep reading in place — *copy* is safer for hermeticity
since the source can mutate; caching the bytes makes the snapshot stable).
This half delivers 80% of the value (content-addressed deps, real node
keying, real `--update` lockfile) with **zero network and no threat model**,
so it ships first and is the bulk of the test plan.

---

## 4. Implementation tasks (TDD order)

Do these in order, running `dune runtest` and the fuzzer after each major
step. The offline half (Tasks 1–6) is fully testable now; Task 7 (network)
is gated behind the §3.5 threat-model note.

### Task 1 — URI type + scheme dispatch (offline)

- `src/island.ml`: add `type scheme = File | Git | GitHub` and
  `type uri = { scheme; raw; locator; ref_hint; pin : string option }`.
  Add `parse_uri : string -> uri` and `parse_island_arg : string -> uri option`.
- Reject an unknown scheme with a clear error (`island: unknown scheme …`).
- Update `primitives.ml`'s `island-fetch` to return the **parsed** uri
  (still a string repr for now; it stops being identity in Task 4).
- Test (`tests/035-islands.sh` subcase): `(island file:./x)` parses;
  `(island noscheme:foo)` errors identically in both backends.

### Task 2 — content-addressed pin store (offline)

- Replace `pin_path uri`/`resolve`/`write_pin` with the `index` + `src/<pin>/`
  layout (§3.2). Add `Island.canonical_tree_hash : dir:string -> pin` and
  `Island.verify_pin : dir:string -> pin -> (unit, string) result`.
- `Island.pin_local : path:string -> pin` hashes a local dir, copies it into
  `src/<pin>/` (refuse overwrite; idempotent if hash matches), appends `index`.
- `Island.resolve` reads `index`; if the URI is pinned, returns the existing
  pin path (verifying the on-disk tree hash matches — tamper check).
- Missing pin with fetching disabled → the hard error in §3.5.
- Unit-test the tree hash is stable across re-hashes and across move; test the
  tamper check (mutate a byte inside `src/<pin>/`, expect resolve to error).

### Task 3 — `EIsland` resolves through `Island` (offline, both backends)

- `src/evaluator.ml` `EIsland`: call `Island.resolve uri pin`, then
  `Runtime.loader_read resolved_path`, then evaluate as a **module**
  (`VEnvMap` exports, like `ELoadModule`), not a bare `ELoad`. Add a
  `Runtime.record_read ("runtime:island:" ^ uri) pin` synthetic cell.
- `src/compiler.ml` `EIsland`: emit a new `ISLAND <uri-idx> <pin-idx-opt>` op
  (mirrors `LOAD_MODULE_FILE` but resolves via `Island` first).
- `src/vm.ml` `ISLAND`: same `Island.resolve` + `loader_read` + module-eval +
  synthetic cell, mirroring the tree-walker exactly.
- `Runtime` gains `island_fetch_enabled : bool ref` (set by `--fetch-islands`).
- Test: `(import (island file:./lib))` binds an exported name; the same import
  inside a `node` records both a `runtime:file:` and `runtime:island:` cell;
  editing the source *outside* the pin does nothing (it's pinned), bumping the
  pin (re-running with the source changed and `--fetch-islands` / a forced
  re-pin) invalidates the node; both backends agree.

### Task 4 — `--update` / `--fetch-islands` semantics for `file:` (offline)

- `main.ml`: keep `--update` setting `Island.update_mode`; add
  `--fetch-islands`; wire both to the new `Runtime.island_fetch_enabled`.
- For `file:`, "update" = re-hash the source dir and re-pin if the hash
  changed (writes a new `index` line + new `src/<pin>/`). Without the flag,
  the existing index pin is frozen.
- Test: a node caches on the old pin; running `pp --update` bumps the pin;
  the node recomputes; running plain `pp` again (no `--update`) keeps using
  the new pin and hits. Both backends agree.

### Task 5 — lockfile / offline reproducibility (offline)

- The `index` file *is* the lockfile. Add `pp island-pins` (read-only) and a
  documented convention that checking `~/.pp/islands/index` into a project's
  pinned store location yields reproducible offline builds.
- Test: copy a populated `index` + `src/` into an isolated `$HOME` containing
  *no network access* and *no original source dir*; a `file:`/`git:` island
  resolves purely from the pin store; both backends agree.

### Task 6 — make `tests/005-island-test.pp` actually pin content (offline)

- Rewrite `tests/005-island-test.pp` to use `file:` over a real local dir
  created in the shell harness (or fold it into `tests/035`), so the test
  asserts *real* island behavior (binding + cache invalidation) instead of
  the current "both backends error identically." Update the harness in
  `scripts/run-tests.sh` if a shell wrapper is needed (mirror `tests/025`).

### Task 7 — `git:`/`github:` fetch (network, threat-model-gated)

- Write `docs/THREAT-MODEL-islands.md` (§3.5) first. Do not commit fetch code
  without it.
- `Island.fetch_git : uri -> pin` shells out to `git clone --no-local …` into
  a temp dir, checks out `ref_hint`, canonical-tree-hashes, copies into
  `src/<pin>/`, appends `index`. Never executes hooks.
- Gated strictly on `Runtime.island_fetch_enabled`; disabled → hard error on
  a missing pin (never silent network).
- Test (`tests/035` network subcase, **opt-in**, skipped without a
  `PP_ISLAND_NET_TEST=1` env): create a *local* bare git repo as the remote
  (no real network), point a `git:` URI at it, assert fetch + pin + import +
  cache invalidation; assert that with fetching disabled the same program
  errors cleanly; both backends agree. Keeping the "remote" a local bare repo
  means the CI test exercises the *git plumbing* deterministically without
  touching the internet.

### Task 8 — fuzzer coverage for the offline half

- `tools/fuzz.ml`: under a new guarded grammar (`--grammar islands` or a
  sampled branch inside `full`), generate `(import (island file:./<local>))`
  over a fixed fixture dir of small `.pp` islands, so the differential
  property — tree-walker and VM agree on island-importing programs — is
  continuously exercised. Keep `git:`/`github:` *out* of the fuzzer (real
  nondeterminism). Update the "Never generated" note in `docs/TESTING.md`
  to "Network islands never generated; pinned `file:` islands are sampled."

### Task 9 — documentation pass

See section 7.

---

## 5. File-by-file changes

| File | Change |
|------|--------|
| `src/island.ml` | Real URI type + `parse_uri`; `index` + `src/<pin>/` pin store; `canonical_tree_hash`; `verify_pin`; `pin_local`; `fetch_git` (Task 7); `resolve` consults index + verifies; `update_mode` finally read. |
| `src/runtime.ml` | Add `island_fetch_enabled : bool ref`; add `record_island_read uri pin` (records the `runtime:island:` cell, gated like `record_config_read`). Keep reads through existing `loader_read`. |
| `src/evaluator.ml` | `EIsland`: resolve via `Island.resolve`, `loader_read` the path, evaluate as a module (`VEnvMap`), record the synthetic island cell. |
| `src/compiler.ml` | `EIsland`: emit new `ISLAND (uri-cp-idx, pin-cp-idx-opt)` opcode; keep `LOAD_FILE` for `ELoad`. |
| `src/vm.ml` | `ISLAND` op mirrors the tree-walker's `EIsland` (resolve → `loader_read` → module-eval → synthetic cell). |
| `src/types.ml` | Add `ISLAND of int * int option` to the opcode variant (and its opcode-count/parity plumbing); `hash_expr` for `EIsland` already includes uri+pin — verify pin now means *content* hash if present. |
| `src/main.ml` | Wire `--update` to `Island.update_mode` (now read) and `--fetch-islands` to `Runtime.island_fetch_enabled`; `--update` implies fetch. |
| `src/primitives.ml` | `island-fetch`: return parsed uri (or, better, rename/deprecate to `island-resolve` returning `{"pin","path"}`) — only meaningful once fetch lands; keep both backends identical. |
| `tests/035-islands.sh` + `tests/035` fixtures | New shell harness; mirror `tests/020`/`tests/025` conventions (isolated `$HOME`, both backends, `assert NAME PAT present|absent`). |
| `docs/THREAT-MODEL-islands.md` | New, Task 7 prerequisite — the narrow network-fetch threat model. |

---

## 6. Test plan

New file: `tests/035-islands.sh` (plus any `.pp` fixtures in `tests/035/`).

Register it in `scripts/run-tests.sh` after the `034-fenced-effects` block with
an `--- Islands (D2) suite ---` header.

Subcases (each asserted in *both* backends unless noted):

1. **Parse & scheme dispatch.** `(island file:./x)` parses; unknown schemes
   error identically; an explicit hex pin is accepted; a non-hex second arg
   is treated as a ref hint.
2. **`file:` import binds exports.** `(import (island file:./lib))` brings an
   exported name into scope; using it logs the value.
3. **Pin is content-addressed.** Resolve the same `file:` island twice; the
   recorded `<pin>` is stable; a copy reads as the same `src/<pin>/`.
4. **Tamper check.** Mutate one byte inside `src/<pin>/`; the next resolve
   errors (content hash mismatch), never silently re-uses.
5. **Island import is a node boundary.** A `(node … (import (island file:./lib))
   use)` caches; editing the *source dir outside the pin* does nothing (it's
   pinned); re-pinning with `--update` (new content) invalidates and
   recomputes; the synthetic `runtime:island:` cell is the validity lever.
6. **`--fetch-islands` gating (offline analog).** With fetching *disabled*, an
   island whose pin is absent errors cleanly; with it enabled, a `file:`
   island pins and resolves; never silent.
7. **Offline reproducibility.** Drop the populated `index` + `src/` into an
   isolated `$HOME` with the original source dir removed; the island resolves
   and nodes hit — proving the lockfile is self-sufficient.
8. **VM parity throughout.** Every assertion runs under `--bytecode` and must
   match the tree-walker (the `--diff` discipline; node keys for imported
   islands must share store entries, à la `tests/014`).
9. **Network (opt-in, local bare-repo fake remote).** Guarded by
   `PP_ISLAND_NET_TEST=1`: a `git:` URI pointing at a local bare repo fetches,
   pins by commit, imports, and invalidates on `--update`; disabling fetch
   errors exactly once. Skipped in default CI to keep the suite hermetic.

Re-run the full `tests/010`–`tests/024`, `tests/028`–`tests/034` battery after
touching `Runtime`/store/keying — island cells are a new trace kind and must
not perturb LAW 21/23b/33 cache decisions.

---

## 7. Documentation updates (do these as you go, not at the end)

Update docs in the same commit as the code that makes them true.

- [ ] `docs/STATUS.md`
  - D2 row: change "**Open (Phase 4).** island does a local open_in …" to
    "**Fixed (offline half: `file:`). / Network half: `git:`/`github:` live
    behind `--fetch-islands`**" once each task lands.
  - Add bullets under "What actually works" describing the content-addressed
    pin store, the `runtime:island:` cell, island imports as node boundaries,
    and `--fetch-islands`/`--update` semantics.

- [ ] `docs/SPEC.md`
  - Add a sentence to LAW 24 noting that `island` is now a real resolve (not a
    naive local read) and that the synthetic `runtime:island:<uri>` cell is the
    validity carrier for the URI→pin mapping.
  - Add a short dedicated subsection (or a new LAW if you prefer a normative
    pin) under §12 (Location transparency) making explicit: *identity is the
    pinned content, not the URI*; *fetching is opt-in runtime authority, not a
    user capability*; *a missing pin with fetch disabled is a hard error*. Cross
    reference §0 ("Identity is structure").
  - Update Appendix A status table row for whatever LAW you cite.

- [ ] `docs/ROADMAP.md`
  - Phase 4 line: change "Islands that actually fetch/pin (… D2). `--update`
    made real" to reflect the split; mark the offline half **done**, the network
    half done behind `--fetch-islands` + the threat-model note.
  - Keep the cluster-forcing / LAW 34/35 threat-model gate wording unchanged
    (that gate is *not* this one).

- [ ] `docs/ARCHITECTURE.md`
  - Replace the "Not yet wired — `island.ml` stub" paragraph with the real
    `Island` responsibilities (parse, resolve, verify, fetch).
  - File-by-file table: update the `src/island.ml` row from "(stub)".
  - Add `--fetch-islands` and clarify `--update` in the CLI surface list.

- [ ] `docs/GLOSSARY.md`
  - Rewrite the **island** entry from "*(mostly planned)*" to the real
    definition (URI → content-addressed pin → node-boundary import; fetch
    opt-in).
  - Cross-link **reconciler** is unaffected; link the **node**, **content
    hash**, and **loader authority** entries.

- [ ] `docs/DESIGN.md`
  - Update the "island imports" mention in the node definition (§2.1) to state
    the boundary is the materialized content, not the URI.
  - Add a paragraph under the loader-authority section (§3) describing
    `--fetch-islands` as runtime authority for procurement, distinct from user
    `net`/`process` caps.

- [ ] `docs/TESTING.md`
  - Update the "Never generated" line: network islands never generated; pinned
    `file:` islands are sampled in the fuzzer (post-Task 8).
  - Document `tests/035-islands.sh` and the opt-in network subcase env.

- [ ] `docs/THREAT-MODEL-islands.md` (new, Task 7 prerequisite)
  - Malicious-host risk during clone, mitigations (no hooks, temp dir, hash
    verification), and the identity-not-ref invariant.

---

## 8. Definition of done / D2 close

All of these must be green:

- [ ] `dune runtest` passes, including new `tests/035-islands.sh` (offline
      subcases; network subcase skipped without `PP_ISLAND_NET_TEST=1`).
- [ ] Fuzzer passes with the new `file:` island grammar branch:
      `dune exec ./tools/fuzz.exe -- --grammar full --count 1000`.
- [ ] `tests/005` now asserts real island behavior (not identical-error).
- [ ] A node importing a `file:` island caches and is invalidated *only* by a
      pin bump (content change + `--update`), never by source-dir mutation.
- [ ] Tamper inside `src/<pin>/` is detected and errors.
- [ ] Offline reproducibility: `index` + `src/` alone (no original source,
      no network) resolves and hits.
- [ ] `--fetch-islands` gating: missing pin errors cleanly when disabled.
- [ ] (Network half, gated) `git:` fetch + pin + invalidation works against a
      local bare-repo fake remote; never executes git hooks.
- [ ] Both backends agree on every island assertion (shared node keys and
      store entries for imported islands).
- [ ] All docs listed in section 7 updated; D2 row in `STATUS.md` reflects
      reality; `THREAT-MODEL-islands.md` exists before any fetch commit.

A closed D2 does **not** imply Phase 4 itself is closed — cluster forcing,
remote object sync, and signed capability tokens (LAW 34/35) remain gated on
the broader Phase 4 threat model. Islands are package procurement; they close
only D2.

---

## 9. Risks and open questions

- **Identity vs ref.** The hardest call: should `(island …)` with a ref hint
  and *no* explicit pin be allowed to resolve at all without a locked index
  entry, given that the ref can move? Recommendation: NO — an unresolved ref
  with fetch disabled is the hard error of §3.5; the *first* `--fetch-islands`
  run freezes it into `index`, after which plain `pp` is hermetic. This keeps
  the LAW-21/LAW-37 honesty rule (declared nondeterminism; identity =
  content) literally true.
- **Pin format.** Reusing `Types.hash_string` over a canonicalized tree
  serialization keeps one hasher in the project (the store/blobs one). Don't
  invent a second hash.
- **VM opcode parity.** Adding `ISLAND` bumps the opcode count and the
  `--diff` micro-suite; mirror the VM's cell recording precisely so a node
  importing an island hits the *same store entry* in both backends (D7
  discipline). Watch `tests/014`.
- **Pin verification cost.** Re-hashing the tree on every resolve is O(tree).
  For v1 accept the linear cost; a cached `src/<pin>/.verified` marker
  (content hash of a manifest) can short-circuit in a later pass — but the
  *first* resolve after a change must re-verify.
- **Fuzzer nondeterminism.** Only ever generate `file:` islands over a
  *fixed* fixture set; any path the fuzzer materializes must be stable across
  the two backend runs *in one process pair*. Pin writes go to an isolated
  `$HOME` (mirror `tests/020`).
- **Threat-model scope creep.** Resist folding cluster-forcing trust into
  this note. Islands trust a *content hash*; a malicious host cannot escape
  that because pp never trusts the ref after first pin — and never runs
  fetched code as part of fetch (only `git`'s plumbing, no hooks).
- **`island-fetch` primitive.** Decide whether the primitive survives or is
  replaced by `island-resolve` returning `{"pin","path"}`. Keep whichever the
  two backends agree on; do not leave it as identity.

---

## 10. Keeping docs in sync while you work

Update docs in the same commit as the code change that makes them true:

1. Implement a behavior.
2. Add or update the test that pins it.
3. Update the relevant doc paragraph(s) immediately (STATUS D2 row, the SPEC
   law you cite, ARCHITECTURE's "Not yet wired" list).
4. `dune runtest` + fuzzer.
5. Commit.

Do not leave "island does a local open_in (planned)" prose alive once the real
resolve exists — that is exactly how D2 spent this long as inert code with
docs describing a future. When the offline half lands, strike the stub
language the same day. The `--update` flag in particular must not be set-but-
unread for another release; wire it in Task 4 or remove it.

---

## 11. Suggested first commit

```
island: parse URIs into a typed scheme; content-address the pin store

Replaces the inert `~/.pp/islands/<Digest(uri)>.pin` stub with a typed
URI (file|git|github) and an index + src/<pin>/ layout pinned by a
canonical tree hash. `file:` islands resolve and import through
`loader_read` as a node boundary (VEnvMap exports, runtime:island:
validity cell); `git:`/`github:` still error with "fetch disabled"
pending the threat-model note. `--update` is now read (re-pins on
content change). No network yet.

Adds tests/035-islands.sh (offline subcases, both backends).
```

Then proceed task-by-task through section 4, Tasks 2→6 offline first,
Task 7 (network) only after `docs/THREAT-MODEL-islands.md` exists.