# Threat model: cluster forcing (M5)

Scope: what a `pp` cluster — ≥2 machines under ONE owner, sharing store
artifacts and dispatch via `docs/PLAN-m5-distribution.md` — trusts. This is
the gate MASTERPLAN requires before M5 (= Phase 4) ships any distribution
code; stage A (this document's implementation) is the transport
abstraction, signed capability tokens, and by-hash artifact sync. Remote
placement, host-qualified domain distribution, and store GC are later
stages of the same milestone and are NOT covered by stage A's
implementation, though the adversaries and invariants below already bound
them.

This is deliberately narrower than a generic distributed-systems threat
model, and deliberately broader than `docs/THREAT-MODEL-islands.md`
(package-procurement trust for `git:`/`github:` fetches, a different
surface entirely). The two documents don't overlap: islands trusts a
*remote git host* to hand back source at first pin; this document trusts
*cluster members* — machines the SAME owner controls — to exchange store
artifacts and evaluation requests over a network the owner does not fully
control.

## Assets

- **Store integrity.** The content address IS the integrity check: a
  result, a blob, or a trace is only ever named by a hash derived from its
  own bytes (or, for a value object, the hash of the decoded value —
  `store.ml`'s header). Nothing about distribution may make it possible to
  have a hash-named artifact whose bytes don't match that hash.
- **Capability authority.** Capabilities are mint-once, root-only, and
  never widened downstream (SPEC LAW 22) — that invariant must survive
  going over a wire exactly as it survives `with-caps`/`cap-restrict`
  locally. LAW 23b (a cache hit is gated on the caller's authority over
  the transitive read closure) must hold **across the wire**, not just
  in-process.
- **Secret confidentiality.** Sealed bytes already never enter the store
  (M4, SPEC LAW 39: `VSealed` fails the node boundary and fails
  `Codec.encode_value`). M5 must not regress this — a sealed value must be
  exactly as impossible to ship over the transport as it is to write to
  `~/.pp/store/objects`.
- **Audit integrity.** `pp why` / the journal redact, never lie (LAW 23c).
  A synced trace must redact for the SYNCED caller's own authority, not
  leak what a broader token originally saw.

## Adversaries considered

- **A compromised or curious cluster member holding a valid token.** They
  can request anything their token's capabilities name, and nothing else —
  this is the ordinary LAW 23b boundary, generalized to "holds a token"
  instead of "holds `node_caps`". They cannot forge a broader token
  (T2) and cannot get a hit whose closure their token doesn't cover, even
  for a key whose bytes happen to already be sitting on disk somewhere
  they can read directly (T3 — LAW 23b is about AUTHORITY over the read,
  not about byte availability).
- **A network MITM.** Can drop, delay, or corrupt anything in flight
  between two honest members. Cannot forge a valid token (no secret) and
  cannot make a corrupted artifact accepted (T1 — re-hash on receipt is
  structural, not advisory). ssh's transport confidentiality is a BONUS
  this model never depends on: local-dir (plain file copy, no encryption
  at all) must be exactly as safe against this adversary as ssh, because
  the actual defenses (content hashes, HMAC, capability gating) live above
  the transport, not in it.
- **A malicious store payload.** An artifact that arrives with the right
  NAME but the wrong bytes (corrupted in transit, or planted by a
  compromised peer) must never be silently accepted into the receiving
  member's own store.

## Adversaries NOT considered

- **Multi-tenant stores / E7 hash-guessing exfiltration.** This is
  explicitly named out of scope per MASTERPLAN's M5 gate: a cluster is ONE
  owner's machines. Multi-tenancy (mutually distrusting members sharing
  one store) is cache-service product work, a different product with a
  different threat model, not language completeness. Sealed cells (M4)
  already cover the one tenant-adjacent risk a single-owner cluster
  actually has (a secret must not leak into shared, cacheable storage).
- **A malicious owner.** Whoever holds the cluster secret can mint any
  token for any capability — that's the trust model (identical to holding
  the root's `--grant` authority locally), not a threat this model
  defends against. An owner minting themselves an overbroad token is not
  a violation of anything; it's exactly as meaningful as running `pp`
  locally with a broad `--grant`.
- **Side channels beyond the content oracle.** Timing, cache-population
  side channels, and traffic analysis are out of scope, same posture as
  the rest of the codebase's security model (LAW 23b is about explicit
  authority checks, not about hiding whether a key was ever computed by
  anyone).
