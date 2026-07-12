# M5 design — distribution (threat model + architecture)

Architect pass + adversarial review; the implementation contract. Refs
against commit `ec9d981`. Includes the threat-model gate MASTERPLAN
requires. Implementation stages: A (transport+tokens+sync), B (remote
placement), C (host-qualified domains + GC).

## Threat model — cluster forcing (the gate)

- **Scope:** ≥2 machines, ONE owner, sharing store artifacts and dispatch.
- **Assets:** store integrity (the content address IS the integrity check);
  capability authority (mint-once, root-only, never widened downstream);
  secret confidentiality (sealed bytes already never enter the store — M4;
  M5 must not regress this); audit integrity (why/journal redact, never lie).
- **Adversaries:** a compromised/curious member holding a valid token; a
  network MITM (ssh confidentiality is a bonus, never a dependency); a
  malicious store payload. **Explicitly out of scope:** multi-tenant stores
  / E7 hash-guessing (one owner; cache-service product work); a malicious
  owner (they hold the mint — the trust model, not a threat); side channels
  beyond the content oracle; procurement risk (islands doc).
- **Trust anchor:** ONE cluster secret, minted by `pp cluster-init` on the
  root machine, distributed out of band (the operator's problem, like ssh
  host keys). v1 has no per-member asymmetric identity — HMAC-SHA256 via
  cryptokit (already a dep); no adversary here needs non-repudiation.
