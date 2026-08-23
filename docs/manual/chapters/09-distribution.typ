#import "/lib.typ": example

= Distribution

The thesis of this manual: no local/remote distinction at the language
surface. No `remote-eval`, no placement annotation, no node-pinning form —
ever. `force` is the only execution primitive; where it runs is a scheduler
decision, chosen by flag, never written into the program. A program is
byte-identical on one core, eight, or a cluster. The moment location becomes
syntax, callers hard-code topology and the deployment boundary is back inside
the language.

`--schedule serial | parallel:N | race:N | remote:<member>` selects the
policy. `parallel:N` forks workers across cores; `race:N` runs N redundant
copies and takes the first; `remote:<member>` ships work to another machine.
Same feature, different fan-out. The scheduler is result-transparent — it
changes where and when, never the answer — so it appears in no cache key and
no trace. `pp --check` proves it: any non-serial policy forced serial against
the same store must match hashes.

Libraries can select the same handlers through `stdlib/runtime.pp`. They can
also provide a pure custom scheduler policy over data-only job descriptors.
The policy returns a mode and a complete partition of job indexes; the runtime
still owns execution, cancellation, and remote transport.

== Identity is location-independent

Location can be the scheduler's business because identity is a content hash: a
node's key hashes its code and input values, never where or when it ran. Two
machines evaluating the same node compute the same key and byte-identical
result with no coordination. Results move by that hash: published into a shared
store, pulled by name, re-hashed on receipt. The content address is the
integrity check.

The transcript uses two throwaway `HOME`s as two machines with separate stores
and a shared directory as transport. Machine A builds a node; machine B, given
the same program, computes the identical key without talking to A. A publishes
the result by hash, B pulls it byte-identical; one flipped byte in transit and
B rejects it.

#example("dist-by-hash", sh: true)

The machines never agreed on a key; they derived the same one from the code.
A build computed "here" is usable "there" because results are addressed by
what they are, not where they were produced.

== Transport boundary

The by-hash sync, re-hash-on-receipt, signed-token authority checks, and remote
placement are implemented and tested over a local-directory transport. Two
separate `~/.pp` stores stand in for two machines. No SSH implementation or
generic transport plugin ships today. A remote provider can carry the same
canonical artifacts and signed requests; integrity and authority remain runtime
checks rather than promises made by the connection.

== Host-qualified identity

Host-qualified identity names world state ("the greeter running on B"), not a
dispatch location: a process on host B is a different cell than the same
process on host A.
The desired-state map generalizes one level, from `{domain → desired}` to
`{host → {domain → desired}}`; `--member-name B` selects host B's slice and
hands it to the unchanged reconciler. A member is just
`pp --watch --supervise --member-name B`: the single-machine supervisor,
verbatim, fed a slice of a cluster-wide value. Naming a host absent from the
map is a hard error, not a silent no-op.

Membership is ambient configuration: which machines exist, and where their
stores are. It is read from `~/.pp/cluster/members` or `$PP_CLUSTER_MEMBERS`. It
is deliberately not a capability. An address is not an authority ceiling, the
same distinction the language draws everywhere between location and permission.
Authority to act across the cluster travels separately, as a signed token minted
from the same `--grant` grammar you use locally.

== Trace merge, audit, and growth

A result carries its verifying trace, so syncing a result syncs its evidence:
the pulled `(cell, hash)` observations are re-verified against the local world
before a hit. Authority checks survive the crossing — a hit served over the
wire is gated on the requesting token's authority over the trace's read
closure, exactly as locally. A narrow caller cannot launder a broad read
through a cached aggregator just because bytes arrived by network, and `pp why`
on a pulling machine redacts identically to a purely local run. Audit redacts;
it never lies.

A shared store grows, so growth is bounded explicitly. Each pass records its
desired object and forced node keys as a wanted root; `pp gc` walks the same
durable edges used by validation and stabilization and sweeps only unreachable
objects, traces, blobs. Never automatic; a grace period protects concurrent
writes, a changed root manifest stops deletion.