- **Procurement risk.** Covered by `docs/THREAT-MODEL-islands.md`; a
  different surface (fetching source, not syncing store artifacts).

## Trust anchors

- **ONE cluster secret**, minted by `pp cluster-init` on the root machine
  (`Token.init`, `src/token.ml`): 32 bytes from Cryptokit's secure RNG
  (`Cryptokit.Random.secure_rng`), hex-encoded, written to
  `~/.pp/cluster/secret` with mode 0600 via `O_CREAT|O_EXCL` (refuses to
  overwrite an existing secret — no silent rotation that would invalidate
  every outstanding token). Alongside it, `~/.pp/cluster/id` — a bare
  cluster-id label, not secret, embedded in the clear in every token so a
  token minted for cluster X is rejected by cluster Y even if (implausibly)
  it shared bytes with X's own tokens.
- **Distribution is out of band** — the operator copies both files to
  other cluster members by hand (scp, config management, whatever the
  operator already uses to distribute ssh host keys). `pp` never
  transmits either file over any transport this document covers; there is
  no "join the cluster" network protocol in stage A. This is the identical
  posture to an ssh host key: losing the secret means re-minting AND
  redistributing, and a member without a copy simply cannot mint or verify
  tokens — not a soft degradation, a hard capability boundary.
- **v1 has no per-member asymmetric identity.** HMAC-SHA256 via Cryptokit
  (already a project dependency, used for content hashing — no new crypto
  surface) is symmetric: every member holding the secret can both mint and
  verify. No adversary in this model needs non-repudiation (there is no
  "which member said this" dispute to resolve — a single owner trusts
  every member they've handed the secret to, exactly as they trust every
  machine they've copied an ssh private key to). Asymmetric PKI is
  rejected for v1 for this reason (see PLAN-m5-distribution.md
  "Rejected").

## Falsifiable claims

Each is an adversarial test, exercised end-to-end in `tests/047-cluster-sync.sh`
via two (or three) `pp` process invocations differing only in `$HOME` — a
process-level stand-in for distinct machines, sharing a "world" directory
the way the CI loopback local-dir transport does (see `src/transport.ml`'s
module header for why this shape, not a true single-process dual-store, is
used).

- **T1 — synced artifacts are re-hash-verified before use; mismatches are
  refused, never silently accepted.** `Transport.ingest_object`/
  `ingest_blob` decode/hash the received bytes and compare against the
  claimed name BEFORE calling `Store.store_object`/`store_blob` — there is
  no other function in `transport.ml` that writes a remote-sourced
  artifact into the local store. `ingest_trace_lines` rejects any line
  that fails to parse under the exact local grammar (traces have no
  self-describing content hash — their name is a node key, not a hash of
  their own bytes — so structural validity is the receive-time analog).
  Tested: a corrupted object, a corrupted blob, and a truncated trace file
  each cause `--transport-pull` to exit nonzero naming the artifact,
  never a partial or silent accept.
- **T2 — tampered/expired/wrong-secret tokens are rejected before any
  serve.** `Token.verify` checks MAC, then cluster id, then expiry, THEN
  parses capabilities — a forged token never reaches the capability
  parser, and `Transport.decide` calls `Token.token_to_caps` before
  touching `Store.hit` at all, so a rejected token never causes a single
  byte to move (`serve_hit`'s push calls live only inside the `DHit`
  branch — structurally unreachable from a `DDeny`). Tested: a flipped MAC
  byte and a negative-TTL (already-expired) token are both denied, and
  the shared root is never even created.
- **T3 — LAW 23b holds across the wire: no hit is served whose transitive
  read closure the REQUESTING token's capabilities don't cover, even if
  the bytes are on local disk.** `Transport.decide` computes
  `authorized = cell_authorized_for (token_to_caps token)` and passes it
  to the UNCHANGED `Store.hit` — the exact same gate a local caller with
  narrow `node_caps` hits. A token covering an unrelated directory gets a
  MISS for a key whose trace reads a cell it doesn't cover, while a
  broader token gets a HIT for the identical key — proving it's the
  token's authority, not the key or the bytes' presence, that decides.
- **T4 — `pp why` over a synced trace redacts per the requester's own
  token/grant (LAW 23c), matching what a purely local run redacts.**
  Redaction is enforced entirely by `Store.hit`'s `authorized` predicate at
  READ time, independent of how the trace arrived — so a trace synced from
  a broad-token build, once on a member's disk, is redacted identically to
  a locally-built one when that member's own ambient grant is narrow.
  Tested: `pp why` under the same narrow grant, run once locally on the
  builder and once on the syncing member, produces byte-identical
  redaction markers (`<redacted unauthorized cell>`) and never names the
  real cell path in a `[why]`-tagged line either way. Defense in depth on
  top of this: `Transport.decide` additionally filters to only the
  trace(s) the SERVING token's own capabilities cover before pushing, so
  an unauthorized cell's path is never even copied across, not merely
  redacted after arrival.
- **T5 — sealed bytes never cross the transport.** Unregressed by
  construction: a node that touches a sealed value already fails at the
  EXISTING M4 node boundary (`a node may not return a sealed value`,
  `Codec.encode_value` returns `None` for `VSealed`) — there is nothing
  for `Store.hit` to ever find for such a key, so `serve_hit` can only
  ever answer MISS. Defense in depth: `Transport.decide` and
  `LocalDir.push_object` both explicitly re-check `Codec.encode_value`
  before shipping and hard-fail (naming the violation) rather than
  shipping on any doubt, even though this is unreachable given
  `Codec.decode_value`'s grammar has no code/capability/sealed
  constructor to produce in the first place. Tested: a recursive grep of
  everything the test touched — every node's store, the shared sync
  roots, every reply file — for the secret's distinctive bytes, after a
  program that attempts (and is refused) a sealed read.
- **T6 — placement never changes a key or a result hash** (the diagonal's
  placement axis; full remote placement is stage B, so this is proven for
  the piece stage A actually has: syncing, not scheduling). A node built
  independently on a third, never-synced member computes the SAME key
  (LAW 20: identity is `H(code, free-var value hashes)`, independent of
  where it's computed) and a byte-identical result object; the object
  synced via `serve-hit`/`recv-hit` onto a receiving member is also
  byte-identical to the builder's own copy.
- **T7 — GC under a concurrent parallel build: no crash, no wrong result,
  a subsequent rebuild is byte-identical.** Store GC is stage C, not
  implemented in stage A; T7 is listed here because the contract's
  threat-model gate names it, and it stays a live claim this document
  continues to bind once GC exists — it is NOT exercised by stage A's
  tests.

## What stage A is not

- **Not remote evaluation.** `serve-hit` answers "does this key already
  have a verified result you're authorized to see", nothing else. No code
  runs on a peer as a side effect of anything in this document; forcing a
  node on a remote member is stage B (remote placement).
- **Not a membership protocol.** There is no "join"/"leave" network
  operation; membership (who has a copy of the secret) is entirely an
  out-of-band, operator-managed fact, mirrored in ambient config for stage
  B's dispatch — never granted via `--grant` (an address/membership fact
  is not an authority ceiling, LAW 34's own distinction, PLAN-m5-
  distribution.md "Remote placement").
- **Not encrypted-by-us.** local-dir is plain file copy; ssh (stubbed this
  stage, `Transport.Ssh`) gets transport confidentiality for free from ssh
  itself, but this model never treats that confidentiality as
  load-bearing — every claim above holds even for local-dir's fully plain
  local file copy, which is deliberately the harder case CI exercises.