- **Falsifiable claims** (each an adversarial test): T1 synced artifacts
  re-hash-verified before use, mismatches refused; T2 tampered/expired/
  wrong-secret tokens rejected before any serve; T3 LAW 23b across the
  wire — no hit served whose transitive closure the REQUESTING token's caps
  don't cover, even if the bytes are on local disk; T4 why over synced
  traces redacts per the requester's token (LAW 23c); T5 sealed bytes never
  cross the transport (grep everything that moved); T6 placement never
  changes a key or a result hash (the diagonal's placement axis); T7 GC
  under a concurrent parallel build: no crash, no wrong result, subsequent
  rebuild byte-identical.

## Transport

- Abstract: `push`/`pull` of hash-named artifacts (objects|blobs|traces) +
  a `control` request/reply channel in the store's canonical s-expr text
  (no new wire format — a captured message is inspectable like a trace).
- **Receiving side re-hashes EVERY item against its claimed name before
  accepting — the transport is untrusted for integrity** (the islands
  invariant generalized). This discharges T1/MITM/malicious-payload by
  construction.
- Implementations: **(a) local-dir** — a second store root on one machine;
  the CI loopback that makes every exit test runnable with zero infra;
  **(b) ssh** — scp/rsync for artifacts, `ssh <host> pp --worker-control`
  for control. Both behind one TRANSPORT signature in src/transport.ml.
- **Core, not userland** (the Q13 split applied): trusted mechanics =
  hash-verify, token mint/verify, subprocess invocation; policy (members
  file, which member, when) = ambient CLI/config. A userland transport
  would let library code decide whether to honor LAW 23b — a LAW-25-class
  violation.
- **Version handshake:** control exchanges build versions first (M2's
  dune-build-info); mismatch = refuse. Workers must run the same rebuilder
  — M1's lesson across a wire.

## Signed capability tokens

- Token = (caps in --grant grammar, cluster id, issued, expires, HMAC).
  **Never a pp value** — lives entirely at the CLI/transport layer, so it
  cannot be printed, laundered through a result, or cross the node
  boundary; there is no path into the value world.
- Verify at the serving member: MAC → expiry → parse caps with the SAME
  parse_grant parser → use as `Store.hit ~authorized:(cell_authorized_for
  caps)`. **Zero new authority code** — the hit gate and cap_subseteq are
  reused verbatim with a wire-verified capability list standing where
  node_caps stands locally. Redaction (23c) is already parameterized on the
  same predicate and survives sync for free.

## Remote placement (--schedule remote:<member>)

- **Data-closed nodes only:** every free var's forced value encodes under
  Codec (the existing non-data predicate at a new decision point). Non-
  data-closed nodes stay local silently (the degrade-to-serial posture).
- **No code crosses the wire.** The remote holds byte-identical program
  source (verified by tree hash — island pinning reused); given identical
  source + identical free-var data + pre-seeded pins, its own
  node_key_of/vm_node_key computes identical keys (T6/LAW 20).
- **Advisory responsibility partition (adversarial-review amendment):**
  the dispatcher ships the batch's key set + pins + source hash; the
  remote runs the same program and computes the keys it's responsible for,
  BUT computes any dependency it needs regardless of partition. Duplicate
  computation across machines is SOUND (identical keys, deterministic
  identical results — LAW 37; R9 absorbs it) and bounded by partition
  quality; correctness never depends on the partition. No "force only key
  K" surface exists (rejected for the same reason as M1).
- Membership = ambient config (~/.pp/cluster/members or env), NOT --grant
  (an address is not an authority ceiling — LAW 34's own distinction).

## Q11-bis — sandbox-inputs-by-hash (the snapshot barrier, remote only)

Before remote dispatch the dispatcher pre-observes the granted source
scope (tree-observe machinery reused), ships {cell-id -> blob-hash} + the
bytes, and the remote **pre-seeds Store.run_pins from the wire before
anything runs** — a pre-seeded cell is served from the pin, never from the
remote's own disk: the remote cannot observe dispatcher paths at all.
`tool:` cells are deliberately NOT pre-seeded (the remote's own cc is a
legitimate distinct observation — the M2 posture). LAW 20 unaffected (the
free var is the path string); LAW 21 traces are interchangeable with
locally-produced ones (the cross-machine-hit exit); LAW 23b stays
orthogonal (pins solve integrity, tokens solve authority — the codebase's
existing validity/authority separation).

## Host-qualified domain distribution

- The desired map generalizes ONE level: {host -> {domain -> desired}}.
  A member (`--member-name <n>`, explicit — never inferred from hostname)
  indexes its slice and calls the UNCHANGED Domains.run_all.
- Syncs: the desired-state value object by hash + the blob: refs it names.
  Does NOT sync: fenced actions (root-only by construction), journals
  (per-machine audit logs; aggregation deferred).
- kill -9 convergence = the local supervisor's existing story verbatim —
  the reconciler re-observes reality every pass regardless of where the
  desired value came from. M5 adds a new SOURCE for the value, no new
  mechanism.
- file:<host>:/proc:<host>: cells activate M2's reserved grammar — naming
  world state, not a location surface (LAW 34 negative half intact).

## Store GC (pp gc — explicit, never automatic)

- Roots: last N epochs' desired-state root hashes (a new epoch journal
  entry records each pass's root object hash — the one honest bookkeeping
  addition) + their transitive blob: refs; the islands cache is a SEPARATE
  lifecycle, never touched.
- **Mark by replay** (load-bearing finding: traces do NOT record
  child-keys — Q8 names it "still to come" — so there is no on-disk node
  graph to walk): re-run the last N root programs against the warm store,
  hits-only, recording every trace/object/blob touched as live; sweep the
  rest. The child-keys store-format bump is the documented escape hatch if
  replay proves slow — deliberately not taken now.
- Safety under concurrency: delete-time re-check of the roots manifest +
  a creation-time grace period (over-retention is always safe; deletion of
  live data is the only hazard — the tests/038 soundness shape).
- Bound test: N --watch iterations with churn — bounded with gc, visibly
  growing without; plus the T7 concurrent-GC stress.

## Exit tests

1. 101-TU build across two stores via local-dir transport in CI:
   byte-identical desired hash + tree vs serial (extends tests/024).
2. Cross-machine hit: built on A, hits on B; why on B redacts per a
   narrower token (extends tests/019's assertions).
3. Tampered token refused (T2); LAW 23b across the wire (T3).
4. GC bound + T7 concurrency stress.
5. Diagonal gains `remote` as a placement value.

## Rejected

ssh as a userland domain (library code deciding LAW 23b); --grant member:
(address ≠ authority); asymmetric PKI v1 (no adversary needs it); child-
keys format bump for GC alone; heuristic predictive file shipping
(a wrong guess silently observes wrong bytes — whole-scope pre-observation
is coarse-but-sound, the Q2 posture); automatic GC; fresh-pp-per-key
(M1's rejection, unchanged).

## Residuals

Whole-scope pre-observation cost on huge grants (coarse-but-sound);
replay-marking is O(epochs); HMAC blast radius = the cluster secret
(same trust as --grant's root mint, now signature-shaped); the version
handshake wire format left to implementation.
