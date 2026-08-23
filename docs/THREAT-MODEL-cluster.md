# Threat model: cluster forcing

This document sets out what a pp cluster trusts. A cluster is two or more
machines under one owner, sharing store artifacts and dispatch work with
each other.

The gate pp must pass before shipping any code that distributes work across
a cluster. This document covers the transport abstraction, signed capability
tokens, and syncing artifacts by content hash. Remote placement and
host-distributed domains build on this foundation, are not implemented here,
and may not violate anything stated here.

Narrower than a general distributed-systems threat model, and disjoint from
[THREAT-MODEL-islands.md](THREAT-MODEL-islands.md) (package procurement for
`git:`/`github:` fetches). Islands trusts a remote git host to return the
right source at pin time; this document trusts cluster members to exchange
store artifacts and evaluation requests over a network the owner does not
fully control.

## Assets

Cluster forcing must protect these assets:

- store integrity: the content address is the integrity check. pp names a
  result, a blob or a trace only by a hash of its own bytes (for a value
  object, the hash of the decoded value; see `lisp/runtime/store.lisp`).
  Distribution must never let a hash-named artifact's bytes fail to match
  that name
- capability authority: pp mints capabilities once, only at the root, and
  never widens them downstream (LAW 22). This must hold exactly the same
  way over the network as it does locally through `with-caps` and
  `cap-restrict`. A cache hit must only be granted when the caller's
  authority covers everything the result transitively read, whether the
  request comes from the same process or over the wire (LAW 23b)
- secret confidentiality: a sealed value fails at the node boundary and
  fails `Codec.encode_value` (LAW 39), so pp already refuses to let it
  reach the store. Cluster forcing must not weaken this: shipping a sealed
  value over the transport must be exactly as impossible as writing it to
  `~/.pp/store/objects`
- audit integrity: `pp why` and the journal redact information they must
  not show, and they never lie about what happened (LAW 23c). When a trace
  has synced to another member, it must redact according to that member's
  own authority, not leak what the broader token that built it originally
  saw

## Adversaries considered

This model considers these adversaries:

- a compromised or curious cluster member holding a valid token. This
  member can request anything its token's capabilities name, and nothing
  else. This is the same boundary LAW 23b sets locally, extended from
  "holds the right capabilities" to "holds a token naming the right
  capabilities". The member cannot forge a broader token (tested as claim
  T2, below) and cannot get a cache hit for a key whose closure its token
  doesn't cover, even if the bytes already sit on disk somewhere it can
  read directly. LAW 23b gates authority over the read, not whether the
  bytes happen to be available (tested as claim T3)
