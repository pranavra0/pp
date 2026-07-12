# M3 design — in-language capability attenuation (gates M4d)

Architect pass + adversarial review. The implementation contract. Line
numbers reference commit `0af6a7d`.

## Surface

- **`(current-capabilities)`** — zero-arg primitive, callable anywhere:
  reifies the ambient set as of the call as
  `VCapability (CapCompose !current_capabilities)`. Observation of the
  ceiling the code already exercises on every perform — never a mint
  (LAW 22). Rejected: a root powerbox binding (no `main` hook exists; raises
  load/module-boundary questions a plain primitive sidesteps) and named
  `--grant` bindings (new CLI surface, no added expressiveness).
- **`cap-restrict cap scope [mode]`** — gains the optional mode argument
  (`CapRestrict` gets `mode : fs_mode option`); requesting a mode wider than
  the underlying cap's is `Capability_error` ("cannot widen mode"), never a
  silent widen. `cap-compose` unions authority ALREADY HELD — the attack
  shape is composing with a *constructed* cap, categorically impossible
  because construction is impossible (D18).
- **`(with-caps cap-expr body)`** — new special form (EWithCaps, both
  backends, the EWithConfig/with_ref pattern; LAW 27 exception/tail-safe
  restore). REPLACES the dynamic ambient with exactly the requested cap for
  the body's extent, gated by `cap_subseteq requested !current_capabilities`
  — checked against the CURRENT ambient, not the root grant, so narrowing
  composes even when code lexically retains a broader value.
- **`effect` (the capability-union form) is REMOVED.** Its rule is
  `caps @ ambient` — a widening backdoor the instant cap values exist. It is
  vacuous today (nothing produces a cap value) and untested. Check
  tools/fuzz.ml: if any grammar arm generates `(effect ...)`, delete that
  arm in the same change. (`with-handler`/`perform` are unrelated and stay.)
- `cap_subseteq` implemented per-kind via the existing check functions; its
  CapRestrict arm requires fixing the latent `list_fs_paths` bug (scope
  should INTERSECT the underlying paths, not `Filename.concat` onto them —
  currently uncalled/untested code that becomes load-bearing here).

## The node boundary: authority crosses in NEITHER direction

The load-bearing danger is not cache identity — the hit gate (LAW 23b)
already re-derives authority from the caller. It is a node body EXERCISING
smuggled authority on a miss (principle 5: nodes must never write). Enforced
at independent layers:

1. **Free-var ban (import side):** at `node_key_of`/`vm_node_key`, if a free
   variable's forced value contains a `VCapability`
   (`Hasher.contains_capability` — structural walk, closure-env-aware with
   the existing cycle guard, does NOT force unforced thunks per LAW 14),
   raise `Capability_error`. Runs on every force (both functions already do).
2. **Result ban (export side — adversarial-review amendment):** in
   `run_node_body`, if the result contains a `VCapability`, raise
   `Capability_error` ("a node may not return a capability") before
   storing. Otherwise `(node (current-capabilities))` is an
   ambient-dependent result invisible to both key and trace — a determinism
   hole; and a broad cap could ride a result out to a narrower caller. The
   law becomes symmetric: authority may not cross the node boundary.
3. **Use-time gates (the actual security floor):** a cap that slips past 1
   via an unforced thunk (documented gap — deep-forcing would violate
   LAW 14) can only be USED via `with-caps`, whose ⊆-check runs against the
   node's own captured ambient — no escalation possible; every perform path
   is ambient-gated and takes no explicit cap argument (M4d's domain-write
   primitive MUST keep this property). Domain writes additionally hard-error
   inside node bodies via the existing `trace_stack` check (the fenced/LAW 31
   mechanism).

## Node capture (Q11's promise)

- `thunk` gains `node_caps : capability list`, populated at the two node
  construction sites (ENode eval; VM MAKE_NODE) from the ambient at
  creation.
- `force_node` (the single shared choke-point, both backends): hit gate uses
  `cell_authorized_for t.node_caps` (parameterized refactor of
  cell_authorized); miss recompute runs under
  `with_ref current_capabilities t.node_caps`.
- "Caller's capabilities" (LAW 23b) now means: the forcing thunk's
  `node_caps`, captured at this process's creation of this `(node e)`
  occurrence. Collapses exactly to today's per-process `--grant` set when
  `with-caps` is unused — tests/011/013/017 unaffected byte-for-byte.
- The differential test (impossible to write before with-caps): a node
  CREATED under a narrowed ambient, forced outside it under the full
  ambient, is still denied (capture-at-creation); a node created under the
  full ambient, forced inside a narrower with-caps, still succeeds (fixed at
  creation, mirroring lexical closure capture of every other value kind).

## M4d threading shape (sketch only; Q13 is M4's design pass)

Root: `(current-capabilities)` → `cap-restrict` to the domain →
`register-domain` (ordinary primitive, root scope) consumes the cap into a
core-side registry never re-exposed as a pp value. The reconciler invokes
the domain's apply under `with_ref current_capabilities [write_cap]` — the
with-caps mechanism from OCaml. apply is NOT a node (never key-resolved), so
the free-var ban doesn't touch it; a node built inside apply that tries to
close over a cap hard-errors via layer 1; the domain-write primitive is
ambient-gated + trace_stack-guarded via layer 3. `CapDomain` / `--grant
domain:<name>[:mode]` is M4d surface, not M3.

## Adversarial suite additions (capability-adversarial.sh, D18 lineage)

forge-from-print (printed cap is inert; nothing parses text→cap);
compose-does-not-resurrect (union of two narrowed views ≠ the broad root);
cap-restrict-mode-widen-rejected; with-caps-widen-rejected (lexically-held
broad value fails ⊆ inside a narrowed extent); with-caps tail-safe +
exception-safe (LAW 27 pattern); node-cap-capture-direct +
node-cap-capture-via-closure (layer 1, both backends);
node-cap-result-rejected (layer 2, both backends); the §capture differential
test both directions; effect-removed (unbound).

## SPEC changes

LAW 20: nodes' free variables may not contain capabilities (hygiene atop key
exclusion; soundness lives in use-time gates) and nodes may not RETURN
capabilities (symmetric boundary). New law (or LAW 22 addendum): with-caps
narrows to a held value, ⊆-checked against the CURRENT ambient. LAW 23b:
"caller's capabilities" defined as the forcing thunk's node_caps. Status
table rows updated accordingly.

## Rejected

Constant-hash caps in keys (soundness question was never identity);
unrestricted structural hashing as the only mechanism (does nothing at
miss-time execution); keeping `effect` alongside with-caps (widening
backdoor); deep-forcing the capture check airtight (violates LAW 14);
env-level has-cap flag (unforced let-thunks invisible at bind time).

## Known residuals

The layer-1 gap for caps hidden behind unforced thunks (documented; layers
2+3 are the floor). `list_fs_paths` fix is new load-bearing code with no
prior behavior to preserve. Performance of the containment walk piggybacks
existing hashing traversals — audit on the 101-TU build after landing.