- a network attacker sitting between two honest members. This attacker can
  drop, delay or corrupt anything in flight. Without the cluster secret, it
  cannot forge a valid token, and it cannot get a corrupted artifact
  accepted: pp re-hashes every artifact on receipt as a structural check,
  not an optional one (claim T1). Encrypting the connection over ssh is a
  bonus this model never relies on. Copying files in plain text over a
  local directory, with no encryption at all, must be exactly as safe
  against this attacker as ssh, because the real defences (content
  hashes, the token's MAC check, and capability gating) sit above the
  transport, not inside it
- a malicious store payload: an artifact that arrives with the right name
  but the wrong bytes, whether corrupted in transit or planted by a
  compromised peer. The receiving member must never accept this silently
  into its own store

## Adversaries not considered

This model does not consider these adversaries:

- multi-tenant stores and hash-guessing exfiltration attacks that use cache
  hits and misses as an oracle. This is out of scope by definition: a
  cluster is one owner's machines, already sharing full trust. Letting
  mutually distrusting members share one store is a different product with
  a different threat model, not a gap in the language. Sealed cells
  already cover the one risk a single-owner cluster does face here: a
  secret must never leak into storage that is shared and cacheable
- a malicious owner. Whoever holds the cluster secret can mint a token for
  any capability. That is the trust model itself, identical to holding the
  root's `--grant` authority on a single machine, not a threat this model
  defends against. An owner who mints themselves an overly broad token has
  not violated anything; it carries the same weight as running pp locally
  with a broad `--grant`
- side channels beyond the content oracle. Timing attacks, cache-population
  side channels and traffic analysis are out of scope. This matches the
  rest of the codebase's security model: LAW 23b checks explicit
  authority, and does not try to hide whether a key was ever computed by
  anyone
- procurement risk: fetching source code, rather than syncing store
  artifacts. This is a different surface, covered in
  `docs/THREAT-MODEL-islands.md`

## Trust anchors

- one cluster secret. `pp cluster-init` mints it on the root machine
  (`lisp/kernel/cap-token.lisp`): cryptographically random, written to
  `~/.pp/cluster/secret` mode 0600, never silently overwritten (silent
  rotation would invalidate every issued token). Alongside it sits
  `~/.pp/cluster/id`, a non-secret label embedded in the clear in every
  token, so one cluster's tokens are rejected by another.
- distribution happens out of band. The operator copies both files to members
  by hand (scp, configuration management, whatever distributes ssh host
  keys). pp never transmits either over any transport covered here, and there
  is no join protocol. Lose the secret: re-mint and redistribute. A member
  without a copy cannot mint or verify — a hard capability boundary.
- no per-member identity in this version. HMAC-SHA256 via the runtime's
  existing cryptographic provider: no new crypto surface. HMAC is symmetric;
  every member can mint and verify. No adversary here needs non-repudiation —
  a single owner trusts members the way they trust machines holding an ssh
  private key. Asymmetric PKI was rejected: complexity against no adversary
  this model considers.

## Falsifiable claims

Each claim below is an adversarial test. All run end-to-end in
`tests/047-cluster-sync.sh`, using two or three `pp` process invocations
that differ only in their `$HOME` directory. This stands in for distinct
machines at the process level, sharing a "world" directory the way the
continuous-integration loopback local-directory transport does. The runtime
distribution boundary keeps this process-level setup separate from a
single-process, dual-store setup.

- claim T1: pp re-hashes every synced artifact before use, and refuses any
  mismatch rather than silently accepting it. `distribution-transport-push`
  decodes and hashes the received bytes, then compares the result
  against the claimed name, before ever calling the object or blob
  repository. No other transport function writes a remote
  artifact into the local store. Traces have no self-describing content
  hash: their name is a node key, not a hash of their own bytes, so
  trace ingest instead rejects any line that fails to parse under
  the exact local grammar, the receive-time equivalent of a hash check.
  Tested: a corrupted object, a corrupted blob, and a truncated trace file
  each make `--transport-pull` exit with a nonzero status naming the
  artifact, never a partial or silent accept
- claim T2: pp rejects a tampered, expired or wrong-secret token before
  serving anything. `verify-capability-token` checks the MAC first, then the cluster
  id, then the expiry, and only then parses the capabilities, so a forged
  token never reaches the capability parser. The serve-hit command resolves
  a token's capabilities before it ever touches cache policy, so a rejected
  token never moves a single byte: the push path runs only
  inside the branch for a granted hit, and is structurally unreachable
  from the denial branch. Tested: a flipped byte in the MAC and a token
  with a negative time-to-live (already expired) are both denied, and the
  shared root directory is never even created
- claim T3: LAW 23b holds across the network. pp never serves a hit whose
  transitive read closure isn't fully covered by the requesting token's
  capabilities, even when the bytes already sit on local disk.
  `%command-serve-hit-command` computes the authorized set from the token's
  capabilities and applies it to each trace's read closure, the same gate a local
  caller with narrow capabilities hits. A token covering an unrelated
  directory gets a miss for a key whose trace reads a cell outside that
  directory, while a broader token gets a hit for the identical key. This
  proves the token's authority decides the outcome, not the key or whether
  the bytes happen to be present
- claim T4: `pp why`, run over a synced trace, redacts according to the
  requester's own token or grant, matching what a purely local run redacts
  (LAW 23c). Redaction is enforced entirely by cache policy's authorized
  predicate at read time, independent of how the trace arrived. So a trace
  synced from a build with a broad token, once on a member's disk, redacts
  identically to a trace built locally there, provided that member's own
  ambient grant is narrow. Tested: running `pp why` under the same narrow
  grant, once locally on the builder and once on the syncing member,
  produces byte-identical redaction markers and never names the real cell
  path either way. As defence in depth on top of this, the serve-hit command
  also filters to only the traces the serving token's own capabilities
  cover before pushing, so an unauthorized cell's path is never even
  copied across, not merely redacted after it arrives
- claim T5: sealed bytes never cross the transport. This holds by
  construction, not just by testing: a node that touches a sealed value
  already fails at the existing node boundary (a node may not return a
  sealed value, and `encode-value` returns nothing for one), so
  there is nothing for cache policy to find for such a key, and the serve-hit
  can only ever answer with a miss. As defence in depth, both the push and
  receive paths re-check `encode-value` before
  shipping anything, and hard-fail, naming the violation, rather than
  shipping on any doubt, even though this path is unreachable, since the
  decoder's grammar has no constructor that could produce a code,
  capability or sealed value in the first place. Tested: after a program
  attempts and is refused a sealed read, a recursive search of everything
  the test touched (every node's store, the shared sync roots, every reply
  file) for the secret's distinctive bytes finds nothing
- claim T6: placement never changes a key or a result hash. Remote placement
  sends only data-closed node misses. The member computes the same key and
  result as a local worker because identity uses code and free-variable
  hashes, not location (LAW 20).
- claim T7: garbage collection of the store, running beside a parallel build,
  causes no crash or wrong result. `pp gc` marks by replay and protects recent
  and concurrent data. `tests/050` checks this.

## What this document does not cover

This document does not cover:

- arbitrary remote evaluation: the serve-hit command answers one question only: does
  this key have a verified result that the caller may read? Remote placement
  runs only data-closed node misses through the separate `remote:MEMBER`
  scheduler path.
- a membership protocol: there is no network operation to join or leave
  the cluster. Membership (who holds a copy of the secret) is entirely
  an out-of-band fact the operator manages, mirrored in ambient
  configuration for remote placement's dispatch logic. It is never granted
  through `--grant`: an address or membership fact is not an authority
  ceiling, the same distinction LAW 34 draws between location and syntax
- encryption performed by pp itself: the local-directory transport is a
  plain file copy. A future remote transport
  gets its confidentiality for free from ssh itself, but this model never
  treats that confidentiality as load-bearing. Every claim above holds
  even for the local-directory transport's fully plain file copy, which is
  deliberately the harder case the continuous-integration tests exercise
